-- Reference bin locations for the supported single-hub launch mode.
-- This intentionally does not split balances or lots by warehouse/bin and seeds no rows.
CREATE TABLE public.warehouse_bins(
 id varchar(36) PRIMARY KEY,
 warehouse_id varchar(36) NOT NULL REFERENCES public.warehouses(id),
 code varchar(40) NOT NULL CHECK(code ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,39}$'),
 label varchar(120),
 active boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 created_at bigint NOT NULL,
 updated_at bigint NOT NULL
);
CREATE UNIQUE INDEX jana_warehouse_bin_code ON public.warehouse_bins(warehouse_id,lower(code));
CREATE TABLE public.stock_item_bins(
 stock_id varchar(36) PRIMARY KEY REFERENCES public.stock_items(id),
 bin_id varchar(36) NOT NULL REFERENCES public.warehouse_bins(id),
 assigned_by varchar(36) NOT NULL REFERENCES public.users(id),
 assigned_at bigint NOT NULL
);
CREATE INDEX jana_stock_bin_lookup ON public.stock_item_bins(bin_id,stock_id);
ALTER TABLE public.warehouse_bins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_item_bins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.warehouse_bins,public.stock_item_bins FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.warehouse_bins,public.stock_item_bins TO service_role;

CREATE FUNCTION public.jana_inventory_bin_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;previous public.idempotency_records;scope_key text;request_hash text;result jsonb;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;reason text;changes jsonb;
 binrow public.warehouse_bins;saved_bin public.warehouse_bins;before_state jsonb;v_bin_id text;v_warehouse_id text;v_stock_id text;next_active boolean;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation NOT IN ('bin.save','stock.assign_bin') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'bin_validation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='inventory-bin:'||u.id||':'||p_idem_key;
 request_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO previous FROM public.idempotency_records WHERE scope=scope_key;
 IF previous.scope IS NOT NULL THEN IF previous.request_hash<>request_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN previous.response::jsonb;END IF;
 reason=trim(coalesce(p_payload->>'reason',''));IF length(reason) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'bin_validation';END IF;

 IF p_operation='bin.save' THEN
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) AS k(key) WHERE key NOT IN ('id','revision','reason','changes')) THEN RAISE EXCEPTION 'bin_validation';END IF;
  changes=p_payload->'changes';IF jsonb_typeof(changes) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(changes) AS k(key) WHERE key NOT IN ('warehouse_id','code','label','active')) THEN RAISE EXCEPTION 'bin_validation';END IF;
  v_bin_id=nullif(trim(coalesce(p_payload->>'id','')),'');
  IF v_bin_id IS NULL THEN
   binrow.id='bin-'||replace(gen_random_uuid()::text,'-','');binrow.active=false;binrow.revision=1;binrow.created_at=nowms;
  ELSE
   SELECT * INTO binrow FROM public.warehouse_bins WHERE id=v_bin_id FOR UPDATE;
   IF binrow.id IS NULL THEN RAISE EXCEPTION 'bin_not_found';END IF;
   IF p_payload->>'revision' IS NULL OR (p_payload->>'revision')::bigint IS DISTINCT FROM binrow.revision THEN RAISE EXCEPTION 'bin_changed';END IF;
   before_state=to_jsonb(binrow);
  END IF;
  IF changes?'warehouse_id' THEN
   IF jsonb_typeof(changes->'warehouse_id') IS DISTINCT FROM 'string' OR length(trim(changes->>'warehouse_id')) NOT BETWEEN 3 AND 36 THEN RAISE EXCEPTION 'bin_validation';END IF;
   v_warehouse_id=trim(changes->>'warehouse_id');
   IF v_bin_id IS NOT NULL AND v_warehouse_id<>binrow.warehouse_id THEN RAISE EXCEPTION 'bin_warehouse_immutable';END IF;
   binrow.warehouse_id=v_warehouse_id;
  END IF;
  IF changes?'code' THEN
   IF jsonb_typeof(changes->'code') IS DISTINCT FROM 'string' OR trim(changes->>'code') !~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,39}$' THEN RAISE EXCEPTION 'bin_validation';END IF;
   binrow.code=upper(trim(changes->>'code'));
  END IF;
  IF changes?'label' THEN
   IF jsonb_typeof(changes->'label') IS DISTINCT FROM 'string' OR length(trim(changes->>'label'))>120 THEN RAISE EXCEPTION 'bin_validation';END IF;
   binrow.label=nullif(trim(changes->>'label'),'');
  END IF;
  next_active=binrow.active;
  IF changes?'active' THEN IF jsonb_typeof(changes->'active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'bin_validation';END IF;next_active=(changes->>'active')::boolean;END IF;
  IF binrow.warehouse_id IS NULL OR binrow.code IS NULL OR NOT EXISTS(SELECT 1 FROM public.warehouses w WHERE w.id=binrow.warehouse_id) THEN RAISE EXCEPTION 'bin_validation';END IF;
  IF next_active AND NOT EXISTS(SELECT 1 FROM public.warehouses w WHERE w.id=binrow.warehouse_id AND w.active FOR SHARE) THEN RAISE EXCEPTION 'bin_unavailable';END IF;
  IF binrow.active AND NOT next_active AND EXISTS(SELECT 1 FROM public.stock_item_bins sb WHERE sb.bin_id=binrow.id) THEN RAISE EXCEPTION 'bin_assigned';END IF;
  binrow.active=next_active;binrow.updated_at=nowms;
  BEGIN
   IF v_bin_id IS NULL THEN
    INSERT INTO public.warehouse_bins(id,warehouse_id,code,label,active,revision,created_at,updated_at)
    VALUES(binrow.id,binrow.warehouse_id,binrow.code,binrow.label,binrow.active,1,nowms,nowms) RETURNING * INTO saved_bin;
   ELSE
    UPDATE public.warehouse_bins SET code=binrow.code,label=binrow.label,active=binrow.active,revision=revision+1,updated_at=nowms WHERE id=binrow.id RETURNING * INTO saved_bin;
   END IF;
  EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'bin_code_exists';END;
  result=to_jsonb(saved_bin);
  INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES
  ('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN v_bin_id IS NULL THEN 'warehouse_bin_created' ELSE 'warehouse_bin_updated' END,binrow.id,jsonb_build_object('before',before_state,'after',result,'reason',reason,'reference_only',true),nowms);
 ELSE
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) AS k(key) WHERE key NOT IN ('stock_id','bin_id','reason')) THEN RAISE EXCEPTION 'bin_validation';END IF;
  v_stock_id=nullif(trim(coalesce(p_payload->>'stock_id','')),'');
  IF v_stock_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.stock_items s WHERE s.id=v_stock_id FOR UPDATE) THEN RAISE EXCEPTION 'stock_not_found';END IF;
  SELECT jsonb_build_object('bin_id',sb.bin_id,'bin_code',b.code,'warehouse_id',b.warehouse_id) INTO before_state FROM public.stock_item_bins sb JOIN public.warehouse_bins b ON b.id=sb.bin_id WHERE sb.stock_id=v_stock_id FOR UPDATE OF sb;
  IF p_payload->'bin_id' IS NULL OR p_payload->'bin_id'='null'::jsonb OR trim(coalesce(p_payload->>'bin_id',''))='' THEN
   DELETE FROM public.stock_item_bins WHERE stock_item_bins.stock_id=v_stock_id;
   result=jsonb_build_object('stock_id',v_stock_id,'bin_id',NULL,'bin_code',NULL,'warehouse_id',NULL);
  ELSE
   IF jsonb_typeof(p_payload->'bin_id') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'bin_validation';END IF;
   v_bin_id=trim(p_payload->>'bin_id');
   SELECT * INTO binrow FROM public.warehouse_bins WHERE id=v_bin_id FOR SHARE;
   IF binrow.id IS NULL THEN RAISE EXCEPTION 'bin_not_found';END IF;
   IF NOT binrow.active OR NOT EXISTS(SELECT 1 FROM public.warehouses w WHERE w.id=binrow.warehouse_id AND w.active FOR SHARE) THEN RAISE EXCEPTION 'bin_inactive';END IF;
   INSERT INTO public.stock_item_bins(stock_id,bin_id,assigned_by,assigned_at) VALUES(v_stock_id,v_bin_id,u.id,nowms)
   ON CONFLICT ON CONSTRAINT stock_item_bins_pkey DO UPDATE SET bin_id=excluded.bin_id,assigned_by=excluded.assigned_by,assigned_at=excluded.assigned_at;
   result=jsonb_build_object('stock_id',v_stock_id,'bin_id',binrow.id,'bin_code',binrow.code,'warehouse_id',binrow.warehouse_id);
  END IF;
  INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES
  ('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'stock_bin_assigned',v_stock_id,jsonb_build_object('before',before_state,'after',result,'reason',reason,'reference_only',true),nowms);
 END IF;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,request_hash,result,nowms);
 RETURN result;
