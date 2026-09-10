-- Published seller identity and policies are immutable commercial versions.
-- Launch starts closed; existing orders and reserved quotes are not rewritten.
CREATE TABLE public.storefront_profiles(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),version integer NOT NULL UNIQUE CHECK(version>0),
 profile jsonb NOT NULL CHECK(jsonb_typeof(profile)='object'),published_at bigint NOT NULL,
 published_by varchar(36) NOT NULL REFERENCES public.users(id)
);
CREATE INDEX jana_storefront_publisher ON public.storefront_profiles(published_by);
CREATE TRIGGER jana_storefront_immutable BEFORE UPDATE OR DELETE ON public.storefront_profiles
 FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();
CREATE TABLE public.storefront_state(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 draft jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(draft)='object'),
 published_id uuid REFERENCES public.storefront_profiles(id),accepting_orders boolean NOT NULL DEFAULT false,
 customer_message text NOT NULL DEFAULT 'نجهز المتجر لاستقبال الطلبات. يمكنك تصفح المنتجات والاحتفاظ بسلتك.',
 updated_at bigint NOT NULL DEFAULT 0
);
INSERT INTO public.storefront_state(singleton) VALUES(true);
ALTER TABLE public.storefront_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.storefront_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storefront_profiles,public.storefront_state FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.storefront_profiles,public.storefront_state TO service_role;

CREATE FUNCTION public.jana_storefront_profile_valid(p_profile jsonb,p_complete boolean)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE k text;v text;allowed text[]:=ARRAY['display_name','legal_name','registration_type','registration_number','business_address','phone','email','support_hours','tax_status','tax_number','terms','privacy','delivery','returns'];
BEGIN
 IF p_profile IS NULL OR jsonb_typeof(p_profile)<>'object' OR octet_length(p_profile::text)>60000 THEN RETURN false;END IF;
 FOR k,v IN SELECT key,value FROM jsonb_each_text(p_profile) LOOP
  IF NOT k=ANY(allowed) OR jsonb_typeof(p_profile->k)<>'string' THEN RETURN false;END IF;
  IF length(v)>CASE WHEN k IN ('terms','privacy','delivery','returns') THEN 6000 ELSE 500 END THEN RETURN false;END IF;
 END LOOP;
 IF p_profile?'tax_status' AND p_profile->>'tax_status' NOT IN ('','not_registered','registered') THEN RETURN false;END IF;
 IF p_profile?'registration_type' AND p_profile->>'registration_type' NOT IN ('','commercial_registration','freelance_document','other_license') THEN RETURN false;END IF;
 IF NOT p_complete THEN RETURN true;END IF;
 IF NOT p_profile ?& allowed OR p_profile->>'tax_status' NOT IN ('not_registered','registered')
  OR p_profile->>'registration_type' NOT IN ('commercial_registration','freelance_document','other_license') THEN RETURN false;END IF;
 FOREACH k IN ARRAY ARRAY['display_name','legal_name','registration_number','business_address','support_hours'] LOOP
  IF length(trim(p_profile->>k)) NOT BETWEEN 3 AND 500 THEN RETURN false;END IF;
 END LOOP;
 FOREACH k IN ARRAY ARRAY['terms','privacy','delivery','returns'] LOOP
  IF length(trim(p_profile->>k)) NOT BETWEEN 50 AND 6000 THEN RETURN false;END IF;
 END LOOP;
 IF p_profile->>'phone' !~ '^[+]?[0-9 ()-]{7,25}$' OR p_profile->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN RETURN false;END IF;
 IF p_profile->>'tax_status'='registered' AND p_profile->>'tax_number' !~ '^[0-9]{15}$' THEN RETURN false;END IF;
 IF p_profile->>'tax_status'='not_registered' AND p_profile->>'tax_number'<>'' THEN RETURN false;END IF;
 RETURN true;
END$$;

