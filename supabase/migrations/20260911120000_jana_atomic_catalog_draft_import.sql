-- Owner-supplied catalog files create reviewable drafts only. The whole file is
-- committed atomically and retries cannot duplicate product families.
CREATE FUNCTION public.jana_admin_import_product_drafts(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users; previous public.idempotency_records; products jsonb; item jsonb;
 scope_key text; request_hash text; normalized_title text; seen_titles text[]='{}';
 result jsonb; drafts jsonb='[]'::jsonb; offering_count integer=0; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR p_payload->>'schema_version'<>'1'
  OR jsonb_typeof(p_payload->'products')<>'array' OR jsonb_array_length(p_payload->'products') NOT BETWEEN 1 AND 50
  OR length(p_payload::text)>1000000 THEN RAISE EXCEPTION 'catalog_import_validation';END IF;
 products=p_payload->'products';
 FOR item IN SELECT value FROM jsonb_array_elements(products) LOOP
  IF jsonb_typeof(item)<>'object' OR nullif(item->>'family_id','') IS NOT NULL OR nullif(item->>'copy_version_id','') IS NOT NULL
   OR jsonb_typeof(item->'offerings')<>'array' THEN RAISE EXCEPTION 'catalog_import_validation';END IF;
  normalized_title=lower(regexp_replace(trim(coalesce(item->>'title','')),'\s+',' ','g'));
  IF length(normalized_title) NOT BETWEEN 2 AND 140 OR normalized_title=ANY(seen_titles) THEN RAISE EXCEPTION 'catalog_import_duplicate_title';END IF;
  seen_titles=array_append(seen_titles,normalized_title);
  offering_count=offering_count+jsonb_array_length(item->'offerings');
  IF offering_count>500 THEN RAISE EXCEPTION 'catalog_import_validation';END IF;
 END LOOP;
 scope_key='catalog-import:'||u.id||':'||p_idem_key;
 request_hash=encode(digest(p_payload::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO previous FROM public.idempotency_records WHERE scope=scope_key;
 IF previous.scope IS NOT NULL THEN
  IF previous.request_hash<>request_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN previous.response::jsonb;
 END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(products) LOOP
  drafts=drafts||jsonb_build_array(public.jana_admin_create_product_version(p_token,NULL,item));
 END LOOP;
 result=jsonb_build_object('schema_version',1,'imported_count',jsonb_array_length(products),'offering_count',offering_count,'drafts',drafts);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,request_hash,result,nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'catalog_drafts_imported',scope_key,
  jsonb_build_object('product_count',jsonb_array_length(products),'offering_count',offering_count,'version_ids',(SELECT jsonb_agg(x->>'id') FROM jsonb_array_elements(drafts) x)),nowms);
 RETURN result;
END$$;

REVOKE ALL ON FUNCTION public.jana_admin_import_product_drafts(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_import_product_drafts(text,text,jsonb) TO service_role;
