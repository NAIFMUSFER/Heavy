-- Dormant phase-8 supplier-pickup funding and settlement evidence.
-- This separates the supplier's actual purchase cost from the customer price,
-- identifies who funded each immutable purchase, and records only evidenced
-- repayments. It does not create inventory, change customer totals, or assume
-- a margin, fee, payment channel, or settlement timing policy.

CREATE TABLE public.procurement_purchase_funding (
 id varchar(36) PRIMARY KEY,
 purchase_record_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_purchase_records(id),
 job_id varchar(36) NOT NULL REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL REFERENCES public.orders(id),
 funding_source varchar(24) NOT NULL CHECK(funding_source IN ('company_paid','employee_paid','supplier_credit')),
 principal_halalas bigint NOT NULL CHECK(principal_halalas BETWEEN 0 AND 9000000000000),
 employee_id varchar(36) REFERENCES public.users(id),
 supplier_id varchar(36) REFERENCES public.suppliers(id),
 evidence_reference varchar(180) NOT NULL CHECK(length(trim(evidence_reference)) BETWEEN 3 AND 180),
 note varchar(1000) NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 1000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),
 created_at bigint NOT NULL,
 CHECK(
  (funding_source='company_paid' AND employee_id IS NULL AND supplier_id IS NULL)
  OR (funding_source='employee_paid' AND employee_id IS NOT NULL AND supplier_id IS NULL AND principal_halalas>0)
  OR (funding_source='supplier_credit' AND employee_id IS NULL AND supplier_id IS NOT NULL AND principal_halalas>0)
 )
);
CREATE INDEX jana_procurement_funding_job ON public.procurement_purchase_funding(job_id,created_at,id);
CREATE INDEX jana_procurement_funding_order ON public.procurement_purchase_funding(order_id,created_at,id);
CREATE INDEX jana_procurement_funding_employee ON public.procurement_purchase_funding(employee_id,created_at,id)
 WHERE employee_id IS NOT NULL;
CREATE INDEX jana_procurement_funding_supplier ON public.procurement_purchase_funding(supplier_id,created_at,id)
 WHERE supplier_id IS NOT NULL;
ALTER TABLE public.procurement_purchase_funding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_purchase_funding FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE public.procurement_settlement_entries (
 id varchar(36) PRIMARY KEY,
 funding_id varchar(36) NOT NULL REFERENCES public.procurement_purchase_funding(id),
 purchase_record_id varchar(36) NOT NULL REFERENCES public.procurement_purchase_records(id),
 job_id varchar(36) NOT NULL REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL REFERENCES public.orders(id),
 beneficiary_type varchar(16) NOT NULL CHECK(beneficiary_type IN ('employee','supplier')),
 beneficiary_id varchar(36) NOT NULL,
 amount_halalas bigint NOT NULL CHECK(amount_halalas>0 AND amount_halalas<=9000000000000),
 payment_reference varchar(180) NOT NULL CHECK(length(trim(payment_reference)) BETWEEN 3 AND 180),
 note varchar(1000) NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 1000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),
 created_at bigint NOT NULL,
 UNIQUE(funding_id,payment_reference)
);
CREATE INDEX jana_procurement_settlement_funding ON public.procurement_settlement_entries(funding_id,created_at,id);
CREATE INDEX jana_procurement_settlement_job ON public.procurement_settlement_entries(job_id,created_at,id);
CREATE INDEX jana_procurement_settlement_order ON public.procurement_settlement_entries(order_id,created_at,id);
CREATE INDEX jana_procurement_settlement_beneficiary ON public.procurement_settlement_entries(beneficiary_type,beneficiary_id,created_at,id);
ALTER TABLE public.procurement_settlement_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_settlement_entries FROM PUBLIC,anon,authenticated,service_role;

