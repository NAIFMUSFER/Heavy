-- Canonical launch warehouse and zone ownership for the supported single-hub mode.
-- Existing production rows are intentionally not guessed or backfilled.
CREATE TABLE public.warehouses(
 id varchar(36) PRIMARY KEY,
 name varchar(120) NOT NULL CHECK(length(trim(name)) BETWEEN 2 AND 120),
 city varchar(120),
 address_line varchar(500),
 latitude numeric(9,6) CHECK(latitude BETWEEN -90 AND 90),
 longitude numeric(9,6) CHECK(longitude BETWEEN -180 AND 180),
 active boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 created_at bigint NOT NULL,
 updated_at bigint NOT NULL
);
CREATE UNIQUE INDEX jana_one_active_warehouse ON public.warehouses((active)) WHERE active;
CREATE TABLE public.delivery_zone_warehouses(
 zone_id varchar(36) PRIMARY KEY REFERENCES public.delivery_zones(id),
 warehouse_id varchar(36) NOT NULL REFERENCES public.warehouses(id),
 assigned_by varchar(36) NOT NULL REFERENCES public.users(id),
 assigned_at bigint NOT NULL
);
CREATE INDEX jana_zone_warehouse_lookup ON public.delivery_zone_warehouses(warehouse_id,zone_id);
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_zone_warehouses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.warehouses,public.delivery_zone_warehouses FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.warehouses,public.delivery_zone_warehouses TO service_role;

