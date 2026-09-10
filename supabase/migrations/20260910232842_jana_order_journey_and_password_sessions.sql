-- Customer order journeys stay scoped to the custom authenticated account.
CREATE INDEX IF NOT EXISTS jana_orders_customer_page_idx ON public.orders(user_id,created_at DESC,id DESC);

CREATE OR REPLACE FUNCTION public.jana_orders_page(p_token text,p_limit integer DEFAULT 50,p_before_at bigint DEFAULT NULL,p_before_id text DEFAULT NULL,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 1000000
 OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 OR p_before_at>9007199254740991
 OR (p_before_id IS NOT NULL AND (length(p_before_id) NOT BETWEEN 1 AND 128 OR p_offset<>0)) THEN RAISE EXCEPTION 'invalid_orders_page';END IF;
 WITH candidates AS MATERIALIZED (
  SELECT id,number,status,payment_state,fulfillment_state,delivery_state,total_halalas,created_at,snapshot
  FROM public.orders WHERE user_id=u.id AND (p_before_at IS NULL OR (created_at,id)<(p_before_at,p_before_id))
  ORDER BY created_at DESC,id DESC LIMIT p_limit+1 OFFSET p_offset
 ), selected AS (SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT p_limit)
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id DESC) FROM selected s),'[]'::jsonb),
  'next',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN (SELECT jsonb_build_object('before_at',created_at,'before_id',id) FROM selected ORDER BY created_at,id LIMIT 1) ELSE NULL END,
  'next_offset',CASE WHEN p_before_at IS NULL AND (SELECT count(*) FROM candidates)>p_limit THEN p_offset+p_limit ELSE NULL END) INTO result;
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
  AND event IN ('order_created','picking','start_picking','ready','out_for_delivery','delivery_failed','delivered','cancelled','substitution_proposed','substitution_accepted','substitution_rejected','refund_completed')
  ORDER BY created_at DESC,id DESC LIMIT 101
 ), selected AS (SELECT * FROM events ORDER BY created_at DESC,id DESC LIMIT 100)
 SELECT coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at,e.id) FROM selected e),'[]'::jsonb),(SELECT count(*) FROM events)>100 INTO history,has_earlier;
 RETURN jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'payment_state',o.payment_state,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,
  'total_halalas',o.total_halalas,'collected_halalas',o.collected_halalas,'refunded_halalas',o.refunded_halalas,'cash_state',o.cash_state,'snapshot',o.snapshot,
  'original_snapshot',jsonb_build_object('store_profile',o.original_snapshot::jsonb->'store_profile','address',o.original_snapshot::jsonb->'address','slot',o.original_snapshot::jsonb->'slot'),
  'created_at',o.created_at,'timeline',history,'timeline_has_earlier',has_earlier);
END$$;

CREATE OR REPLACE FUNCTION public.jana_customer_tracking(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;p public.courier_positions;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 -- A previous driver or delivery attempt is not the customer's current tracking.
 IF o.status='active' AND o.delivery_state='out_for_delivery' AND o.courier_id IS NOT NULL THEN
  SELECT * INTO p FROM public.courier_positions WHERE order_id=o.id AND courier_id=o.courier_id
  AND created_at>=coalesce((SELECT max(created_at) FROM public.order_events WHERE order_id=o.id AND event='out_for_delivery'),o.created_at)
  AND created_at<=nowms AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180
  ORDER BY created_at DESC,id DESC LIMIT 1;
 END IF;
 RETURN jsonb_build_object('order_id',o.id,'delivery_state',o.delivery_state,'latitude',p.latitude,'longitude',p.longitude,'accuracy_m',p.accuracy_m,'updated_at',p.created_at,
  'location_state',CASE WHEN p.id IS NULL THEN 'unavailable' WHEN nowms-p.created_at>300000 THEN 'stale' ELSE 'recent' END);
END$$;

CREATE OR REPLACE FUNCTION public.jana_courier_update_location(p_token text,p_order_id text,p_lat numeric,p_lng numeric,p_accuracy numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'courier' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF o.courier_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF o.status<>'active' OR o.delivery_state<>'out_for_delivery' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 OR (p_accuracy IS NOT NULL AND p_accuracy NOT BETWEEN 0 AND 999999.99) THEN RAISE EXCEPTION 'invalid_coordinates';END IF;
 IF EXISTS(SELECT 1 FROM public.courier_positions WHERE order_id=o.id AND courier_id=u.id AND created_at>nowms-15000) THEN RAISE EXCEPTION 'location_rate_limit';END IF;
 INSERT INTO public.courier_positions(id,order_id,courier_id,latitude,longitude,accuracy_m,created_at) VALUES('pos-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,p_lat,p_lng,p_accuracy,nowms);
 RETURN jsonb_build_object('order_id',o.id,'latitude',p_lat,'longitude',p_lng,'accuracy_m',p_accuracy,'created_at',nowms);
END$$;

CREATE OR REPLACE FUNCTION public.jana_change_password(p_token text,p_current text,p_new text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);
 SELECT * INTO u FROM public.users WHERE id=u.id FOR UPDATE;
 -- Login holds FOR SHARE on this row; password changes serialize with login and each other.
 PERFORM public.jana_auth_user(p_token);
 IF p_new IS NULL OR length(p_new)<12 OR octet_length(p_new)>72 THEN RAISE EXCEPTION 'weak_password';END IF;
 IF p_current IS NULL OR octet_length(p_current)>72 OR crypt(p_current,u.password_hash) IS DISTINCT FROM u.password_hash THEN RAISE EXCEPTION 'invalid_credentials';END IF;
 UPDATE public.users SET password_hash=crypt(p_new,gen_salt('bf',12)) WHERE id=u.id;
 DELETE FROM public.sessions WHERE user_id=u.id;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'password_changed',u.id,'{"all_sessions_revoked":true}'::jsonb,nowms);
 RETURN jsonb_build_object('ok',true,'other_sessions_revoked',true,'all_sessions_revoked',true,'sign_in_again',true);
END$$;

REVOKE ALL ON FUNCTION public.jana_orders_page(text,integer,bigint,text,integer),public.jana_order_detail(text,text),public.jana_customer_tracking(text,text),public.jana_courier_update_location(text,text,numeric,numeric,numeric),public.jana_change_password(text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_orders_page(text,integer,bigint,text,integer),public.jana_order_detail(text,text),public.jana_customer_tracking(text,text),public.jana_courier_update_location(text,text,numeric,numeric,numeric),public.jana_change_password(text,text,text) TO service_role;