CREATE TRIGGER jana_procurement_funding_immutable
BEFORE UPDATE OR DELETE ON public.procurement_purchase_funding FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();
CREATE TRIGGER jana_procurement_settlement_immutable
BEFORE UPDATE OR DELETE ON public.procurement_settlement_entries FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_procurement_funding_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE purchase public.procurement_purchase_records;job public.procurement_jobs;
BEGIN
 SELECT * INTO purchase FROM public.procurement_purchase_records WHERE id=NEW.purchase_record_id;
 IF purchase.id IS NULL THEN RAISE EXCEPTION 'procurement_purchase_not_found';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE id=purchase.job_id;
 IF job.id IS NULL OR NEW.job_id<>job.id OR NEW.order_id<>job.order_id
  OR NEW.principal_halalas<>purchase.total_actual_cost_halalas
 THEN RAISE EXCEPTION 'procurement_funding_mismatch';END IF;
 IF NEW.funding_source='employee_paid' AND NEW.employee_id IS DISTINCT FROM purchase.actor_id
 THEN RAISE EXCEPTION 'procurement_funding_employee_mismatch';END IF;
 IF NEW.funding_source='supplier_credit' AND NEW.supplier_id IS DISTINCT FROM purchase.supplier_id
 THEN RAISE EXCEPTION 'procurement_funding_supplier_mismatch';END IF;
 IF NEW.funding_source<>'company_paid' AND NEW.principal_halalas=0
 THEN RAISE EXCEPTION 'procurement_funding_zero_liability';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_procurement_funding_validate
BEFORE INSERT ON public.procurement_purchase_funding FOR EACH ROW
EXECUTE FUNCTION public.jana_procurement_funding_guard();

CREATE FUNCTION public.jana_procurement_settlement_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE funding public.procurement_purchase_funding;paid bigint;
BEGIN
 SELECT * INTO funding FROM public.procurement_purchase_funding WHERE id=NEW.funding_id FOR UPDATE;
 IF funding.id IS NULL OR funding.funding_source='company_paid'
 THEN RAISE EXCEPTION 'procurement_settlement_not_payable';END IF;
 IF NEW.purchase_record_id<>funding.purchase_record_id OR NEW.job_id<>funding.job_id OR NEW.order_id<>funding.order_id
  OR (funding.funding_source='employee_paid' AND (NEW.beneficiary_type<>'employee' OR NEW.beneficiary_id<>funding.employee_id))
  OR (funding.funding_source='supplier_credit' AND (NEW.beneficiary_type<>'supplier' OR NEW.beneficiary_id<>funding.supplier_id))
 THEN RAISE EXCEPTION 'procurement_settlement_mismatch';END IF;
 SELECT coalesce(sum(amount_halalas),0) INTO paid FROM public.procurement_settlement_entries WHERE funding_id=funding.id;
 IF paid+NEW.amount_halalas>funding.principal_halalas THEN RAISE EXCEPTION 'procurement_settlement_exceeded';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_procurement_settlement_validate
BEFORE INSERT ON public.procurement_settlement_entries FOR EACH ROW
EXECUTE FUNCTION public.jana_procurement_settlement_guard();

