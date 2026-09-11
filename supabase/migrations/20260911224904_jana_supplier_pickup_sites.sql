-- Supplier/retail pickup directory: no warehouse, quantity, purchase or cash side effects.
-- Existing suppliers keep their identities and financial history. No rows are seeded.
CREATE TABLE public.supplier_pickup_sites (
 id varchar(36) PRIMARY KEY,
 supplier_id varchar(36) NOT NULL REFERENCES public.suppliers(id),
 name varchar(120) NOT NULL CHECK(length(trim(name)) BETWEEN 2 AND 120),
 city varchar(120) NOT NULL DEFAULT '',
 address_line varchar(300) NOT NULL DEFAULT '',
 latitude numeric,
 longitude numeric,
 instructions varchar(1000) NOT NULL DEFAULT '',
 active boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 created_at bigint NOT NULL,
 updated_at bigint NOT NULL,
 CONSTRAINT pickup_coordinates CHECK ((latitude IS NULL AND longitude IS NULL) OR
  (latitude IS NOT NULL AND longitude IS NOT NULL AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)),
 CONSTRAINT pickup_active_address CHECK (NOT active OR
  (length(trim(city))>=2 AND length(trim(address_line))>=3 AND latitude IS NOT NULL AND longitude IS NOT NULL))
);
CREATE INDEX jana_pickup_supplier ON public.supplier_pickup_sites(supplier_id,id);
ALTER TABLE public.supplier_pickup_sites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_pickup_sites FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.supplier_pickup_sites TO service_role;

CREATE FUNCTION public.jana_supplier_pickup_sites(p_token text,p_limit integer DEFAULT 50,p_after_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; rows jsonb; suppliers_list jsonb; has_more boolean; next_id text;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','inventory','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR (p_after_id IS NOT NULL AND p_after_id !~ '^pup-[a-f0-9]{32}$') THEN RAISE EXCEPTION 'pickup_validation';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id),'[]'::jsonb) INTO rows FROM (
  SELECT p.*,s.name AS supplier_name,s.phone AS supplier_phone,s.active AS supplier_active
  FROM public.supplier_pickup_sites p JOIN public.suppliers s ON s.id=p.supplier_id
  WHERE (p_after_id IS NULL OR p.id>p_after_id) AND (u.role<>'picker' OR (p.active AND s.active))
  ORDER BY p.id LIMIT p_limit+1
 ) x;
 has_more=jsonb_array_length(rows)>p_limit;
 IF has_more THEN rows=rows-p_limit;next_id=rows->(p_limit-1)->>'id';END IF;
 -- Only maintainers need supplier choices; omit private supplier notes/email.
 SELECT CASE WHEN u.role='picker' THEN '[]'::jsonb ELSE coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id),'[]'::jsonb) END INTO suppliers_list
 FROM (SELECT id,name,phone,active FROM public.suppliers ORDER BY id LIMIT 250) x;
 RETURN jsonb_build_object('items',rows,'next',next_id,'suppliers',suppliers_list,
  'suppliers_truncated',u.role<>'picker' AND (SELECT count(*)>250 FROM public.suppliers),
  'can_manage',u.role IN ('admin','inventory'),'operating_model','supplier_pickup',
  'order_flow_ready',false);
END$$;

