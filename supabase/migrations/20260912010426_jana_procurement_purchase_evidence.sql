-- Dormant phase-3 supplier-pickup purchase evidence.
-- Records actual collection/cost evidence without inventory, customer-price,
-- courier-custody, payable or cash-settlement side effects.
CREATE TABLE public.procurement_purchase_records (
 id varchar(36) PRIMARY KEY,
 job_id varchar(36) NOT NULL REFERENCES public.procurement_jobs(id),
 supplier_id varchar(36) NOT NULL REFERENCES public.suppliers(id),
 pickup_site_id varchar(36) NOT NULL REFERENCES public.supplier_pickup_sites(id),
 supplier_snapshot jsonb NOT NULL CHECK(jsonb_typeof(supplier_snapshot)='object'),
 site_snapshot jsonb NOT NULL CHECK(jsonb_typeof(site_snapshot)='object'),
 document_reference varchar(180) NOT NULL CHECK(length(trim(document_reference)) BETWEEN 3 AND 180),
 note varchar(1000) NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 1000),
 total_actual_cost_halalas bigint NOT NULL CHECK(total_actual_cost_halalas BETWEEN 0 AND 9000000000000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),
 created_at bigint NOT NULL,
 UNIQUE(job_id,supplier_id,document_reference)
);
CREATE INDEX jana_purchase_record_job ON public.procurement_purchase_records(job_id,created_at,id);
CREATE INDEX jana_purchase_record_supplier ON public.procurement_purchase_records(supplier_id,created_at,id);
CREATE INDEX jana_purchase_record_site ON public.procurement_purchase_records(pickup_site_id,created_at,id);
CREATE INDEX jana_purchase_record_actor ON public.procurement_purchase_records(actor_id,created_at,id);
ALTER TABLE public.procurement_purchase_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_purchase_records FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.procurement_purchase_lines (
 record_id varchar(36) NOT NULL REFERENCES public.procurement_purchase_records(id),
 job_id varchar(36) NOT NULL REFERENCES public.procurement_jobs(id),
 requested_line_id varchar(80) NOT NULL,
 offering_id varchar(36) NOT NULL REFERENCES public.offerings(id),
 requested_qty numeric(14,3) NOT NULL CHECK(requested_qty>0),
 collected_qty numeric(14,3) NOT NULL CHECK(collected_qty>0 AND collected_qty<=requested_qty),
 actual_cost_halalas bigint NOT NULL CHECK(actual_cost_halalas BETWEEN 0 AND 9000000000000),
 quality_note varchar(1000) NOT NULL CHECK(length(trim(quality_note)) BETWEEN 3 AND 1000),
 created_at bigint NOT NULL,
 PRIMARY KEY(record_id,requested_line_id)
);
CREATE INDEX jana_purchase_line_job ON public.procurement_purchase_lines(job_id,requested_line_id,created_at);
CREATE INDEX jana_purchase_line_offering ON public.procurement_purchase_lines(offering_id,created_at);
ALTER TABLE public.procurement_purchase_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_purchase_lines FROM PUBLIC,anon,authenticated,service_role;

