CREATE OR REPLACE FUNCTION public.jana_ops_transition(p_token text, p_order_id text, p_action text, p_code text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  uid varchar; r varchar; o orders%rowtype;
  nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
  action text := lower(trim(coalesce(p_action,'')));
  amount bigint;
BEGIN
  SELECT s.user_id,u.role INTO uid,r
  FROM sessions s JOIN users u ON u.id=s.user_id
  WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex')
    AND s.expires_at>nowms AND u.active=true LIMIT 1;
  IF uid IS NULL OR r NOT IN ('admin','picker','courier') THEN RAISE EXCEPTION 'unauthorized'; END IF;

  IF action IN ('claim','start') THEN action='start_picking'; END IF;
  IF action='dispatch' THEN action='out_for_delivery'; END IF;
  IF action='deliver' THEN action='delivered'; END IF;
  IF action='fail' THEN action='delivery_failed'; END IF;

  SELECT * INTO o FROM orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;

  IF action='start_picking' THEN
    IF r NOT IN ('admin','picker') OR o.fulfillment_state<>'queued' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET picker_id=COALESCE(picker_id,uid), fulfillment_state='picking' WHERE id=o.id;

  ELSIF action='ready' THEN
    IF r NOT IN ('admin','picker') OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET picker_id=COALESCE(picker_id,uid), fulfillment_state='ready' WHERE id=o.id;

  ELSIF action='assign_courier' THEN
    IF r<>'admin' OR o.fulfillment_state<>'ready' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET delivery_state='assigned' WHERE id=o.id;

  ELSIF action='out_for_delivery' THEN
    IF r NOT IN ('admin','courier') OR o.fulfillment_state<>'ready' OR o.delivery_state NOT IN ('assigned','unassigned','failed') THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET courier_id=CASE WHEN r='courier' THEN uid ELSE courier_id END, delivery_state='out_for_delivery' WHERE id=o.id;

  ELSIF action='delivered' THEN
    IF r NOT IN ('admin','courier') OR o.delivery_state<>'out_for_delivery' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    IF o.code_attempts>=5 THEN RAISE EXCEPTION 'delivery_code_locked'; END IF;
    IF o.code_expires_at IS NULL OR o.code_expires_at<nowms OR encode(digest(COALESCE(p_code,''),'sha256'),'hex')<>o.code_hash THEN
      UPDATE orders SET code_attempts=code_attempts+1 WHERE id=o.id;
      RAISE EXCEPTION 'invalid_delivery_code';
    END IF;
    UPDATE orders SET courier_id=COALESCE(courier_id,CASE WHEN r='courier' THEN uid ELSE courier_id END), delivery_state='delivered', status='completed' WHERE id=o.id;

  ELSIF action='delivery_failed' THEN
    IF r NOT IN ('admin','courier') OR o.delivery_state<>'out_for_delivery' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET courier_id=COALESCE(courier_id,CASE WHEN r='courier' THEN uid ELSE courier_id END), delivery_state='failed' WHERE id=o.id;

  ELSIF action='collect' THEN
    IF r NOT IN ('admin','courier') OR o.delivery_state<>'delivered' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    IF o.payment_state<>'awaiting_collection' OR o.collected_halalas<>0 THEN RAISE EXCEPTION 'already_collected'; END IF;
    BEGIN amount := p_code::bigint; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'invalid_collection_amount'; END;
    IF amount<>o.total_halalas THEN RAISE EXCEPTION 'invalid_collection_amount'; END IF;
    UPDATE orders SET payment_state='collected', collected_halalas=amount, cash_state='with_courier' WHERE id=o.id;

  ELSE
    RAISE EXCEPTION 'invalid_action';
  END IF;

  INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at)
  VALUES ('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,action,'',jsonb_build_object('role',r),nowms);

  RETURN (SELECT jsonb_build_object('id',id,'number',number,'status',status,'fulfillment_state',fulfillment_state,'delivery_state',delivery_state,'payment_state',payment_state,'cash_state',cash_state,'collected_halalas',collected_halalas,'total_halalas',total_halalas) FROM orders WHERE id=o.id);
END$function$;

REVOKE ALL ON FUNCTION public.jana_ops_transition(text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ops_transition(text,text,text,text) TO service_role;