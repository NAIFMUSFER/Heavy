-- A missing fixed-basket component may be replaced only with explicit customer
-- consent. The replacement keeps the sold basket price and exact base quantity;
-- reservations remain unchanged until the decision transaction succeeds.

CREATE FUNCTION public.jana_propose_component_substitution(
 p_token text,p_order_id text,p_line_id text,p_component_id text,p_replacement_stock_id text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;replacement public.stock_items;target jsonb;original_component jsonb;
 replacement_component jsonb;replacement_line jsonb;new_components jsonb;terms jsonb;sid text;
 planned bigint;actual bigint;slot_end bigint;nowms bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 IF EXISTS(SELECT 1 FROM public.substitutions WHERE order_id=o.id AND state='pending') THEN RAISE EXCEPTION 'substitution_pending';END IF;
 SELECT value INTO target FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WHERE value->>'line_id'=p_line_id;
 IF target IS NULL THEN RAISE EXCEPTION 'line_not_found';END IF;
 IF jsonb_array_length(target->'components')<2 THEN RAISE EXCEPTION 'invalid_substitution';END IF;
 SELECT value INTO original_component FROM jsonb_array_elements(target->'components') WHERE value->>'stock_id'=p_component_id;
 IF original_component IS NULL OR (SELECT count(*) FROM jsonb_array_elements(target->'components') c WHERE c->>'stock_id'=p_component_id)<>1 THEN RAISE EXCEPTION 'invalid_substitution';END IF;
 SELECT * INTO replacement FROM public.stock_items WHERE id=p_replacement_stock_id AND active FOR SHARE;
 IF replacement.id IS NULL OR replacement.id=p_component_id OR replacement.base_unit<>original_component->>'base_unit'
  OR EXISTS(SELECT 1 FROM jsonb_array_elements(target->'components') c WHERE c->>'stock_id'=replacement.id)
 THEN RAISE EXCEPTION 'invalid_substitution';END IF;
 planned=(original_component->>'base_qty')::bigint*(target->>'qty')::bigint;
 SELECT (value->>'actual_base')::bigint INTO actual FROM jsonb_array_elements(target->'component_check'->'items')
  WHERE value->>'stock_id'=p_component_id;
 IF actual IS NULL OR actual>=planned THEN RAISE EXCEPTION 'basket_components_unresolved';END IF;
 SELECT ends_at INTO slot_end FROM public.delivery_slots WHERE id=o.slot_id;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 IF NOT EXISTS(SELECT 1 FROM public.stock_balances WHERE stock_id=replacement.id AND on_hand_base-reserved_base>=planned)
  OR coalesce((SELECT sum(on_hand_base-reserved_base) FROM public.inventory_lots
   WHERE stock_id=replacement.id AND inspection_state='accepted' AND expires_at>greatest(nowms,slot_end) AND on_hand_base>reserved_base),0)<planned
 THEN RAISE EXCEPTION 'insufficient_stock';END IF;
 SELECT jsonb_agg(CASE WHEN c->>'stock_id'=p_component_id THEN c||jsonb_build_object(
  'stock_id',replacement.id,'name',replacement.name,'base_unit',replacement.base_unit,
  'substituted_from_stock_id',p_component_id) ELSE c END ORDER BY n)
 INTO new_components FROM jsonb_array_elements(target->'components') WITH ORDINALITY e(c,n);
 replacement_line=(target-'component_check')||jsonb_build_object('components',new_components);
 replacement_component=jsonb_build_object('stock_id',replacement.id,'name',replacement.name,
  'base_unit',replacement.base_unit,'base_qty',(original_component->>'base_qty')::bigint,'planned_base',planned);
 sid='sub-'||replace(gen_random_uuid()::text,'-','');
 terms=jsonb_build_object('action','replace_component','original_line',target,'replacement_line',replacement_line,
  'original_component',original_component||jsonb_build_object('planned_base',planned,'actual_base',actual),
  'replacement_component',replacement_component,'order_snapshot_hash',encode(digest(o.snapshot::jsonb::text,'sha256'),'hex'),
  'original_total_halalas',o.total_halalas,'subtotal_halalas',(o.snapshot->>'subtotal_halalas')::bigint,
  'discount_halalas',(o.snapshot->>'discount_halalas')::bigint,'total_halalas',o.total_halalas,
  'price_difference_halalas',0,'inventory_reserved',false,'quantity_policy','same_base_quantity');
 INSERT INTO public.substitutions(id,order_id,line_id,component_id,proposed,default_action,state,expires_at,actor_id,created_at)
 VALUES(sid,o.id,p_line_id,p_component_id,terms,'hold_for_resolution','pending',nowms+900000,u.id,nowms);
 UPDATE public.orders SET fulfillment_state='awaiting_customer' WHERE id=o.id;
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'component-sub-'||sid,'استبدال مكوّن في السلة يحتاج موافقتك',
  'أحد مكونات السلة ناقص. راجع المكوّن البديل؛ الكمية والوحدة والسعر الإجمالي لن تتغير.',o.id,false,nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'component_substitution_proposed',sid,
  jsonb_build_object('line_id',p_line_id,'component_id',p_component_id,'replacement_stock_id',replacement.id,'total_halalas',o.total_halalas),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'component_substitution_proposed',sid,
  jsonb_build_object('role',u.role,'order_id',o.id,'line_id',p_line_id,'original_component',terms->'original_component','replacement_component',replacement_component,'total_halalas',o.total_halalas),nowms);
 RETURN jsonb_build_object('id',sid,'order_id',o.id,'line_id',p_line_id,'component_id',p_component_id,
  'state','pending','expires_at',nowms+900000,'proposed',terms);
