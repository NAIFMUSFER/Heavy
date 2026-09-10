-- Geographic administration uses revisions, audited reasons and the same slot
-- locks used by quote reservation. Existing order/quote terms remain snapshots.
ALTER TABLE public.delivery_zones ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(metadata)='object');
ALTER TABLE public.delivery_slots ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK(revision>0);
CREATE FUNCTION public.jana_delivery_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF (to_jsonb(NEW)-'revision'-'booked') IS DISTINCT FROM (to_jsonb(OLD)-'revision'-'booked') THEN NEW.revision=OLD.revision+1;ELSE NEW.revision=OLD.revision;END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_delivery_zone_revision BEFORE UPDATE ON public.delivery_zones FOR EACH ROW EXECUTE FUNCTION public.jana_delivery_revision();
CREATE TRIGGER jana_delivery_slot_revision BEFORE UPDATE ON public.delivery_slots FOR EACH ROW EXECUTE FUNCTION public.jana_delivery_revision();
CREATE FUNCTION public.jana_slot_history_guard() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF (NEW.zone_id,NEW.starts_at,NEW.ends_at) IS DISTINCT FROM (OLD.zone_id,OLD.starts_at,OLD.ends_at)
 AND EXISTS(SELECT 1 FROM public.quotes WHERE slot_id=OLD.id) THEN RAISE EXCEPTION 'slot_schedule_immutable';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_slot_history_guard BEFORE UPDATE ON public.delivery_slots FOR EACH ROW EXECUTE FUNCTION public.jana_slot_history_guard();

