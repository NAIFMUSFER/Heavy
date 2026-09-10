-- Saved lists contain stable sellable lineages, never trusted browser prices.
ALTER TABLE public.shopping_lists ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK(revision>0);
ALTER TABLE public.recurring_plans ADD COLUMN name text NOT NULL DEFAULT 'طلب دوري',ADD COLUMN cadence text NOT NULL DEFAULT 'custom_days' CHECK(cadence IN ('weekly','fortnightly','monthly','custom_days')),ADD COLUMN anchor_day integer CHECK(anchor_day BETWEEN 1 AND 31),ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK(revision>0);
ALTER TABLE public.recurring_plans ADD CONSTRAINT jana_recurring_state CHECK(state IN ('active','paused','cancelled'));
ALTER TABLE public.users ADD COLUMN preferences jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(preferences)='object');
CREATE INDEX jana_recurring_due_idx ON public.recurring_plans(next_at,id) WHERE state='active';
CREATE FUNCTION public.jana_saved_items(p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=public,pg_temp AS $$
DECLARE item jsonb;fid text;q integer;result jsonb;
BEGIN
 IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items)>60 THEN RAISE EXCEPTION 'invalid_list_items';END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  IF jsonb_typeof(item) IS DISTINCT FROM 'object' OR jsonb_typeof(item->'quantity') IS DISTINCT FROM 'number' OR (item->>'quantity') !~ '^[0-9]{1,2}$' THEN RAISE EXCEPTION 'invalid_list_items';END IF;
  q=(item->>'quantity')::integer;fid=item->>'offering_family_id';
  IF q NOT BETWEEN 1 AND 20 OR fid IS NULL OR NOT EXISTS(SELECT 1 FROM public.offerings WHERE family_id=fid) THEN RAISE EXCEPTION 'invalid_list_items';END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) x GROUP BY x->>'offering_family_id' HAVING sum((x->>'quantity')::integer)>20) THEN RAISE EXCEPTION 'invalid_list_items';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('offering_family_id',s.fid,'quantity',s.qty) ORDER BY s.fid),'[]') INTO result FROM (SELECT x->>'offering_family_id' fid,sum((x->>'quantity')::integer) qty FROM jsonb_array_elements(p_items) x GROUP BY x->>'offering_family_id')s;
 RETURN result;
END$$;
CREATE FUNCTION public.jana_saved_items_view(p_items jsonb,p_catalog jsonb)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('offering_family_id',i.value->>'offering_family_id','quantity',(i.value->>'quantity')::integer,'offering_id',o.value->>'id','available',o.value IS NOT NULL AND (o.value->>'available_units')::bigint >= (i.value->>'quantity')::integer,'available_units',coalesce((o.value->>'available_units')::bigint,0),'name',coalesce(o.value->>'name',history.name),'size_label',coalesce(o.value->>'size_label',history.size_label),'price_halalas',(o.value->>'price_halalas')::bigint,'emoji',o.value->>'emoji','version',o.value->'version') ORDER BY i.ordinality),'[]')
 FROM jsonb_array_elements(p_items) WITH ORDINALITY i LEFT JOIN LATERAL (SELECT value FROM jsonb_array_elements(p_catalog) c WHERE c.value->>'family_id'=i.value->>'offering_family_id' LIMIT 1)o ON true
 LEFT JOIN LATERAL(SELECT name,size_label FROM public.offerings WHERE family_id=i.value->>'offering_family_id' ORDER BY version DESC LIMIT 1)history ON true;
