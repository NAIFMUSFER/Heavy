-- Phase 13: let the owning customer explicitly approve or reject the current
-- shortage request. The existing decision primitive remains private; this
-- wrapper binds the request to the order in the URL and exposes the current
-- procurement revision through the already customer-owned order detail.
ALTER FUNCTION public.jana_order_detail(text,text)
 RENAME TO jana_order_detail_pre_customer_shortage_decision;

CREATE FUNCTION public.jana_order_detail(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE result jsonb;job_revision bigint;
BEGIN
 result=public.jana_order_detail_pre_customer_shortage_decision(p_token,p_order_id);
 IF result->'procurement_progress' IS NULL OR result->'procurement_progress'='null'::jsonb THEN
  RETURN result;
 END IF;
 SELECT revision INTO job_revision FROM public.procurement_jobs WHERE order_id=p_order_id;
 IF job_revision IS NULL THEN RAISE EXCEPTION 'procurement_changed';END IF;
 RETURN jsonb_set(result,'{procurement_progress,revision}',to_jsonb(job_revision),true);
END$$;

CREATE FUNCTION public.jana_customer_procurement_shortage_decide(
 p_token text,p_idem_key text,p_order_id text,p_request_id text,
 p_expected_revision bigint,p_decision text,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF coalesce(p_order_id,'')='' OR coalesce(p_request_id,'')='' THEN
  RAISE EXCEPTION 'procurement_shortage_decision_validation';
 END IF;
 result=public.jana_procurement_shortage_decide(
  p_token,p_idem_key,p_request_id,p_expected_revision,p_decision,p_note
 );
 -- This check intentionally happens after the inner call: any mismatch raises
 -- and rolls the entire transaction back, including the decision and audit rows.
 IF result->>'order_id' IS DISTINCT FROM p_order_id THEN
  RAISE EXCEPTION 'procurement_shortage_not_found';
 END IF;
 RETURN result;
END$$;

REVOKE ALL ON FUNCTION public.jana_order_detail_pre_customer_shortage_decision(text,text)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_order_detail(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_order_detail(text,text) TO service_role;

REVOKE ALL ON FUNCTION public.jana_customer_procurement_shortage_decide(text,text,text,text,bigint,text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_customer_procurement_shortage_decide(text,text,text,text,bigint,text,text)
 TO service_role;
-- Keep the broader primitive inaccessible through PostgREST.
REVOKE ALL ON FUNCTION public.jana_procurement_shortage_decide(text,text,text,bigint,text,text)
 FROM PUBLIC,anon,authenticated,service_role;
