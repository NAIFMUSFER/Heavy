CREATE OR REPLACE FUNCTION public.jana_order_detail(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; o public.orders;
BEGIN
 u=public.jana_auth_user(p_token);
 SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 RETURN jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'payment_state',o.payment_state,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,'total_halalas',o.total_halalas,'collected_halalas',o.collected_halalas,'refunded_halalas',o.refunded_halalas,'cash_state',o.cash_state,'snapshot',o.snapshot,'created_at',o.created_at);
END$$;

CREATE OR REPLACE FUNCTION public.jana_rotate_delivery_code(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; o public.orders; code text; nowms bigint;
BEGIN
 u=public.jana_auth_user(p_token); nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.status<>'active' OR o.delivery_state='delivered' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 code=lpad((floor(random()*1000000))::int::text,6,'0');
 UPDATE public.orders SET code_hash=encode(digest(code,'sha256'),'hex'),code_attempts=0,code_expires_at=nowms+172800000 WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'delivery_code_rotated','customer_request',jsonb_build_object('delivery_state',o.delivery_state),nowms);
 RETURN jsonb_build_object('order_id',o.id,'delivery_code',code,'expires_at',nowms+172800000);
END$$;

CREATE OR REPLACE FUNCTION public.jana_picker_record_actual(p_token text,p_order_id text,p_line_id text,p_actual_base bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar; o public.orders; lines jsonb; line jsonb; newlines jsonb='[]'::jsonb; comp jsonb; planned bigint; old_total bigint; new_total bigint; subtotal bigint:=0; delivery bigint; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint; found boolean:=false;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 lines=o.snapshot->'lines';
 FOR line IN SELECT value FROM jsonb_array_elements(lines) LOOP
   IF line->>'line_id'=p_line_id THEN
     found=true;
     IF jsonb_array_length((line->'components')::jsonb)<>1 THEN RAISE EXCEPTION 'actual_weight_not_supported'; END IF;
     comp=(line->'components')->0;
     planned=((comp->>'base_qty')::bigint)*((line->>'qty')::bigint);
     IF p_actual_base<=0 OR p_actual_base>planned THEN RAISE EXCEPTION 'invalid_actual_weight'; END IF;
     old_total=(line->>'line_total_halalas')::bigint;
     new_total=greatest(1,round(old_total::numeric*p_actual_base::numeric/planned::numeric)::bigint);
     line=jsonb_set(line,'{actual_base_qty}',to_jsonb(p_actual_base),true);
     line=jsonb_set(line,'{line_total_halalas}',to_jsonb(new_total),true);
     line=jsonb_set(line,'{actual_recorded_at}',to_jsonb(nowms),true);
   END IF;
   subtotal=subtotal+COALESCE((line->>'line_total_halalas')::bigint,0);
   newlines=newlines||jsonb_build_array(line);
 END LOOP;
 IF NOT found THEN RAISE EXCEPTION 'line_not_found'; END IF;
 delivery=COALESCE((o.snapshot->>'delivery_fee_halalas')::bigint,0);
 UPDATE public.orders SET snapshot=jsonb_set(jsonb_set(o.snapshot,'{lines}',newlines,true),'{subtotal_halalas}',to_jsonb(subtotal),true), total_halalas=subtotal+delivery WHERE id=o.id;
 UPDATE public.orders SET snapshot=jsonb_set(snapshot,'{total_halalas}',to_jsonb(total_halalas),true) WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'actual_weight_recorded',p_line_id,jsonb_build_object('actual_base_qty',p_actual_base,'total_halalas',subtotal+delivery),nowms);
 RETURN (SELECT jsonb_build_object('id',id,'number',number,'total_halalas',total_halalas,'snapshot',snapshot) FROM public.orders WHERE id=o.id);
END$$;

CREATE OR REPLACE FUNCTION public.jana_finalize_picking(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar; o public.orders; alloc jsonb; rec record; need bigint; take bigint; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 FOR rec IN
   WITH ln AS (SELECT value l FROM jsonb_array_elements(o.snapshot->'lines')),
   req AS (SELECT c->>'stock_id' stock_id,sum(CASE WHEN jsonb_array_length((l->'components')::jsonb)=1 AND l ? 'actual_base_qty' THEN (l->>'actual_base_qty')::bigint ELSE ((c->>'base_qty')::bigint)*((l->>'qty')::bigint) END)::bigint need FROM ln CROSS JOIN LATERAL jsonb_array_elements((l->'components')::jsonb)c GROUP BY c->>'stock_id') SELECT * FROM req
 LOOP
   need=rec.need;
   FOR alloc IN SELECT value FROM jsonb_array_elements(o.snapshot->'allocations') WHERE value->>'stock_id'=rec.stock_id LOOP
     EXIT WHEN need<=0;
     take=least(need,(alloc->>'base_qty')::bigint);
     UPDATE public.inventory_lots SET on_hand_base=on_hand_base-take,reserved_base=reserved_base-take WHERE id=alloc->>'lot_id' AND reserved_base>=take AND on_hand_base>=take;
     IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
     UPDATE public.stock_balances SET on_hand_base=on_hand_base-take,reserved_base=reserved_base-take WHERE stock_id=rec.stock_id AND reserved_base>=take AND on_hand_base>=take;
     INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),rec.stock_id,alloc->>'lot_id',-take,-take,'order_picked',o.id,uid,nowms);
     need=need-take;
   END LOOP;
   IF need>0 THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   FOR alloc IN SELECT value FROM jsonb_array_elements(o.snapshot->'allocations') WHERE value->>'stock_id'=rec.stock_id LOOP
     take=(alloc->>'base_qty')::bigint;
     IF take>0 THEN
       -- release any remaining reservation for this order allocation that was not consumed above, capped by current reserved amount
       UPDATE public.inventory_lots SET reserved_base=GREATEST(0,reserved_base-LEAST(reserved_base,take)) WHERE id=alloc->>'lot_id';
     END IF;
   END LOOP;
 END LOOP;
 -- synchronize aggregate reserved balances conservatively from lots for affected stocks
 UPDATE public.stock_balances sb SET reserved_base=COALESCE((SELECT sum(l.reserved_base) FROM public.inventory_lots l WHERE l.stock_id=sb.stock_id),0) WHERE sb.stock_id IN (SELECT DISTINCT value->>'stock_id' FROM jsonb_array_elements(o.snapshot->'allocations'));
 UPDATE public.orders SET fulfillment_state='ready',picker_id=COALESCE(picker_id,uid) WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'ready','picking_finalized',jsonb_build_object('fulfillment_state','ready','total_halalas',(SELECT total_halalas FROM public.orders WHERE id=o.id)),nowms);
 RETURN (SELECT jsonb_build_object('id',id,'number',number,'fulfillment_state',fulfillment_state,'delivery_state',delivery_state,'total_halalas',total_halalas) FROM public.orders WHERE id=o.id);
END$$;

REVOKE ALL ON FUNCTION public.jana_order_detail(text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_rotate_delivery_code(text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_picker_record_actual(text,text,text,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_finalize_picking(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_order_detail(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_rotate_delivery_code(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_picker_record_actual(text,text,text,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_finalize_picking(text,text) TO service_role;