$$;
CREATE OR REPLACE FUNCTION public.jana_shopping_lists(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;catalog jsonb;
BEGIN u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;catalog=public.jana_public_catalog();
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,'revision',l.revision,'created_at',l.created_at,'updated_at',l.updated_at,'items',public.jana_saved_items_view(l.items,catalog)) ORDER BY updated_at DESC,id) FROM public.shopping_lists l WHERE user_id=u.id),'[]');END$$;
CREATE FUNCTION public.jana_save_shopping_list(p_token text,p_list_id text,p_name text,p_items jsonb,p_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;l public.shopping_lists;canonical_items jsonb;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 PERFORM 1 FROM public.users WHERE id=u.id FOR UPDATE;
 IF p_list_id IS NOT NULL THEN SELECT * INTO l FROM public.shopping_lists WHERE id=p_list_id AND user_id=u.id FOR UPDATE;IF l.id IS NULL THEN RAISE EXCEPTION 'list_not_found';END IF;IF p_revision IS DISTINCT FROM l.revision THEN RAISE EXCEPTION 'saved_list_changed';END IF;END IF;
 p_name=trim(coalesce(p_name,l.name,''));IF length(p_name) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_list_name';END IF;
 IF p_list_id IS NULL AND p_items IS NULL THEN RAISE EXCEPTION 'invalid_list_items';END IF;
 canonical_items=public.jana_saved_items(coalesce(p_items,l.items,'[]'));
 IF l.id IS NULL THEN
  IF (SELECT count(*) FROM public.shopping_lists WHERE user_id=u.id)>=50 THEN RAISE EXCEPTION 'list_limit';END IF;
  INSERT INTO public.shopping_lists(id,user_id,name,items,created_at,updated_at) VALUES('lst-'||replace(gen_random_uuid()::text,'-',''),u.id,p_name,canonical_items,nowms,nowms) RETURNING * INTO l;
 ELSE UPDATE public.shopping_lists SET name=p_name,items=canonical_items,updated_at=nowms,revision=revision+1 WHERE id=l.id RETURNING * INTO l;END IF;
 RETURN jsonb_build_object('id',l.id,'name',l.name,'revision',l.revision);
END$$;
CREATE OR REPLACE FUNCTION public.jana_create_shopping_list(p_token text,p_name text,p_items jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$ SELECT public.jana_save_shopping_list(p_token,NULL,p_name,p_items,NULL);$$;
CREATE FUNCTION public.jana_delete_list_version(p_token text,p_list_id text,p_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;l public.shopping_lists;
BEGIN u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO l FROM public.shopping_lists WHERE id=p_list_id AND user_id=u.id FOR UPDATE;IF l.id IS NULL THEN RAISE EXCEPTION 'list_not_found';END IF;IF p_revision IS DISTINCT FROM l.revision THEN RAISE EXCEPTION 'saved_list_changed';END IF;
 DELETE FROM public.shopping_lists WHERE id=l.id;RETURN jsonb_build_object('deleted',true);END$$;

-- Monthly reminders preserve the selected day through short months, in Saudi time.
CREATE FUNCTION public.jana_next_reminder(p_at bigint,p_cadence text,p_days integer,p_anchor integer)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE local_at timestamp;month_start timestamp;next_local timestamp;last_day integer;
BEGIN
 local_at=to_timestamp(p_at/1000.0) AT TIME ZONE 'Asia/Riyadh';
 IF p_cadence='monthly' THEN
  month_start=date_trunc('month',local_at)+interval '1 month';last_day=extract(day FROM month_start+interval '1 month - 1 day');
  next_local=month_start+make_interval(days=>least(coalesce(p_anchor,extract(day FROM local_at)::integer),last_day)-1)+(local_at-date_trunc('day',local_at));
 ELSE next_local=local_at+make_interval(days=>CASE p_cadence WHEN 'weekly' THEN 7 WHEN 'fortnightly' THEN 14 ELSE p_days END);END IF;
 RETURN (extract(epoch FROM next_local AT TIME ZONE 'Asia/Riyadh')*1000)::bigint;
END$$;
CREATE FUNCTION public.jana_save_recurring(p_token text,p_plan_id text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;r public.recurring_plans;items jsonb;cad text;nxt bigint;days integer;addr text;nm text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;st text;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;PERFORM 1 FROM public.users WHERE id=u.id FOR UPDATE;
 IF p_plan_id IS NOT NULL THEN SELECT * INTO r FROM public.recurring_plans WHERE id=p_plan_id AND user_id=u.id FOR UPDATE;IF r.id IS NULL THEN RAISE EXCEPTION 'plan_not_found';END IF;IF (p_payload->>'revision')::bigint IS DISTINCT FROM r.revision THEN RAISE EXCEPTION 'saved_list_changed';END IF;IF r.state='cancelled' THEN RAISE EXCEPTION 'plan_cancelled';END IF;END IF;
 nm=trim(coalesce(p_payload->>'name',r.name,'طلب دوري'));cad=coalesce(p_payload->>'cadence',r.cadence,'weekly');st=coalesce(p_payload->>'state',r.state,'active');
 days=CASE cad WHEN 'weekly' THEN 7 WHEN 'fortnightly' THEN 14 WHEN 'monthly' THEN 30 ELSE coalesce((p_payload->>'interval_days')::integer,r.interval_days) END;
 nxt=coalesce((p_payload->>'next_at')::bigint,r.next_at);addr=coalesce(p_payload->>'address_id',r.address_id);items=public.jana_saved_items(coalesce(p_payload->'items',r.cart::jsonb));
 IF length(nm) NOT BETWEEN 1 AND 100 OR cad NOT IN ('weekly','fortnightly','monthly','custom_days') OR days IS NULL OR days NOT BETWEEN 1 AND 90 OR st NOT IN ('active','paused','cancelled') OR jsonb_array_length(items)=0 THEN RAISE EXCEPTION 'invalid_recurring';END IF;
 IF nxt IS NULL OR ((r.id IS NULL OR p_payload?'next_at' OR (st='active' AND r.state='paused')) AND (nxt<=nowms OR nxt>nowms+31622400000)) THEN RAISE EXCEPTION 'invalid_reminder_date';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.addresses WHERE id=addr AND user_id=u.id) THEN RAISE EXCEPTION 'invalid_address';END IF;
 IF r.id IS NULL THEN
  IF (SELECT count(*) FROM public.recurring_plans WHERE user_id=u.id AND state<>'cancelled')>=20 THEN RAISE EXCEPTION 'recurring_limit';END IF;
  INSERT INTO public.recurring_plans(id,user_id,address_id,cart,interval_days,next_at,state,last_notice_at,name,cadence,anchor_day) VALUES('rec-'||replace(gen_random_uuid()::text,'-',''),u.id,addr,items,days,nxt,st,NULL,nm,cad,extract(day FROM to_timestamp(nxt/1000.0) AT TIME ZONE 'Asia/Riyadh')) RETURNING * INTO r;
 ELSE UPDATE public.recurring_plans SET name=nm,address_id=addr,cart=items,interval_days=days,next_at=nxt,state=st,cadence=cad,anchor_day=CASE WHEN p_payload?'next_at' THEN extract(day FROM to_timestamp(nxt/1000.0) AT TIME ZONE 'Asia/Riyadh') ELSE anchor_day END,revision=revision+1 WHERE id=r.id RETURNING * INTO r;END IF;
 RETURN jsonb_build_object('id',r.id,'name',r.name,'revision',r.revision,'state',r.state,'next_at',r.next_at,'mode','reminder_only');
END$$;
CREATE OR REPLACE FUNCTION public.jana_recurring_list(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;catalog jsonb;
BEGIN u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;catalog=public.jana_public_catalog();
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'address_id',r.address_id,'address_label',a.label,'items',public.jana_saved_items_view(r.cart::jsonb,catalog),'interval_days',r.interval_days,'cadence',r.cadence,'next_at',r.next_at,'state',r.state,'revision',r.revision,'last_notice_at',r.last_notice_at,'mode','reminder_only') ORDER BY r.next_at,r.id) FROM public.recurring_plans r JOIN public.addresses a ON a.id=r.address_id WHERE r.user_id=u.id),'[]');END$$;
CREATE OR REPLACE FUNCTION public.jana_recurring_create(p_token text,p_address_id text,p_cart jsonb,p_interval_days integer,p_next_at bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE items jsonb;
BEGIN
 IF jsonb_typeof(p_cart) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_list_items';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('offering_family_id',coalesce(x->>'offering_family_id',o.family_id),'quantity',coalesce(x->'quantity',x->'qty'))),'[]') INTO items FROM jsonb_array_elements(p_cart) x LEFT JOIN public.offerings o ON o.id=x->>'offering_id';
 RETURN public.jana_save_recurring(p_token,NULL,jsonb_build_object('address_id',p_address_id,'items',items,'cadence','custom_days','interval_days',p_interval_days,'next_at',p_next_at));
END$$;
CREATE OR REPLACE FUNCTION public.jana_recurring_update(p_token text,p_plan_id text,p_state text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;r public.recurring_plans;
BEGIN u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 PERFORM 1 FROM public.users WHERE id=u.id FOR UPDATE;SELECT * INTO r FROM public.recurring_plans WHERE id=p_plan_id AND user_id=u.id FOR UPDATE;IF r.id IS NULL THEN RAISE EXCEPTION 'plan_not_found';END IF;
 RETURN public.jana_save_recurring(p_token,p_plan_id,jsonb_build_object('state',p_state,'revision',r.revision));END$$;

CREATE FUNCTION public.jana_recurring_reminders()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE target record;r public.recurring_plans;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;nxt bigint;n integer:=0;steps integer;detail jsonb;
BEGIN
 FOR target IN SELECT p.id,p.user_id FROM public.recurring_plans p JOIN public.users u ON u.id=p.user_id AND u.active WHERE p.state='active' AND p.next_at<=nowms ORDER BY p.next_at,p.id LIMIT 100 LOOP
  PERFORM 1 FROM public.users WHERE id=target.user_id AND active FOR KEY SHARE;IF NOT FOUND THEN CONTINUE;END IF;
  SELECT * INTO r FROM public.recurring_plans WHERE id=target.id AND state='active' AND next_at<=nowms FOR UPDATE SKIP LOCKED;IF r.id IS NULL THEN CONTINUE;END IF;
  INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),r.user_id,'recurring-'||r.id||'-'||r.next_at,'تذكير بقائمة مشترياتك','حان موعد '+r.name+'. راجع قائمتك والأسعار والتوصيل ثم أكد الطلب بنفسك. لم يُنشأ طلب ولم يُحجز مخزون.',NULL,false,nowms) ON CONFLICT(dedupe_key) DO NOTHING;
  nxt=r.next_at;steps=0;LOOP nxt=public.jana_next_reminder(nxt,r.cadence,r.interval_days,r.anchor_day);steps=steps+1;EXIT WHEN nxt>nowms;IF steps>3700 THEN RAISE EXCEPTION 'reminder_schedule_invalid';END IF;END LOOP;
  UPDATE public.recurring_plans SET next_at=nxt,last_notice_at=nowms,revision=revision+1 WHERE id=r.id;n=n+1;
 END LOOP;
 detail=jsonb_build_object('reminders_sent',n,'ran_at',nowms);
 INSERT INTO public.worker_runs(name,last_success_at,detail) VALUES('recurring_reminders',nowms,detail) ON CONFLICT(name) DO UPDATE SET last_success_at=EXCLUDED.last_success_at,detail=EXCLUDED.detail;RETURN detail;