CREATE FUNCTION public.jana_save_warehouse(p_token text,p_warehouse_id text,p_payload jsonb,p_revision bigint,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;w public.warehouses;before_state jsonb;result public.warehouses;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;k text;next_active boolean;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000
  OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('name','city','address_line','latitude','longitude','active')) THEN RAISE EXCEPTION 'warehouse_validation';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('jana-single-active-warehouse',0));
 IF p_warehouse_id IS NULL THEN
  w.id='wh-'||replace(gen_random_uuid()::text,'-','');w.active=false;w.revision=1;w.created_at=nowms;
 ELSE
  SELECT * INTO w FROM public.warehouses WHERE id=p_warehouse_id FOR UPDATE;
  IF w.id IS NULL THEN RAISE EXCEPTION 'warehouse_not_found';END IF;
  IF p_revision IS DISTINCT FROM w.revision THEN RAISE EXCEPTION 'warehouse_changed';END IF;
  before_state=to_jsonb(w);
 END IF;
 IF p_payload?'name' THEN IF jsonb_typeof(p_payload->'name') IS DISTINCT FROM 'string' OR length(trim(p_payload->>'name')) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'warehouse_validation';END IF;w.name=trim(p_payload->>'name');END IF;
 FOREACH k IN ARRAY ARRAY['city','address_line'] LOOP
  IF p_payload?k THEN IF jsonb_typeof(p_payload->k) IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'warehouse_validation';END IF;
   IF k='city' THEN w.city=nullif(trim(p_payload->>k),'');ELSE w.address_line=nullif(trim(p_payload->>k),'');END IF;
  END IF;
 END LOOP;
 IF w.name IS NULL THEN RAISE EXCEPTION 'warehouse_validation';END IF;
 IF p_payload?'latitude' THEN IF jsonb_typeof(p_payload->'latitude') NOT IN ('number','null') THEN RAISE EXCEPTION 'warehouse_validation';END IF;w.latitude=CASE WHEN p_payload->'latitude'='null'::jsonb THEN NULL ELSE (p_payload->>'latitude')::numeric END;END IF;
 IF p_payload?'longitude' THEN IF jsonb_typeof(p_payload->'longitude') NOT IN ('number','null') THEN RAISE EXCEPTION 'warehouse_validation';END IF;w.longitude=CASE WHEN p_payload->'longitude'='null'::jsonb THEN NULL ELSE (p_payload->>'longitude')::numeric END;END IF;
 IF w.latitude IS NOT NULL AND w.latitude NOT BETWEEN -90 AND 90 OR w.longitude IS NOT NULL AND w.longitude NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'warehouse_validation';END IF;
 next_active=w.active;
 IF p_payload?'active' THEN IF jsonb_typeof(p_payload->'active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'warehouse_validation';END IF;next_active=(p_payload->>'active')::boolean;END IF;
 IF next_active AND (length(trim(coalesce(w.city,'')))<2 OR length(trim(coalesce(w.address_line,'')))<5 OR w.latitude IS NULL OR w.longitude IS NULL) THEN RAISE EXCEPTION 'delivery_validation';END IF;
 IF next_active AND EXISTS(SELECT 1 FROM public.warehouses x WHERE x.active AND x.id<>w.id) THEN RAISE EXCEPTION 'delivery_validation';END IF;
 IF NOT next_active AND w.active AND EXISTS(SELECT 1 FROM public.storefront_state WHERE singleton AND accepting_orders FOR SHARE) THEN RAISE EXCEPTION 'delivery_changed';END IF;
 w.active=next_active;w.updated_at=nowms;
 IF p_warehouse_id IS NULL THEN
  INSERT INTO public.warehouses(id,name,city,address_line,latitude,longitude,active,revision,created_at,updated_at)
  VALUES(w.id,w.name,w.city,w.address_line,w.latitude,w.longitude,w.active,1,nowms,nowms) RETURNING * INTO result;
 ELSE
  UPDATE public.warehouses SET name=w.name,city=w.city,address_line=w.address_line,latitude=w.latitude,longitude=w.longitude,active=w.active,revision=revision+1,updated_at=nowms WHERE id=w.id RETURNING * INTO result;
 END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES
 ('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN p_warehouse_id IS NULL THEN 'warehouse_created' ELSE 'warehouse_updated' END,w.id,jsonb_build_object('before',before_state,'after',to_jsonb(result),'reason',trim(p_reason)),nowms);
 RETURN to_jsonb(result);
END$$;

ALTER FUNCTION public.jana_delivery_admin_write(text,text,text,jsonb) RENAME TO jana_delivery_admin_write_pre_warehouse;
CREATE FUNCTION public.jana_delivery_admin_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;prior public.idempotency_records;scope_key text;req_hash text;r jsonb;changes jsonb;warehouse_id text;zone_id text;current_warehouse text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;base_key text;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation NOT IN ('warehouse.save','zone.save','slot.save') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'delivery_validation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='delivery-hub:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 IF p_operation='warehouse.save' THEN
  r=public.jana_save_warehouse(p_token,p_payload->>'id',p_payload->'changes',(p_payload->>'revision')::bigint,p_payload->>'reason');
 ELSE
  changes=coalesce(p_payload->'changes','{}'::jsonb);base_key=encode(digest('warehouse-base:'||p_idem_key,'sha256'),'hex');
  IF p_operation='zone.save' THEN
   IF changes?'warehouse_id' THEN
    IF jsonb_typeof(changes->'warehouse_id') IS DISTINCT FROM 'string' OR length(trim(changes->>'warehouse_id')) NOT BETWEEN 3 AND 36 THEN RAISE EXCEPTION 'warehouse_validation';END IF;
    warehouse_id=trim(changes->>'warehouse_id');changes=changes-'warehouse_id';
   ELSIF p_payload->>'id' IS NOT NULL THEN SELECT zw.warehouse_id INTO warehouse_id FROM public.delivery_zone_warehouses zw WHERE zw.zone_id=p_payload->>'id';END IF;
   IF warehouse_id IS NULL THEN RAISE EXCEPTION 'delivery_validation';END IF;
   PERFORM pg_advisory_xact_lock(hashtextextended('jana-single-active-warehouse',0));
   IF NOT EXISTS(SELECT 1 FROM public.warehouses WHERE id=warehouse_id AND active FOR SHARE) THEN RAISE EXCEPTION 'delivery_validation';END IF;
   SELECT zw.warehouse_id INTO current_warehouse FROM public.delivery_zone_warehouses zw WHERE zw.zone_id=p_payload->>'id' FOR UPDATE;
   IF current_warehouse IS NOT NULL AND current_warehouse<>warehouse_id AND (EXISTS(SELECT 1 FROM public.delivery_slots s JOIN public.quotes q ON q.slot_id=s.id WHERE s.zone_id=p_payload->>'id') OR EXISTS(SELECT 1 FROM public.storefront_state WHERE singleton AND accepting_orders)) THEN RAISE EXCEPTION 'delivery_changed';END IF;
   r=public.jana_delivery_admin_write_pre_warehouse(p_token,base_key,'zone.save',p_payload||jsonb_build_object('changes',changes));zone_id=r->>'id';
   INSERT INTO public.delivery_zone_warehouses(zone_id,warehouse_id,assigned_by,assigned_at) VALUES(zone_id,warehouse_id,u.id,nowms)
   ON CONFLICT(zone_id) DO UPDATE SET warehouse_id=excluded.warehouse_id,assigned_by=excluded.assigned_by,assigned_at=excluded.assigned_at WHERE delivery_zone_warehouses.warehouse_id<>excluded.warehouse_id;
   IF current_warehouse IS DISTINCT FROM warehouse_id THEN INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'delivery_zone_warehouse_assigned',zone_id,jsonb_build_object('before_warehouse_id',current_warehouse,'after_warehouse_id',warehouse_id,'reason',trim(p_payload->>'reason')),nowms);END IF;
   r=r||jsonb_build_object('warehouse_id',warehouse_id);
  ELSE
   zone_id=coalesce(changes->>'zone_id',(SELECT zone_id FROM public.delivery_slots WHERE id=p_payload->>'id'));
   IF zone_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.delivery_zone_warehouses zw JOIN public.warehouses w ON w.id=zw.warehouse_id WHERE zw.zone_id=zone_id AND w.active FOR SHARE) THEN RAISE EXCEPTION 'delivery_validation';END IF;
   r=public.jana_delivery_admin_write_pre_warehouse(p_token,base_key,'slot.save',p_payload);
  END IF;
 END IF;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,req_hash,r,nowms);
 RETURN r;
