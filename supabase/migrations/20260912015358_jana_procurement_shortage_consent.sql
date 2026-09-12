-- Dormant phase-4 supplier-pickup shortage consent.
-- Freezes the complete missing-quantity proposal and the customer's explicit
-- decision without changing retail price, inventory, custody or settlement.
ALTER TABLE public.procurement_jobs DROP CONSTRAINT procurement_jobs_state_check;
ALTER TABLE public.procurement_jobs ADD CONSTRAINT procurement_jobs_state_check
 CHECK(state IN ('unassigned','assigned','collecting','awaiting_customer','shortage_approved','ready','cancelled'));

CREATE TABLE public.procurement_shortage_requests (
 id varchar(36) PRIMARY KEY,
 job_id varchar(36) NOT NULL REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL REFERENCES public.orders(id),
 employee_id varchar(36) NOT NULL REFERENCES public.users(id),
 missing_lines jsonb NOT NULL CHECK(jsonb_typeof(missing_lines)='array' AND jsonb_array_length(missing_lines)>0),
 proposed_reduction_halalas bigint NOT NULL CHECK(proposed_reduction_halalas>0),
 customer_total_before_halalas bigint NOT NULL CHECK(customer_total_before_halalas>=proposed_reduction_halalas),
 reason varchar(1000) NOT NULL CHECK(length(trim(reason)) BETWEEN 3 AND 1000),
 state varchar(16) NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','approved','rejected')),
 created_at bigint NOT NULL,
 decided_at bigint,
 CHECK((state='pending' AND decided_at IS NULL) OR (state IN ('approved','rejected') AND decided_at IS NOT NULL))
);
CREATE UNIQUE INDEX jana_shortage_one_pending_job ON public.procurement_shortage_requests(job_id) WHERE state='pending';
CREATE INDEX jana_shortage_request_order ON public.procurement_shortage_requests(order_id,created_at DESC,id DESC);
CREATE INDEX jana_shortage_request_employee ON public.procurement_shortage_requests(employee_id,created_at DESC,id DESC);
ALTER TABLE public.procurement_shortage_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_shortage_requests FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.procurement_shortage_decisions (
 id varchar(36) PRIMARY KEY,
 request_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_shortage_requests(id),
 job_id varchar(36) NOT NULL REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL REFERENCES public.orders(id),
 customer_id varchar(36) NOT NULL REFERENCES public.users(id),
 decision varchar(24) NOT NULL CHECK(decision IN ('approve_removal','reject_removal')),
 missing_lines_snapshot jsonb NOT NULL CHECK(jsonb_typeof(missing_lines_snapshot)='array' AND jsonb_array_length(missing_lines_snapshot)>0),
 proposed_reduction_halalas bigint NOT NULL CHECK(proposed_reduction_halalas>0),
 customer_total_before_halalas bigint NOT NULL CHECK(customer_total_before_halalas>=proposed_reduction_halalas),
 note varchar(1000) NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 1000),
 created_at bigint NOT NULL
);
CREATE INDEX jana_shortage_decision_job ON public.procurement_shortage_decisions(job_id,created_at DESC,id DESC);
CREATE INDEX jana_shortage_decision_order ON public.procurement_shortage_decisions(order_id,created_at DESC,id DESC);
CREATE INDEX jana_shortage_decision_customer ON public.procurement_shortage_decisions(customer_id,created_at DESC,id DESC);
ALTER TABLE public.procurement_shortage_decisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_shortage_decisions FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.jana_procurement_shortage_request_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'shortage_request_immutable';END IF;
 IF NEW.id IS DISTINCT FROM OLD.id OR NEW.job_id IS DISTINCT FROM OLD.job_id
  OR NEW.order_id IS DISTINCT FROM OLD.order_id OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
  OR NEW.missing_lines IS DISTINCT FROM OLD.missing_lines
  OR NEW.proposed_reduction_halalas IS DISTINCT FROM OLD.proposed_reduction_halalas
  OR NEW.customer_total_before_halalas IS DISTINCT FROM OLD.customer_total_before_halalas
  OR NEW.reason IS DISTINCT FROM OLD.reason OR NEW.created_at IS DISTINCT FROM OLD.created_at
  OR OLD.state<>'pending' OR NEW.state NOT IN ('approved','rejected') OR NEW.decided_at IS NULL
 THEN RAISE EXCEPTION 'shortage_request_immutable';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_shortage_request_guard
