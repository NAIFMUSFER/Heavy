-- External delivery is opt-in. No existing notification is queued or sent.
CREATE TABLE public.notification_channels(
 channel text PRIMARY KEY CHECK(channel IN ('email','sms','whatsapp','push')),
 enabled boolean NOT NULL DEFAULT false,provider text NOT NULL,
 retry_window_ms bigint NOT NULL CHECK(retry_window_ms BETWEEN 60000 AND 82800000),
 max_attempts integer NOT NULL DEFAULT 8 CHECK(max_attempts BETWEEN 1 AND 8)
);
INSERT INTO public.notification_channels(channel,provider,retry_window_ms) VALUES('email','resend',82800000),('sms','unconfigured',60000),('whatsapp','unconfigured',60000),('push','unconfigured',60000);
CREATE TABLE public.notification_destinations(
 user_id varchar(36) NOT NULL REFERENCES public.users(id),channel text NOT NULL REFERENCES public.notification_channels(channel),
 recipient text NOT NULL CHECK(length(recipient) BETWEEN 3 AND 500),verified_at bigint NOT NULL CHECK(verified_at>0),
 verification_reference text NOT NULL CHECK(length(verification_reference) BETWEEN 3 AND 180),
 consent_at bigint NOT NULL CHECK(consent_at>0),active boolean NOT NULL DEFAULT false,PRIMARY KEY(user_id,channel)
);
CREATE TABLE public.notification_outbox(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),notification_id varchar(36) NOT NULL REFERENCES public.notifications(id),
 user_id varchar(36) NOT NULL REFERENCES public.users(id),channel text NOT NULL REFERENCES public.notification_channels(channel),provider text NOT NULL,
 recipient text NOT NULL,title text NOT NULL,body text NOT NULL,created_at bigint NOT NULL,retry_until bigint NOT NULL,
 state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','leased','retry','submitted','dead_letter','reconcile','cancelled')),
 attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count BETWEEN 0 AND 8),max_attempts integer NOT NULL CHECK(max_attempts BETWEEN 1 AND 8),
 next_attempt_at bigint NOT NULL,lease_id uuid,lease_until bigint,provider_id text,error_code text,
 UNIQUE(notification_id,channel),CHECK(retry_until>created_at),
 CHECK((state='leased' AND lease_id IS NOT NULL AND lease_until IS NOT NULL) OR (state<>'leased' AND lease_id IS NULL AND lease_until IS NULL))
);
CREATE INDEX jana_outbox_due ON public.notification_outbox(channel,next_attempt_at,created_at,id) WHERE state IN ('queued','retry','leased');
CREATE INDEX jana_outbox_user ON public.notification_outbox(user_id);
CREATE INDEX jana_outbox_history ON public.notification_outbox(created_at DESC,id DESC);
CREATE TABLE public.notification_attempts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_id uuid NOT NULL REFERENCES public.notification_outbox(id),lease_id uuid NOT NULL,
 event text NOT NULL CHECK(event IN ('claimed','finished','lease_expired')),attempt_number integer NOT NULL,
 outcome text,error_code text,provider_id text,request_hash text,result jsonb,created_at bigint NOT NULL,
 UNIQUE(job_id,lease_id,event)
);
CREATE TRIGGER jana_notification_attempts_immutable BEFORE UPDATE OR DELETE ON public.notification_attempts FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();
CREATE FUNCTION public.jana_outbox_payload_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF ROW(NEW.notification_id,NEW.user_id,NEW.channel,NEW.provider,NEW.recipient,NEW.title,NEW.body,NEW.created_at,NEW.retry_until,NEW.max_attempts)
 IS DISTINCT FROM ROW(OLD.notification_id,OLD.user_id,OLD.channel,OLD.provider,OLD.recipient,OLD.title,OLD.body,OLD.created_at,OLD.retry_until,OLD.max_attempts) THEN RAISE EXCEPTION 'notification_payload_immutable';END IF;RETURN NEW;
END$$;
CREATE TRIGGER jana_outbox_payload_immutable BEFORE UPDATE ON public.notification_outbox FOR EACH ROW EXECUTE FUNCTION public.jana_outbox_payload_immutable();
CREATE FUNCTION public.jana_enqueue_notification_channels() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 INSERT INTO public.notification_outbox(notification_id,user_id,channel,provider,recipient,title,body,created_at,retry_until,max_attempts,next_attempt_at)
 SELECT NEW.id,NEW.user_id,c.channel,c.provider,d.recipient,NEW.title,NEW.body,NEW.created_at,NEW.created_at+c.retry_window_ms,c.max_attempts,NEW.created_at
 FROM public.notification_channels c JOIN public.notification_destinations d ON d.channel=c.channel AND d.user_id=NEW.user_id
 JOIN public.users u ON u.id=d.user_id WHERE c.enabled AND c.provider<>'unconfigured' AND d.active AND u.active
 ON CONFLICT(notification_id,channel) DO NOTHING;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_enqueue_notification_channels AFTER INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.jana_enqueue_notification_channels();

