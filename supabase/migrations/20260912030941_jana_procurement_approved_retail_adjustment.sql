-- Dormant phase-5 supplier-pickup retail adjustment.
-- Applies only the exact reduction the order-owning customer approved. It never
-- derives a margin, changes supplier cost, touches inventory, or creates cash.
CREATE TABLE public.procurement_retail_adjustments (
 id varchar(36) PRIMARY KEY,
 request_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_shortage_requests(id),
 decision_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_shortage_decisions(id),
 job_id varchar(36) NOT NULL REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL REFERENCES public.orders(id),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),
 missing_lines_snapshot jsonb NOT NULL CHECK(jsonb_typeof(missing_lines_snapshot)='array' AND jsonb_array_length(missing_lines_snapshot)>0),
 customer_total_before_halalas bigint NOT NULL CHECK(customer_total_before_halalas>0),
 subtotal_before_halalas bigint NOT NULL CHECK(subtotal_before_halalas>0),
 approved_reduction_halalas bigint NOT NULL CHECK(approved_reduction_halalas>0),
 subtotal_after_halalas bigint NOT NULL CHECK(subtotal_after_halalas>0),
 customer_total_after_halalas bigint NOT NULL CHECK(customer_total_after_halalas>0),
 snapshot_hash_before varchar(64) NOT NULL CHECK(snapshot_hash_before~'^[0-9a-f]{64}$'),
 snapshot_hash_after varchar(64) NOT NULL CHECK(snapshot_hash_after~'^[0-9a-f]{64}$'),
 reason varchar(1000) NOT NULL CHECK(length(trim(reason)) BETWEEN 3 AND 1000),
 created_at bigint NOT NULL,
 CHECK(subtotal_before_halalas-subtotal_after_halalas=approved_reduction_halalas),
 CHECK(customer_total_before_halalas-customer_total_after_halalas=approved_reduction_halalas)
);
CREATE INDEX jana_retail_adjustment_job ON public.procurement_retail_adjustments(job_id,created_at DESC,id DESC);
CREATE INDEX jana_retail_adjustment_order ON public.procurement_retail_adjustments(order_id,created_at DESC,id DESC);
CREATE INDEX jana_retail_adjustment_actor ON public.procurement_retail_adjustments(actor_id,created_at DESC,id DESC);
ALTER TABLE public.procurement_retail_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_retail_adjustments FROM PUBLIC,anon,authenticated,service_role;