CREATE FUNCTION public.jana_supplier_pickup_site_write(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;previous public.idempotency_records;scope_key text;request_hash text;result jsonb;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;reason text;changes jsonb;k text;
 site public.supplier_pickup_sites;saved public.supplier_pickup_sites;before_state jsonb;site_id text;v_supplier public.suppliers;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) AS t(key) WHERE key NOT IN ('id','revision','reason','changes')) THEN RAISE EXCEPTION 'pickup_validation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='supplier-pickup:'||u.id||':'||p_idem_key;
 request_hash=encode(digest(p_payload::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO previous FROM public.idempotency_records WHERE scope=scope_key;
 IF previous.scope IS NOT NULL THEN IF previous.request_hash<>request_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN previous.response::jsonb;END IF;
 reason=trim(coalesce(p_payload->>'reason',''));IF length(reason) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'pickup_validation';END IF;
 changes=p_payload->'changes';IF jsonb_typeof(changes) IS DISTINCT FROM 'object' OR changes='{}'::jsonb OR EXISTS(SELECT 1 FROM jsonb_object_keys(changes) AS t(key) WHERE key NOT IN ('supplier_id','name','city','address_line','latitude','longitude','instructions','active')) THEN RAISE EXCEPTION 'pickup_validation';END IF;
 site_id=nullif(p_payload->>'id','');
 IF site_id IS NULL THEN
  site.id='pup-'||replace(gen_random_uuid()::text,'-','');site.active=false;site.revision=1;site.created_at=nowms;
  site.city='';site.address_line='';site.instructions='';
 ELSE
  SELECT * INTO site FROM public.supplier_pickup_sites WHERE id=site_id FOR UPDATE;
  IF site.id IS NULL THEN RAISE EXCEPTION 'pickup_not_found';END IF;
  IF jsonb_typeof(p_payload->'revision') IS DISTINCT FROM 'number' OR (p_payload->>'revision')::numeric IS DISTINCT FROM site.revision::numeric THEN RAISE EXCEPTION 'pickup_changed';END IF;
  before_state=to_jsonb(site);
 END IF;
 FOREACH k IN ARRAY ARRAY['supplier_id','name','city','address_line','instructions'] LOOP
  IF changes?k AND (jsonb_typeof(changes->k) IS DISTINCT FROM 'string' OR length(trim(changes->>k))>CASE k WHEN 'supplier_id' THEN 36 WHEN 'name' THEN 120 WHEN 'city' THEN 120 WHEN 'address_line' THEN 300 ELSE 1000 END) THEN RAISE EXCEPTION 'pickup_validation';END IF;
 END LOOP;
 IF changes?'supplier_id' THEN
  IF length(trim(changes->>'supplier_id')) NOT BETWEEN 1 AND 36 THEN RAISE EXCEPTION 'pickup_validation';END IF;
  IF site_id IS NOT NULL AND trim(changes->>'supplier_id')<>site.supplier_id THEN RAISE EXCEPTION 'pickup_supplier_immutable';END IF;
  site.supplier_id=trim(changes->>'supplier_id');
 END IF;
 IF changes?'name' THEN site.name=trim(changes->>'name');END IF;
 IF changes?'city' THEN site.city=trim(changes->>'city');END IF;
 IF changes?'address_line' THEN site.address_line=trim(changes->>'address_line');END IF;
 IF changes?'instructions' THEN site.instructions=trim(changes->>'instructions');END IF;
 IF changes?'latitude' OR changes?'longitude' THEN
  IF NOT(changes?'latitude' AND changes?'longitude') OR
   (jsonb_typeof(changes->'latitude') NOT IN ('number','null')) OR
   (jsonb_typeof(changes->'longitude') NOT IN ('number','null')) THEN RAISE EXCEPTION 'pickup_validation';END IF;
  site.latitude=(changes->>'latitude')::numeric;site.longitude=(changes->>'longitude')::numeric;
 END IF;
 IF changes?'active' THEN IF jsonb_typeof(changes->'active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'pickup_validation';END IF;site.active=(changes->>'active')::boolean;END IF;
 IF site.name IS NULL OR length(site.name)<2 OR
  ((site.latitude IS NULL)<>(site.longitude IS NULL)) OR
  (site.latitude IS NOT NULL AND (site.latitude NOT BETWEEN -90 AND 90 OR site.longitude NOT BETWEEN -180 AND 180)) THEN RAISE EXCEPTION 'pickup_validation';END IF;
 SELECT * INTO v_supplier FROM public.suppliers WHERE id=site.supplier_id FOR SHARE;
 IF v_supplier.id IS NULL THEN RAISE EXCEPTION 'pickup_supplier_required';END IF;
 IF site.active AND (NOT v_supplier.active OR length(site.city)<2 OR length(site.address_line)<3 OR site.latitude IS NULL) THEN RAISE EXCEPTION 'pickup_incomplete';END IF;
 site.updated_at=nowms;
 IF site_id IS NULL THEN
  INSERT INTO public.supplier_pickup_sites SELECT (site).* RETURNING * INTO saved;
 ELSE
  UPDATE public.supplier_pickup_sites SET name=site.name,city=site.city,address_line=site.address_line,
   latitude=site.latitude,longitude=site.longitude,instructions=site.instructions,active=site.active,
   revision=revision+1,updated_at=nowms WHERE id=site_id RETURNING * INTO saved;
 END IF;
 result=to_jsonb(saved);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES
 ('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN site_id IS NULL THEN 'supplier_pickup_site_created' ELSE 'supplier_pickup_site_updated' END,site.id,
 jsonb_build_object('before',before_state,'after',result,'reason',reason,'directory_only',true),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,request_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range THEN RAISE EXCEPTION 'pickup_validation';
END$$;
REVOKE ALL ON FUNCTION public.jana_supplier_pickup_sites(text,integer,text),public.jana_supplier_pickup_site_write(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_supplier_pickup_sites(text,integer,text),public.jana_supplier_pickup_site_write(text,text,jsonb) TO service_role;
