CREATE OR REPLACE FUNCTION public.jana_finalize_picking(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar; o public.orders; alloc jsonb; rec record; need bigint; take bigint; used bigint; remain bigint; consumed jsonb:='{}'::jsonb; lotid text; stockid text; allocbase bigint; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
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
     lotid=alloc->>'lot_id'; stockid=alloc->>'stock_id'; allocbase=(alloc->>'base_qty')::bigint; used=COALESCE((consumed->>lotid)::bigint,0); take=least(need,allocbase-used);
     IF take>0 THEN
       UPDATE public.inventory_lots SET on_hand_base=on_hand_base-take,reserved_base=reserved_base-take WHERE id=lotid AND reserved_base>=take AND on_hand_base>=take;
       IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
       UPDATE public.stock_balances SET on_hand_base=on_hand_base-take,reserved_base=reserved_base-take WHERE stock_id=stockid AND reserved_base>=take AND on_hand_base>=take;
       IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
       consumed=jsonb_set(consumed,ARRAY[lotid],to_jsonb(used+take),true);
       INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),stockid,lotid,-take,-take,'order_picked',o.id,uid,nowms);
       need=need-take;
     END IF;
   END LOOP;
   IF need>0 THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
 END LOOP;
 FOR alloc IN SELECT value FROM jsonb_array_elements(o.snapshot->'allocations') LOOP
   lotid=alloc->>'lot_id'; stockid=alloc->>'stock_id'; allocbase=(alloc->>'base_qty')::bigint; used=COALESCE((consumed->>lotid)::bigint,0); remain=GREATEST(allocbase-used,0);
   IF remain>0 THEN
     UPDATE public.inventory_lots SET reserved_base=reserved_base-remain WHERE id=lotid AND reserved_base>=remain;
     IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
     UPDATE public.stock_balances SET reserved_base=reserved_base-remain WHERE stock_id=stockid AND reserved_base>=remain;
     IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
     INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),stockid,lotid,0,-remain,'order_reservation_release',o.id,uid,nowms);
   END IF;
 END LOOP;
 UPDATE public.orders SET fulfillment_state='ready',picker_id=COALESCE(picker_id,uid) WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'ready','picking_finalized',jsonb_build_object('fulfillment_state','ready','total_halalas',(SELECT total_halalas FROM public.orders WHERE id=o.id)),nowms);
 RETURN (SELECT jsonb_build_object('id',id,'number',number,'fulfillment_state',fulfillment_state,'delivery_state',delivery_state,'total_halalas',total_halalas) FROM public.orders WHERE id=o.id);
END$$;