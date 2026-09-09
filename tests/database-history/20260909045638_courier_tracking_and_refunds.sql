CREATE TABLE IF NOT EXISTS public.courier_positions (
 id text PRIMARY KEY,
 order_id text NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
 courier_id text NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
 latitude numeric(9,6) NOT NULL,
 longitude numeric(9,6) NOT NULL,
 accuracy_m numeric(8,2),
 created_at bigint NOT NULL
);
ALTER TABLE public.courier_positions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS courier_positions_order_created_idx ON public.courier_positions(order_id,created_at DESC);
REVOKE ALL ON public.courier_positions FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.courier_positions TO service_role;

CREATE OR REPLACE FUNCTION public.jana_courier_update_location(p_token text,p_order_id text,p_lat numeric,p_lng numeric,p_accuracy numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar; o public.orders; nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','courier') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.delivery_state<>'out_for_delivery' OR (r='courier' AND o.courier_id<>uid) THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 IF p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'invalid_coordinates'; END IF;
 INSERT INTO public.courier_positions(id,order_id,courier_id,latitude,longitude,accuracy_m,created_at) VALUES('pos-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,p_lat,p_lng,p_accuracy,nowms);
 RETURN jsonb_build_object('order_id',o.id,'latitude',p_lat,'longitude',p_lng,'accuracy_m',p_accuracy,'created_at',nowms);
END$$;

CREATE OR REPLACE FUNCTION public.jana_customer_tracking(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; o public.orders; p public.courier_positions;
BEGIN
 u=public.jana_auth_user(p_token);
 SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 SELECT * INTO p FROM public.courier_positions WHERE order_id=o.id ORDER BY created_at DESC LIMIT 1;
 RETURN jsonb_build_object('order_id',o.id,'delivery_state',o.delivery_state,'latitude',p.latitude,'longitude',p.longitude,'accuracy_m',p.accuracy_m,'updated_at',p.created_at);
END$$;

CREATE OR REPLACE FUNCTION public.jana_admin_refund(p_token text,p_order_id text,p_amount_halalas bigint,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar; o public.orders; rid text; nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','finance','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF p_amount_halalas<=0 OR p_amount_halalas>(o.collected_halalas-o.refunded_halalas) THEN RAISE EXCEPTION 'invalid_refund_amount'; END IF;
 rid='ref-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.refunds(id,order_id,amount_halalas,reason,state,created_at) VALUES(rid,o.id,p_amount_halalas,coalesce(nullif(trim(p_reason),''),'manual_adjustment'),'completed',nowms);
 UPDATE public.orders SET refunded_halalas=refunded_halalas+p_amount_halalas WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'refund_completed',coalesce(p_reason,''),jsonb_build_object('refund_halalas',p_amount_halalas),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),uid,'refund_completed',o.id,jsonb_build_object('amount_halalas',p_amount_halalas,'reason',coalesce(p_reason,'')),nowms);
 RETURN jsonb_build_object('refund_id',rid,'order_id',o.id,'amount_halalas',p_amount_halalas,'refunded_total_halalas',o.refunded_halalas+p_amount_halalas);
END$$;

REVOKE ALL ON FUNCTION public.jana_courier_update_location(text,text,numeric,numeric,numeric) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_customer_tracking(text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_admin_refund(text,text,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_courier_update_location(text,text,numeric,numeric,numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_customer_tracking(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_admin_refund(text,text,bigint,text) TO service_role;