CREATE FUNCTION public.jana_storefront_readiness() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE p jsonb;s public.storefront_state;nowms bigint:=(extract(epoch from statement_timestamp())*1000)::bigint;
BEGIN
 SELECT * INTO s FROM public.storefront_state WHERE singleton;
 SELECT profile INTO p FROM public.storefront_profiles WHERE id=s.published_id;
 RETURN jsonb_build_object('profile_published',p IS NOT NULL,'tax_supported',coalesce(p->>'tax_status'='not_registered',false),
 'preview_products',(SELECT count(*) FROM public.offerings WHERE active AND (description ~* '(معاينة|تجريبي|preview|demo)')),
 'active_products',(SELECT count(*) FROM public.offerings WHERE active),
 'available_products',(SELECT count(*) FROM jsonb_array_elements(public.jana_public_catalog()) item WHERE (item->>'available_units')::bigint>0),
 'available_slots',(SELECT count(*) FROM public.delivery_slots sl JOIN public.delivery_zones z ON z.id=sl.zone_id WHERE sl.active AND z.active AND sl.cutoff_at>nowms AND sl.booked<sl.capacity),
 'health',public.jana_deep_health());
END$$;

CREATE FUNCTION public.jana_public_storefront(p_version_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE s public.storefront_state;p public.storefront_profiles;
BEGIN
 SELECT * INTO s FROM public.storefront_state WHERE singleton;
 SELECT * INTO p FROM public.storefront_profiles WHERE id=coalesce(p_version_id,s.published_id);
 IF p_version_id IS NOT NULL AND p.id IS NULL THEN RAISE EXCEPTION 'storefront_version_not_found';END IF;
 RETURN jsonb_build_object('accepting_orders',s.accepting_orders,'message',s.customer_message,
  'published',CASE WHEN p.id IS NULL THEN NULL ELSE jsonb_build_object('id',p.id,'version',p.version,'published_at',p.published_at,'profile',p.profile) END);
END$$;

CREATE FUNCTION public.jana_admin_storefront(p_token text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;s public.storefront_state;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO s FROM public.storefront_state WHERE singleton;
 RETURN to_jsonb(s)||public.jana_public_storefront()||jsonb_build_object('readiness',public.jana_storefront_readiness());
END$$;

CREATE FUNCTION public.jana_storefront_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.storefront_state;prior public.idempotency_records;scope_key text;req_hash text;
 result jsonb;readiness jsonb;profile jsonb;v public.storefront_profiles;nowms bigint;new_accepting boolean;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation IS NULL OR p_operation NOT IN ('draft.save','profile.publish','intake.set') THEN RAISE EXCEPTION 'invalid_operation';END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'storefront_validation';END IF;
 IF jsonb_typeof(p_payload->'revision') IS DISTINCT FROM 'number' OR p_payload->>'revision' !~ '^[0-9]{1,15}$' THEN RAISE EXCEPTION 'storefront_validation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='storefront:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 SELECT * INTO s FROM public.storefront_state WHERE singleton FOR UPDATE;
 IF s.revision<>(p_payload->>'revision')::bigint THEN RAISE EXCEPTION 'storefront_changed';END IF;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 IF p_operation='draft.save' THEN
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('revision','profile')) OR NOT public.jana_storefront_profile_valid(p_payload->'profile',false) THEN RAISE EXCEPTION 'storefront_validation';END IF;
  SELECT coalesce(jsonb_object_agg(key,trim(value)),'{}') INTO profile FROM jsonb_each_text(p_payload->'profile');
  UPDATE public.storefront_state SET draft=profile,revision=revision+1,updated_at=nowms WHERE singleton;
 ELSIF p_operation='profile.publish' THEN
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('revision','confirmed')) OR p_payload->'confirmed' IS DISTINCT FROM 'true'::jsonb OR NOT public.jana_storefront_profile_valid(s.draft,true) THEN RAISE EXCEPTION 'storefront_validation';END IF;
  IF s.accepting_orders AND s.draft->>'tax_status'<>'not_registered' THEN RAISE EXCEPTION 'storefront_tax_setup_required';END IF;
  INSERT INTO public.storefront_profiles(version,profile,published_at,published_by)
  VALUES((SELECT coalesce(max(version),0)+1 FROM public.storefront_profiles),s.draft,nowms,u.id) RETURNING * INTO v;
  UPDATE public.storefront_state SET published_id=v.id,revision=revision+1,updated_at=nowms WHERE singleton;
 ELSE
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('revision','accepting_orders','message','reason','reviewed','reference'))
   OR jsonb_typeof(p_payload->'accepting_orders') IS DISTINCT FROM 'boolean'
   OR jsonb_typeof(p_payload->'reason') IS DISTINCT FROM 'string' OR length(trim(p_payload->>'reason')) NOT BETWEEN 8 AND 1000
   OR jsonb_typeof(p_payload->'message') IS DISTINCT FROM 'string' OR length(trim(p_payload->>'message')) NOT BETWEEN 8 AND 300 THEN RAISE EXCEPTION 'storefront_validation';END IF;
  new_accepting=(p_payload->>'accepting_orders')::boolean;
  IF new_accepting THEN
   IF p_payload->'reviewed' IS DISTINCT FROM '{"catalog":true,"inventory":true,"coverage":true,"tax":true,"operations":true}'::jsonb
    OR jsonb_typeof(p_payload->'reference') IS DISTINCT FROM 'string' OR length(trim(p_payload->>'reference')) NOT BETWEEN 5 AND 180 THEN RAISE EXCEPTION 'storefront_review_required';END IF;
   readiness=public.jana_storefront_readiness();
   IF NOT (readiness->>'profile_published')::boolean THEN RAISE EXCEPTION 'storefront_not_ready';END IF;
   IF NOT (readiness->>'tax_supported')::boolean THEN RAISE EXCEPTION 'storefront_tax_setup_required';END IF;
   IF NOT (readiness->>'profile_published')::boolean OR (readiness->>'preview_products')::bigint<>0
    OR (readiness->>'available_products')::bigint<1 OR (readiness->>'available_slots')::bigint<1 OR NOT (readiness->'health'->>'ok')::boolean THEN RAISE EXCEPTION 'storefront_not_ready';END IF;
  END IF;
  UPDATE public.storefront_state SET accepting_orders=new_accepting,customer_message=trim(p_payload->>'message'),revision=revision+1,updated_at=nowms WHERE singleton;
 END IF;
 result=public.jana_admin_storefront(p_token);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'storefront_'||replace(p_operation,'.','_'),'storefront',
  jsonb_build_object('role',u.role,'before_revision',s.revision,'after_revision',result->'revision','published_id',result->'published_id','payload',p_payload),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