END$$;

ALTER FUNCTION public.jana_admin_catalog(text) RENAME TO jana_admin_catalog_pre_bins;
CREATE FUNCTION public.jana_admin_catalog(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;stock_rows jsonb;
BEGIN
 r=public.jana_admin_catalog_pre_bins(p_token);
 SELECT coalesce(jsonb_agg(item||jsonb_build_object('bin_id',sb.bin_id,'bin_code',b.code,'bin_label',b.label,'bin_warehouse_id',b.warehouse_id) ORDER BY item->>'name',item->>'id'),'[]'::jsonb)
 INTO stock_rows FROM jsonb_array_elements(coalesce(r->'stock','[]'::jsonb)) item
 LEFT JOIN public.stock_item_bins sb ON sb.stock_id=item->>'id' LEFT JOIN public.warehouse_bins b ON b.id=sb.bin_id;
 RETURN (r-'stock')||jsonb_build_object(
  'stock',stock_rows,
  'warehouse_bins',coalesce((SELECT jsonb_agg(to_jsonb(b)||jsonb_build_object('assigned_count',(SELECT count(*) FROM public.stock_item_bins sb WHERE sb.bin_id=b.id)) ORDER BY b.active DESC,b.code,b.id) FROM public.warehouse_bins b),'[]'::jsonb));
END$$;

REVOKE ALL ON FUNCTION public.jana_inventory_bin_write(text,text,text,jsonb),public.jana_admin_catalog(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_admin_catalog_pre_bins(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.jana_inventory_bin_write(text,text,text,jsonb),public.jana_admin_catalog(text) TO service_role;
