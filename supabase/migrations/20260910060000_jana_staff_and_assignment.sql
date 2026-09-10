-- Staff membership and assignment changes share a transaction advisory lock.
CREATE FUNCTION public.jana_staff_public(p_user public.users)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',p_user.id,'name',p_user.name,'email',p_user.email,'phone',p_user.phone,'role',p_user.role,'active',p_user.active,'created_at',p_user.created_at);
$$;
CREATE FUNCTION public.jana_list_staff(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN coalesce((SELECT jsonb_agg(public.jana_staff_public(s) ORDER BY s.name,s.id) FROM public.users s WHERE s.role<>'customer'),'[]'::jsonb);
END$$;
CREATE OR REPLACE FUNCTION public.jana_create_staff(p_token text,p_email text,p_name text,p_password text,p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.users;uid text:='usr-'||replace(gen_random_uuid()::text,'-','');nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('jana-staff-membership',0));
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_email=lower(trim(coalesce(p_email,'')));p_name=trim(coalesce(p_name,''));
 IF p_role IS NULL OR p_role NOT IN ('admin','inventory','picker','courier','finance','support') THEN RAISE EXCEPTION 'invalid_role';END IF;
 IF p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' OR length(p_email)>254 OR length(p_name) NOT BETWEEN 2 AND 100 THEN RAISE EXCEPTION 'staff_validation';END IF;
 IF p_password IS NULL OR length(p_password)<12 OR octet_length(p_password)>72 THEN RAISE EXCEPTION 'weak_password';END IF;
 IF EXISTS(SELECT 1 FROM public.users WHERE email=p_email) THEN RAISE EXCEPTION 'email_exists';END IF;
 INSERT INTO public.users(id,email,name,password_hash,role,verified_phone,active,created_at)
 VALUES(uid,p_email,p_name,crypt(p_password,gen_salt('bf',12)),p_role,false,true,nowms) RETURNING * INTO s;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'staff_created',s.id,jsonb_build_object('role',u.role,'after',public.jana_staff_public(s)),nowms);
 RETURN public.jana_staff_public(s);
END$$;

CREATE FUNCTION public.jana_update_staff(p_token text,p_user_id text,p_payload jsonb,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.users;r public.users;next_role text;next_active boolean;next_email text;next_name text;next_phone text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('jana-staff-membership',0));
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO s FROM public.users WHERE id=p_user_id FOR UPDATE;
 IF s.id IS NULL OR s.role='customer' THEN RAISE EXCEPTION 'staff_not_found';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'staff_validation';END IF;
 next_role=coalesce(p_payload->>'role',s.role);next_active=coalesce((p_payload->>'active')::boolean,s.active);
 next_email=lower(trim(coalesce(p_payload->>'email',s.email)));next_name=trim(coalesce(p_payload->>'name',s.name));
 next_phone=CASE WHEN p_payload?'phone' THEN nullif(trim(p_payload->>'phone'),'') ELSE s.phone END;
 IF next_role NOT IN ('admin','inventory','picker','courier','finance','support') OR (p_payload?'active' AND jsonb_typeof(p_payload->'active') IS DISTINCT FROM 'boolean') OR next_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' OR length(next_email)>254 OR length(next_name) NOT BETWEEN 2 AND 100 OR (next_phone IS NOT NULL AND next_phone !~ '^(05[0-9]{8}|\+9665[0-9]{8})$') THEN RAISE EXCEPTION 'staff_validation';END IF;
 IF s.active AND s.role='admin' AND (NOT next_active OR next_role<>'admin') AND NOT EXISTS(SELECT 1 FROM public.users WHERE role='admin' AND active AND id<>s.id) THEN RAISE EXCEPTION 'last_active_admin';END IF;
 IF (NOT next_active OR next_role<>s.role) AND EXISTS(SELECT 1 FROM public.orders WHERE status='active' AND (picker_id=s.id OR courier_id=s.id)) THEN RAISE EXCEPTION 'staff_has_active_orders';END IF;
 IF (NOT next_active OR next_role<>s.role) AND EXISTS(SELECT 1 FROM public.orders WHERE courier_id=s.id AND delivery_state='delivered' AND payment_state='awaiting_collection') THEN RAISE EXCEPTION 'staff_has_uncollected_orders';END IF;
 IF (NOT next_active OR next_role<>s.role) AND EXISTS(SELECT 1 FROM public.tickets WHERE assigned_to=s.id AND state<>'closed') THEN RAISE EXCEPTION 'staff_has_open_tickets';END IF;
 IF (NOT next_active OR next_role<>s.role) AND EXISTS(SELECT 1 FROM public.orders WHERE courier_id=s.id AND collected_halalas-settled_halalas-courier_refunded_halalas>0) THEN RAISE EXCEPTION 'staff_has_cash_liability';END IF;
 UPDATE public.users SET name=next_name,email=next_email,phone=next_phone,role=next_role,active=next_active WHERE id=s.id RETURNING * INTO r;
 IF s.role<>r.role OR s.active<>r.active THEN DELETE FROM public.sessions WHERE user_id=s.id;END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'staff_updated',s.id,jsonb_build_object('role',u.role,'reason',trim(p_reason),'before',public.jana_staff_public(s),'after',public.jana_staff_public(r)),nowms);
 RETURN public.jana_staff_public(r)||jsonb_build_object('sign_in_again',s.id=u.id AND (s.role<>r.role OR s.active<>r.active));
