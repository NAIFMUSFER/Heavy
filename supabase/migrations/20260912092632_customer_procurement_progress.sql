-- Phase 12: expose only customer-owned collection progress through the existing
-- order detail boundary. Supplier, employee, receipt and actual-cost evidence
-- stays private; this adds no mutation route and does not change retail terms.
ALTER FUNCTION public.jana_order_detail(text,text) RENAME TO jana_order_detail_pre_procurement_progress;

CREATE FUNCTION public.jana_order_detail(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;o public.orders;j public.procurement_jobs;
 result jsonb;lines jsonb;shortage jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 result=public.jana_order_detail_pre_procurement_progress(p_token,p_order_id);
 SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE order_id=o.id;
 IF j.id IS NULL THEN
  RETURN result||jsonb_build_object('procurement_progress',NULL);
 END IF;

 WITH balance AS (
  SELECT x.value line,x.ord,(x.value->>'qty')::numeric requested_qty,
   coalesce((SELECT sum(l.collected_qty) FROM public.procurement_purchase_lines l
    WHERE l.job_id=j.id AND l.requested_line_id=x.value->>'line_id'),0) collected_qty
  FROM jsonb_array_elements(j.requested_lines) WITH ORDINALITY x(value,ord)
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'line_id',line->>'line_id','name',line->>'name','size_label',line->>'size_label',
   'requested_qty',requested_qty,'collected_qty',collected_qty,
   'remaining_qty',requested_qty-collected_qty
  ) ORDER BY ord),'[]'::jsonb) INTO lines FROM balance;

 SELECT CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_build_object(
  'id',r.id,'state',r.state,'proposed_reduction_halalas',r.proposed_reduction_halalas,
  'customer_total_before_halalas',r.customer_total_before_halalas,
  'customer_total_if_approved_halalas',r.customer_total_before_halalas-r.proposed_reduction_halalas,
  'created_at',r.created_at,'decided_at',r.decided_at,
  'decision',(SELECT d.decision FROM public.procurement_shortage_decisions d WHERE d.request_id=r.id),
  'missing_lines',(SELECT coalesce(jsonb_agg(jsonb_build_object(
    'line_id',x.value->>'line_id','name',x.value->>'name','size_label',x.value->>'size_label',
    'requested_qty',(x.value->>'requested_qty')::numeric,
    'collected_qty',(x.value->>'collected_qty')::numeric,
    'missing_qty',(x.value->>'missing_qty')::numeric,
    'proposed_reduction_halalas',(x.value->>'proposed_reduction_halalas')::bigint
   ) ORDER BY x.ord),'[]'::jsonb)
   FROM jsonb_array_elements(r.missing_lines) WITH ORDINALITY x(value,ord))
 ) END INTO shortage FROM public.procurement_shortage_requests r
 WHERE r.job_id=j.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1;

 RETURN result||jsonb_build_object('procurement_progress',jsonb_build_object(
  'version',1,'state',j.state,'updated_at',j.updated_at,
  'requested_line_count',jsonb_array_length(j.requested_lines),'lines',lines,
  'customer_action_required',j.state='awaiting_customer','shortage',shortage,
  'inventory_reserved',false,'supplier_detail_included',false,
  'staff_identity_included',false,'actual_cost_included',false
 ));
END$$;

REVOKE ALL ON FUNCTION public.jana_order_detail_pre_procurement_progress(text,text)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_order_detail(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_order_detail(text,text) TO service_role;