END$$;

ALTER FUNCTION public.jana_create_quote(text,text,text,jsonb) RENAME TO jana_create_quote_store_base;
CREATE FUNCTION public.jana_create_quote(p_token text,p_slot_id text,p_address_id text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE s public.storefront_state;p public.storefront_profiles;r jsonb;terms jsonb;
BEGIN
 -- Authenticate before returning store state; serialize admission with closure.
 PERFORM public.jana_auth_user(p_token);
 SELECT * INTO s FROM public.storefront_state WHERE singleton FOR SHARE;
 IF NOT s.accepting_orders OR s.published_id IS NULL THEN RAISE EXCEPTION 'storefront_closed';END IF;
 SELECT * INTO p FROM public.storefront_profiles WHERE id=s.published_id;
 r=public.jana_create_quote_store_base(p_token,p_slot_id,p_address_id,p_items);
 terms=jsonb_build_object('id',p.id,'version',p.version,'display_name',p.profile->>'display_name','legal_name',p.profile->>'legal_name',
  'registration_type',p.profile->>'registration_type','registration_number',p.profile->>'registration_number','tax_status',p.profile->>'tax_status');
 UPDATE public.quotes SET snapshot=(snapshot::jsonb||jsonb_build_object('store_profile',terms))::json WHERE id=r->>'id';
 RETURN r||jsonb_build_object('store_profile',terms);
END$$;

REVOKE ALL ON FUNCTION public.jana_storefront_profile_valid(jsonb,boolean),public.jana_storefront_readiness(),public.jana_create_quote_store_base(text,text,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_public_storefront(uuid),public.jana_admin_storefront(text),public.jana_storefront_write(text,text,text,jsonb),public.jana_create_quote(text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_public_storefront(uuid),public.jana_admin_storefront(text),public.jana_storefront_write(text,text,text,jsonb),public.jana_create_quote(text,text,text,jsonb) TO service_role;