END$$;

CREATE FUNCTION public.jana_assign_order(p_token text,p_order_id text,p_assignments jsonb,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;pid text;cid text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('jana-staff-membership',0));
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF o.status<>'active' OR jsonb_typeof(p_assignments) IS DISTINCT FROM 'object' OR NOT (p_assignments?'picker_id' OR p_assignments?'courier_id') OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'assignment_validation';END IF;
 pid=CASE WHEN p_assignments?'picker_id' THEN nullif(p_assignments->>'picker_id','') ELSE o.picker_id END;
 cid=CASE WHEN p_assignments?'courier_id' THEN nullif(p_assignments->>'courier_id','') ELSE o.courier_id END;
 IF p_assignments?'picker_id' THEN
  IF o.fulfillment_state NOT IN ('queued','picking','awaiting_customer') OR pid IS NULL OR NOT EXISTS(SELECT 1 FROM public.users WHERE id=pid AND active AND role IN ('admin','picker')) THEN RAISE EXCEPTION 'picker_assignment_invalid';END IF;
 END IF;
 IF p_assignments?'courier_id' THEN
  IF o.fulfillment_state<>'ready' OR o.delivery_state NOT IN ('unassigned','assigned','failed') OR o.collected_halalas<>0 OR cid IS NULL OR NOT EXISTS(SELECT 1 FROM public.users WHERE id=cid AND active AND role='courier') THEN RAISE EXCEPTION 'courier_assignment_invalid';END IF;
 END IF;
 UPDATE public.orders SET picker_id=pid,courier_id=cid,delivery_state=CASE WHEN p_assignments?'courier_id' THEN 'assigned' ELSE delivery_state END WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'staff_assigned',trim(p_reason),jsonb_build_object('picker_id',pid,'courier_id',cid),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'order_staff_assigned',o.id,jsonb_build_object('role',u.role,'reason',trim(p_reason),'before',jsonb_build_object('picker_id',o.picker_id,'courier_id',o.courier_id),'after',jsonb_build_object('picker_id',pid,'courier_id',cid)),nowms);
 RETURN jsonb_build_object('id',o.id,'picker_id',pid,'courier_id',cid);
END$$;