CREATE FUNCTION public.jana_procurement_funding_record(
 p_token text,p_idem_key text,p_purchase_record_id text,p_funding_source text,p_evidence_reference text,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;purchase public.procurement_purchase_records;job public.procurement_jobs;existing public.procurement_purchase_funding;
 prior public.idempotency_records;scope_key text;req_hash text;result jsonb;funding_id text;
 employee_id text;supplier_id text;liability_type text;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_funding_source=trim(coalesce(p_funding_source,''));
 p_evidence_reference=trim(coalesce(p_evidence_reference,''));p_note=trim(coalesce(p_note,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR p_funding_source NOT IN ('company_paid','employee_paid','supplier_credit')
  OR length(p_evidence_reference) NOT BETWEEN 3 AND 180 OR length(p_note) NOT BETWEEN 3 AND 1000
 THEN RAISE EXCEPTION 'procurement_funding_validation';END IF;
 scope_key='procurement-funding:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('purchase_record_id',p_purchase_record_id,'funding_source',p_funding_source,
  'evidence_reference',p_evidence_reference,'note',p_note)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO purchase FROM public.procurement_purchase_records WHERE id=p_purchase_record_id FOR SHARE;
 IF purchase.id IS NULL THEN RAISE EXCEPTION 'procurement_purchase_not_found';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE id=purchase.job_id FOR SHARE;
 IF job.id IS NULL OR job.state='cancelled' THEN RAISE EXCEPTION 'procurement_funding_state_invalid';END IF;
 SELECT * INTO existing FROM public.procurement_purchase_funding WHERE purchase_record_id=purchase.id;
 IF existing.id IS NOT NULL THEN RAISE EXCEPTION 'procurement_funding_exists';END IF;
 IF purchase.total_actual_cost_halalas=0 AND p_funding_source<>'company_paid'
 THEN RAISE EXCEPTION 'procurement_funding_zero_liability';END IF;
 employee_id=CASE WHEN p_funding_source='employee_paid' THEN purchase.actor_id ELSE NULL END;
 supplier_id=CASE WHEN p_funding_source='supplier_credit' THEN purchase.supplier_id ELSE NULL END;
 liability_type=CASE p_funding_source WHEN 'employee_paid' THEN 'employee_reimbursement'
  WHEN 'supplier_credit' THEN 'supplier_payable' ELSE 'none' END;
 funding_id='pfd-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_purchase_funding(id,purchase_record_id,job_id,order_id,funding_source,principal_halalas,
  employee_id,supplier_id,evidence_reference,note,actor_id,created_at)
 VALUES(funding_id,purchase.id,job.id,job.order_id,p_funding_source,purchase.total_actual_cost_halalas,
  employee_id,supplier_id,p_evidence_reference,p_note,u.id,nowms);
 result=jsonb_build_object('id',funding_id,'purchase_record_id',purchase.id,'job_id',job.id,'order_id',job.order_id,
  'funding_source',p_funding_source,'principal_halalas',purchase.total_actual_cost_halalas,
  'liability_type',liability_type,'employee_id',employee_id,'supplier_id',supplier_id,
  'settled_halalas',0,'outstanding_halalas',CASE WHEN liability_type='none' THEN 0 ELSE purchase.total_actual_cost_halalas END,
  'customer_total_changed',false,'inventory_changed',false,'customer_cash_changed',false,'created_at',nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_funding_recorded',funding_id,
  jsonb_build_object('role',u.role,'purchase_record_id',purchase.id,'job_id',job.id,'order_id',job.order_id,
   'funding_source',p_funding_source,'principal_halalas',purchase.total_actual_cost_halalas,
   'liability_type',liability_type,'evidence_reference',p_evidence_reference,
   'customer_total_changed',false,'inventory_changed',false,'customer_cash_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_funding_validation';
END$$;

CREATE FUNCTION public.jana_procurement_settlement_record(
 p_token text,p_idem_key text,p_funding_id text,p_amount_halalas bigint,p_payment_reference text,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;funding public.procurement_purchase_funding;prior public.idempotency_records;
 scope_key text;req_hash text;result jsonb;settlement_id text;paid bigint;beneficiary_type text;beneficiary_id text;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_payment_reference=trim(coalesce(p_payment_reference,''));p_note=trim(coalesce(p_note,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR p_amount_halalas IS NULL OR p_amount_halalas<=0
  OR p_amount_halalas>9000000000000 OR length(p_payment_reference) NOT BETWEEN 3 AND 180
  OR length(p_note) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'procurement_settlement_validation';END IF;
 scope_key='procurement-settlement:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('funding_id',p_funding_id,'amount_halalas',p_amount_halalas,
  'payment_reference',p_payment_reference,'note',p_note)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO funding FROM public.procurement_purchase_funding WHERE id=p_funding_id FOR UPDATE;
 IF funding.id IS NULL THEN RAISE EXCEPTION 'procurement_funding_not_found';END IF;
 IF funding.funding_source='company_paid' THEN RAISE EXCEPTION 'procurement_settlement_not_payable';END IF;
 SELECT coalesce(sum(amount_halalas),0) INTO paid FROM public.procurement_settlement_entries WHERE funding_id=funding.id;
 IF paid+p_amount_halalas>funding.principal_halalas THEN RAISE EXCEPTION 'procurement_settlement_exceeded';END IF;
 beneficiary_type=CASE WHEN funding.funding_source='employee_paid' THEN 'employee' ELSE 'supplier' END;
 beneficiary_id=coalesce(funding.employee_id,funding.supplier_id);
 settlement_id='pst-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_settlement_entries(id,funding_id,purchase_record_id,job_id,order_id,beneficiary_type,
  beneficiary_id,amount_halalas,payment_reference,note,actor_id,created_at)
 VALUES(settlement_id,funding.id,funding.purchase_record_id,funding.job_id,funding.order_id,beneficiary_type,
  beneficiary_id,p_amount_halalas,p_payment_reference,p_note,u.id,nowms);
 result=jsonb_build_object('id',settlement_id,'funding_id',funding.id,'purchase_record_id',funding.purchase_record_id,
  'job_id',funding.job_id,'order_id',funding.order_id,'beneficiary_type',beneficiary_type,'beneficiary_id',beneficiary_id,
  'amount_halalas',p_amount_halalas,'settled_halalas',paid+p_amount_halalas,
  'outstanding_halalas',funding.principal_halalas-paid-p_amount_halalas,
  'fully_settled',paid+p_amount_halalas=funding.principal_halalas,
  'payment_reference',p_payment_reference,'customer_total_changed',false,'inventory_changed',false,
  'customer_cash_changed',false,'created_at',nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_settlement_recorded',settlement_id,
  jsonb_build_object('role',u.role,'funding_id',funding.id,'purchase_record_id',funding.purchase_record_id,
   'job_id',funding.job_id,'order_id',funding.order_id,'beneficiary_type',beneficiary_type,
   'beneficiary_id',beneficiary_id,'amount_halalas',p_amount_halalas,'settled_halalas',paid+p_amount_halalas,
   'outstanding_halalas',funding.principal_halalas-paid-p_amount_halalas,'payment_reference',p_payment_reference,
   'customer_total_changed',false,'inventory_changed',false,'customer_cash_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_settlement_validation';
END$$;

-- Funding attribution is required before physical custody can leave purchasing.
-- Repayment itself remains independent because supplier/employee payment timing
-- is an owner policy and may occur before or after delivery.
ALTER FUNCTION public.jana_procurement_handover_prepare(text,text,text,text,bigint,text)
 RENAME TO jana_procurement_handover_prepare_funding_base;
CREATE FUNCTION public.jana_procurement_handover_prepare(
 p_token text,p_idem_key text,p_order_id text,p_courier_id text,p_expected_revision bigint,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;result jsonb;missing integer;employee_due bigint;supplier_due bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT count(*) INTO missing FROM public.procurement_purchase_records r
 JOIN public.procurement_jobs j ON j.id=r.job_id
 WHERE j.order_id=p_order_id AND NOT EXISTS(
  SELECT 1 FROM public.procurement_purchase_funding f WHERE f.purchase_record_id=r.id
 );
 IF missing>0 THEN RAISE EXCEPTION 'procurement_funding_required';END IF;
 result=public.jana_procurement_handover_prepare_funding_base(
  p_token,p_idem_key,p_order_id,p_courier_id,p_expected_revision,p_note
 );
 SELECT
  coalesce(sum(CASE WHEN f.funding_source='employee_paid' THEN f.principal_halalas-coalesce(s.paid,0) ELSE 0 END),0),
  coalesce(sum(CASE WHEN f.funding_source='supplier_credit' THEN f.principal_halalas-coalesce(s.paid,0) ELSE 0 END),0)
 INTO employee_due,supplier_due
 FROM public.procurement_purchase_funding f
 LEFT JOIN LATERAL(SELECT sum(e.amount_halalas) paid FROM public.procurement_settlement_entries e WHERE e.funding_id=f.id)s ON true
 WHERE f.job_id=(result->>'job_id');
 RETURN result||jsonb_build_object('purchase_funding_recorded',true,
  'employee_reimbursement_outstanding_halalas',employee_due,
  'supplier_payable_outstanding_halalas',supplier_due);
END$$;

ALTER FUNCTION public.jana_deep_health() RENAME TO jana_deep_health_procurement_funding_base;
CREATE FUNCTION public.jana_deep_health() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;bad integer;
BEGIN
 result=public.jana_deep_health_procurement_funding_base();
 SELECT count(*) INTO bad FROM public.procurement_purchase_funding f
 JOIN public.procurement_purchase_records r ON r.id=f.purchase_record_id
 JOIN public.procurement_jobs j ON j.id=r.job_id
 WHERE f.job_id<>r.job_id OR f.order_id<>j.order_id OR f.principal_halalas<>r.total_actual_cost_halalas
  OR (f.funding_source='employee_paid' AND f.employee_id IS DISTINCT FROM r.actor_id)
  OR (f.funding_source='supplier_credit' AND f.supplier_id IS DISTINCT FROM r.supplier_id)
  OR coalesce((SELECT sum(e.amount_halalas) FROM public.procurement_settlement_entries e WHERE e.funding_id=f.id),0)>f.principal_halalas;
 RETURN result||jsonb_build_object('ok',(result->>'ok')::boolean AND bad=0,
  'procurement_funding_invariant_violations',bad);
END$$;

REVOKE ALL ON FUNCTION public.jana_procurement_funding_guard(),public.jana_procurement_settlement_guard(),
 public.jana_procurement_funding_record(text,text,text,text,text,text),
 public.jana_procurement_settlement_record(text,text,text,bigint,text,text),
 public.jana_procurement_handover_prepare_funding_base(text,text,text,text,bigint,text),
 public.jana_procurement_handover_prepare(text,text,text,text,bigint,text),
 public.jana_deep_health_procurement_funding_base(),public.jana_deep_health()
FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.jana_deep_health() TO service_role;
