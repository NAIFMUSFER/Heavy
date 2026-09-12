-- Phase 9: bounded, role-scoped staff reads for the warehouse-free purchasing
-- journey. These reads expose no customer contact and grant no transaction
-- primitive; commercial intake and the write path remain dormant.
CREATE INDEX jana_procurement_jobs_created_page
 ON public.procurement_jobs(created_at DESC,id DESC);

CREATE FUNCTION public.jana_procurement_jobs_page(
 p_token text,p_limit integer DEFAULT 50,p_before_at bigint DEFAULT NULL,
 p_before_id text DEFAULT NULL,p_state text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;items jsonb;next_cursor jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','finance','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
  OR ((p_before_at IS NULL)<>(p_before_id IS NULL))
  OR (p_before_at IS NOT NULL AND (p_before_at<0 OR p_before_id!~'^prc-[0-9a-f]{32}$'))
  OR (p_state IS NOT NULL AND p_state NOT IN ('unassigned','assigned','collecting','awaiting_customer',
   'shortage_approved','ready','handover_pending','handed_over','cancelled'))
 THEN RAISE EXCEPTION 'procurement_query_invalid';END IF;
 WITH page AS MATERIALIZED(
  SELECT j.id,j.order_id,o.number order_number,j.state,j.revision,j.assigned_to,a.name assigned_name,
   j.created_at,j.updated_at,o.total_halalas customer_total_halalas,
   jsonb_array_length(j.requested_lines) requested_line_count,
   (SELECT count(*) FROM public.procurement_purchase_records r WHERE r.job_id=j.id) purchase_count,
   (SELECT coalesce(sum(r.total_actual_cost_halalas),0) FROM public.procurement_purchase_records r WHERE r.job_id=j.id) actual_cost_total_halalas,
   (SELECT count(*) FROM public.procurement_purchase_records r WHERE r.job_id=j.id AND NOT EXISTS(
    SELECT 1 FROM public.procurement_purchase_funding f WHERE f.purchase_record_id=r.id)) unfunded_purchase_count,
   (SELECT coalesce(sum(CASE WHEN f.funding_source='employee_paid' THEN
     f.principal_halalas-coalesce((SELECT sum(e.amount_halalas) FROM public.procurement_settlement_entries e WHERE e.funding_id=f.id),0)
     ELSE 0 END),0) FROM public.procurement_purchase_funding f WHERE f.job_id=j.id) employee_reimbursement_outstanding_halalas,
   (SELECT coalesce(sum(CASE WHEN f.funding_source='supplier_credit' THEN
     f.principal_halalas-coalesce((SELECT sum(e.amount_halalas) FROM public.procurement_settlement_entries e WHERE e.funding_id=f.id),0)
     ELSE 0 END),0) FROM public.procurement_purchase_funding f WHERE f.job_id=j.id) supplier_payable_outstanding_halalas
  FROM public.procurement_jobs j
  JOIN public.orders o ON o.id=j.order_id
  LEFT JOIN public.users a ON a.id=j.assigned_to
  WHERE (u.role IN ('admin','finance') OR j.assigned_to=u.id)
   AND (p_state IS NULL OR j.state=p_state)
   AND (p_before_at IS NULL OR (j.created_at,j.id)<(p_before_at,p_before_id))
  ORDER BY j.created_at DESC,j.id DESC LIMIT p_limit+1
 ),numbered AS(
  SELECT *,row_number() OVER(ORDER BY created_at DESC,id DESC) rn FROM page
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',id,'order_id',order_id,'order_number',order_number,'state',state,'revision',revision,
   'assigned_to',assigned_to,'assigned_name',assigned_name,'created_at',created_at,'updated_at',updated_at,
   'requested_line_count',requested_line_count,'purchase_count',purchase_count,
   'actual_cost_total_halalas',actual_cost_total_halalas,'unfunded_purchase_count',unfunded_purchase_count,
   'employee_reimbursement_outstanding_halalas',employee_reimbursement_outstanding_halalas,
   'supplier_payable_outstanding_halalas',supplier_payable_outstanding_halalas,
   'customer_total_halalas',customer_total_halalas,'customer_contact_included',false
  ) ORDER BY created_at DESC,id DESC) FILTER(WHERE rn<=p_limit),'[]'::jsonb),
  CASE WHEN count(*)>p_limit THEN (jsonb_agg(jsonb_build_object('before_at',created_at,'before_id',id)
   ORDER BY created_at DESC,id DESC) FILTER(WHERE rn<=p_limit))->(p_limit-1) ELSE NULL END
 INTO items,next_cursor FROM numbered;
 RETURN jsonb_build_object('items',items,'next',next_cursor,'limit',p_limit,'state_filter',p_state,
  'financial_detail_included',u.role IN ('admin','finance'),'customer_contact_included',false);
END$$;