BEFORE UPDATE OR DELETE ON public.procurement_shortage_requests FOR EACH ROW
EXECUTE FUNCTION public.jana_procurement_shortage_request_guard();
CREATE TRIGGER jana_shortage_decision_immutable
BEFORE UPDATE OR DELETE ON public.procurement_shortage_decisions FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();
REVOKE ALL ON FUNCTION public.jana_procurement_shortage_request_guard() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.jana_procurement_shortage_propose(
 p_token text,p_idem_key text,p_order_id text,p_expected_revision bigint,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;o public.orders;job public.procurement_jobs;prior public.idempotency_records;
 scope_key text;req_hash text;result jsonb;missing jsonb;reduction numeric;request_id text;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_reason=trim(coalesce(p_reason,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR length(p_reason) NOT BETWEEN 3 AND 1000
  OR p_expected_revision IS NULL OR p_expected_revision<1 THEN RAISE EXCEPTION 'procurement_shortage_validation';END IF;
 scope_key='procurement-shortage-propose:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('order_id',p_order_id,'revision',p_expected_revision,'reason',p_reason)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR SHARE;
 IF o.id IS NULL OR o.status<>'active' OR o.snapshot::jsonb->>'fulfillment_model'<>'supplier_pickup'
 THEN RAISE EXCEPTION 'procurement_order_invalid';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE order_id=o.id FOR UPDATE;
 IF job.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 IF job.revision<>p_expected_revision THEN RAISE EXCEPTION 'procurement_changed';END IF;
 IF job.state NOT IN ('assigned','collecting') OR job.assigned_to IS DISTINCT FROM u.id
 THEN RAISE EXCEPTION 'procurement_custody_required';END IF;
 IF EXISTS(SELECT 1 FROM public.procurement_shortage_requests r WHERE r.job_id=job.id AND r.state='pending')
 THEN RAISE EXCEPTION 'procurement_shortage_pending';END IF;
 WITH requested AS (
  SELECT value r,ord FROM jsonb_array_elements(job.requested_lines) WITH ORDINALITY x(value,ord)
 ),balance AS (
  SELECT r,ord,(r->>'qty')::numeric requested_qty,
   coalesce((SELECT sum(l.collected_qty) FROM public.procurement_purchase_lines l
    WHERE l.job_id=job.id AND l.requested_line_id=r->>'line_id'),0) collected_qty
  FROM requested
 ),remaining AS (
  SELECT r,ord,requested_qty,collected_qty,requested_qty-collected_qty missing_qty
  FROM balance WHERE requested_qty>collected_qty
 )
 SELECT jsonb_agg(jsonb_build_object(
   'line_id',r->>'line_id','offering_id',r->>'offering_id','name',r->>'name','size_label',r->>'size_label',
   'requested_qty',requested_qty,'collected_qty',collected_qty,'missing_qty',missing_qty,
   'unit_price_halalas',(r->>'unit_price_halalas')::bigint,
   'proposed_reduction_halalas',((r->>'unit_price_halalas')::numeric*missing_qty)::bigint
  ) ORDER BY ord),sum((r->>'unit_price_halalas')::numeric*missing_qty)
 INTO missing,reduction FROM remaining;
 IF missing IS NULL OR reduction IS NULL OR reduction<=0 OR reduction<>trunc(reduction)
  OR reduction>o.total_halalas THEN RAISE EXCEPTION 'procurement_shortage_invalid';END IF;
 request_id='shr-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_shortage_requests(id,job_id,order_id,employee_id,missing_lines,
  proposed_reduction_halalas,customer_total_before_halalas,reason,created_at)
 VALUES(request_id,job.id,o.id,u.id,missing,reduction::bigint,o.total_halalas,p_reason,nowms);
 UPDATE public.procurement_jobs SET state='awaiting_customer',revision=revision+1,updated_at=nowms
 WHERE id=job.id RETURNING * INTO job;
 result=jsonb_build_object('id',request_id,'job_id',job.id,'order_id',o.id,'state','pending',
  'job_state',job.state,'revision',job.revision,'missing_lines',missing,
  'proposed_reduction_halalas',reduction::bigint,'customer_total_before_halalas',o.total_halalas,
  'customer_total_if_approved_halalas',o.total_halalas-reduction::bigint,
  'customer_total_changed',false,'inventory_changed',false,'created_at',nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'procurement_shortage_proposed',p_reason,
  jsonb_build_object('job_id',job.id,'request_id',request_id,'revision',job.revision,'missing_lines',missing,
   'proposed_reduction_halalas',reduction::bigint,'customer_total_changed',false),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_shortage_proposed',request_id,
  jsonb_build_object('job_id',job.id,'order_id',o.id,'revision',job.revision,
   'proposed_reduction_halalas',reduction::bigint,'customer_total_changed',false,'inventory_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_shortage_validation';
END$$;

CREATE FUNCTION public.jana_procurement_shortage_decide(
 p_token text,p_idem_key text,p_request_id text,p_expected_revision bigint,p_decision text,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;o public.orders;job public.procurement_jobs;request public.procurement_shortage_requests;
 prior public.idempotency_records;scope_key text;req_hash text;result jsonb;decision_id text;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_decision=trim(coalesce(p_decision,''));p_note=trim(coalesce(p_note,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR p_decision NOT IN ('approve_removal','reject_removal')
  OR length(p_note) NOT BETWEEN 3 AND 1000 OR p_expected_revision IS NULL OR p_expected_revision<1
 THEN RAISE EXCEPTION 'procurement_shortage_decision_validation';END IF;
 scope_key='procurement-shortage-decide:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('request_id',p_request_id,'revision',p_expected_revision,
  'decision',p_decision,'note',p_note)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT r.* INTO request FROM public.procurement_shortage_requests r
 JOIN public.orders x ON x.id=r.order_id WHERE r.id=p_request_id AND x.user_id=u.id FOR UPDATE OF r;
 IF request.id IS NULL THEN RAISE EXCEPTION 'procurement_shortage_not_found';END IF;
 IF request.state<>'pending' THEN RAISE EXCEPTION 'procurement_shortage_decided';END IF;
 SELECT * INTO o FROM public.orders WHERE id=request.order_id AND status='active' FOR SHARE;
 IF o.id IS NULL OR o.total_halalas<>request.customer_total_before_halalas
 THEN RAISE EXCEPTION 'procurement_order_changed';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE id=request.job_id FOR UPDATE;
 IF job.id IS NULL OR job.state<>'awaiting_customer' THEN RAISE EXCEPTION 'procurement_shortage_state_invalid';END IF;
 IF job.revision<>p_expected_revision THEN RAISE EXCEPTION 'procurement_changed';END IF;
 UPDATE public.procurement_shortage_requests SET state=CASE WHEN p_decision='approve_removal' THEN 'approved' ELSE 'rejected' END,
  decided_at=nowms WHERE id=request.id RETURNING * INTO request;
 UPDATE public.procurement_jobs SET state=CASE WHEN p_decision='approve_removal' THEN 'shortage_approved' ELSE 'collecting' END,
  revision=revision+1,updated_at=nowms WHERE id=job.id RETURNING * INTO job;
 decision_id='shd-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_shortage_decisions(id,request_id,job_id,order_id,customer_id,decision,
  missing_lines_snapshot,proposed_reduction_halalas,customer_total_before_halalas,note,created_at)
 VALUES(decision_id,request.id,job.id,o.id,u.id,p_decision,request.missing_lines,
  request.proposed_reduction_halalas,request.customer_total_before_halalas,p_note,nowms);
 result=jsonb_build_object('id',decision_id,'request_id',request.id,'job_id',job.id,'order_id',o.id,
  'decision',p_decision,'request_state',request.state,'job_state',job.state,'revision',job.revision,
  'missing_lines',request.missing_lines,'proposed_reduction_halalas',request.proposed_reduction_halalas,
  'customer_total_before_halalas',o.total_halalas,
  'customer_total_if_approved_halalas',o.total_halalas-request.proposed_reduction_halalas,
  'customer_total_changed',false,'approved_adjustment_applied',false,
  'requires_financial_adjustment',p_decision='approve_removal','created_at',nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'procurement_shortage_decided',p_note,
  jsonb_build_object('job_id',job.id,'request_id',request.id,'decision_id',decision_id,'decision',p_decision,
   'state',job.state,'revision',job.revision,'customer_total_changed',false,'approved_adjustment_applied',false),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_shortage_decided',decision_id,
  jsonb_build_object('job_id',job.id,'order_id',o.id,'request_id',request.id,'decision',p_decision,
   'proposed_reduction_halalas',request.proposed_reduction_halalas,'customer_total_changed',false,
   'approved_adjustment_applied',false,'inventory_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_shortage_decision_validation';
END$$;

-- Deliberately dormant until the approved retail adjustment, handover and
-- settlement steps are implemented and tested end to end.
REVOKE ALL ON FUNCTION
 public.jana_procurement_shortage_propose(text,text,text,bigint,text),
 public.jana_procurement_shortage_decide(text,text,text,bigint,text,text)
FROM PUBLIC,anon,authenticated,service_role;
