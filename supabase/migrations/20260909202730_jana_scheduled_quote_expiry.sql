CREATE EXTENSION IF NOT EXISTS pg_cron;
REVOKE USAGE ON SCHEMA cron FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.jana_expiry_worker()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE expired integer; detail jsonb; nowms bigint;
BEGIN
 expired=public.jana_expire_quotes();
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 detail=jsonb_build_object('quotes_expired',expired,'ran_at',nowms);
 INSERT INTO public.worker_runs(name,last_success_at,detail) VALUES('quote_expiry',nowms,detail)
 ON CONFLICT(name) DO UPDATE SET last_success_at=EXCLUDED.last_success_at,detail=EXCLUDED.detail;
 RETURN detail;
END$$;
REVOKE ALL ON FUNCTION public.jana_expiry_worker() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_expiry_worker() TO service_role;
SELECT cron.schedule('jana-quote-expiry','* * * * *','SELECT public.jana_expiry_worker();');
