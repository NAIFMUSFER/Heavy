-- A phone is a login identifier, not proof of ownership. Registration never
-- marks it verified or enables SMS recovery without an actual provider.
CREATE FUNCTION public.jana_normalize_phone(p_phone text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE WHEN trim(p_phone) ~ '^05[0-9]{8}$' THEN '+966'||substring(trim(p_phone) FROM 2) WHEN trim(p_phone) ~ '^\+9665[0-9]{8}$' THEN trim(p_phone) ELSE NULL END
$$;
ALTER TABLE public.users ALTER COLUMN email DROP NOT NULL;
ALTER TABLE public.users ADD CONSTRAINT jana_account_identifier CHECK(email IS NOT NULL OR public.jana_normalize_phone(phone) IS NOT NULL);
CREATE UNIQUE INDEX jana_users_normalized_phone ON public.users(public.jana_normalize_phone(phone)) WHERE phone IS NOT NULL;

CREATE OR REPLACE FUNCTION public.jana_register(p_email text,p_name text,p_password text,p_phone text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid text;tok text;csrf text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;normalized_phone text;
BEGIN
 p_email=nullif(lower(trim(p_email)),'');p_name=trim(p_name);p_phone=nullif(trim(p_phone),'');normalized_phone=public.jana_normalize_phone(p_phone);
 IF p_email IS NOT NULL AND (length(p_email)>254 OR p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') THEN RAISE EXCEPTION 'invalid_email';END IF;
 IF (p_phone IS NOT NULL AND normalized_phone IS NULL) OR (p_email IS NULL AND normalized_phone IS NULL) THEN RAISE EXCEPTION 'account_identifier_required';END IF;
 IF p_name IS NULL OR length(p_name) NOT BETWEEN 2 AND 100 THEN RAISE EXCEPTION 'invalid_name';END IF;
 IF p_password IS NULL OR length(p_password)<12 OR octet_length(p_password)>72 THEN RAISE EXCEPTION 'weak_password';END IF;
 uid='usr-'||replace(gen_random_uuid()::text,'-','');
 BEGIN
  INSERT INTO public.users(id,email,phone,name,password_hash,role,verified_phone,active,created_at) VALUES(uid,p_email,normalized_phone,p_name,crypt(p_password,gen_salt('bf',12)),'customer',false,true,nowms);
 EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'account_exists';END;
 tok=encode(gen_random_bytes(32),'hex');csrf=encode(gen_random_bytes(24),'hex');
 INSERT INTO public.sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(digest(tok,'sha256'),'hex'),uid,encode(digest(csrf,'sha256'),'hex'),nowms+2592000000,nowms);
 RETURN jsonb_build_object('token',tok,'csrf',csrf,'expires_at',nowms+2592000000,'user',jsonb_build_object('id',uid,'email',p_email,'phone',normalized_phone,'verified_phone',false,'name',p_name,'role','customer'));
END$$;

CREATE OR REPLACE FUNCTION public.jana_login(p_email text,p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;tok text;csrf text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;k text;rc integer;normalized_phone text;
BEGIN
 p_email=lower(trim(coalesce(p_email,'')));normalized_phone=public.jana_normalize_phone(p_email);
 IF length(p_email)<3 OR length(p_email)>254 THEN RETURN jsonb_build_object('_error','invalid_credentials','status',401);END IF;
 SELECT * INTO u FROM public.users WHERE active AND (email=p_email OR (normalized_phone IS NOT NULL AND role='customer' AND public.jana_normalize_phone(phone)=normalized_phone));
 -- Email and phone aliases for one account share a single persistent limit.
 k='login:'||encode(digest(coalesce(u.email,normalized_phone,p_email),'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(k,0));
 INSERT INTO public.rate_windows(key,count,expires_at) VALUES(k,0,nowms+900000) ON CONFLICT(key) DO UPDATE SET count=CASE WHEN rate_windows.expires_at<=nowms THEN 0 ELSE rate_windows.count END,expires_at=CASE WHEN rate_windows.expires_at<=nowms THEN excluded.expires_at ELSE rate_windows.expires_at END;
 SELECT count INTO rc FROM public.rate_windows WHERE key=k FOR UPDATE;
 IF rc>=10 THEN RETURN jsonb_build_object('_error','too_many_attempts','status',429);END IF;
 IF u.id IS NOT NULL THEN SELECT * INTO u FROM public.users WHERE id=u.id AND active AND (email=p_email OR (normalized_phone IS NOT NULL AND role='customer' AND public.jana_normalize_phone(phone)=normalized_phone)) FOR SHARE;END IF;
 IF p_password IS NULL OR length(p_password)=0 OR octet_length(p_password)>72 OR u.id IS NULL OR u.password_hash IS NULL OR crypt(p_password,u.password_hash) IS DISTINCT FROM u.password_hash THEN
  UPDATE public.rate_windows SET count=count+1 WHERE key=k;RETURN jsonb_build_object('_error','invalid_credentials','status',401);
 END IF;
 DELETE FROM public.rate_windows WHERE key=k;tok=encode(gen_random_bytes(32),'hex');csrf=encode(gen_random_bytes(24),'hex');
 INSERT INTO public.sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(digest(tok,'sha256'),'hex'),u.id,encode(digest(csrf,'sha256'),'hex'),nowms+2592000000,nowms);
 RETURN jsonb_build_object('token',tok,'csrf',csrf,'expires_at',nowms+2592000000,'user',jsonb_build_object('id',u.id,'email',u.email,'phone',u.phone,'verified_phone',u.verified_phone,'name',u.name,'role',u.role));
END$$;

CREATE OR REPLACE FUNCTION public.jana_customer_profile(p_token text,p_changes jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;nm text;phone_value text;pref jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_changes IS NOT NULL THEN
  SELECT * INTO u FROM public.users WHERE id=u.id FOR UPDATE;nm=trim(coalesce(p_changes->>'name',u.name));phone_value=CASE WHEN p_changes?'phone' THEN nullif(trim(p_changes->>'phone'),'') ELSE u.phone END;pref=coalesce(p_changes->'preferences',u.preferences);
  IF jsonb_typeof(p_changes) IS DISTINCT FROM 'object' OR length(nm) NOT BETWEEN 2 AND 100 OR (phone_value IS NOT NULL AND public.jana_normalize_phone(phone_value) IS NULL) OR (u.email IS NULL AND phone_value IS NULL) OR jsonb_typeof(pref) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_each(pref) WHERE key NOT IN ('language','marketing_opt_in')) OR (pref?'language' AND (jsonb_typeof(pref->'language') IS DISTINCT FROM 'string' OR pref->>'language'<>'ar')) OR (pref?'marketing_opt_in' AND jsonb_typeof(pref->'marketing_opt_in') IS DISTINCT FROM 'boolean') THEN RAISE EXCEPTION 'profile_validation';END IF;
  BEGIN UPDATE public.users SET name=nm,phone=phone_value,verified_phone=CASE WHEN public.jana_normalize_phone(phone) IS DISTINCT FROM public.jana_normalize_phone(phone_value) THEN false ELSE verified_phone END,preferences=pref WHERE id=u.id RETURNING * INTO u;EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'phone_already_used';END;
 END IF;
 RETURN jsonb_build_object('id',u.id,'name',u.name,'email',u.email,'phone',u.phone,'verified_phone',u.verified_phone,'preferences',u.preferences);
END$$;
REVOKE ALL ON FUNCTION public.jana_normalize_phone(text) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_register(text,text,text,text),public.jana_login(text,text),public.jana_customer_profile(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_register(text,text,text,text),public.jana_login(text,text),public.jana_customer_profile(text,jsonb) TO service_role;
