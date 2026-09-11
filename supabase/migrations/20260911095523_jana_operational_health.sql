-- Read-only operational observations. Never release stock, run a job or send a message.
CREATE INDEX IF NOT EXISTS ix_jana_active_quote_expiry ON public.quotes(expires_at) WHERE state='active';
CREATE INDEX IF NOT EXISTS ix_jana_pending_substitution_expiry ON public.substitutions(expires_at) WHERE state='pending';
-- Active reminders already use jana_recurring_due_idx(next_at,id).

CREATE FUNCTION public.jana_operational_health()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
 heartbeat_limit bigint:=180000; queue_grace bigint:=120000; row_limit integer:=1000;
 launch_setting text:=current_setting('cron.launch_active_jobs',true);
 enabled boolean; expected record; q record; jobs jsonb:='[]'; queues jsonb:='[]';
 job_count integer; configured boolean; active boolean; last_success bigint; status text; alerts integer:=0;
BEGIN
 enabled=CASE WHEN launch_setting IN ('on','true','1') THEN true WHEN launch_setting IN ('off','false','0') THEN false ELSE NULL END;
 FOR expected IN SELECT * FROM (VALUES
  ('quote_expiry','jana-quote-expiry','selectpublic.jana_expiry_worker();'),
  ('recurring_reminders','jana-recurring-reminders','selectpublic.jana_recurring_reminders();')
 ) x(code,job_name,command_text) LOOP
  SELECT count(*),bool_and(j.active),bool_and(j.schedule='* * * * *' AND j.database=current_database()
    AND regexp_replace(lower(j.command),'\s','','g')=expected.command_text)
   INTO job_count,active,configured FROM cron.job j WHERE j.jobname=expected.job_name;
  SELECT w.last_success_at INTO last_success FROM public.worker_runs w WHERE w.name=expected.code;
  status=CASE WHEN enabled IS NULL THEN 'unknown'
   WHEN NOT enabled THEN 'scheduler_disabled'
   WHEN job_count=0 THEN 'missing_job'
   WHEN job_count<>1 OR configured IS DISTINCT FROM true THEN 'misconfigured'
   WHEN active IS DISTINCT FROM true THEN 'disabled'
   WHEN last_success IS NULL THEN 'missing_heartbeat'
   WHEN last_success<=0 OR last_success>nowms+30000 THEN 'invalid_heartbeat'
   WHEN nowms-last_success>heartbeat_limit THEN 'stale'
   ELSE 'ok' END;
  IF status<>'ok' THEN alerts=alerts+1; END IF;
  jobs=jobs||jsonb_build_array(jsonb_build_object('code',expected.code,'status',status,
   'last_success_at',last_success,'age_ms',CASE WHEN last_success>0 AND last_success<=nowms+30000 THEN greatest(0,nowms-last_success) END,
   'stale_after_ms',heartbeat_limit));
 END LOOP;

 -- Partial indexes and a strict cap avoid scanning an unlimited backlog. Only counts/times leave the function.
 FOR q IN
  SELECT 'expired_quotes'::text code,count(*) n,min(expires_at) oldest FROM
   (SELECT expires_at FROM public.quotes WHERE state='active' AND expires_at<=nowms-queue_grace ORDER BY expires_at LIMIT row_limit+1) x
  UNION ALL
  SELECT 'expired_substitutions',count(*),min(expires_at) FROM
   (SELECT expires_at FROM public.substitutions WHERE state='pending' AND expires_at<=nowms-queue_grace ORDER BY expires_at LIMIT row_limit+1) x
  UNION ALL
  SELECT 'overdue_reminders',count(*),min(next_at) FROM
   (SELECT r.next_at FROM public.recurring_plans r JOIN public.users u ON u.id=r.user_id AND u.active
    WHERE r.state='active' AND r.next_at<=nowms-queue_grace ORDER BY r.next_at LIMIT row_limit+1) x
 LOOP
  IF q.n>0 THEN alerts=alerts+1; END IF;
  queues=queues||jsonb_build_array(jsonb_build_object('code',q.code,'status',CASE WHEN q.n>0 THEN 'backlog' ELSE 'ok' END,
   'count',least(q.n,row_limit),'capped',q.n>row_limit,'oldest_due_at',q.oldest,
   'oldest_delay_ms',CASE WHEN q.oldest IS NOT NULL THEN nowms-q.oldest END,'grace_ms',queue_grace));
 END LOOP;
 RETURN jsonb_build_object('schema_version',1,'checked_at',nowms,'ok',alerts=0,'alert_count',alerts,
  'scheduler_enabled',enabled,'jobs',jobs,'queues',queues);
END$$;

CREATE OR REPLACE FUNCTION public.jana_admin_deep_health(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden'; END IF;
 RETURN public.jana_deep_health()||jsonb_build_object('operations',public.jana_operational_health());
END$$;

REVOKE ALL ON FUNCTION public.jana_operational_health() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_admin_deep_health(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_deep_health(text) TO service_role;