END$$;

CREATE OR REPLACE FUNCTION public.jana_reallocate_order(p_order_id text,p_lines jsonb,p_actor_id text,p_reason_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE o public.orders;slot_end bigint;rec record;lotrec record;a jsonb;need bigint;take bigint;allocations jsonb:='[]';nowms bigint;
BEGIN
 IF p_reason_kind IS NULL OR p_reason_kind NOT IN ('substitution','weight','line_removal','component_substitution') THEN RAISE EXCEPTION 'invalid_operation';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.fulfillment_state NOT IN ('picking','awaiting_customer') THEN RAISE EXCEPTION 'invalid_transition';END IF;
 SELECT ends_at INTO slot_end FROM public.delivery_slots WHERE id=o.slot_id FOR UPDATE;
 PERFORM 1 FROM public.stock_balances WHERE stock_id IN (
  SELECT value->>'stock_id' FROM jsonb_array_elements(o.snapshot::jsonb->'allocations')
  UNION SELECT c->>'stock_id' FROM jsonb_array_elements(p_lines) l CROSS JOIN LATERAL jsonb_array_elements(l->'components') c
 ) ORDER BY stock_id FOR UPDATE;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 FOR a IN SELECT value FROM jsonb_array_elements(o.snapshot::jsonb->'allocations') LOOP
  UPDATE public.inventory_lots SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE id=a->>'lot_id' AND stock_id=a->>'stock_id' AND reserved_base>=(a->>'base_qty')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid';END IF;
  UPDATE public.stock_balances SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE stock_id=a->>'stock_id' AND reserved_base>=(a->>'base_qty')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid';END IF;
  INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
  VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),a->>'stock_id',a->>'lot_id',0,-(a->>'base_qty')::bigint,p_reason_kind||'_reservation_release',o.id,p_actor_id,nowms);
 END LOOP;
 FOR rec IN SELECT c->>'stock_id' stock_id,sum(CASE WHEN jsonb_array_length(l->'components')=1 AND l?'actual_base_qty' THEN (l->>'actual_base_qty')::bigint ELSE (c->>'base_qty')::bigint*(l->>'qty')::bigint END)::bigint required
  FROM jsonb_array_elements(p_lines) l CROSS JOIN LATERAL jsonb_array_elements(l->'components') c GROUP BY c->>'stock_id' ORDER BY c->>'stock_id'
 LOOP
  IF NOT EXISTS(SELECT 1 FROM public.stock_items WHERE id=rec.stock_id AND active) OR NOT EXISTS(SELECT 1 FROM public.stock_balances WHERE stock_id=rec.stock_id AND on_hand_base-reserved_base>=rec.required) THEN RAISE EXCEPTION 'insufficient_stock';END IF;
  need=rec.required;
  FOR lotrec IN SELECT id,on_hand_base-reserved_base available FROM public.inventory_lots WHERE stock_id=rec.stock_id AND inspection_state='accepted' AND expires_at>greatest(nowms,slot_end) AND on_hand_base>reserved_base ORDER BY expires_at,id FOR UPDATE LOOP
   EXIT WHEN need<=0;take=least(need,lotrec.available);
   UPDATE public.inventory_lots SET reserved_base=reserved_base+take WHERE id=lotrec.id;
   allocations=allocations||jsonb_build_array(jsonb_build_object('stock_id',rec.stock_id,'lot_id',lotrec.id,'base_qty',take));
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
   VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),rec.stock_id,lotrec.id,0,take,p_reason_kind||'_reserved',o.id,p_actor_id,nowms);need=need-take;
  END LOOP;
  IF need>0 THEN RAISE EXCEPTION 'insufficient_lot_stock';END IF;
  UPDATE public.stock_balances SET reserved_base=reserved_base+rec.required WHERE stock_id=rec.stock_id;
 END LOOP;
 RETURN allocations;
