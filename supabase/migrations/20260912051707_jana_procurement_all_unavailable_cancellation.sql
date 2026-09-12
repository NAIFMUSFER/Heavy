-- Dormant phase-7 supplier-pickup all-unavailable cancellation.
-- A prior approved shortage is not treated as cancellation consent. The order
-- customer must explicitly confirm cancellation after every line is proven
-- unavailable. Historical retail terms remain unchanged and only the booked
-- delivery capacity is released.
CREATE TABLE public.procurement_unavailable_cancellations (
 id varchar(36) PRIMARY KEY,
 request_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_shortage_requests(id),
 decision_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_shortage_decisions(id),
 job_id varchar(36) NOT NULL UNIQUE REFERENCES public.procurement_jobs(id),
 order_id varchar(36) NOT NULL UNIQUE REFERENCES public.orders(id),
 customer_id varchar(36) NOT NULL REFERENCES public.users(id),
 slot_id varchar(36) NOT NULL REFERENCES public.delivery_slots(id),
 missing_lines_snapshot jsonb NOT NULL CHECK(jsonb_typeof(missing_lines_snapshot)='array' AND jsonb_array_length(missing_lines_snapshot)>0),
 unavailable_subtotal_halalas bigint NOT NULL CHECK(unavailable_subtotal_halalas>0),
 delivery_fee_halalas bigint NOT NULL CHECK(delivery_fee_halalas>=0),
 customer_total_halalas bigint NOT NULL CHECK(customer_total_halalas>0),
 current_snapshot_hash varchar(64) NOT NULL CHECK(current_snapshot_hash~'^[0-9a-f]{64}$'),
 original_snapshot_hash varchar(64) NOT NULL CHECK(original_snapshot_hash~'^[0-9a-f]{64}$'),
 slot_booked_before integer NOT NULL CHECK(slot_booked_before>0),
 slot_booked_after integer NOT NULL CHECK(slot_booked_after>=0),
 note varchar(1000) NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 1000),
 created_at bigint NOT NULL,
 CHECK(customer_total_halalas=unavailable_subtotal_halalas+delivery_fee_halalas),
 CHECK(slot_booked_after=slot_booked_before-1)
);
CREATE INDEX jana_unavailable_cancel_customer ON public.procurement_unavailable_cancellations(customer_id,created_at DESC,id DESC);
CREATE INDEX jana_unavailable_cancel_slot ON public.procurement_unavailable_cancellations(slot_id,created_at DESC,id DESC);
ALTER TABLE public.procurement_unavailable_cancellations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_unavailable_cancellations FROM PUBLIC,anon,authenticated,service_role;