END$$;

ALTER FUNCTION public.jana_admin_catalog(text) RENAME TO jana_admin_catalog_pre_warehouse;
CREATE FUNCTION public.jana_admin_catalog(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;
BEGIN
 r=public.jana_admin_catalog_pre_warehouse(p_token);
 RETURN r||jsonb_build_object(
  'warehouses',coalesce((SELECT jsonb_agg(to_jsonb(w) ORDER BY w.active DESC,w.name,w.id) FROM public.warehouses w),'[]'::jsonb),
  'zones',coalesce((SELECT jsonb_agg((to_jsonb(z)-'geom')||jsonb_build_object('warehouse_id',zw.warehouse_id) ORDER BY z.name,z.id) FROM public.delivery_zones z LEFT JOIN public.delivery_zone_warehouses zw ON zw.zone_id=z.id),'[]'::jsonb));
END$$;

ALTER FUNCTION public.jana_storefront_readiness() RENAME TO jana_storefront_readiness_pre_warehouse;
CREATE FUNCTION public.jana_storefront_readiness() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;nowms bigint:=(extract(epoch from statement_timestamp())*1000)::bigint;active_count bigint;routed bigint;unrouted bigint;
BEGIN
 r=public.jana_storefront_readiness_pre_warehouse();
 SELECT count(*) INTO active_count FROM public.warehouses WHERE active;
 SELECT count(*) FILTER(WHERE w.id IS NOT NULL),count(*) FILTER(WHERE w.id IS NULL) INTO routed,unrouted
 FROM public.delivery_slots sl JOIN public.delivery_zones z ON z.id=sl.zone_id
 LEFT JOIN public.delivery_zone_warehouses zw ON zw.zone_id=z.id LEFT JOIN public.warehouses w ON w.id=zw.warehouse_id AND w.active
 WHERE sl.active AND z.active AND sl.cutoff_at>nowms AND sl.booked<sl.capacity;
 RETURN r||jsonb_build_object('active_warehouses',active_count,'routed_available_slots',routed,'unrouted_available_slots',unrouted,'warehouse_ready',active_count=1 AND routed>0 AND unrouted=0,'available_slots',routed);
END$$;

ALTER FUNCTION public.jana_storefront_write(text,text,text,jsonb) RENAME TO jana_storefront_write_pre_warehouse;
CREATE FUNCTION public.jana_storefront_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE readiness jsonb;
BEGIN
 IF p_operation='intake.set' AND jsonb_typeof(p_payload->'accepting_orders')='boolean' AND (p_payload->>'accepting_orders')::boolean THEN
  PERFORM pg_advisory_xact_lock(hashtextextended('jana-single-active-warehouse',0));
  PERFORM 1 FROM public.warehouses WHERE active FOR SHARE;
  readiness=public.jana_storefront_readiness();
  IF NOT coalesce((readiness->>'warehouse_ready')::boolean,false) THEN RAISE EXCEPTION 'storefront_not_ready';END IF;
 END IF;
 RETURN public.jana_storefront_write_pre_warehouse(p_token,p_idem_key,p_operation,p_payload);
END$$;

REVOKE ALL ON FUNCTION public.jana_save_warehouse(text,text,jsonb,bigint,text),public.jana_delivery_admin_write_pre_warehouse(text,text,text,jsonb),public.jana_admin_catalog_pre_warehouse(text),public.jana_storefront_readiness_pre_warehouse(),public.jana_storefront_readiness() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_delivery_admin_write(text,text,text,jsonb),public.jana_admin_catalog(text),public.jana_storefront_write_pre_warehouse(text,text,text,jsonb),public.jana_storefront_write(text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_delivery_admin_write(text,text,text,jsonb),public.jana_admin_catalog(text),public.jana_storefront_write(text,text,text,jsonb) TO service_role;