END$$;

CREATE OR REPLACE FUNCTION public.jana_decide_substitution(p_token text,p_substitution_id text,p_accept boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.substitutions;o public.orders;oid text;newlines jsonb;allocations jsonb;result jsonb;nowms bigint;removal boolean;component_swap boolean;
BEGIN
 u=public.jana_auth_user(p_token);
 SELECT order_id INTO oid FROM public.substitutions WHERE id=p_substitution_id;
 SELECT * INTO o FROM public.orders WHERE id=oid AND user_id=u.id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 SELECT * INTO s FROM public.substitutions WHERE id=p_substitution_id FOR UPDATE;
 IF p_accept IS NULL THEN RAISE EXCEPTION 'invalid_substitution_decision';END IF;
 IF s.state IN ('accepted','rejected') THEN
  IF (s.state='accepted') IS DISTINCT FROM p_accept THEN RAISE EXCEPTION 'substitution_already_decided';END IF;
  RETURN s.decision_result;
 END IF;
 IF s.state='expired' THEN RETURN jsonb_build_object('_error','substitution_expired','status',409);END IF;
 IF s.state<>'pending' OR o.status<>'active' OR o.fulfillment_state<>'awaiting_customer' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 removal=coalesce(s.proposed->>'action','')='remove_line';component_swap=coalesce(s.proposed->>'action','')='replace_component';
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 IF s.expires_at<=nowms THEN
  result=jsonb_build_object('_error','substitution_expired','status',409);
  UPDATE public.substitutions SET state='expired',decided_at=nowms,decision_result=result WHERE id=s.id;
  UPDATE public.orders SET fulfillment_state='picking' WHERE id=o.id;
 ELSE
  IF p_accept THEN
   IF s.proposed->>'order_snapshot_hash' IS DISTINCT FROM encode(digest(o.snapshot::jsonb::text,'sha256'),'hex') THEN RAISE EXCEPTION 'substitution_terms_changed';END IF;
   IF removal THEN
    SELECT coalesce(jsonb_agg(l ORDER BY n) FILTER(WHERE l->>'line_id'<>s.line_id),'[]'::jsonb) INTO newlines FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY e(l,n);
    IF jsonb_array_length(newlines)<1 THEN RAISE EXCEPTION 'cannot_remove_last_line';END IF;
    allocations=public.jana_reallocate_order(o.id,newlines,u.id,'line_removal');
   ELSIF component_swap THEN
    SELECT jsonb_agg(CASE WHEN l->>'line_id'=s.line_id THEN s.proposed->'replacement_line' ELSE l END ORDER BY n) INTO newlines FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY e(l,n);
    IF newlines IS NULL OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(newlines) l WHERE l->>'line_id'=s.line_id) THEN RAISE EXCEPTION 'invalid_substitution';END IF;
    allocations=public.jana_reallocate_order(o.id,newlines,u.id,'component_substitution');
   ELSE
    SELECT jsonb_agg(CASE WHEN l->>'line_id'=s.line_id THEN s.proposed::jsonb->'replacement_line' ELSE l END ORDER BY n) INTO newlines FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY e(l,n);
    allocations=public.jana_reallocate_order(o.id,newlines,u.id,'substitution');
   END IF;
   UPDATE public.orders SET snapshot=o.snapshot::jsonb||jsonb_build_object('lines',newlines,'allocations',allocations,'subtotal_halalas',(s.proposed->>'subtotal_halalas')::bigint,'discount_halalas',(s.proposed->>'discount_halalas')::bigint,'total_halalas',(s.proposed->>'total_halalas')::bigint),total_halalas=(s.proposed->>'total_halalas')::bigint WHERE id=o.id;
   IF (SELECT total_halalas FROM public.orders WHERE id=o.id)<>(s.proposed->>'total_halalas')::bigint THEN RAISE EXCEPTION 'substitution_terms_changed';END IF;
   IF removal THEN
    UPDATE public.picking_line_issues SET state='removed',updated_at=nowms WHERE order_id=o.id AND line_id=s.line_id;
   ELSIF NOT component_swap THEN
    UPDATE public.picking_line_issues SET state='replaced',updated_at=nowms WHERE order_id=o.id AND line_id=s.line_id;
   END IF;
  END IF;
  result=jsonb_build_object('id',s.id,'order_id',o.id,'action',CASE WHEN removal THEN 'remove_line' WHEN component_swap THEN 'replace_component' ELSE 'replace_line' END,'state',CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,'total_halalas',(SELECT total_halalas FROM public.orders WHERE id=o.id));
  UPDATE public.substitutions SET state=CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,decided_at=nowms,decision_result=result WHERE id=s.id;
  UPDATE public.orders SET fulfillment_state='picking' WHERE id=o.id;
 END IF;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,
  CASE WHEN component_swap AND s.expires_at<=nowms THEN 'component_substitution_expired' WHEN component_swap AND p_accept THEN 'component_substitution_accepted' WHEN component_swap THEN 'component_substitution_rejected' WHEN removal AND s.expires_at<=nowms THEN 'line_removal_expired' WHEN removal AND p_accept THEN 'line_removal_accepted' WHEN removal THEN 'line_removal_rejected' WHEN s.expires_at<=nowms THEN 'substitution_expired' WHEN p_accept THEN 'substitution_accepted' ELSE 'substitution_rejected' END,s.id,result,nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN component_swap THEN 'component_substitution_decision' WHEN removal THEN 'line_removal_decision' ELSE 'substitution_decision' END,s.id,jsonb_build_object('role',u.role,'before','pending','after',result),nowms);
 RETURN result;
