CREATE OR REPLACE FUNCTION public.jana_ops_orders(p_token text, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE uid varchar; r varchar;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at > (extract(epoch from now())*1000)::bigint AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker','courier','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF p_role='picker' AND r NOT IN ('admin','picker') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF p_role='courier' AND r NOT IN ('admin','courier') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,'payment_state',o.payment_state,'total_halalas',o.total_halalas,'picker_id',o.picker_id,'courier_id',o.courier_id,'created_at',o.created_at) ORDER BY o.created_at DESC) FROM orders o WHERE o.status='active' AND (r='admin' OR (p_role='picker' AND (o.picker_id IS NULL OR o.picker_id=uid)) OR (p_role='courier' AND (o.courier_id IS NULL OR o.courier_id=uid)))), '[]'::jsonb);
END$$;

CREATE OR REPLACE FUNCTION public.jana_ops_transition(p_token text,p_order_id text,p_action text,p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE uid varchar; r varchar; o orders%rowtype; nowms bigint := (extract(epoch from now())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker','courier') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM orders WHERE id=p_order_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF p_action='start_picking' THEN
   IF r NOT IN ('admin','picker') OR o.fulfillment_state<>'queued' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
   UPDATE orders SET picker_id=COALESCE(picker_id,uid),fulfillment_state='picking' WHERE id=o.id;
 ELSIF p_action='ready' THEN
   IF r NOT IN ('admin','picker') OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
   UPDATE orders SET picker_id=COALESCE(picker_id,uid),fulfillment_state='ready' WHERE id=o.id;
 ELSIF p_action='assign_courier' THEN
   IF r<>'admin' OR o.fulfillment_state<>'ready' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
   UPDATE orders SET delivery_state='assigned' WHERE id=o.id;
 ELSIF p_action='out_for_delivery' THEN
   IF r NOT IN ('admin','courier') OR o.fulfillment_state<>'ready' OR o.delivery_state NOT IN ('assigned','unassigned') THEN RAISE EXCEPTION 'invalid_transition'; END IF;
   UPDATE orders SET courier_id=COALESCE(courier_id,uid),delivery_state='out_for_delivery' WHERE id=o.id;
 ELSIF p_action='delivered' THEN
   IF r NOT IN ('admin','courier') OR o.delivery_state<>'out_for_delivery' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
   IF o.code_expires_at IS NULL OR o.code_expires_at<nowms OR encode(digest(COALESCE(p_code,''),'sha256'),'hex')<>o.code_hash THEN UPDATE orders SET code_attempts=code_attempts+1 WHERE id=o.id; RAISE EXCEPTION 'invalid_delivery_code'; END IF;
   UPDATE orders SET courier_id=COALESCE(courier_id,uid),delivery_state='delivered',payment_state='collected',collected_halalas=total_halalas,cash_state='with_courier',status='completed' WHERE id=o.id;
 ELSE RAISE EXCEPTION 'invalid_action'; END IF;
 INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES ('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,p_action,'',jsonb_build_object('role',r),nowms);
 RETURN (SELECT jsonb_build_object('id',id,'number',number,'status',status,'fulfillment_state',fulfillment_state,'delivery_state',delivery_state,'payment_state',payment_state,'cash_state',cash_state) FROM orders WHERE id=o.id);
END$$;
REVOKE ALL ON FUNCTION public.jana_ops_orders(text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_ops_transition(text,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ops_orders(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_ops_transition(text,text,text,text) TO service_role;