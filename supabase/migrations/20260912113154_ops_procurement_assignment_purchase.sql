-- Phase 15: expose only path-bound assignment and immutable purchase evidence
-- through jana-api. The broader order-based primitives remain private so the
-- Edge route cannot be confused into mutating a different procurement job.
CREATE FUNCTION public.jana_ops_procurement_assign(
 p_token text,p_idem_key text,p_job_id text,p_employee_id text,
 p_expected_revision bigint,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF coalesce(p_job_id,'')!~'^prc-[0-9a-f]{32}$'
  OR length(trim(coalesce(p_employee_id,''))) NOT BETWEEN 1 AND 36
  OR p_expected_revision IS NULL OR p_expected_revision<1
  OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000
 THEN RAISE EXCEPTION 'procurement_assignment_validation';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id FOR SHARE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 result=public.jana_procurement_job_assign(
  p_token,p_idem_key,j.order_id,p_employee_id,p_expected_revision,p_reason
 );
 -- Validate the inner result after its write. A mismatch raises in the same
 -- transaction and therefore rolls the assignment, event and audit back.
 IF result->>'id' IS DISTINCT FROM p_job_id
  OR result->>'order_id' IS DISTINCT FROM j.order_id
  OR result->>'assigned_to' IS DISTINCT FROM p_employee_id
 THEN RAISE EXCEPTION 'procurement_assignment_not_found';END IF;
 RETURN result;
END$$;

CREATE FUNCTION public.jana_ops_procurement_purchase_record(
 p_token text,p_idem_key text,p_job_id text,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;result jsonb;bound_payload jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF coalesce(p_job_id,'')!~'^prc-[0-9a-f]{32}$'
  OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
  OR p_payload?'job_id' OR p_payload?'order_id'
  OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) t(key) WHERE key NOT IN
   ('expected_revision','supplier_id','pickup_site_id','document_reference','note','lines'))
 THEN RAISE EXCEPTION 'procurement_purchase_validation';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id FOR SHARE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 bound_payload=p_payload||jsonb_build_object('order_id',j.order_id);
 result=public.jana_procurement_purchase_record(p_token,p_idem_key,bound_payload);
 -- The route owns the job identity; a successful inner write for any other
 -- resource is rejected and all of its rows are rolled back atomically.
 IF result->>'job_id' IS DISTINCT FROM p_job_id
  OR result->>'order_id' IS DISTINCT FROM j.order_id
  OR result->>'supplier_id' IS DISTINCT FROM p_payload->>'supplier_id'
  OR result->>'pickup_site_id' IS DISTINCT FROM p_payload->>'pickup_site_id'
 THEN RAISE EXCEPTION 'procurement_purchase_not_found';END IF;
 RETURN result;
END$$;

REVOKE ALL ON FUNCTION public.jana_ops_procurement_assign(text,text,text,text,bigint,text),
 public.jana_ops_procurement_purchase_record(text,text,text,jsonb)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ops_procurement_assign(text,text,text,text,bigint,text),
 public.jana_ops_procurement_purchase_record(text,text,text,jsonb)
 TO service_role;

-- Keep the broad primitives outside PostgREST even though their narrow wrappers
-- are now live.
REVOKE ALL ON FUNCTION public.jana_procurement_job_assign(text,text,text,text,bigint,text),
 public.jana_procurement_purchase_record(text,text,jsonb)
 FROM PUBLIC,anon,authenticated,service_role;