END$$;
CREATE FUNCTION public.jana_customer_profile(p_token text,p_changes jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;nm text;phone_value text;pref jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_changes IS NOT NULL THEN
  SELECT * INTO u FROM public.users WHERE id=u.id FOR UPDATE;nm=trim(coalesce(p_changes->>'name',u.name));phone_value=CASE WHEN p_changes?'phone' THEN nullif(trim(p_changes->>'phone'),'') ELSE u.phone END;
  pref=coalesce(p_changes->'preferences',u.preferences);
  IF jsonb_typeof(p_changes) IS DISTINCT FROM 'object' OR length(nm) NOT BETWEEN 2 AND 100 OR (phone_value IS NOT NULL AND phone_value !~ '^(05[0-9]{8}|\+9665[0-9]{8})$') OR jsonb_typeof(pref) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_each(pref) WHERE key NOT IN ('language','marketing_opt_in')) OR (pref?'language' AND (jsonb_typeof(pref->'language') IS DISTINCT FROM 'string' OR pref->>'language'<>'ar')) OR (pref?'marketing_opt_in' AND jsonb_typeof(pref->'marketing_opt_in') IS DISTINCT FROM 'boolean') THEN RAISE EXCEPTION 'profile_validation';END IF;
  BEGIN UPDATE public.users SET name=nm,phone=phone_value,verified_phone=CASE WHEN phone IS DISTINCT FROM phone_value THEN false ELSE verified_phone END,preferences=pref WHERE id=u.id RETURNING * INTO u;EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'phone_already_used';END;
 END IF;
 RETURN jsonb_build_object('id',u.id,'name',u.name,'email',u.email,'phone',u.phone,'verified_phone',u.verified_phone,'preferences',u.preferences);
