CREATE INDEX jana_customers_created_order ON public.users(created_at DESC,id DESC) WHERE role='customer';
CREATE FUNCTION public.jana_admin_customers(p_token text,p_query text DEFAULT '',p_before_at bigint DEFAULT NULL,p_before_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_query IS NULL OR length(p_query)>120 OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 OR length(p_before_id)>36 THEN RAISE EXCEPTION 'customer_query_invalid';END IF;p_query=lower(trim(p_query));
 WITH candidates AS MATERIALIZED (
  SELECT id,name,email,phone,active,verified_phone,created_at FROM public.users
  WHERE role='customer' AND (p_before_at IS NULL OR (created_at,id)<(p_before_at,p_before_id)) AND (p_query='' OR strpos(lower(name),p_query)>0 OR strpos(coalesce(email,''),p_query)>0 OR strpos(coalesce(phone,''),p_query)>0)
  ORDER BY created_at DESC,id DESC LIMIT 51
 ), selected AS MATERIALIZED (SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT 50), counts AS (
  SELECT o.user_id,count(*) orders_count FROM public.orders o JOIN selected c ON c.id=o.user_id GROUP BY o.user_id
 )
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(c)||jsonb_build_object('orders_count',coalesce(n.orders_count,0)) ORDER BY c.created_at DESC,c.id DESC) FROM selected c LEFT JOIN counts n ON n.user_id=c.id),'[]'::jsonb),'next',CASE WHEN (SELECT count(*) FROM candidates)>50 THEN (SELECT jsonb_build_object('before_at',created_at,'before_id',id) FROM selected ORDER BY created_at,id LIMIT 1) ELSE NULL END) INTO r;
 RETURN r;
END$$;

CREATE FUNCTION public.jana_admin_customer_detail(p_token text,p_customer_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;c public.users;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO c FROM public.users WHERE id=p_customer_id AND role='customer';IF c.id IS NULL THEN RAISE EXCEPTION 'customer_not_found';END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'customer_record_viewed',c.id,jsonb_build_object('actor_role',u.role,'purpose','customer_operations_review'),nowms);
 RETURN jsonb_build_object('customer',jsonb_build_object('id',c.id,'name',c.name,'email',c.email,'phone',c.phone,'active',c.active,'verified_phone',c.verified_phone,'created_at',c.created_at),'orders_count',(SELECT count(*) FROM public.orders WHERE user_id=c.id),'open_tickets',(SELECT count(*) FROM public.tickets WHERE user_id=c.id AND state<>'closed'),'orders',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC) FROM (SELECT id,number,status,fulfillment_state,delivery_state,payment_state,total_halalas,refunded_halalas,created_at FROM public.orders WHERE user_id=c.id ORDER BY created_at DESC,id DESC LIMIT 20)x),'[]'::jsonb));
END$$;
REVOKE ALL ON FUNCTION public.jana_admin_customers(text,text,bigint,text),public.jana_admin_customer_detail(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_customers(text,text,bigint,text),public.jana_admin_customer_detail(text,text) TO service_role;
