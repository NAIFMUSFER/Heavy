-- Phase 17: expose the two-party purchasing-to-courier custody handover.
-- The purchasing employee freezes the exact collected lines and selects an
-- active courier. Only that courier can read and accept the frozen custody.
-- Courier reads intentionally omit supplier identity, receipts, actual cost,
-- customer totals and settlement data. Neither write creates inventory or
-- changes customer price, supplier settlement or cash collection.

ALTER FUNCTION public.jana_procurement_jobs_page(text,integer,bigint,text,text)
 RENAME TO jana_procurement_jobs_page_staff_base;
ALTER FUNCTION public.jana_procurement_job_detail(text,text)
 RENAME TO jana_procurement_job_detail_staff_base;

CREATE FUNCTION public.jana_procurement_jobs_page(
 p_token text,p_limit integer DEFAULT 50,p_before_at bigint DEFAULT NULL,
 p_before_id text DEFAULT NULL,p_state text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;items jsonb;next_cursor jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'courier' THEN
  RETURN public.jana_procurement_jobs_page_staff_base(
   p_token,p_limit,p_before_at,p_before_id,p_state
  );
 END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
  OR ((p_before_at IS NULL)<>(p_before_id IS NULL))
  OR (p_before_at IS NOT NULL AND (p_before_at<0 OR p_before_id!~'^prc-[0-9a-f]{32}$'))
  OR (p_state IS NOT NULL AND p_state NOT IN ('handover_pending','handed_over'))
 THEN RAISE EXCEPTION 'procurement_query_invalid';END IF;
 WITH page AS MATERIALIZED(
  SELECT j.id,j.order_id,o.number order_number,j.state,j.revision,j.assigned_to,
   buyer.name assigned_name,j.created_at,j.updated_at,
   jsonb_array_length(h.collected_lines_snapshot) requested_line_count,
   h.id handover_request_id,h.created_at handover_created_at,
   a.created_at handover_accepted_at
  FROM public.procurement_handover_requests h
  JOIN public.procurement_jobs j ON j.id=h.job_id
  JOIN public.orders o ON o.id=h.order_id
  LEFT JOIN public.users buyer ON buyer.id=h.purchasing_employee_id
  LEFT JOIN public.procurement_handover_acceptances a ON a.request_id=h.id
  WHERE h.courier_id=u.id AND j.state IN ('handover_pending','handed_over')
   AND (p_state IS NULL OR j.state=p_state)
   AND (p_before_at IS NULL OR (j.created_at,j.id)<(p_before_at,p_before_id))
  ORDER BY j.created_at DESC,j.id DESC LIMIT p_limit+1
 ),numbered AS(
  SELECT *,row_number() OVER(ORDER BY created_at DESC,id DESC) rn FROM page
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',id,'order_id',order_id,'order_number',order_number,'state',state,'revision',revision,
   'assigned_to',assigned_to,'assigned_name',assigned_name,'created_at',created_at,'updated_at',updated_at,
   'requested_line_count',requested_line_count,'handover_request_id',handover_request_id,
   'handover_created_at',handover_created_at,'handover_accepted_at',handover_accepted_at,
   'courier_custody_only',true,'financial_detail_included',false,'customer_contact_included',false
  ) ORDER BY created_at DESC,id DESC) FILTER(WHERE rn<=p_limit),'[]'::jsonb),
  CASE WHEN count(*)>p_limit THEN (jsonb_agg(jsonb_build_object(
   'before_at',created_at,'before_id',id
  ) ORDER BY created_at DESC,id DESC) FILTER(WHERE rn<=p_limit))->(p_limit-1) ELSE NULL END
 INTO items,next_cursor FROM numbered;
 RETURN jsonb_build_object('items',items,'next',next_cursor,'limit',p_limit,'state_filter',p_state,
  'courier_custody_only',true,'financial_detail_included',false,'customer_contact_included',false);
END$$;

