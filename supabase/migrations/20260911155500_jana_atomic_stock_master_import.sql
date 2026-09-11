-- Owner-supplied stock-master files create inactive zero-balance definitions.
-- No lot, quantity, cost, supplier or sellable catalog state is imported here.
CREATE FUNCTION public.jana_inventory_import_stock_master(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users; previous public.idempotency_records; item jsonb; items jsonb;
 scope_key text; request_hash text; normalized_name text; seen_names text[]='{}';
 sid text; threshold bigint; imported jsonb='[]'::jsonb; result jsonb;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR p_payload->>'schema_version'<>'1'
  OR jsonb_typeof(p_payload->'items')<>'array' OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 200
  OR length(p_payload::text)>300000 THEN RAISE EXCEPTION 'stock_import_validation';END IF;
 items=p_payload->'items';
 FOR item IN SELECT value FROM jsonb_array_elements(items) LOOP
  IF jsonb_typeof(item)<>'object' OR item?'id' OR item?'active' OR item?'on_hand_base' OR item?'reserved_base'
   OR coalesce(item->>'base_unit','') NOT IN ('gram','piece')
   OR length(trim(coalesce(item->>'name',''))) NOT BETWEEN 2 AND 140
   OR length(trim(coalesce(item->>'name_en','')))>140 OR length(trim(coalesce(item->>'category','')))>80
   OR (item?'reorder_base' AND item->'reorder_base'<>'null'::jsonb AND (jsonb_typeof(item->'reorder_base')<>'number' OR item->>'reorder_base'!~ '^[0-9]{1,13}$'))
  THEN RAISE EXCEPTION 'stock_import_validation';END IF;
  IF item?'reorder_base' AND item->'reorder_base'<>'null'::jsonb THEN
   threshold=(item->>'reorder_base')::bigint;IF threshold>9000000000000 THEN RAISE EXCEPTION 'stock_import_validation';END IF;
  END IF;
  normalized_name=lower(regexp_replace(trim(item->>'name'),'\s+',' ','g'));
  IF normalized_name=ANY(seen_names) THEN RAISE EXCEPTION 'invalid_stock_import_duplicate_name';END IF;
  seen_names=array_append(seen_names,normalized_name);
 END LOOP;
 scope_key='stock-master-import:'||u.id||':'||p_idem_key;
 request_hash=encode(digest(p_payload::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO previous FROM public.idempotency_records WHERE scope=scope_key;
 IF previous.scope IS NOT NULL THEN
  IF previous.request_hash<>request_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN previous.response::jsonb;
 END IF;
 -- Different files are serialized only while names are checked and inserted.
 PERFORM pg_advisory_xact_lock(hashtextextended('jana-stock-master-names',0));
 IF EXISTS(
  SELECT 1 FROM public.stock_items s
  WHERE lower(regexp_replace(trim(s.name),'\s+',' ','g'))=ANY(seen_names)
 ) THEN RAISE EXCEPTION 'invalid_stock_import_existing_name';END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(items) LOOP
  normalized_name=regexp_replace(trim(item->>'name'),'\s+',' ','g');
  sid='stk-'||replace(gen_random_uuid()::text,'-','');
  threshold=CASE WHEN item?'reorder_base' AND item->'reorder_base'<>'null'::jsonb THEN (item->>'reorder_base')::bigint ELSE NULL END;
  INSERT INTO public.stock_items(id,name,name_en,category,base_unit,reorder_base,active,updated_at)
  VALUES(sid,normalized_name,nullif(trim(coalesce(item->>'name_en','')),''),trim(coalesce(item->>'category','')),item->>'base_unit',threshold,false,nowms);
  INSERT INTO public.stock_balances(stock_id,on_hand_base,reserved_base) VALUES(sid,0,0);
  imported=imported||jsonb_build_array(jsonb_build_object('id',sid,'name',normalized_name,'name_en',nullif(trim(coalesce(item->>'name_en','')),''),'category',trim(coalesce(item->>'category','')),'base_unit',item->>'base_unit','reorder_base',threshold,'active',false,'on_hand_base',0,'reserved_base',0));
 END LOOP;
 result=jsonb_build_object('schema_version',1,'imported_count',jsonb_array_length(items),'items',imported);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,request_hash,result,nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'stock_master_imported',scope_key,
  jsonb_build_object('stock_count',jsonb_array_length(items),'stock_ids',(SELECT jsonb_agg(x->>'id') FROM jsonb_array_elements(imported) x),'active',false,'balances_created_at_zero',true),nowms);
 RETURN result;
END$$;

REVOKE ALL ON FUNCTION public.jana_inventory_import_stock_master(text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_inventory_import_stock_master(text,text,jsonb) TO service_role;
