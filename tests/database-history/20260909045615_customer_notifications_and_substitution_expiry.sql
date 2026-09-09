CREATE OR REPLACE FUNCTION public.jana_customer_notifications(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',n.id,'title',n.title,'body',n.body,'order_id',n.order_id,'is_read',n.is_read,'created_at',n.created_at) ORDER BY n.created_at DESC) FROM public.notifications n WHERE n.user_id=u.id),'[]'::jsonb);
END$$;

CREATE OR REPLACE FUNCTION public.jana_mark_notification_read(p_token text,p_notification_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);
 UPDATE public.notifications SET is_read=true WHERE id=p_notification_id AND user_id=u.id;
 IF NOT FOUND THEN RAISE EXCEPTION 'notification_not_found'; END IF;
 RETURN jsonb_build_object('id',p_notification_id,'is_read',true);
END$$;

CREATE OR REPLACE FUNCTION public.jana_expire_substitutions()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE n integer; nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 WITH expired AS (
   UPDATE public.substitutions s SET state='expired'
   WHERE s.state='pending' AND s.created_at < nowms-900000
   RETURNING s.order_id,s.id
 ), ord AS (
   UPDATE public.orders o SET fulfillment_state='picking'
   WHERE o.id IN (SELECT order_id FROM expired) AND o.fulfillment_state='awaiting_customer'
   RETURNING o.id,o.user_id
 )
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 SELECT 'ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'subst-expired-'||o.id,'انتهت مهلة البديل','تم رفض البديل تلقائيًا واستكمال تجهيز طلبك.',o.id,false,nowms FROM ord o
 ON CONFLICT DO NOTHING;
 GET DIAGNOSTICS n = ROW_COUNT;
 RETURN n;
END$$;

REVOKE ALL ON FUNCTION public.jana_customer_notifications(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_mark_notification_read(text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_expire_substitutions() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_customer_notifications(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_mark_notification_read(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_expire_substitutions() TO service_role;