-- Self-claiming an order holds the active staff row until assignment commits.
-- This closes the race with a concurrent administrative deactivation.
ALTER FUNCTION public.jana_ops_transition(text,text,text,text) RENAME TO jana_ops_transition_finance_base;
CREATE FUNCTION public.jana_ops_transition(p_token text,p_order_id text,p_action text,p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;
BEGIN
 u=public.jana_auth_user(p_token);
 PERFORM 1 FROM public.users WHERE id=u.id FOR SHARE;
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker','courier') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF u.role='admin' AND lower(trim(p_action)) IN ('dispatch','out_for_delivery','assign_courier') AND (o.courier_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.users WHERE id=o.courier_id AND role='courier' AND active)) THEN RAISE EXCEPTION 'courier_assignment_invalid';END IF;
 RETURN public.jana_ops_transition_finance_base(p_token,p_order_id,p_action,p_code);
END$$;

CREATE FUNCTION public.jana_staff_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;prior public.idempotency_records;scope_key text;req_hash text;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('jana-staff-membership',0));u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation IS NULL OR p_operation NOT IN ('staff.create','staff.update','order.assign') THEN RAISE EXCEPTION 'invalid_operation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='staff:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 CASE p_operation
 WHEN 'staff.create' THEN r=public.jana_create_staff(p_token,p_payload->>'email',p_payload->>'name',p_payload->>'password',p_payload->>'role');
 WHEN 'staff.update' THEN r=public.jana_update_staff(p_token,p_payload->>'user_id',p_payload->'changes',p_payload->>'reason');
 WHEN 'order.assign' THEN r=public.jana_assign_order(p_token,p_payload->>'order_id',p_payload->'assignments',p_payload->>'reason');
 END CASE;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,req_hash,r,(extract(epoch from clock_timestamp())*1000)::bigint);
 RETURN r;
END$$;

CREATE FUNCTION public.jana_audit_redact(p_value jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE r jsonb;
BEGIN
 IF jsonb_typeof(p_value)='object' THEN
  SELECT coalesce(jsonb_object_agg(key,public.jana_audit_redact(value)),'{}') INTO r FROM jsonb_each(p_value)
  WHERE key !~* '(password|token|cookie|secret|csrf|private.key|service.role.key)';RETURN r;
 ELSIF jsonb_typeof(p_value)='array' THEN
  SELECT coalesce(jsonb_agg(public.jana_audit_redact(value) ORDER BY ordinality),'[]') INTO r FROM jsonb_array_elements(p_value) WITH ORDINALITY;RETURN r;
 END IF;RETURN p_value;
END$$;

CREATE FUNCTION public.jana_audit_page(p_token text,p_before_at bigint DEFAULT NULL,p_before_id text DEFAULT NULL,p_action text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;rows jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) OR length(coalesce(p_action,''))>100 THEN RAISE EXCEPTION 'audit_validation';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC),'[]') INTO rows FROM (
 SELECT a.id,a.actor_id,actor.name actor_name,a.action,a.entity_id,public.jana_audit_redact(a.detail::jsonb) detail,a.created_at
 FROM public.audit_log a LEFT JOIN public.users actor ON actor.id=a.actor_id
 WHERE (p_before_at IS NULL OR (a.created_at,a.id)<(p_before_at,p_before_id)) AND (nullif(p_action,'') IS NULL OR a.action=p_action)
 ORDER BY a.created_at DESC,a.id DESC LIMIT 50)x;
 RETURN jsonb_build_object('items',rows,'next',CASE WHEN jsonb_array_length(rows)=50 THEN jsonb_build_object('before_at',rows->49->'created_at','before_id',rows->49->>'id') ELSE NULL END);
END$$;
CREATE INDEX jana_audit_page_idx ON public.audit_log(created_at DESC,id DESC);

DO $privs$ DECLARE r record;BEGIN
 FOR r IN SELECT oid::regprocedure sig,proname FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=ANY(ARRAY['jana_audit_redact','jana_staff_public','jana_list_staff','jana_create_staff','jana_update_staff','jana_assign_order','jana_ops_transition','jana_ops_transition_finance_base','jana_staff_write','jana_audit_page']) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.sig);
  IF r.proname IN ('jana_audit_redact','jana_staff_public','jana_ops_transition_finance_base') THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role',r.sig);ELSE EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',r.sig);END IF;
 END LOOP;
END $privs$;
