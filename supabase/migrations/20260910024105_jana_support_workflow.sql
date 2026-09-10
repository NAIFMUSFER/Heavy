ALTER TABLE public.tickets ADD COLUMN category text NOT NULL DEFAULT 'other' CHECK(category IN ('order','product','delivery','refund','account','other'));
ALTER TABLE public.tickets DROP CONSTRAINT ticket_state;
ALTER TABLE public.tickets ADD CONSTRAINT ticket_state CHECK(state IN ('open','pending_customer','closed'));
CREATE FUNCTION public.jana_ticket_history_guard() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE prefix jsonb;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_ticket_history';END IF;
 IF (to_jsonb(NEW)-ARRAY['messages','state','priority','assigned_to','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['messages','state','priority','assigned_to','updated_at']) THEN RAISE EXCEPTION 'immutable_ticket_history';END IF;
 IF jsonb_typeof(NEW.messages::jsonb)<>'array' THEN RAISE EXCEPTION 'invalid_ticket';END IF;
 SELECT coalesce(jsonb_agg(x.item ORDER BY x.n),'[]') INTO prefix FROM jsonb_array_elements(NEW.messages::jsonb) WITH ORDINALITY x(item,n) WHERE n<=jsonb_array_length(OLD.messages::jsonb);
 IF prefix IS DISTINCT FROM OLD.messages::jsonb THEN RAISE EXCEPTION 'immutable_ticket_history';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER immutable_ticket_history BEFORE UPDATE OR DELETE ON public.tickets FOR EACH ROW EXECUTE FUNCTION public.jana_ticket_history_guard();
CREATE FUNCTION public.jana_ticket_messages(p_messages jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(x.item||jsonb_build_object('actor',coalesce(x.item->>'actor',x.item->>'by','customer'),'text',coalesce(x.item->>'text',x.item->>'message','')) ORDER BY x.n),'[]') FROM jsonb_array_elements(coalesce(p_messages,'[]')) WITH ORDINALITY x(item,n);
$$;
CREATE OR REPLACE FUNCTION public.jana_my_tickets(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',t.id,'order_id',t.order_id,'subject',t.subject,'category',t.category,'state',t.state,'messages',public.jana_ticket_messages(t.messages::jsonb),'priority',t.priority,'created_at',t.created_at,'updated_at',t.updated_at) ORDER BY t.updated_at DESC) FROM public.tickets t WHERE t.user_id=u.id),'[]');
END$$;
CREATE OR REPLACE FUNCTION public.jana_support_tickets(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',t.id,'user_id',t.user_id,'customer_name',cu.name,'order_id',t.order_id,'subject',t.subject,'category',t.category,'state',t.state,'priority',t.priority,'assigned_to',t.assigned_to,'messages',public.jana_ticket_messages(t.messages::jsonb),'created_at',t.created_at,'updated_at',t.updated_at) ORDER BY CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 ELSE 2 END,t.updated_at DESC) FROM public.tickets t JOIN public.users cu ON cu.id=t.user_id),'[]');
END$$;
CREATE FUNCTION public.jana_support_roster(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'role',role) ORDER BY name),'[]') FROM public.users WHERE active AND role IN ('admin','support'));
END$$;
CREATE FUNCTION public.jana_ticket_write(p_token text,p_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;t public.tickets;prior public.idempotency_records;scopekey text;bodyhash text;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;msg text;mid text;ns text;np text;assigned text;tid text;category text;subject text;oid text;before_state jsonb;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF p_operation IS NULL OR p_operation NOT IN ('ticket.create','ticket.reply','ticket.update') OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'invalid_ticket';END IF;
 IF p_operation='ticket.update' AND u.role NOT IN ('admin','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation='ticket.reply' AND NOT EXISTS(SELECT 1 FROM public.tickets WHERE id=p_payload->>'ticket_id' AND user_id=u.id) THEN RAISE EXCEPTION 'ticket_not_found';END IF;
 IF length(trim(coalesce(p_key,''))) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scopekey='ticket:'||u.id||':'||p_key;bodyhash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scopekey,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scopekey;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>bodyhash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 msg=trim(coalesce(p_payload->>'message',''));mid=gen_random_uuid()::text;
 IF length(msg)>2000 OR (p_operation IN ('ticket.create','ticket.reply') AND length(msg)<2) THEN RAISE EXCEPTION 'invalid_ticket';END IF;
 IF p_operation='ticket.create' THEN
  subject=trim(coalesce(p_payload->>'subject',''));category=coalesce(p_payload->>'category','other');oid=nullif(p_payload->>'order_id','');
  IF length(subject) NOT BETWEEN 3 AND 120 OR category NOT IN ('order','product','delivery','refund','account','other') THEN RAISE EXCEPTION 'invalid_ticket';END IF;
  IF oid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.orders WHERE id=oid AND user_id=u.id) THEN RAISE EXCEPTION 'order_not_found';END IF;
  tid='tkt-'||replace(gen_random_uuid()::text,'-','');ns='open';np='normal';assigned=NULL;
  INSERT INTO public.tickets(id,user_id,order_id,subject,category,state,messages,created_at,priority,assigned_to,updated_at)
  VALUES(tid,u.id,oid,subject,category,ns,jsonb_build_array(jsonb_build_object('id',mid,'actor','customer','text',msg,'at',nowms))::json,nowms,np,NULL,nowms) RETURNING * INTO t;
  before_state=NULL;
 ELSE
  SELECT * INTO t FROM public.tickets WHERE id=p_payload->>'ticket_id' FOR UPDATE;
  IF t.id IS NULL OR (p_operation='ticket.reply' AND t.user_id<>u.id) THEN RAISE EXCEPTION 'ticket_not_found';END IF;
  tid=t.id;before_state=jsonb_build_object('state',t.state,'priority',t.priority,'assigned_to',t.assigned_to);
  IF p_operation='ticket.reply' THEN ns='open';np=t.priority;assigned=t.assigned_to;
  ELSE
   ns=coalesce(p_payload->>'state',t.state);np=coalesce(p_payload->>'priority',t.priority);assigned=CASE WHEN p_payload?'assigned_to' THEN nullif(p_payload->>'assigned_to','') ELSE t.assigned_to END;
   IF ns NOT IN ('open','pending_customer','closed') OR np NOT IN ('low','normal','high','urgent') THEN RAISE EXCEPTION 'invalid_ticket';END IF;
   IF assigned IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.users WHERE id=assigned AND active AND role IN ('admin','support')) THEN RAISE EXCEPTION 'invalid_support_assignee';END IF;
   IF msg='' AND ns=t.state AND np=t.priority AND assigned IS NOT DISTINCT FROM t.assigned_to THEN RAISE EXCEPTION 'invalid_ticket';END IF;
  END IF;
  UPDATE public.tickets SET state=ns,priority=np,assigned_to=assigned,updated_at=nowms,
   messages=CASE WHEN msg='' THEN messages ELSE (messages::jsonb||jsonb_build_array(jsonb_build_object('id',mid,'actor',CASE WHEN p_operation='ticket.reply' THEN 'customer' ELSE 'support' END,'text',msg,'at',nowms)))::json END WHERE id=t.id;
  IF p_operation='ticket.update' AND (msg<>'' OR ns<>t.state) THEN
   INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
   VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),t.user_id,'ticket-'||mid,'تحديث طلب الدعم',CASE WHEN msg<>'' THEN left(msg,180) WHEN ns='closed' THEN 'تم إغلاق طلب الدعم. يمكنك الرد إذا احتجت مساعدة إضافية.' ELSE 'تم تحديث حالة طلب الدعم' END,t.order_id,false,nowms);
  END IF;
 END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,p_operation,tid,jsonb_build_object('role',u.role,'before',before_state,'after',jsonb_build_object('state',ns,'priority',np,'assigned_to',assigned),'message_id',CASE WHEN msg<>'' THEN mid ELSE NULL END),nowms);
 r=jsonb_build_object('id',tid,'state',ns,'priority',np,'assigned_to',assigned);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scopekey,u.id,p_key,bodyhash,r::json,nowms);
 RETURN r;
