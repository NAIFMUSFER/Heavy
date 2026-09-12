-- Dormant phase-6 supplier-pickup custody handover.
-- The assigned purchasing employee freezes the actually collected goods, then
-- the selected courier explicitly accepts custody. No inventory, payable or
-- cash settlement is created by either step.
ALTER TABLE public.procurement_jobs DROP CONSTRAINT procurement_jobs_state_check;
ALTER TABLE public.procurement_jobs ADD CONSTRAINT procurement_jobs_state_check
 CHECK(state IN ('unassigned','assigned','collecting','awaiting_customer','shortage_approved',
  'ready','handover_pending','handed_over','cancelled'));

CREATE TABLE public.procurement_handover_requests (
 id varchar(36) PRIMARY KEY,
 job_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL UNIQUE REFERENCES public.orders(id),
 purchasing_employee_id varchar(36) NOT NULL REFERENCES public.users(id),
 courier_id varchar(36) NOT NULL REFERENCES public.users(id),
 collected_lines_snapshot jsonb NOT NULL CHECK(jsonb_typeof(collected_lines_snapshot)='array' AND jsonb_array_length(collected_lines_snapshot)>0),
 purchase_record_ids jsonb NOT NULL CHECK(jsonb_typeof(purchase_record_ids)='array' AND jsonb_array_length(purchase_record_ids)>0),
 purchase_evidence_hash varchar(64) NOT NULL CHECK(purchase_evidence_hash~'^[0-9a-f]{64}$'),
 current_snapshot_hash varchar(64) NOT NULL CHECK(current_snapshot_hash~'^[0-9a-f]{64}$'),
 supplier_cost_total_halalas bigint NOT NULL CHECK(supplier_cost_total_halalas>=0),
 customer_total_halalas bigint NOT NULL CHECK(customer_total_halalas>0),
 note varchar(1000) NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 1000),
 created_at bigint NOT NULL
);
CREATE INDEX jana_handover_request_employee ON public.procurement_handover_requests(purchasing_employee_id,created_at DESC,id DESC);
CREATE INDEX jana_handover_request_courier ON public.procurement_handover_requests(courier_id,created_at DESC,id DESC);
ALTER TABLE public.procurement_handover_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_handover_requests FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.procurement_handover_acceptances (
 id varchar(36) PRIMARY KEY,
 request_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_handover_requests(id),
 job_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL UNIQUE REFERENCES public.orders(id),
 purchasing_employee_id varchar(36) NOT NULL REFERENCES public.users(id),
 courier_id varchar(36) NOT NULL REFERENCES public.users(id),
 collected_lines_snapshot jsonb NOT NULL CHECK(jsonb_typeof(collected_lines_snapshot)='array' AND jsonb_array_length(collected_lines_snapshot)>0),
 purchase_evidence_hash varchar(64) NOT NULL CHECK(purchase_evidence_hash~'^[0-9a-f]{64}$'),
 supplier_cost_total_halalas bigint NOT NULL CHECK(supplier_cost_total_halalas>=0),
 customer_total_halalas bigint NOT NULL CHECK(customer_total_halalas>0),
 note varchar(1000) NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 1000),
 created_at bigint NOT NULL
);
CREATE INDEX jana_handover_accept_employee ON public.procurement_handover_acceptances(purchasing_employee_id,created_at DESC,id DESC);
CREATE INDEX jana_handover_accept_courier ON public.procurement_handover_acceptances(courier_id,created_at DESC,id DESC);
ALTER TABLE public.procurement_handover_acceptances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_handover_acceptances FROM PUBLIC,anon,authenticated,service_role;