CREATE FUNCTION public.jana_notification_claim(p_channel text,p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.notification_channels;j public.notification_outbox;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;lid uuid;
BEGIN
 SELECT * INTO c FROM public.notification_channels WHERE channel=p_channel FOR SHARE;
 IF c.channel IS NULL OR NOT c.enabled OR c.provider<>p_provider THEN RETURN NULL;END IF;
 FOR j IN SELECT * FROM public.notification_outbox WHERE channel=p_channel AND provider=p_provider
 AND ((state IN ('queued','retry') AND next_attempt_at<=nowms) OR (state='leased' AND lease_until<=nowms))
 ORDER BY next_attempt_at,created_at,id LIMIT 20 FOR UPDATE SKIP LOCKED LOOP
  IF j.state='leased' THEN
   INSERT INTO public.notification_attempts(job_id,lease_id,event,attempt_number,outcome,error_code,created_at)
   VALUES(j.id,j.lease_id,'lease_expired',j.attempt_count,'unknown','LEASE_EXPIRED',nowms);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.notification_destinations d JOIN public.users u ON u.id=d.user_id WHERE d.user_id=j.user_id AND d.channel=j.channel AND d.recipient=j.recipient AND d.active AND u.active) THEN
   UPDATE public.notification_outbox SET state=CASE WHEN j.attempt_count>0 THEN 'reconcile' ELSE 'cancelled' END,error_code='DESTINATION_INACTIVE',lease_id=NULL,lease_until=NULL WHERE id=j.id;CONTINUE;
  END IF;
  IF j.retry_until<=nowms OR j.attempt_count>=j.max_attempts THEN
   UPDATE public.notification_outbox SET state=CASE WHEN j.attempt_count>0 THEN 'reconcile' ELSE 'dead_letter' END,error_code=CASE WHEN j.retry_until<=nowms THEN 'RETRY_WINDOW_EXPIRED' ELSE 'ATTEMPTS_EXHAUSTED' END,lease_id=NULL,lease_until=NULL WHERE id=j.id;CONTINUE;
  END IF;
  lid=gen_random_uuid();
  UPDATE public.notification_outbox SET state='leased',attempt_count=attempt_count+1,lease_id=lid,lease_until=nowms+120000,error_code=NULL WHERE id=j.id RETURNING * INTO j;
  INSERT INTO public.notification_attempts(job_id,lease_id,event,attempt_number,created_at) VALUES(j.id,lid,'claimed',j.attempt_count,nowms);
  RETURN jsonb_build_object('id',j.id,'lease_id',lid,'channel',j.channel,'provider',j.provider,'recipient',j.recipient,'title',j.title,'body',j.body,'created_at',j.created_at,'retry_until',j.retry_until,'attempt',j.attempt_count,'idempotency_key','jana-notification-'||j.id);
 END LOOP;
 RETURN NULL;
END$$;