CREATE FUNCTION public.jana_procurement_job_detail(p_token text,p_job_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;o public.orders;h public.procurement_handover_requests;
 buyer_name text;accepted_at bigint;custody_lines jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'courier' THEN
  RETURN public.jana_procurement_job_detail_staff_base(p_token,p_job_id);
 END IF;
 IF p_job_id IS NULL OR p_job_id!~'^prc-[0-9a-f]{32}$'
 THEN RAISE EXCEPTION 'procurement_query_invalid';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id;
 SELECT * INTO h FROM public.procurement_handover_requests
  WHERE job_id=p_job_id AND courier_id=u.id;
 IF j.id IS NULL OR h.id IS NULL OR j.state NOT IN ('handover_pending','handed_over')
 THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=h.order_id;
 SELECT name INTO buyer_name FROM public.users WHERE id=h.purchasing_employee_id;
 SELECT created_at INTO accepted_at FROM public.procurement_handover_acceptances
  WHERE request_id=h.id;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'line_id',line->>'line_id','offering_id',line->>'offering_id','name',line->>'name',
  'size_label',line->>'size_label','sale_unit',line->>'sale_unit',
  'qty',(line->>'qty')::numeric,'collected_qty',(line->>'collected_qty')::numeric
 ) ORDER BY ord),'[]'::jsonb) INTO custody_lines
 FROM jsonb_array_elements(h.collected_lines_snapshot) WITH ORDINALITY x(line,ord);
 RETURN jsonb_build_object(
  'job',jsonb_build_object('id',j.id,'order_id',j.order_id,'order_number',o.number,
   'state',j.state,'revision',j.revision,'assigned_to',j.assigned_to,
   'assigned_name',buyer_name,'created_at',j.created_at,'updated_at',j.updated_at),
  'customer_terms',NULL,'lines',custody_lines,
  'purchases','[]'::jsonb,'funding','[]'::jsonb,'settlements','[]'::jsonb,'shortage',NULL,
  'handover',jsonb_build_object('request_id',h.id,'purchasing_employee_name',buyer_name,
   'created_at',h.created_at,'accepted_at',accepted_at,'collected_lines',custody_lines),
  'courier_custody_only',true,'financial_detail_included',false,'customer_contact_included',false
 );
END$$;

CREATE FUNCTION public.jana_procurement_active_couriers(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.name)
  ORDER BY c.name,c.id) FROM public.users c WHERE c.role='courier' AND c.active),'[]'::jsonb);
END$$;

