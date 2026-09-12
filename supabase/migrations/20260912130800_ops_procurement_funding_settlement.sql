-- Phase 16: expose path-bound purchase funding and settlement evidence to
-- admin/finance through jana-api. No payment source or timing is defaulted;
-- every write remains an explicit, auditable choice against actual cost.
CREATE FUNCTION public.jana_ops_procurement_funding_record(
 p_token text,p_idem_key text,p_job_id text,p_purchase_record_id text,
 p_funding_source text,p_evidence_reference text,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;r public.procurement_purchase_records;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF coalesce(p_job_id,'')!~'^prc-[0-9a-f]{32}$'
  OR coalesce(p_purchase_record_id,'')!~'^pur-[0-9a-f]{32}$'
 THEN RAISE EXCEPTION 'procurement_funding_validation';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id FOR SHARE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 SELECT * INTO r FROM public.procurement_purchase_records WHERE id=p_purchase_record_id FOR SHARE;
 IF r.id IS NULL OR r.job_id<>j.id THEN RAISE EXCEPTION 'procurement_funding_not_found';END IF;
 result=public.jana_procurement_funding_record(
  p_token,p_idem_key,r.id,p_funding_source,p_evidence_reference,p_note
 );
 IF result->>'purchase_record_id' IS DISTINCT FROM r.id
  OR result->>'job_id' IS DISTINCT FROM j.id
  OR result->>'order_id' IS DISTINCT FROM j.order_id
  OR result->>'funding_source' IS DISTINCT FROM trim(coalesce(p_funding_source,''))
 THEN RAISE EXCEPTION 'procurement_funding_not_found';END IF;
 RETURN result;
END$$;

CREATE FUNCTION public.jana_ops_procurement_settlement_record(
 p_token text,p_idem_key text,p_job_id text,p_funding_id text,
 p_amount_halalas bigint,p_payment_reference text,p_note text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;j public.procurement_jobs;f public.procurement_purchase_funding;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF coalesce(p_job_id,'')!~'^prc-[0-9a-f]{32}$'
  OR coalesce(p_funding_id,'')!~'^pfd-[0-9a-f]{32}$'
 THEN RAISE EXCEPTION 'procurement_settlement_validation';END IF;
 SELECT * INTO j FROM public.procurement_jobs WHERE id=p_job_id FOR SHARE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 SELECT * INTO f FROM public.procurement_purchase_funding WHERE id=p_funding_id FOR SHARE;
 IF f.id IS NULL OR f.job_id<>j.id THEN RAISE EXCEPTION 'procurement_funding_not_found';END IF;
 result=public.jana_procurement_settlement_record(
  p_token,p_idem_key,f.id,p_amount_halalas,p_payment_reference,p_note
 );
 IF result->>'funding_id' IS DISTINCT FROM f.id
  OR result->>'job_id' IS DISTINCT FROM j.id
  OR result->>'order_id' IS DISTINCT FROM j.order_id
 THEN RAISE EXCEPTION 'procurement_settlement_not_found';END IF;
 RETURN result;
END$$;

REVOKE ALL ON FUNCTION public.jana_ops_procurement_funding_record(text,text,text,text,text,text,text),
 public.jana_ops_procurement_settlement_record(text,text,text,text,bigint,text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ops_procurement_funding_record(text,text,text,text,text,text,text),
 public.jana_ops_procurement_settlement_record(text,text,text,text,bigint,text,text)
 TO service_role;

-- The broad primitives stay private; only the path-bound wrappers are exposed.
REVOKE ALL ON FUNCTION public.jana_procurement_funding_record(text,text,text,text,text,text),
 public.jana_procurement_settlement_record(text,text,text,bigint,text,text)
 FROM PUBLIC,anon,authenticated,service_role;