CREATE FUNCTION public.jana_notification_finish(p_job_id uuid,p_lease_id uuid,p_result jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE j public.notification_outbox;previous public.notification_attempts;h text;st text;outcome text;err text;pid text;result jsonb;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 IF jsonb_typeof(p_result) IS DISTINCT FROM 'object' OR jsonb_typeof(p_result->'outcome') IS DISTINCT FROM 'string' OR p_result->>'outcome' NOT IN ('submitted','not_submitted','unknown') OR NOT p_result ? 'outcome'
 OR jsonb_typeof(p_result->'retryable') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'notification_result_invalid';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_result) k WHERE k NOT IN ('outcome','retryable','provider_id','error_code')) THEN RAISE EXCEPTION 'notification_result_invalid';END IF;
 outcome=p_result->>'outcome';pid=p_result->>'provider_id';err=p_result->>'error_code';
 IF (outcome='submitted' AND (err IS NOT NULL OR (p_result->>'retryable')::boolean OR jsonb_typeof(p_result->'provider_id') IS DISTINCT FROM 'string' OR pid IS NULL OR length(pid) NOT BETWEEN 1 AND 180 OR pid!~'^[A-Za-z0-9:_-]+$'))
 OR (outcome<>'submitted' AND (pid IS NOT NULL OR err IS NULL OR err!~'^[A-Z][A-Z0-9_]{2,79}$')) THEN RAISE EXCEPTION 'notification_result_invalid';END IF;
 h=encode(digest(p_result::text,'sha256'),'hex');
 SELECT * INTO j FROM public.notification_outbox WHERE id=p_job_id FOR UPDATE;IF j.id IS NULL THEN RAISE EXCEPTION 'notification_job_not_found';END IF;
 SELECT * INTO previous FROM public.notification_attempts WHERE job_id=j.id AND lease_id=p_lease_id AND event='finished';
 IF previous.id IS NOT NULL THEN IF previous.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN previous.result;END IF;
 IF j.state<>'leased' OR j.lease_id IS DISTINCT FROM p_lease_id OR j.lease_until<=nowms THEN RAISE EXCEPTION 'notification_lease_stale';END IF;
 st=CASE WHEN outcome='submitted' THEN 'submitted'
 WHEN (p_result->>'retryable')::boolean AND j.attempt_count<j.max_attempts AND nowms+least(3600000,30000*power(2,j.attempt_count-1)::bigint)<j.retry_until THEN 'retry'
 WHEN outcome='unknown' OR err='DELIVERY_RECONCILIATION_REQUIRED' OR EXISTS(SELECT 1 FROM public.notification_attempts a WHERE a.job_id=j.id AND a.outcome='unknown') THEN 'reconcile' ELSE 'dead_letter' END;
 UPDATE public.notification_outbox SET state=st,lease_id=NULL,lease_until=NULL,provider_id=pid,error_code=err,
 next_attempt_at=nowms+least(3600000,30000*power(2,j.attempt_count-1)::bigint) WHERE id=j.id;
 result=jsonb_build_object('id',j.id,'state',st,'attempt',j.attempt_count);
 INSERT INTO public.notification_attempts(job_id,lease_id,event,attempt_number,outcome,error_code,provider_id,request_hash,result,created_at)
 VALUES(j.id,p_lease_id,'finished',j.attempt_count,outcome,err,pid,h,result,nowms);
 RETURN result;
END$$;

-- Binding for internal event producers; browser/customer roles cannot execute it.
CREATE FUNCTION public.jana_notification_insert_once(p_event_id text,p_user_id text,p_title text,p_body text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE key text;n public.notifications;
BEGIN
 IF p_event_id IS NULL OR length(p_event_id) NOT BETWEEN 1 AND 160 OR p_title IS NULL OR length(p_title) NOT BETWEEN 1 AND 140 OR p_body IS NULL OR length(p_body) NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'notification_invalid';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.users WHERE id=p_user_id AND active) THEN RAISE EXCEPTION 'notification_recipient_invalid';END IF;
 key='adapter:'||encode(digest(jsonb_build_array(p_event_id,p_user_id)::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(key,0));
 SELECT * INTO n FROM public.notifications WHERE dedupe_key=key;
 IF n.id IS NOT NULL THEN IF n.title<>p_title OR n.body<>p_body OR n.user_id<>p_user_id THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN jsonb_build_object('id',n.id);END IF;
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,is_read,created_at) VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),p_user_id,key,p_title,p_body,false,(extract(epoch from clock_timestamp())*1000)::bigint) RETURNING * INTO n;
 RETURN jsonb_build_object('id',n.id);
END$$;
CREATE FUNCTION public.jana_notification_overview(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT jsonb_build_object('channels',(SELECT coalesce(jsonb_agg(jsonb_build_object('channel',channel,'enabled',enabled,'provider',provider)),'[]'::jsonb) FROM public.notification_channels),
 'counts',(SELECT coalesce(jsonb_object_agg(state,n),'{}'::jsonb) FROM(SELECT state,count(*) n FROM public.notification_outbox GROUP BY state)s),
 'items',(SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY created_at DESC,id DESC),'[]'::jsonb) FROM(SELECT id,notification_id,channel,provider,state,attempt_count,error_code,created_at,next_attempt_at FROM public.notification_outbox ORDER BY created_at DESC,id DESC LIMIT 50)s)) INTO r;
 RETURN r;
END$$;
DO $grants$ DECLARE n text; BEGIN
 FOREACH n IN ARRAY ARRAY['notification_channels','notification_destinations','notification_outbox','notification_attempts'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',n);EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',n);
 END LOOP;
END$grants$;
REVOKE ALL ON FUNCTION public.jana_outbox_payload_immutable(),public.jana_enqueue_notification_channels(),public.jana_notification_claim(text,text),public.jana_notification_finish(uuid,uuid,jsonb),public.jana_notification_insert_once(text,text,text,text),public.jana_notification_overview(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_outbox_payload_immutable(),public.jana_enqueue_notification_channels() FROM service_role;
GRANT EXECUTE ON FUNCTION public.jana_notification_claim(text,text),public.jana_notification_finish(uuid,uuid,jsonb),public.jana_notification_insert_once(text,text,text,text),public.jana_notification_overview(text) TO service_role;