CREATE TRIGGER jana_unavailable_cancellation_immutable
BEFORE UPDATE OR DELETE ON public.procurement_unavailable_cancellations FOR EACH ROW
EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_procurement_all_unavailable_cancel(
 p_token text,p_idem_key text,p_request_id text,p_expected_revision bigint,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;o public.orders;job public.procurement_jobs;request public.procurement_shortage_requests;
 decision public.procurement_shortage_decisions;slot public.delivery_slots;prior public.idempotency_records;
 scope_key text;req_hash text;result jsonb;cancellation_id text;current_hash text;original_hash text;
 subtotal bigint;delivery_fee bigint;matched integer;slot_before integer;slot_after integer;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_note=trim(coalesce(p_note,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR length(p_note) NOT BETWEEN 3 AND 1000
  OR p_expected_revision IS NULL OR p_expected_revision<1
 THEN RAISE EXCEPTION 'procurement_cancellation_validation';END IF;
 scope_key='procurement-all-unavailable-cancel:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('request_id',p_request_id,'revision',p_expected_revision,
  'note',p_note)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT r.* INTO request FROM public.procurement_shortage_requests r
 JOIN public.orders x ON x.id=r.order_id WHERE r.id=p_request_id AND x.user_id=u.id FOR SHARE OF r;
 IF request.id IS NULL OR request.state<>'approved' THEN RAISE EXCEPTION 'procurement_shortage_not_found';END IF;
 SELECT d.* INTO decision FROM public.procurement_shortage_decisions d
 WHERE d.request_id=request.id AND d.customer_id=u.id AND d.decision='approve_removal' FOR SHARE OF d;
 IF decision.id IS NULL OR decision.missing_lines_snapshot<>request.missing_lines
  OR decision.proposed_reduction_halalas<>request.proposed_reduction_halalas
  OR decision.customer_total_before_halalas<>request.customer_total_before_halalas
 THEN RAISE EXCEPTION 'procurement_cancellation_consent_invalid';END IF;
 SELECT * INTO o FROM public.orders WHERE id=request.order_id AND user_id=u.id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.payment_state<>'awaiting_collection'
  OR o.fulfillment_state<>'queued' OR o.delivery_state<>'unassigned' OR o.courier_id IS NOT NULL
  OR o.collected_halalas<>0 OR o.refunded_halalas<>0 OR o.cash_state<>'uncollected'
  OR o.snapshot::jsonb->>'fulfillment_model'<>'supplier_pickup'
  OR o.total_halalas<>request.customer_total_before_halalas
 THEN RAISE EXCEPTION 'procurement_order_changed';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE id=request.job_id AND order_id=o.id FOR UPDATE;
 IF job.id IS NULL OR job.state<>'shortage_approved' OR job.assigned_to IS NULL
 THEN RAISE EXCEPTION 'procurement_cancellation_state_invalid';END IF;
 IF job.revision<>p_expected_revision THEN RAISE EXCEPTION 'procurement_changed';END IF;
 IF EXISTS(SELECT 1 FROM public.procurement_retail_adjustments a WHERE a.request_id=request.id)
  OR EXISTS(SELECT 1 FROM public.procurement_handover_requests h WHERE h.job_id=job.id)
  OR EXISTS(SELECT 1 FROM public.procurement_purchase_records r WHERE r.job_id=job.id)
 THEN RAISE EXCEPTION 'procurement_cancellation_evidence_invalid';END IF;
 subtotal=(o.snapshot::jsonb->>'subtotal_halalas')::bigint;
 delivery_fee=coalesce((o.snapshot::jsonb->>'delivery_fee_halalas')::bigint,0);
 IF subtotal<=0 OR o.total_halalas<>subtotal+delivery_fee
  OR request.proposed_reduction_halalas<>subtotal
  OR jsonb_array_length(request.missing_lines)<>jsonb_array_length(o.snapshot::jsonb->'lines')
 THEN RAISE EXCEPTION 'procurement_all_unavailable_required';END IF;
 SELECT count(*) INTO matched
 FROM jsonb_array_elements(o.snapshot::jsonb->'lines') l
 JOIN jsonb_array_elements(request.missing_lines) m ON m->>'line_id'=l->>'line_id'
 WHERE (m->>'requested_qty')::numeric=(l->>'qty')::numeric
  AND (m->>'missing_qty')::numeric=(l->>'qty')::numeric
  AND (m->>'collected_qty')::numeric=0
  AND (m->>'unit_price_halalas')::bigint=(l->>'unit_price_halalas')::bigint
  AND (m->>'proposed_reduction_halalas')::bigint=(l->>'line_total_halalas')::bigint;
 IF matched<>jsonb_array_length(o.snapshot::jsonb->'lines')
 THEN RAISE EXCEPTION 'procurement_all_unavailable_required';END IF;
 IF EXISTS(SELECT 1 FROM public.procurement_unavailable_cancellations c WHERE c.order_id=o.id)
 THEN RAISE EXCEPTION 'procurement_cancellation_exists';END IF;
 SELECT * INTO slot FROM public.delivery_slots WHERE id=o.slot_id FOR UPDATE;
 IF slot.id IS NULL OR slot.booked<1 THEN RAISE EXCEPTION 'procurement_slot_invalid';END IF;
 slot_before=slot.booked;slot_after=slot.booked-1;
 current_hash=encode(digest(o.snapshot::jsonb::text,'sha256'),'hex');
 original_hash=encode(digest(o.original_snapshot::jsonb::text,'sha256'),'hex');
 cancellation_id='puc-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.procurement_unavailable_cancellations(id,request_id,decision_id,job_id,order_id,
  customer_id,slot_id,missing_lines_snapshot,unavailable_subtotal_halalas,delivery_fee_halalas,
  customer_total_halalas,current_snapshot_hash,original_snapshot_hash,slot_booked_before,
  slot_booked_after,note,created_at)
 VALUES(cancellation_id,request.id,decision.id,job.id,o.id,u.id,o.slot_id,request.missing_lines,
  subtotal,delivery_fee,o.total_halalas,current_hash,original_hash,slot_before,slot_after,p_note,nowms);
 UPDATE public.delivery_slots SET booked=slot_after WHERE id=slot.id;
 UPDATE public.orders SET status='cancelled',payment_state='cancelled',fulfillment_state='cancelled',
  delivery_state='cancelled',code_hash=NULL,code_expires_at=NULL WHERE id=o.id;
 UPDATE public.procurement_jobs SET state='cancelled',revision=revision+1,updated_at=nowms
 WHERE id=job.id RETURNING * INTO job;
 result=jsonb_build_object('id',cancellation_id,'request_id',request.id,'decision_id',decision.id,
  'job_id',job.id,'order_id',o.id,'job_state',job.state,'revision',job.revision,
  'status','cancelled','payment_state','cancelled','fulfillment_state','cancelled','delivery_state','cancelled',
  'unavailable_subtotal_halalas',subtotal,'delivery_fee_halalas',delivery_fee,
  'customer_total_halalas',o.total_halalas,'customer_total_changed',false,
  'current_snapshot_changed',false,'original_snapshot_changed',false,
  'delivery_capacity_released',true,'slot_booked_before',slot_before,'slot_booked_after',slot_after,
  'inventory_changed',false,'supplier_cost_changed',false,'cash_changed',false,'created_at',nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement-unavailable-cancel-'||o.id,
  'تم إلغاء الطلب','بناءً على تأكيدك، أُلغي الطلب لتعذر توفير جميع الأصناف ولم يُسجل عليك تحصيل.',o.id,false,nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'procurement_all_unavailable_cancelled',p_note,
  jsonb_build_object('job_id',job.id,'request_id',request.id,'decision_id',decision.id,
   'cancellation_id',cancellation_id,'revision',job.revision,'customer_total_halalas',o.total_halalas,
   'customer_total_changed',false,'delivery_capacity_released',true,'inventory_changed',false,'cash_changed',false),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_all_unavailable_cancelled',cancellation_id,
  jsonb_build_object('job_id',job.id,'order_id',o.id,'request_id',request.id,'decision_id',decision.id,
   'revision',job.revision,'current_snapshot_hash',current_hash,'original_snapshot_hash',original_hash,
   'slot_id',o.slot_id,'slot_booked_before',slot_before,'slot_booked_after',slot_after,
   'customer_total_changed',false,'inventory_changed',false,'supplier_cost_changed',false,'cash_changed',false),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
EXCEPTION WHEN string_data_right_truncation OR check_violation OR invalid_text_representation OR numeric_value_out_of_range
 THEN RAISE EXCEPTION 'procurement_cancellation_validation';
END$$;

-- Still dormant: supplier/employee settlement and complete Edge/UI support are
-- unfinished, so neither clients nor service_role can invoke this function.
REVOKE ALL ON FUNCTION public.jana_procurement_all_unavailable_cancel(text,text,text,bigint,text)
FROM PUBLIC,anon,authenticated,service_role;
