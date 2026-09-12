-- Phase 14: expose only the exact, customer-approved shortage reduction to
-- admin/finance through jana-api. The original adjustment primitive stays
-- private; this wrapper binds the shortage request to the staff-visible job.
CREATE FUNCTION public.jana_ops_procurement_shortage_apply_adjustment(
 p_token text,p_idem_key text,p_job_id text,p_request_id text,
 p_expected_revision bigint,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF coalesce(p_job_id,'')!~'^prc-[0-9a-f]{32}$'
  OR coalesce(p_request_id,'')!~'^shr-[0-9a-f]{32}$' THEN
  RAISE EXCEPTION 'procurement_adjustment_validation';
 END IF;
 result=public.jana_procurement_shortage_apply_adjustment(
  p_token,p_idem_key,p_request_id,p_expected_revision,p_reason
 );
 -- Check after the inner write so a mismatch rolls the entire transaction
 -- back, including the order change, event, notification and audit records.
 IF result->>'job_id' IS DISTINCT FROM p_job_id
  OR result->>'request_id' IS DISTINCT FROM p_request_id THEN
  RAISE EXCEPTION 'procurement_adjustment_not_found';
 END IF;
 RETURN result;
END$$;

REVOKE ALL ON FUNCTION public.jana_ops_procurement_shortage_apply_adjustment(text,text,text,text,bigint,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ops_procurement_shortage_apply_adjustment(text,text,text,text,bigint,text)
 TO service_role;
-- Preserve the narrow PostgREST boundary: the broader primitive cannot be
-- invoked directly even with the Edge service credential.
REVOKE ALL ON FUNCTION public.jana_procurement_shortage_apply_adjustment(text,text,text,bigint,text)
 FROM PUBLIC,anon,authenticated,service_role;