CREATE FUNCTION public.jana_save_delivery_zone(p_token text,p_zone_id text,p_payload jsonb,p_revision bigint,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;z public.delivery_zones;before_state jsonb;result public.delivery_zones;g geometry;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;k text;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'delivery_validation';END IF;
 IF p_zone_id IS NOT NULL THEN
  SELECT * INTO z FROM public.delivery_zones WHERE id=p_zone_id FOR UPDATE;IF z.id IS NULL THEN RAISE EXCEPTION 'zone_not_found';END IF;
  IF p_revision IS DISTINCT FROM z.revision THEN RAISE EXCEPTION 'delivery_changed';END IF;before_state=to_jsonb(z)-'geom';
 ELSE z.id='zn-'||replace(gen_random_uuid()::text,'-','');z.active=true;z.metadata='{}';END IF;
 IF p_payload?'name' THEN IF jsonb_typeof(p_payload->'name') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'delivery_validation';END IF;z.name=trim(p_payload->>'name');END IF;
 IF z.name IS NULL OR length(z.name) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'delivery_validation';END IF;
 FOREACH k IN ARRAY ARRAY['fee_halalas','minimum_halalas'] LOOP
  IF p_payload?k AND (jsonb_typeof(p_payload->k) IS DISTINCT FROM 'number' OR (p_payload->>k)!~'^[0-9]{1,10}$') THEN RAISE EXCEPTION 'delivery_validation';END IF;
 END LOOP;
 IF p_payload?'fee_halalas' THEN z.fee_halalas=(p_payload->>'fee_halalas')::bigint;END IF;
 IF p_payload?'minimum_halalas' THEN z.minimum_halalas=(p_payload->>'minimum_halalas')::bigint;END IF;
 IF z.fee_halalas IS NULL OR z.minimum_halalas IS NULL OR z.fee_halalas NOT BETWEEN 0 AND 10000000 OR z.minimum_halalas NOT BETWEEN 0 AND 10000000 THEN RAISE EXCEPTION 'delivery_validation';END IF;
 IF p_payload?'active' THEN IF jsonb_typeof(p_payload->'active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'delivery_validation';END IF;z.active=(p_payload->>'active')::boolean;END IF;
 IF p_payload?'metadata' THEN IF jsonb_typeof(p_payload->'metadata') IS DISTINCT FROM 'object' OR octet_length((p_payload->'metadata')::text)>4096 THEN RAISE EXCEPTION 'delivery_validation';END IF;z.metadata=p_payload->'metadata';END IF;
 IF p_payload?'polygon' THEN z.polygon=(p_payload->'polygon')::json;END IF;
 IF z.polygon IS NULL OR jsonb_typeof(z.polygon::jsonb) IS DISTINCT FROM 'object' OR z.polygon->>'type' IS DISTINCT FROM 'Polygon' THEN RAISE EXCEPTION 'invalid_delivery_polygon';END IF;
 BEGIN
  g=ST_SetSRID(ST_GeomFromGeoJSON(z.polygon::text),4326);
  IF g IS NULL OR ST_GeometryType(g)<>'ST_Polygon' OR ST_NDims(g)<>2 OR ST_IsEmpty(g) OR NOT ST_IsValid(g) OR ST_NPoints(g)>2000 OR ST_Area(g)<=0 OR ST_XMin(g::box3d)<-180 OR ST_XMax(g::box3d)>180 OR ST_YMin(g::box3d)<-90 OR ST_YMax(g::box3d)>90 THEN RAISE EXCEPTION 'invalid_delivery_polygon';END IF;
 EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'invalid_delivery_polygon';END;
 IF p_zone_id IS NULL THEN
  INSERT INTO public.delivery_zones(id,name,polygon,fee_halalas,minimum_halalas,active,metadata) VALUES(z.id,z.name,z.polygon,z.fee_halalas,z.minimum_halalas,z.active,z.metadata) RETURNING * INTO result;
 ELSE
  UPDATE public.delivery_zones SET name=z.name,polygon=z.polygon,fee_halalas=z.fee_halalas,minimum_halalas=z.minimum_halalas,active=z.active,metadata=z.metadata WHERE id=z.id RETURNING * INTO result;
 END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN p_zone_id IS NULL THEN 'delivery_zone_created' ELSE 'delivery_zone_updated' END,z.id,jsonb_build_object('before',before_state,'after',to_jsonb(result)-'geom','reason',trim(p_reason)),nowms);
 RETURN to_jsonb(result)-'geom';
END$$;

CREATE FUNCTION public.jana_save_delivery_slot(p_token text,p_slot_id text,p_payload jsonb,p_revision bigint,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.delivery_slots;before_state jsonb;result public.delivery_slots;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;k text;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'delivery_validation';END IF;
 IF p_slot_id IS NOT NULL THEN
  SELECT * INTO s FROM public.delivery_slots WHERE id=p_slot_id FOR UPDATE;IF s.id IS NULL THEN RAISE EXCEPTION 'slot_not_found';END IF;
  IF p_revision IS DISTINCT FROM s.revision THEN RAISE EXCEPTION 'delivery_changed';END IF;before_state=to_jsonb(s);
 ELSE s.id='sl-'||replace(gen_random_uuid()::text,'-','');s.booked=0;s.active=true;END IF;
 IF p_payload?'zone_id' THEN s.zone_id=p_payload->>'zone_id';END IF;
 IF s.zone_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.delivery_zones WHERE id=s.zone_id) THEN RAISE EXCEPTION 'zone_not_found';END IF;
 FOREACH k IN ARRAY ARRAY['starts_at','ends_at','cutoff_at','capacity'] LOOP
  IF p_payload?k AND (jsonb_typeof(p_payload->k) IS DISTINCT FROM 'number' OR (p_payload->>k)!~'^[0-9]{1,16}$') THEN RAISE EXCEPTION 'delivery_validation';END IF;
 END LOOP;
 IF p_payload?'starts_at' THEN s.starts_at=(p_payload->>'starts_at')::bigint;END IF;
 IF p_payload?'ends_at' THEN s.ends_at=(p_payload->>'ends_at')::bigint;END IF;
 IF p_payload?'cutoff_at' THEN s.cutoff_at=(p_payload->>'cutoff_at')::bigint;END IF;
 IF p_payload?'capacity' THEN IF (p_payload->>'capacity')::bigint NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'delivery_validation';END IF;s.capacity=(p_payload->>'capacity')::integer;END IF;
 IF s.starts_at IS NULL OR s.ends_at IS NULL OR s.cutoff_at IS NULL OR s.capacity IS NULL OR s.capacity<1 OR s.ends_at<=s.starts_at OR s.cutoff_at>s.starts_at OR s.cutoff_at<=0 THEN RAISE EXCEPTION 'delivery_validation';END IF;
 IF s.capacity<s.booked THEN RAISE EXCEPTION 'slot_below_booked';END IF;
 IF p_payload?'active' THEN IF jsonb_typeof(p_payload->'active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'delivery_validation';END IF;s.active=(p_payload->>'active')::boolean;END IF;
 IF p_slot_id IS NULL OR s.starts_at IS DISTINCT FROM (before_state->>'starts_at')::bigint OR s.ends_at IS DISTINCT FROM (before_state->>'ends_at')::bigint OR s.zone_id IS DISTINCT FROM before_state->>'zone_id' THEN
  IF s.starts_at<=nowms OR s.cutoff_at<=nowms OR s.ends_at-s.starts_at>86400000 OR s.starts_at>nowms+366::bigint*86400000 OR NOT EXISTS(SELECT 1 FROM public.delivery_zones WHERE id=s.zone_id AND active) THEN RAISE EXCEPTION 'delivery_validation';END IF;
 END IF;
 IF p_slot_id IS NULL THEN
  INSERT INTO public.delivery_slots(id,zone_id,starts_at,ends_at,cutoff_at,capacity,booked,active) VALUES(s.id,s.zone_id,s.starts_at,s.ends_at,s.cutoff_at,s.capacity,0,s.active) RETURNING * INTO result;
 ELSE
  UPDATE public.delivery_slots SET zone_id=s.zone_id,starts_at=s.starts_at,ends_at=s.ends_at,cutoff_at=s.cutoff_at,capacity=s.capacity,active=s.active WHERE id=s.id RETURNING * INTO result;
 END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN p_slot_id IS NULL THEN 'delivery_slot_created' ELSE 'delivery_slot_updated' END,s.id,jsonb_build_object('before',before_state,'after',to_jsonb(result),'reason',trim(p_reason)),nowms);
 RETURN to_jsonb(result);
END$$;

CREATE FUNCTION public.jana_delivery_admin_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;prior public.idempotency_records;scope_key text;req_hash text;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);PERFORM 1 FROM public.users WHERE id=u.id FOR SHARE;u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation IS NULL OR p_operation NOT IN ('zone.save','slot.save') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'delivery_validation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='delivery-admin:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 IF p_operation='zone.save' THEN r=public.jana_save_delivery_zone(p_token,p_payload->>'id',p_payload->'changes',(p_payload->>'revision')::bigint,p_payload->>'reason');
 ELSE r=public.jana_save_delivery_slot(p_token,p_payload->>'id',p_payload->'changes',(p_payload->>'revision')::bigint,p_payload->>'reason');END IF;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,req_hash,r,(extract(epoch from clock_timestamp())*1000)::bigint);
 RETURN r;