END$$;
CREATE FUNCTION public.jana_customer_saved_write(p_token text,p_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;prior public.idempotency_records;scope_key text;req_hash text;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation IS NULL OR p_operation NOT IN ('list.save','list.delete','recurring.save','profile.update') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'invalid_operation';END IF;
 p_key=trim(coalesce(p_key,''));IF length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='customer-saved:'||u.id||':'||p_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 CASE p_operation WHEN 'list.save' THEN r=public.jana_save_shopping_list(p_token,p_payload->>'list_id',p_payload->>'name',p_payload->'items',(p_payload->>'revision')::bigint);
 WHEN 'list.delete' THEN r=public.jana_delete_list_version(p_token,p_payload->>'list_id',(p_payload->>'revision')::bigint);
 WHEN 'recurring.save' THEN r=public.jana_save_recurring(p_token,p_payload->>'plan_id',p_payload->'changes');
 WHEN 'profile.update' THEN r=public.jana_customer_profile(p_token,p_payload);
 END CASE;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_key,req_hash,r,(extract(epoch FROM clock_timestamp())*1000)::bigint);RETURN r;
END$$;
CREATE OR REPLACE FUNCTION public.jana_anonymize_account(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'staff_account_requires_admin';END IF;
 PERFORM 1 FROM public.users WHERE id=u.id FOR UPDATE;
 RETURN public.jana_anonymize_customer_base(p_token);
END$$;
DO $privs$ DECLARE r record;BEGIN
 FOR r IN SELECT oid::regprocedure sig,proname FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=ANY(ARRAY['jana_saved_items','jana_saved_items_view','jana_shopping_lists','jana_save_shopping_list','jana_create_shopping_list','jana_delete_list_version','jana_next_reminder','jana_save_recurring','jana_recurring_list','jana_recurring_create','jana_recurring_update','jana_recurring_reminders','jana_customer_profile','jana_customer_saved_write']) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.sig);
  IF r.proname IN ('jana_saved_items','jana_saved_items_view','jana_next_reminder') THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role',r.sig);ELSE EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',r.sig);END IF;
 END LOOP;
END $privs$;
SELECT cron.schedule('jana-recurring-reminders','* * * * *','SELECT public.jana_recurring_reminders();');