END$$;

CREATE OR REPLACE FUNCTION public.jana_expire_substitutions()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE o public.orders;s public.substitutions;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;n int:=0;removal boolean;component_swap boolean;
BEGIN
 FOR o IN SELECT * FROM public.orders WHERE id IN(SELECT order_id FROM public.substitutions WHERE state='pending' AND expires_at<=nowms) ORDER BY id FOR UPDATE SKIP LOCKED LOOP
  FOR s IN SELECT * FROM public.substitutions WHERE order_id=o.id AND state='pending' AND expires_at<=nowms FOR UPDATE LOOP
   removal=coalesce(s.proposed->>'action','')='remove_line';component_swap=coalesce(s.proposed->>'action','')='replace_component';
   UPDATE public.substitutions SET state='expired',decided_at=nowms,decision_result=jsonb_build_object('_error','substitution_expired','status',409) WHERE id=s.id;
   IF o.status='active' AND o.fulfillment_state='awaiting_customer' THEN UPDATE public.orders SET fulfillment_state='picking' WHERE id=o.id;END IF;
   INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
   VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'sub-expired-'||s.id,
    CASE WHEN component_swap THEN 'انتهت مهلة استبدال مكوّن السلة' WHEN removal THEN 'انتهت مهلة حذف الصنف' ELSE 'انتهت مهلة البديل' END,
    CASE WHEN component_swap THEN 'لم يُستبدل المكوّن. تظل السلة بحاجة إلى معالجة من فريق التجهيز.' WHEN removal THEN 'لم يُحذف الصنف. يظل بحاجة إلى معالجة من فريق التجهيز.' ELSE 'لم يُعتمد البديل. يظل الصنف بحاجة إلى معالجة من فريق التجهيز.' END,o.id,false,nowms);
   INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
   VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,null,CASE WHEN component_swap THEN 'component_substitution_expired' WHEN removal THEN 'line_removal_expired' ELSE 'substitution_expired' END,s.id,jsonb_build_object('line_id',s.line_id,'requires_resolution',true),nowms);n=n+1;
  END LOOP;
 END LOOP;
 RETURN n;
END$$;