CREATE TRIGGER jana_handover_request_immutable
BEFORE UPDATE OR DELETE ON public.procurement_handover_requests FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();
CREATE TRIGGER jana_handover_acceptance_immutable
BEFORE UPDATE OR DELETE ON public.procurement_handover_acceptances FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_procurement_handover_prepare(
 p_token text,p_idem_key text,p_order_id text,p_courier_id text,p_expected_revision bigint,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;o public.orders;job public.procurement_jobs;courier public.users;prior public.idempotency_records;
 scope_key text;req_hash text;result jsonb;request_id text;lines jsonb;record_ids jsonb;evidence jsonb;
 evidence_hash text;snapshot_hash text;supplier_cost bigint;line_count integer;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_note=trim(coalesce(p_note,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR length(p_note) NOT BETWEEN 3 AND 1000
  OR p_expected_revision IS NULL OR p_expected_revision<1 THEN RAISE EXCEPTION 'procurement_handover_validation';END IF;
 scope_key='procurement-handover-prepare:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('order_id',p_order_id,'courier_id',p_courier_id,
  'revision',p_expected_revision,'note',p_note)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.snapshot::jsonb->>'fulfillment_model'<>'supplier_pickup'
  OR o.fulfillment_state<>'queued' OR o.delivery_state<>'unassigned' OR o.courier_id IS NOT NULL
  OR o.collected_halalas<>0 OR o.refunded_halalas<>0 OR o.cash_state<>'uncollected'
 THEN RAISE EXCEPTION 'procurement_order_changed';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE order_id=o.id FOR UPDATE;
 IF job.id IS NULL OR job.state<>'ready' OR job.assigned_to IS DISTINCT FROM u.id
 THEN RAISE EXCEPTION 'procurement_custody_required';END IF;
 IF job.revision<>p_expected_revision THEN RAISE EXCEPTION 'procurement_changed';END IF;
 IF EXISTS(SELECT 1 FROM public.procurement_handover_requests h WHERE h.job_id=job.id)
 THEN RAISE EXCEPTION 'procurement_handover_exists';END IF;
 SELECT * INTO courier FROM public.users WHERE id=p_courier_id AND role='courier' AND active FOR SHARE;
 IF courier.id IS NULL OR courier.id=u.id THEN RAISE EXCEPTION 'procurement_courier_invalid';END IF;

 WITH current_lines AS (
  SELECT l,ord FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY x(l,ord)
 ),line_evidence AS (
  SELECT l,ord,coalesce((SELECT sum(pl.collected_qty) FROM public.procurement_purchase_lines pl
    WHERE pl.job_id=job.id AND pl.requested_line_id=l->>'line_id'),0) collected_qty,
   coalesce((SELECT jsonb_agg(pl.record_id ORDER BY pr.created_at,pl.record_id)
    FROM public.procurement_purchase_lines pl JOIN public.procurement_purchase_records pr ON pr.id=pl.record_id
    WHERE pl.job_id=job.id AND pl.requested_line_id=l->>'line_id'),'[]'::jsonb) sources
  FROM current_lines
 )
 SELECT jsonb_agg(jsonb_build_object('line_id',l->>'line_id','offering_id',l->>'offering_id',
   'name',l->>'name','size_label',l->>'size_label','sale_unit',l->>'sale_unit',
   'qty',(l->>'qty')::numeric,'collected_qty',collected_qty,
   'line_total_halalas',(l->>'line_total_halalas')::bigint,'purchase_record_ids',sources) ORDER BY ord),count(*)
 INTO lines,line_count FROM line_evidence WHERE collected_qty=(l->>'qty')::numeric;
 IF line_count<>jsonb_array_length(o.snapshot::jsonb->'lines') OR lines IS NULL
  OR EXISTS(SELECT 1 FROM public.procurement_purchase_lines pl WHERE pl.job_id=job.id AND NOT EXISTS(
   SELECT 1 FROM jsonb_array_elements(o.snapshot::jsonb->'lines') l WHERE l->>'line_id'=pl.requested_line_id))
 THEN RAISE EXCEPTION 'procurement_collection_evidence_invalid';END IF;
 SELECT coalesce(jsonb_agg(r.id ORDER BY r.created_at,r.id),'[]'::jsonb),coalesce(sum(r.total_actual_cost_halalas),0),
  coalesce(jsonb_agg(jsonb_build_object('record',to_jsonb(r),'lines',coalesce((SELECT jsonb_agg(to_jsonb(pl) ORDER BY pl.requested_line_id)
   FROM public.procurement_purchase_lines pl WHERE pl.record_id=r.id),'[]'::jsonb)) ORDER BY r.created_at,r.id),'[]'::jsonb)
 INTO record_ids,supplier_cost,evidence FROM public.procurement_purchase_records r WHERE r.job_id=job.id;
 IF jsonb_array_length(record_ids)<1 THEN RAISE EXCEPTION 'procurement_collection_evidence_invalid';END IF;
 evidence_hash=encode(digest(evidence::text,'sha256'),'hex');
 snapshot_hash=encode(digest(o.snapshot::jsonb::text,'sha256'),'hex');
 request_id='phr-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_handover_requests(id,job_id,order_id,purchasing_employee_id,courier_id,
  collected_lines_snapshot,purchase_record_ids,purchase_evidence_hash,current_snapshot_hash,
  supplier_cost_total_halalas,customer_total_halalas,note,created_at)
 VALUES(request_id,job.id,o.id,u.id,courier.id,lines,record_ids,evidence_hash,snapshot_hash,
  supplier_cost,o.total_halalas,p_note,nowms);
 UPDATE public.procurement_jobs SET state='handover_pending',revision=revision+1,updated_at=nowms
 WHERE id=job.id RETURNING * INTO job;
 result=jsonb_build_object('id',request_id,'job_id',job.id,'order_id',o.id,
  'purchasing_employee_id',u.id,'courier_id',courier.id,'state',job.state,'revision',job.revision,
  'collected_lines',lines,'purchase_record_ids',record_ids,'purchase_evidence_hash',evidence_hash,
  'supplier_cost_total_halalas',supplier_cost,'customer_total_halalas',o.total_halalas,
  'courier_accepted',false,'inventory_changed',false,'supplier_settlement_recorded',false,
  'employee_settlement_recorded',false,'cash_changed',false,'created_at',nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'procurement_handover_prepared',p_note,
  jsonb_build_object('job_id',job.id,'request_id',request_id,'courier_id',courier.id,'revision',job.revision,
   'line_count',jsonb_array_length(lines),'supplier_cost_total_halalas',supplier_cost,'courier_accepted',false),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_handover_prepared',request_id,
  jsonb_build_object('job_id',job.id,'order_id',o.id,'courier_id',courier.id,'revision',job.revision,
   'purchase_evidence_hash',evidence_hash,'current_snapshot_hash',snapshot_hash,
   'inventory_changed',false,'supplier_settlement_recorded',false,'cash_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_handover_validation';
END$$;

CREATE FUNCTION public.jana_procurement_handover_accept(
 p_token text,p_idem_key text,p_request_id text,p_expected_revision bigint,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;o public.orders;job public.procurement_jobs;request public.procurement_handover_requests;
 prior public.idempotency_records;scope_key text;req_hash text;result jsonb;acceptance_id text;
 evidence jsonb;evidence_hash text;snapshot_hash text;supplier_cost bigint;lines jsonb;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'courier' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_note=trim(coalesce(p_note,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR length(p_note) NOT BETWEEN 3 AND 1000
  OR p_expected_revision IS NULL OR p_expected_revision<1 THEN RAISE EXCEPTION 'procurement_handover_validation';END IF;
 scope_key='procurement-handover-accept:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('request_id',p_request_id,'revision',p_expected_revision,
  'note',p_note)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO request FROM public.procurement_handover_requests WHERE id=p_request_id FOR SHARE;
 IF request.id IS NULL OR request.courier_id<>u.id THEN RAISE EXCEPTION 'procurement_handover_not_found';END IF;
 SELECT * INTO o FROM public.orders WHERE id=request.order_id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.fulfillment_state<>'queued' OR o.delivery_state<>'unassigned'
  OR o.courier_id IS NOT NULL OR o.total_halalas<>request.customer_total_halalas
  OR encode(digest(o.snapshot::jsonb::text,'sha256'),'hex')<>request.current_snapshot_hash
 THEN RAISE EXCEPTION 'procurement_order_changed';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE id=request.job_id AND order_id=o.id FOR UPDATE;
 IF job.id IS NULL OR job.state<>'handover_pending' OR job.assigned_to IS DISTINCT FROM request.purchasing_employee_id
 THEN RAISE EXCEPTION 'procurement_handover_state_invalid';END IF;
 IF job.revision<>p_expected_revision THEN RAISE EXCEPTION 'procurement_changed';END IF;
 IF EXISTS(SELECT 1 FROM public.procurement_handover_acceptances a WHERE a.request_id=request.id)
 THEN RAISE EXCEPTION 'procurement_handover_already_accepted';END IF;
 SELECT coalesce(sum(r.total_actual_cost_halalas),0),coalesce(jsonb_agg(jsonb_build_object(
  'record',to_jsonb(r),'lines',coalesce((SELECT jsonb_agg(to_jsonb(pl) ORDER BY pl.requested_line_id)
   FROM public.procurement_purchase_lines pl WHERE pl.record_id=r.id),'[]'::jsonb)) ORDER BY r.created_at,r.id),'[]'::jsonb)
 INTO supplier_cost,evidence FROM public.procurement_purchase_records r WHERE r.job_id=job.id;
 evidence_hash=encode(digest(evidence::text,'sha256'),'hex');
 snapshot_hash=encode(digest(o.snapshot::jsonb::text,'sha256'),'hex');
 IF evidence_hash<>request.purchase_evidence_hash OR supplier_cost<>request.supplier_cost_total_halalas
  OR snapshot_hash<>request.current_snapshot_hash THEN RAISE EXCEPTION 'procurement_handover_evidence_changed';END IF;
 lines=request.collected_lines_snapshot;
 acceptance_id='pha-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_handover_acceptances(id,request_id,job_id,order_id,purchasing_employee_id,
  courier_id,collected_lines_snapshot,purchase_evidence_hash,supplier_cost_total_halalas,
  customer_total_halalas,note,created_at)
 VALUES(acceptance_id,request.id,job.id,o.id,request.purchasing_employee_id,u.id,lines,evidence_hash,
  supplier_cost,o.total_halalas,p_note,nowms);
 UPDATE public.procurement_jobs SET state='handed_over',revision=revision+1,updated_at=nowms
 WHERE id=job.id RETURNING * INTO job;
 UPDATE public.orders SET fulfillment_state='ready',delivery_state='assigned',courier_id=u.id,
  snapshot=snapshot::jsonb||jsonb_build_object('procurement_state','handed_to_courier',
   'procurement_handover_id',acceptance_id) WHERE id=o.id;
 result=jsonb_build_object('id',acceptance_id,'request_id',request.id,'job_id',job.id,'order_id',o.id,
  'purchasing_employee_id',request.purchasing_employee_id,'courier_id',u.id,
  'state',job.state,'revision',job.revision,'fulfillment_state','ready','delivery_state','assigned',
  'collected_lines',lines,'purchase_evidence_hash',evidence_hash,
  'supplier_cost_total_halalas',supplier_cost,'customer_total_halalas',o.total_halalas,
  'courier_accepted',true,'inventory_changed',false,'supplier_settlement_recorded',false,
  'employee_settlement_recorded',false,'cash_changed',false,'created_at',nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'procurement-handover-'||acceptance_id,
  'تم جمع طلبك','اكتمل جمع الأصناف وقَبِل المندوب عهدتها استعدادًا للتوصيل.',o.id,false,nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'procurement_handover_accepted',p_note,
  jsonb_build_object('job_id',job.id,'request_id',request.id,'acceptance_id',acceptance_id,
   'purchasing_employee_id',request.purchasing_employee_id,'courier_id',u.id,'revision',job.revision,
   'fulfillment_state','ready','delivery_state','assigned','cash_changed',false),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_handover_accepted',acceptance_id,
  jsonb_build_object('job_id',job.id,'order_id',o.id,'request_id',request.id,
   'purchasing_employee_id',request.purchasing_employee_id,'courier_id',u.id,'revision',job.revision,
   'purchase_evidence_hash',evidence_hash,'inventory_changed',false,
   'supplier_settlement_recorded',false,'employee_settlement_recorded',false,'cash_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_handover_validation';
END$$;

-- Still dormant: supplier/employee settlement, cancellation and complete
-- Edge/UI support are unfinished, so neither clients nor service_role can call.
REVOKE ALL ON FUNCTION
 public.jana_procurement_handover_prepare(text,text,text,text,bigint,text),
 public.jana_procurement_handover_accept(text,text,text,bigint,text)
FROM PUBLIC,anon,authenticated,service_role;