CREATE TRIGGER jana_purchase_record_immutable
BEFORE UPDATE OR DELETE ON public.procurement_purchase_records FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();
CREATE TRIGGER jana_purchase_line_immutable
BEFORE UPDATE OR DELETE ON public.procurement_purchase_lines FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_procurement_purchase_record(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;job public.procurement_jobs;supplier public.suppliers;site public.supplier_pickup_sites;
 previous public.idempotency_records;scope_key text;request_hash text;result jsonb;
 order_row public.orders;record_id text;document_reference text;note text;lines jsonb;entry jsonb;requested jsonb;
 line_id text;offering_id text;collected numeric;requested_qty numeric;already_collected numeric;actual_cost bigint;
 total_cost bigint:=0;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;complete boolean;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
  OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) t(key) WHERE key NOT IN
   ('order_id','expected_revision','supplier_id','pickup_site_id','document_reference','note','lines'))
  OR jsonb_typeof(p_payload->'order_id') IS DISTINCT FROM 'string'
  OR jsonb_typeof(p_payload->'expected_revision') IS DISTINCT FROM 'number'
  OR jsonb_typeof(p_payload->'supplier_id') IS DISTINCT FROM 'string'
  OR jsonb_typeof(p_payload->'pickup_site_id') IS DISTINCT FROM 'string'
  OR jsonb_typeof(p_payload->'document_reference') IS DISTINCT FROM 'string'
  OR jsonb_typeof(p_payload->'note') IS DISTINCT FROM 'string'
  OR jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array'
  OR jsonb_array_length(p_payload->'lines') NOT BETWEEN 1 AND 40
  OR (p_payload->>'expected_revision')!~'^[1-9][0-9]{0,18}$'
 THEN RAISE EXCEPTION 'procurement_purchase_validation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 document_reference=trim(p_payload->>'document_reference');note=trim(p_payload->>'note');lines=p_payload->'lines';
 IF length(document_reference) NOT BETWEEN 3 AND 180 OR length(note) NOT BETWEEN 3 AND 1000
  OR EXISTS(SELECT 1 FROM jsonb_array_elements(lines) e WHERE jsonb_typeof(e) IS DISTINCT FROM 'object'
   OR EXISTS(SELECT 1 FROM jsonb_object_keys(e) k(key) WHERE key NOT IN ('line_id','collected_qty','actual_cost_halalas','quality_note'))
   OR jsonb_typeof(e->'line_id') IS DISTINCT FROM 'string' OR length(trim(e->>'line_id')) NOT BETWEEN 1 AND 80
   OR jsonb_typeof(e->'collected_qty') IS DISTINCT FROM 'number' OR (e->>'collected_qty')!~'^[0-9]+(\.[0-9]{1,3})?$'
   OR jsonb_typeof(e->'actual_cost_halalas') IS DISTINCT FROM 'number' OR (e->>'actual_cost_halalas')!~'^[0-9]{1,13}$'
   OR jsonb_typeof(e->'quality_note') IS DISTINCT FROM 'string' OR length(trim(e->>'quality_note')) NOT BETWEEN 3 AND 1000)
  OR (SELECT count(*)<>count(DISTINCT trim(e->>'line_id')) FROM jsonb_array_elements(lines) e)
 THEN RAISE EXCEPTION 'procurement_purchase_validation';END IF;
 scope_key='procurement-purchase:'||u.id||':'||p_idem_key;request_hash=encode(digest(p_payload::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO previous FROM public.idempotency_records WHERE scope=scope_key;
 IF previous.scope IS NOT NULL THEN
  IF previous.request_hash<>request_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN previous.response::jsonb;
 END IF;
 SELECT * INTO order_row FROM public.orders WHERE id=p_payload->>'order_id' FOR SHARE;
 IF order_row.id IS NULL OR order_row.status<>'active' OR order_row.snapshot::jsonb->>'fulfillment_model'<>'supplier_pickup'
 THEN RAISE EXCEPTION 'procurement_order_invalid';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE order_id=order_row.id FOR UPDATE;
 IF job.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 IF job.revision<>(p_payload->>'expected_revision')::bigint THEN RAISE EXCEPTION 'procurement_changed';END IF;
 IF job.state NOT IN ('assigned','collecting') OR job.assigned_to IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'procurement_custody_required';END IF;
 SELECT * INTO supplier FROM public.suppliers WHERE id=p_payload->>'supplier_id' AND active FOR SHARE;
 IF supplier.id IS NULL THEN RAISE EXCEPTION 'procurement_supplier_invalid';END IF;
 SELECT * INTO site FROM public.supplier_pickup_sites WHERE id=p_payload->>'pickup_site_id' AND supplier_id=supplier.id AND active FOR SHARE;
 IF site.id IS NULL THEN RAISE EXCEPTION 'procurement_site_invalid';END IF;
 FOR entry IN SELECT value FROM jsonb_array_elements(lines) LOOP
  line_id=trim(entry->>'line_id');collected=(entry->>'collected_qty')::numeric;actual_cost=(entry->>'actual_cost_halalas')::bigint;
  IF collected<=0 OR actual_cost NOT BETWEEN 0 AND 9000000000000 THEN RAISE EXCEPTION 'procurement_purchase_validation';END IF;
  SELECT value INTO requested FROM jsonb_array_elements(job.requested_lines) WHERE value->>'line_id'=line_id;
  IF requested IS NULL THEN RAISE EXCEPTION 'procurement_line_invalid';END IF;
  offering_id=requested->>'offering_id';requested_qty=(requested->>'qty')::numeric;
  SELECT coalesce(sum(l.collected_qty),0) INTO already_collected FROM public.procurement_purchase_lines l
   WHERE l.job_id=job.id AND l.requested_line_id=line_id;
  IF already_collected+collected>requested_qty THEN RAISE EXCEPTION 'procurement_quantity_exceeded';END IF;
  IF total_cost>9000000000000-actual_cost THEN RAISE EXCEPTION 'procurement_purchase_validation';END IF;
  total_cost=total_cost+actual_cost;
 END LOOP;
 record_id='pur-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_purchase_records(id,job_id,supplier_id,pickup_site_id,supplier_snapshot,site_snapshot,
  document_reference,note,total_actual_cost_halalas,actor_id,created_at)
 VALUES(record_id,job.id,supplier.id,site.id,
  jsonb_build_object('id',supplier.id,'name',supplier.name,'phone',supplier.phone),
  jsonb_build_object('id',site.id,'name',site.name,'city',site.city,'address_line',site.address_line,
   'latitude',site.latitude,'longitude',site.longitude,'instructions',site.instructions),
  document_reference,note,total_cost,u.id,nowms);
 FOR entry IN SELECT value FROM jsonb_array_elements(lines) LOOP
  line_id=trim(entry->>'line_id');
  SELECT value INTO requested FROM jsonb_array_elements(job.requested_lines) WHERE value->>'line_id'=line_id;
  INSERT INTO public.procurement_purchase_lines(record_id,job_id,requested_line_id,offering_id,requested_qty,
   collected_qty,actual_cost_halalas,quality_note,created_at)
  VALUES(record_id,job.id,line_id,requested->>'offering_id',(requested->>'qty')::numeric,
   (entry->>'collected_qty')::numeric,(entry->>'actual_cost_halalas')::bigint,trim(entry->>'quality_note'),nowms);
 END LOOP;
 SELECT NOT EXISTS(
  SELECT 1 FROM jsonb_array_elements(job.requested_lines) r
  WHERE coalesce((SELECT sum(l.collected_qty) FROM public.procurement_purchase_lines l
   WHERE l.job_id=job.id AND l.requested_line_id=r->>'line_id'),0)<(r->>'qty')::numeric
 ) INTO complete;
 UPDATE public.procurement_jobs SET state=CASE WHEN complete THEN 'ready' ELSE 'collecting' END,
  revision=revision+1,updated_at=nowms WHERE id=job.id RETURNING * INTO job;
 result=jsonb_build_object('id',record_id,'job_id',job.id,'order_id',order_row.id,'supplier_id',supplier.id,
  'pickup_site_id',site.id,'document_reference',document_reference,'total_actual_cost_halalas',total_cost,
  'lines',lines,'state',job.state,'revision',job.revision,'collection_complete',complete,'customer_total_halalas',order_row.total_halalas,
  'supplier_settlement_recorded',false,'courier_handover_recorded',false,'created_at',nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),order_row.id,u.id,'procurement_purchase_recorded',note,
  jsonb_build_object('job_id',job.id,'record_id',record_id,'supplier_id',supplier.id,'state',job.state,
   'revision',job.revision,'collection_complete',complete,'customer_price_changed',false),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_purchase_recorded',record_id,
  jsonb_build_object('job_id',job.id,'order_id',order_row.id,'supplier_id',supplier.id,'pickup_site_id',site.id,
   'document_reference',document_reference,'total_actual_cost_halalas',total_cost,'line_count',jsonb_array_length(lines),
   'customer_price_changed',false,'inventory_changed',false,'supplier_settlement_recorded',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,request_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_purchase_validation';
END$$;

-- Deliberately dormant until shortage approval, handover and settlement exist.
REVOKE ALL ON FUNCTION public.jana_procurement_purchase_record(text,text,jsonb)
FROM PUBLIC,anon,authenticated,service_role;
