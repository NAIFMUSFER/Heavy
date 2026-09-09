CREATE OR REPLACE FUNCTION public.jana_admin_dashboard(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE uid varchar; r varchar; nowms bigint := (extract(epoch from now())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','finance','inventory','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 RETURN jsonb_build_object(
  'active_orders',(SELECT count(*) FROM orders WHERE status='active'),
  'completed_orders',(SELECT count(*) FROM orders WHERE status='completed'),
  'awaiting_collection',(SELECT count(*) FROM orders WHERE payment_state='awaiting_collection'),
  'cash_with_couriers_halalas',(SELECT coalesce(sum(collected_halalas-refunded_halalas),0) FROM orders WHERE cash_state='with_courier'),
  'settled_halalas',(SELECT coalesce(sum(collected_halalas-refunded_halalas),0) FROM orders WHERE cash_state='settled'),
  'low_stock_items',(SELECT count(*) FROM stock_balances WHERE on_hand_base-reserved_base <= 5000),
  'open_tickets',(SELECT count(*) FROM tickets WHERE state='open'),
  'slot_capacity',(SELECT coalesce(sum(capacity),0) FROM delivery_slots WHERE active),
  'slot_booked',(SELECT coalesce(sum(booked),0) FROM delivery_slots WHERE active),
  'catalog_items',(SELECT count(*) FROM offerings WHERE active)
 );
END$$;

CREATE OR REPLACE FUNCTION public.jana_admin_orders(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE uid varchar; r varchar; nowms bigint := (extract(epoch from now())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','finance','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,'payment_state',o.payment_state,'cash_state',o.cash_state,'total_halalas',o.total_halalas,'collected_halalas',o.collected_halalas,'refunded_halalas',o.refunded_halalas,'created_at',o.created_at) ORDER BY o.created_at DESC) FROM orders o),'[]'::jsonb);
END$$;

CREATE OR REPLACE FUNCTION public.jana_create_staff(p_token text,p_email text,p_name text,p_password text,p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; admin_id varchar; rr varchar; nowms bigint := (extract(epoch from now())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO admin_id,rr FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF admin_id IS NULL OR rr<>'admin' THEN RAISE EXCEPTION 'unauthorized'; END IF;
 p_email=lower(trim(p_email)); p_name=trim(p_name);
 IF p_role NOT IN ('picker','courier','inventory','finance','support','admin') THEN RAISE EXCEPTION 'invalid_role'; END IF;
 IF length(p_password)<12 OR length(p_password)>128 THEN RAISE EXCEPTION 'weak_password'; END IF;
 IF exists(select 1 from users where email=p_email) THEN RAISE EXCEPTION 'email_exists'; END IF;
 uid='usr-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES(uid,p_email,p_name,crypt(p_password,gen_salt('bf',12)),p_role,false,true,nowms);
 INSERT INTO audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),admin_id,'staff_created',uid,jsonb_build_object('role',p_role,'email',p_email),nowms);
 RETURN jsonb_build_object('id',uid,'email',p_email,'name',p_name,'role',p_role);
END$$;

CREATE OR REPLACE FUNCTION public.jana_finance_settle(p_token text,p_order_id text,p_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE uid varchar; r varchar; o orders%rowtype; nowms bigint := (extract(epoch from now())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','finance') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM orders WHERE id=p_order_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.status<>'completed' OR o.payment_state<>'collected' OR o.cash_state<>'with_courier' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 UPDATE orders SET cash_state='settled' WHERE id=o.id;
 INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'cash_settled',coalesce(p_reference,''),jsonb_build_object('cash_state','settled'),nowms);
 INSERT INTO audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),uid,'cash_settled',o.id,jsonb_build_object('reference',coalesce(p_reference,''),'amount_halalas',o.collected_halalas-o.refunded_halalas),nowms);
 RETURN jsonb_build_object('id',o.id,'number',o.number,'cash_state','settled','settled_halalas',o.collected_halalas-o.refunded_halalas);
END$$;

REVOKE ALL ON FUNCTION public.jana_admin_dashboard(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_admin_orders(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_create_staff(text,text,text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_finance_settle(text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_dashboard(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_admin_orders(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_create_staff(text,text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_finance_settle(text,text,text) TO service_role;