CREATE FUNCTION public.jana_ops_procurement_handover_prepare(
 p_token text,p_idem_key text,p_job_id text,p_courier_id text,
 p_expected_revision bigint,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF coalesce(p_job_id,'')!~'^prc-[0-9a-f]{32}$'
  OR length(trim(coalesce(p_courier_id,''))) NOT BETWEEN 1 AND 36
  OR p_expected_revision IS NULL OR p_expected_revision<1
  OR length(trim(coalesce(p_note,''))) NOT BETWEEN 3 AND 1000
 THEN RAISE EXCEPTION 'procurement_handover_validation';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id FOR SHARE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 result=public.jana_procurement_handover_prepare(
  p_token,p_idem_key,j.order_id,trim(p_courier_id),p_expected_revision,p_note
 );
 IF result->>'job_id' IS DISTINCT FROM j.id
  OR result->>'order_id' IS DISTINCT FROM j.order_id
  OR result->>'courier_id' IS DISTINCT FROM trim(p_courier_id)
  OR result->>'purchasing_employee_id' IS DISTINCT FROM u.id
  OR result->>'state' IS DISTINCT FROM 'handover_pending'
 THEN RAISE EXCEPTION 'procurement_handover_not_found';END IF;
 RETURN result;
END$$;

CREATE FUNCTION public.jana_ops_procurement_handover_accept(
 p_token text,p_idem_key text,p_job_id text,p_request_id text,
 p_expected_revision bigint,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;h public.procurement_handover_requests;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'courier' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF coalesce(p_job_id,'')!~'^prc-[0-9a-f]{32}$'
  OR coalesce(p_request_id,'')!~'^phr-[0-9a-f]{32}$'
  OR p_expected_revision IS NULL OR p_expected_revision<1
  OR length(trim(coalesce(p_note,''))) NOT BETWEEN 3 AND 1000
 THEN RAISE EXCEPTION 'procurement_handover_validation';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id FOR SHARE;
 SELECT * INTO h FROM public.procurement_handover_requests
  WHERE id=p_request_id FOR SHARE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 IF h.id IS NULL OR h.job_id<>j.id OR h.order_id<>j.order_id OR h.courier_id<>u.id
 THEN RAISE EXCEPTION 'procurement_handover_not_found';END IF;
 result=public.jana_procurement_handover_accept(
  p_token,p_idem_key,h.id,p_expected_revision,p_note
 );
 IF result->>'request_id' IS DISTINCT FROM h.id
  OR result->>'job_id' IS DISTINCT FROM j.id
  OR result->>'order_id' IS DISTINCT FROM j.order_id
  OR result->>'courier_id' IS DISTINCT FROM u.id
  OR result->>'state' IS DISTINCT FROM 'handed_over'
 THEN RAISE EXCEPTION 'procurement_handover_not_found';END IF;
 RETURN result;
END$$;

-- A selected courier cannot be disabled or moved to another role while the
-- physical handover is awaiting acceptance. Row locking also closes the race
-- between staff deactivation and handover preparation.
ALTER FUNCTION public.jana_update_staff(text,text,jsonb,text)
 RENAME TO jana_update_staff_procurement_base;
CREATE FUNCTION public.jana_update_staff(
 p_token text,p_user_id text,p_payload jsonb,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;target public.users;changes_membership boolean:=false;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('jana-staff-membership',0));
 SELECT * INTO target FROM public.users WHERE id=p_user_id FOR UPDATE;
 IF target.id IS NOT NULL AND target.role='courier' AND jsonb_typeof(p_payload)='object' THEN
  changes_membership=(p_payload?'active' AND jsonb_typeof(p_payload->'active')='boolean'
   AND NOT (p_payload->>'active')::boolean)
   OR (p_payload?'role' AND p_payload->>'role'<>'courier');
  IF changes_membership AND EXISTS(
   SELECT 1 FROM public.procurement_handover_requests h
   JOIN public.procurement_jobs j ON j.id=h.job_id
   LEFT JOIN public.procurement_handover_acceptances a ON a.request_id=h.id
   WHERE h.courier_id=target.id AND j.state='handover_pending' AND a.id IS NULL
  ) THEN RAISE EXCEPTION 'staff_has_active_orders';END IF;
 END IF;
 RETURN public.jana_update_staff_procurement_base(p_token,p_user_id,p_payload,p_reason);
END$$;

REVOKE ALL ON FUNCTION
 public.jana_procurement_jobs_page_staff_base(text,integer,bigint,text,text),
 public.jana_procurement_job_detail_staff_base(text,text),
 public.jana_procurement_handover_prepare(text,text,text,text,bigint,text),
 public.jana_procurement_handover_accept(text,text,text,bigint,text),
 public.jana_update_staff_procurement_base(text,text,jsonb,text)
FROM PUBLIC,anon,authenticated,service_role;

REVOKE ALL ON FUNCTION
 public.jana_procurement_jobs_page(text,integer,bigint,text,text),
 public.jana_procurement_job_detail(text,text),
 public.jana_procurement_active_couriers(text),
 public.jana_ops_procurement_handover_prepare(text,text,text,text,bigint,text),
 public.jana_ops_procurement_handover_accept(text,text,text,text,bigint,text),
 public.jana_update_staff(text,text,jsonb,text)
FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION
 public.jana_procurement_jobs_page(text,integer,bigint,text,text),
 public.jana_procurement_job_detail(text,text),
 public.jana_procurement_active_couriers(text),
 public.jana_ops_procurement_handover_prepare(text,text,text,text,bigint,text),
 public.jana_ops_procurement_handover_accept(text,text,text,text,bigint,text),
 public.jana_update_staff(text,text,jsonb,text)
TO service_role;
