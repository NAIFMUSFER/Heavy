CREATE OR REPLACE FUNCTION public.jana_login(p_email text,p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; tok text; csrf text; nowms bigint; expms bigint; k text; rc int; rex bigint;
BEGIN
 p_email=lower(trim(p_email)); nowms=(extract(epoch from clock_timestamp())*1000)::bigint; k='login:'||encode(digest(p_email,'sha256'),'hex');
 SELECT count,expires_at INTO rc,rex FROM public.rate_windows WHERE key=k FOR UPDATE;
 IF rc IS NOT NULL AND rex>nowms AND rc>=10 THEN RAISE EXCEPTION 'too_many_attempts'; END IF;
 IF rex IS NULL OR rex<=nowms THEN INSERT INTO public.rate_windows(key,count,expires_at) VALUES(k,0,nowms+900000) ON CONFLICT(key) DO UPDATE SET count=0,expires_at=excluded.expires_at; END IF;
 SELECT * INTO u FROM public.users WHERE email=p_email AND active LIMIT 1;
 IF u.id IS NULL OR u.password_hash IS NULL OR crypt(p_password,u.password_hash)<>u.password_hash THEN UPDATE public.rate_windows SET count=count+1 WHERE key=k; RAISE EXCEPTION 'invalid_credentials'; END IF;
 DELETE FROM public.rate_windows WHERE key=k; expms=nowms+2592000000; tok=encode(gen_random_bytes(32),'hex'); csrf=encode(gen_random_bytes(24),'hex');
 INSERT INTO public.sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(digest(tok,'sha256'),'hex'),u.id,encode(digest(csrf,'sha256'),'hex'),expms,nowms);
 RETURN jsonb_build_object('token',tok,'csrf',csrf,'expires_at',expms,'user',jsonb_build_object('id',u.id,'email',u.email,'name',u.name,'role',u.role));
END$$;

CREATE OR REPLACE FUNCTION public.jana_change_password(p_token text,p_current text,p_new text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; th text; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token); IF length(p_new)<12 OR length(p_new)>128 THEN RAISE EXCEPTION 'weak_password'; END IF;
 IF crypt(p_current,u.password_hash)<>u.password_hash THEN RAISE EXCEPTION 'invalid_credentials'; END IF;
 UPDATE public.users SET password_hash=crypt(p_new,gen_salt('bf',12)) WHERE id=u.id; th=encode(digest(p_token,'sha256'),'hex'); DELETE FROM public.sessions WHERE user_id=u.id AND token_hash<>th;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'password_changed',u.id,'{}'::jsonb,nowms);
 RETURN jsonb_build_object('ok',true,'other_sessions_revoked',true);
END$$;

CREATE OR REPLACE FUNCTION public.jana_support_tickets(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token); IF u.role NOT IN ('admin','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',t.id,'user_id',t.user_id,'customer_name',cu.name,'customer_email',cu.email,'order_id',t.order_id,'subject',t.subject,'state',t.state,'priority',t.priority,'assigned_to',t.assigned_to,'messages',t.messages,'created_at',t.created_at,'updated_at',t.updated_at) ORDER BY CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 ELSE 2 END,t.updated_at DESC) FROM public.tickets t JOIN public.users cu ON cu.id=t.user_id WHERE t.state<>'closed' OR t.updated_at>(extract(epoch from clock_timestamp())*1000)::bigint-604800000),'[]'::jsonb);
END$$;

CREATE OR REPLACE FUNCTION public.jana_support_reply(p_token text,p_ticket_id text,p_message text,p_state text DEFAULT NULL,p_priority text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; t public.tickets; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint; nm json; ns text; np text;
BEGIN
 u=public.jana_auth_user(p_token); IF u.role NOT IN ('admin','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO t FROM public.tickets WHERE id=p_ticket_id FOR UPDATE; IF t.id IS NULL THEN RAISE EXCEPTION 'ticket_not_found'; END IF;
 IF length(trim(coalesce(p_message,'')))>2000 THEN RAISE EXCEPTION 'invalid_ticket'; END IF;
 ns=COALESCE(NULLIF(p_state,''),t.state); np=COALESCE(NULLIF(p_priority,''),t.priority);
 IF ns NOT IN ('open','pending_customer','closed') OR np NOT IN ('normal','high','urgent') THEN RAISE EXCEPTION 'invalid_ticket'; END IF;
 nm=COALESCE(t.messages,'[]'::json)::jsonb || jsonb_build_array(jsonb_build_object('by','support','actor_id',u.id,'message',left(trim(coalesce(p_message,'')),2000),'at',nowms));
 UPDATE public.tickets SET messages=nm,state=ns,priority=np,assigned_to=COALESCE(assigned_to,u.id),updated_at=nowms WHERE id=t.id;
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),t.user_id,'ticket-'||t.id||'-'||nowms,'رد من خدمة العملاء',CASE WHEN trim(coalesce(p_message,''))='' THEN 'تم تحديث حالة طلب الدعم' ELSE left(trim(p_message),180) END,t.order_id,false,nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'ticket_updated',t.id,jsonb_build_object('state',ns,'priority',np),nowms);
 RETURN jsonb_build_object('id',t.id,'state',ns,'priority',np);
END$$;

DO $$ DECLARE r record; BEGIN FOR r IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'jana_%' LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',r.sig); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',r.sig); END LOOP; END $$;