CREATE TRIGGER jana_retail_adjustment_immutable
BEFORE UPDATE OR DELETE ON public.procurement_retail_adjustments FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_procurement_shortage_apply_adjustment(
 p_token text,p_idem_key text,p_request_id text,p_expected_revision bigint,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;o public.orders;job public.procurement_jobs;request public.procurement_shortage_requests;
 decision public.procurement_shortage_decisions;prior public.idempotency_records;
 scope_key text;req_hash text;result jsonb;adjustment_id text;newlines jsonb;new_snapshot jsonb;
 subtotal_before bigint;subtotal_after bigint;calculated_subtotal bigint;delivery_fee bigint;total_after bigint;matched integer;
 before_hash text;after_hash text;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_reason=trim(coalesce(p_reason,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR length(p_reason) NOT BETWEEN 3 AND 1000
  OR p_expected_revision IS NULL OR p_expected_revision<1 THEN RAISE EXCEPTION 'procurement_adjustment_validation';END IF;
 scope_key='procurement-shortage-adjust:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('request_id',p_request_id,'revision',p_expected_revision,'reason',p_reason)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO request FROM public.procurement_shortage_requests WHERE id=p_request_id FOR SHARE;
 IF request.id IS NULL OR request.state<>'approved' THEN RAISE EXCEPTION 'procurement_shortage_not_approved';END IF;
 SELECT d.* INTO decision FROM public.procurement_shortage_decisions d
 WHERE d.request_id=request.id AND d.decision='approve_removal' FOR SHARE OF d;
 IF decision.id IS NULL OR decision.job_id<>request.job_id OR decision.order_id<>request.order_id
  OR decision.missing_lines_snapshot<>request.missing_lines
  OR decision.proposed_reduction_halalas<>request.proposed_reduction_halalas
  OR decision.customer_total_before_halalas<>request.customer_total_before_halalas
 THEN RAISE EXCEPTION 'procurement_shortage_evidence_invalid';END IF;
 SELECT * INTO o FROM public.orders WHERE id=request.order_id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.snapshot::jsonb->>'fulfillment_model'<>'supplier_pickup'
  OR o.total_halalas<>request.customer_total_before_halalas OR o.collected_halalas<>0
  OR o.refunded_halalas<>0 OR o.cash_state<>'uncollected'
 THEN RAISE EXCEPTION 'procurement_order_changed';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE id=request.job_id AND order_id=o.id FOR UPDATE;
 IF job.id IS NULL OR job.state<>'shortage_approved' THEN RAISE EXCEPTION 'procurement_shortage_state_invalid';END IF;
 IF job.revision<>p_expected_revision THEN RAISE EXCEPTION 'procurement_changed';END IF;
 IF EXISTS(SELECT 1 FROM public.procurement_retail_adjustments a WHERE a.request_id=request.id)
 THEN RAISE EXCEPTION 'procurement_adjustment_exists';END IF;
 subtotal_before=(o.snapshot->>'subtotal_halalas')::bigint;
 delivery_fee=(o.snapshot->>'delivery_fee_halalas')::bigint;
 IF coalesce((o.snapshot->>'discount_halalas')::bigint,0)<>0
  OR subtotal_before+delivery_fee<>o.total_halalas THEN RAISE EXCEPTION 'procurement_order_terms_unsupported';END IF;
 SELECT count(*) INTO matched
 FROM jsonb_array_elements(request.missing_lines) m
 JOIN jsonb_array_elements(o.snapshot::jsonb->'lines') l ON l->>'line_id'=m->>'line_id'
 WHERE (l->>'qty')::numeric=(m->>'requested_qty')::numeric
  AND (l->>'unit_price_halalas')::bigint=(m->>'unit_price_halalas')::bigint
  AND (m->>'missing_qty')::numeric>0
  AND (m->>'collected_qty')::numeric>=0
  AND (m->>'collected_qty')::numeric+(m->>'missing_qty')::numeric=(m->>'requested_qty')::numeric
  AND (m->>'proposed_reduction_halalas')::numeric=(m->>'unit_price_halalas')::numeric*(m->>'missing_qty')::numeric;
 IF matched<>jsonb_array_length(request.missing_lines) THEN RAISE EXCEPTION 'procurement_shortage_evidence_invalid';END IF;
 WITH current_lines AS (
  SELECT l,ord,(SELECT m FROM jsonb_array_elements(request.missing_lines) m WHERE m->>'line_id'=l->>'line_id') m
  FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY x(l,ord)
 ),adjusted AS (
  SELECT ord,CASE WHEN m IS NULL THEN l||jsonb_build_object('availability_status','collected')
   WHEN (m->>'collected_qty')::numeric>0 THEN l||jsonb_build_object(
    'qty',(m->>'collected_qty')::numeric,
    'line_total_halalas',((m->>'unit_price_halalas')::numeric*(m->>'collected_qty')::numeric)::bigint,
    'availability_status','collected_with_approved_shortage')
   ELSE NULL END line
  FROM current_lines
 ) SELECT coalesce(jsonb_agg(line ORDER BY ord) FILTER(WHERE line IS NOT NULL),'[]'::jsonb)
 INTO newlines FROM adjusted;
 IF jsonb_array_length(newlines)<1 THEN RAISE EXCEPTION 'procurement_empty_order_requires_cancellation';END IF;
 subtotal_after=subtotal_before-request.proposed_reduction_halalas;
 SELECT sum((l->>'line_total_halalas')::bigint) INTO calculated_subtotal FROM jsonb_array_elements(newlines) l;
 total_after=o.total_halalas-request.proposed_reduction_halalas;
 IF subtotal_after<=0 OR calculated_subtotal<>subtotal_after OR total_after<>subtotal_after+delivery_fee
 THEN RAISE EXCEPTION 'procurement_adjustment_invalid';END IF;
 before_hash=encode(digest(o.snapshot::jsonb::text,'sha256'),'hex');
 new_snapshot=o.snapshot::jsonb||jsonb_build_object(
  'lines',newlines,'subtotal_halalas',subtotal_after,'total_halalas',total_after,
  'procurement_state','ready_for_handover','approved_shortage_request_id',request.id);
 after_hash=encode(digest(new_snapshot::text,'sha256'),'hex');
 adjustment_id='pra-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_retail_adjustments(id,request_id,decision_id,job_id,order_id,actor_id,
  missing_lines_snapshot,customer_total_before_halalas,subtotal_before_halalas,approved_reduction_halalas,
  subtotal_after_halalas,customer_total_after_halalas,snapshot_hash_before,snapshot_hash_after,reason,created_at)
 VALUES(adjustment_id,request.id,decision.id,job.id,o.id,u.id,request.missing_lines,o.total_halalas,
  subtotal_before,request.proposed_reduction_halalas,subtotal_after,total_after,before_hash,after_hash,p_reason,nowms);
 UPDATE public.orders SET snapshot=new_snapshot,total_halalas=total_after WHERE id=o.id;
 UPDATE public.procurement_jobs SET state='ready',revision=revision+1,updated_at=nowms
 WHERE id=job.id RETURNING * INTO job;
 result=jsonb_build_object('id',adjustment_id,'request_id',request.id,'decision_id',decision.id,
  'job_id',job.id,'order_id',o.id,'job_state',job.state,'revision',job.revision,
  'missing_lines',request.missing_lines,'customer_total_before_halalas',o.total_halalas,
  'approved_reduction_halalas',request.proposed_reduction_halalas,'customer_total_after_halalas',total_after,
  'customer_total_changed',true,'original_snapshot_changed',false,'inventory_changed',false,
  'supplier_cost_changed',false,'cash_changed',false,'requires_handover',true,'created_at',nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'procurement-adjust-'||adjustment_id,
  'تم تطبيق النقص الذي وافقت عليه','تم تخفيض إجمالي الطلب حسب الكميات التي وافقت على حذفها. يمكنك مراجعة الإجمالي المحدّث في الطلب.',o.id,false,nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'procurement_shortage_adjusted',p_reason,
  jsonb_build_object('job_id',job.id,'request_id',request.id,'decision_id',decision.id,'adjustment_id',adjustment_id,
   'revision',job.revision,'customer_total_before_halalas',o.total_halalas,
   'approved_reduction_halalas',request.proposed_reduction_halalas,'customer_total_after_halalas',total_after,
   'inventory_changed',false,'cash_changed',false),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_shortage_adjusted',adjustment_id,
  jsonb_build_object('role',u.role,'job_id',job.id,'order_id',o.id,'request_id',request.id,'decision_id',decision.id,
   'reason',p_reason,'revision',job.revision,'snapshot_hash_before',before_hash,'snapshot_hash_after',after_hash,
   'customer_total_before_halalas',o.total_halalas,'approved_reduction_halalas',request.proposed_reduction_halalas,
   'customer_total_after_halalas',total_after,'original_snapshot_changed',false,'inventory_changed',false,
   'supplier_cost_changed',false,'cash_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_adjustment_validation';
END$$;

-- Still dormant: handover, settlement and complete Edge/UI support are not yet
-- implemented, so neither clients nor service_role can invoke this function.
REVOKE ALL ON FUNCTION public.jana_procurement_shortage_apply_adjustment(text,text,text,bigint,text)
FROM PUBLIC,anon,authenticated,service_role;