END$$;
-- Keep old trusted RPC names compatible while the public API uses persisted keys.
CREATE OR REPLACE FUNCTION public.jana_create_ticket(p_token text,p_order_id text,p_subject text,p_message text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.jana_ticket_write(p_token,gen_random_uuid()::text,'ticket.create',jsonb_build_object('order_id',p_order_id,'subject',p_subject,'message',p_message));
$$;
CREATE OR REPLACE FUNCTION public.jana_customer_ticket_reply(p_token text,p_ticket_id text,p_message text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.jana_ticket_write(p_token,gen_random_uuid()::text,'ticket.reply',jsonb_build_object('ticket_id',p_ticket_id,'message',p_message));
$$;
CREATE OR REPLACE FUNCTION public.jana_support_reply(p_token text,p_ticket_id text,p_message text,p_state text DEFAULT NULL,p_priority text DEFAULT NULL) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.jana_ticket_write(p_token,gen_random_uuid()::text,'ticket.update',jsonb_build_object('ticket_id',p_ticket_id,'message',p_message)||CASE WHEN p_state IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('state',p_state) END||CASE WHEN p_priority IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('priority',p_priority) END);
$$;
REVOKE ALL ON FUNCTION public.jana_ticket_history_guard(),public.jana_ticket_messages(jsonb),public.jana_ticket_write(text,text,text,jsonb),public.jana_support_roster(text),public.jana_my_tickets(text),public.jana_support_tickets(text),public.jana_create_ticket(text,text,text,text),public.jana_customer_ticket_reply(text,text,text),public.jana_support_reply(text,text,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ticket_write(text,text,text,jsonb),public.jana_support_roster(text),public.jana_my_tickets(text),public.jana_support_tickets(text),public.jana_create_ticket(text,text,text,text),public.jana_customer_ticket_reply(text,text,text),public.jana_support_reply(text,text,text,text,text) TO service_role;