END$$;
-- Preserve legacy service integrations but route them through the same validation.
CREATE OR REPLACE FUNCTION public.jana_admin_create_zone(p_token text,p_name text,p_polygon jsonb,p_fee_halalas bigint,p_minimum_halalas bigint)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$SELECT public.jana_save_delivery_zone(p_token,NULL,jsonb_build_object('name',p_name,'polygon',p_polygon,'fee_halalas',p_fee_halalas,'minimum_halalas',p_minimum_halalas),NULL,'إنشاء منطقة التوصيل')$$;
CREATE OR REPLACE FUNCTION public.jana_admin_create_slot(p_token text,p_zone_id text,p_starts_at bigint,p_ends_at bigint,p_cutoff_at bigint,p_capacity integer)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$SELECT public.jana_save_delivery_slot(p_token,NULL,jsonb_build_object('zone_id',p_zone_id,'starts_at',p_starts_at,'ends_at',p_ends_at,'cutoff_at',p_cutoff_at,'capacity',p_capacity),NULL,'إنشاء موعد التوصيل')$$;
REVOKE ALL ON FUNCTION public.jana_delivery_revision(),public.jana_slot_history_guard(),public.jana_save_delivery_zone(text,text,jsonb,bigint,text),public.jana_save_delivery_slot(text,text,jsonb,bigint,text) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_delivery_admin_write(text,text,text,jsonb),public.jana_admin_create_zone(text,text,jsonb,bigint,bigint),public.jana_admin_create_slot(text,text,bigint,bigint,bigint,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_delivery_admin_write(text,text,text,jsonb),public.jana_admin_create_zone(text,text,jsonb,bigint,bigint),public.jana_admin_create_slot(text,text,bigint,bigint,bigint,integer) TO service_role;