CREATE FUNCTION public.jana_procurement_job_detail(p_token text,p_job_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;o public.orders;assigned_name text;
 lines jsonb;purchases jsonb;funding jsonb;settlements jsonb;shortage jsonb;handover jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','finance','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_job_id IS NULL OR p_job_id!~'^prc-[0-9a-f]{32}$' THEN RAISE EXCEPTION 'procurement_query_invalid';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id;
 IF j.id IS NULL OR (u.role='picker' AND j.assigned_to IS DISTINCT FROM u.id)
 THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=j.order_id;
 SELECT name INTO assigned_name FROM public.users WHERE id=j.assigned_to;

 SELECT coalesce(jsonb_agg(r.line||jsonb_build_object(
   'collected_qty',r.collected_qty,'remaining_qty',(r.line->>'qty')::numeric-r.collected_qty
  ) ORDER BY r.ord),'[]'::jsonb) INTO lines
 FROM (SELECT x.value line,x.ord,
  coalesce((SELECT sum(l.collected_qty) FROM public.procurement_purchase_lines l
   WHERE l.job_id=j.id AND l.requested_line_id=x.value->>'line_id'),0) collected_qty
  FROM jsonb_array_elements(j.requested_lines) WITH ORDINALITY x(value,ord))r;

 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',r.id,'supplier',r.supplier_snapshot,'pickup_site',r.site_snapshot,
  'document_reference',r.document_reference,'note',r.note,
  'total_actual_cost_halalas',r.total_actual_cost_halalas,'actor_id',r.actor_id,'created_at',r.created_at,
  'lines',(SELECT coalesce(jsonb_agg(jsonb_build_object(
    'line_id',l.requested_line_id,'offering_id',l.offering_id,'requested_qty',l.requested_qty,
    'collected_qty',l.collected_qty,'actual_cost_halalas',l.actual_cost_halalas,
    'quality_note',l.quality_note) ORDER BY l.requested_line_id),'[]'::jsonb)
   FROM public.procurement_purchase_lines l WHERE l.record_id=r.id)
 ) ORDER BY r.created_at,r.id),'[]'::jsonb) INTO purchases
 FROM public.procurement_purchase_records r WHERE r.job_id=j.id;

 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',f.id,'purchase_record_id',f.purchase_record_id,'funding_source',f.funding_source,
  'principal_halalas',f.principal_halalas,'employee_id',f.employee_id,'supplier_id',f.supplier_id,
  'evidence_reference',f.evidence_reference,'created_at',f.created_at,
  'settled_halalas',coalesce(s.paid,0),'outstanding_halalas',
   CASE WHEN f.funding_source='company_paid' THEN 0 ELSE f.principal_halalas-coalesce(s.paid,0) END
 ) ORDER BY f.created_at,f.id),'[]'::jsonb) INTO funding
 FROM public.procurement_purchase_funding f
 LEFT JOIN LATERAL(SELECT sum(e.amount_halalas) paid FROM public.procurement_settlement_entries e WHERE e.funding_id=f.id)s ON true
 WHERE f.job_id=j.id;

 IF u.role IN ('admin','finance') THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',e.id,'funding_id',e.funding_id,'beneficiary_type',e.beneficiary_type,
   'beneficiary_id',e.beneficiary_id,'amount_halalas',e.amount_halalas,
   'payment_reference',e.payment_reference,'note',e.note,'actor_id',e.actor_id,'created_at',e.created_at
  ) ORDER BY e.created_at,e.id),'[]'::jsonb) INTO settlements
  FROM public.procurement_settlement_entries e WHERE e.job_id=j.id;
 ELSE settlements='[]'::jsonb;END IF;

 SELECT CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_build_object(
  'id',r.id,'state',r.state,'missing_lines',r.missing_lines,
  'proposed_reduction_halalas',r.proposed_reduction_halalas,'reason',r.reason,
  'created_at',r.created_at,'decided_at',r.decided_at,
  'decision',(SELECT jsonb_build_object('decision',d.decision,'note',d.note,'created_at',d.created_at)
   FROM public.procurement_shortage_decisions d WHERE d.request_id=r.id)
 ) END INTO shortage FROM public.procurement_shortage_requests r
 WHERE r.job_id=j.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1;

 SELECT CASE WHEN h.id IS NULL THEN NULL ELSE jsonb_build_object(
  'request_id',h.id,'courier_id',h.courier_id,'created_at',h.created_at,
  'accepted_at',(SELECT a.created_at FROM public.procurement_handover_acceptances a WHERE a.request_id=h.id)
 ) END INTO handover FROM public.procurement_handover_requests h WHERE h.job_id=j.id;

 RETURN jsonb_build_object('job',jsonb_build_object(
   'id',j.id,'order_id',j.order_id,'order_number',o.number,'state',j.state,'revision',j.revision,
   'assigned_to',j.assigned_to,'assigned_name',assigned_name,'created_at',j.created_at,'updated_at',j.updated_at),
  'customer_terms',jsonb_build_object('total_halalas',o.total_halalas,
   'original_total_halalas',(o.original_snapshot::jsonb->>'total_halalas')::bigint,
   'customer_contact_included',false),
  'lines',lines,'purchases',purchases,'funding',funding,'settlements',settlements,
  'shortage',shortage,'handover',handover,'financial_detail_included',u.role IN ('admin','finance'),
  'customer_contact_included',false);
END$$;

REVOKE ALL ON FUNCTION public.jana_procurement_jobs_page(text,integer,bigint,text,text),
 public.jana_procurement_job_detail(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_procurement_jobs_page(text,integer,bigint,text,text),
 public.jana_procurement_job_detail(text,text) TO service_role;