CREATE OR REPLACE FUNCTION public.jana_picking_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;oid text;key_scope text;req_hash text;prior public.idempotency_records;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF p_operation NOT IN ('substitution.propose','component.substitution.propose','substitution.decide','line.removal.propose','line.unavailable','line.restore','line.actual','picking.finish') OR p_operation IS NULL THEN RAISE EXCEPTION 'invalid_operation';END IF;
 IF p_operation<>'substitution.decide' AND u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation='substitution.decide' THEN SELECT order_id INTO oid FROM public.substitutions WHERE id=p_payload->>'substitution_id';ELSE oid=p_payload->>'order_id';END IF;
 SELECT * INTO o FROM public.orders WHERE id=oid;
 IF o.id IS NULL OR (p_operation='substitution.decide' AND o.user_id<>u.id) THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF p_operation<>'substitution.decide' AND u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 key_scope='picking:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(key_scope,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=key_scope;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 CASE p_operation
 WHEN 'substitution.propose' THEN result=public.jana_propose_substitution(p_token,oid,p_payload->>'line_id',p_payload->>'offering_id',(p_payload->>'qty')::int);
 WHEN 'component.substitution.propose' THEN result=public.jana_propose_component_substitution(p_token,oid,p_payload->>'line_id',p_payload->>'component_id',p_payload->>'replacement_stock_id');
 WHEN 'line.removal.propose' THEN result=public.jana_propose_line_removal(p_token,oid,p_payload->>'line_id');
 WHEN 'substitution.decide' THEN IF jsonb_typeof(p_payload->'accept') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'invalid_substitution_decision';END IF;result=public.jana_decide_substitution(p_token,p_payload->>'substitution_id',(p_payload->>'accept')::boolean);
 WHEN 'line.unavailable' THEN result=public.jana_picking_issue(p_token,oid,p_payload->>'line_id',p_payload->>'reason',false);
 WHEN 'line.restore' THEN result=public.jana_picking_issue(p_token,oid,p_payload->>'line_id',p_payload->>'reason',true);
 WHEN 'line.actual' THEN IF EXISTS(SELECT 1 FROM public.picking_line_issues WHERE order_id=oid AND line_id=p_payload->>'line_id' AND state='open') THEN RAISE EXCEPTION 'unresolved_picking_items';END IF;result=public.jana_picker_record_actual(p_token,oid,p_payload->>'line_id',(p_payload->>'actual_base')::bigint);
 WHEN 'picking.finish' THEN result=public.jana_finalize_picking(p_token,oid);
 END CASE;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(key_scope,u.id,p_idem_key,req_hash,result,(extract(epoch from clock_timestamp())*1000)::bigint);
 RETURN result;
END$$;

CREATE OR REPLACE FUNCTION public.jana_order_detail(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;history jsonb;has_earlier boolean;
BEGIN
 u=public.jana_auth_user(p_token);SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 WITH events AS MATERIALIZED (
  SELECT id,event,created_at FROM public.order_events WHERE order_id=o.id
  AND event IN ('order_created','picking','start_picking','ready','out_for_delivery','delivery_failed','delivered','cancelled','substitution_proposed','substitution_accepted','substitution_rejected','line_removal_proposed','line_removal_accepted','line_removal_rejected','line_removal_expired','component_substitution_proposed','component_substitution_accepted','component_substitution_rejected','component_substitution_expired','refund_completed')
  ORDER BY created_at DESC,id DESC LIMIT 101
 ), selected AS (SELECT * FROM events ORDER BY created_at DESC,id DESC LIMIT 100)
 SELECT coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at,e.id) FROM selected e),'[]'::jsonb),(SELECT count(*) FROM events)>100 INTO history,has_earlier;
 RETURN jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'payment_state',o.payment_state,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,
  'total_halalas',o.total_halalas,'collected_halalas',o.collected_halalas,'refunded_halalas',o.refunded_halalas,'cash_state',o.cash_state,'snapshot',o.snapshot,
  'original_snapshot',jsonb_build_object('store_profile',o.original_snapshot::jsonb->'store_profile','address',o.original_snapshot::jsonb->'address','slot',o.original_snapshot::jsonb->'slot'),
  'created_at',o.created_at,'timeline',history,'timeline_has_earlier',has_earlier);
END$$;

REVOKE ALL ON FUNCTION public.jana_propose_component_substitution(text,text,text,text,text),public.jana_decide_substitution(text,text,boolean),public.jana_expire_substitutions(),public.jana_picking_write(text,text,text,jsonb),public.jana_order_detail(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_propose_component_substitution(text,text,text,text,text),public.jana_decide_substitution(text,text,boolean),public.jana_expire_substitutions(),public.jana_picking_write(text,text,text,jsonb),public.jana_order_detail(text,text) TO service_role;
REVOKE ALL ON FUNCTION public.jana_reallocate_order(text,jsonb,text,text) FROM PUBLIC,anon,authenticated,service_role;
