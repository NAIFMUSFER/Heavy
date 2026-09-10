-- Physical counts preserve baseline quantities and reject stale approvals.
ALTER TABLE public.stock_items ADD COLUMN name_en text;
ALTER TABLE public.stock_items ADD COLUMN category text NOT NULL DEFAULT '';
ALTER TABLE public.stock_items ADD COLUMN reorder_base bigint CHECK(reorder_base>=0);
ALTER TABLE public.stock_items ADD COLUMN updated_at bigint;
ALTER TABLE public.suppliers ADD COLUMN email text;
ALTER TABLE public.suppliers ADD COLUMN notes text NOT NULL DEFAULT '';
ALTER TABLE public.suppliers ADD COLUMN created_at bigint;
ALTER TABLE public.inventory_lots ADD COLUMN quantity_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE public.inventory_lots ADD COLUMN receipt_reference text NOT NULL DEFAULT '';
CREATE FUNCTION public.jana_lot_quantity_revision()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 NEW.quantity_revision=OLD.quantity_revision+CASE WHEN NEW.on_hand_base IS DISTINCT FROM OLD.on_hand_base OR NEW.inspection_state IS DISTINCT FROM OLD.inspection_state THEN 1 ELSE 0 END;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_lot_quantity_revision BEFORE UPDATE ON public.inventory_lots FOR EACH ROW EXECUTE FUNCTION public.jana_lot_quantity_revision();

CREATE TABLE public.inventory_count_sessions(
 id varchar(36) PRIMARY KEY,location text NOT NULL CHECK(length(location) BETWEEN 2 AND 140),
 state text NOT NULL CHECK(state IN ('open','submitted','closed','cancelled')),
 created_by varchar(36) NOT NULL REFERENCES public.users(id),created_at bigint NOT NULL,submitted_at bigint,closed_at bigint,note text NOT NULL DEFAULT ''
);
CREATE INDEX jana_count_session_actor ON public.inventory_count_sessions(created_by);
ALTER TABLE public.inventory_count_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_count_sessions FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.inventory_count_sessions TO service_role;
ALTER TABLE public.count_requests ADD COLUMN session_id varchar(36) REFERENCES public.inventory_count_sessions(id);
ALTER TABLE public.count_requests ADD COLUMN system_revision bigint;
ALTER TABLE public.count_requests ADD COLUMN decided_at bigint;
ALTER TABLE public.count_requests ADD COLUMN decision_reason text;
ALTER TABLE public.count_requests ADD COLUMN movement_id varchar(36) REFERENCES public.stock_movements(id);
CREATE UNIQUE INDEX jana_count_session_lot ON public.count_requests(session_id,lot_id) WHERE session_id IS NOT NULL;
CREATE INDEX jana_count_movement ON public.count_requests(movement_id);
CREATE FUNCTION public.jana_count_history_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_count_history';END IF;
 IF OLD.session_id IS NULL THEN RETURN NEW;END IF;
 IF OLD.state NOT IN ('uncounted','submitted') OR
  (to_jsonb(NEW)-ARRAY['observed_base','reason','state','approved_by','decided_at','decision_reason','movement_id']) IS DISTINCT FROM
  (to_jsonb(OLD)-ARRAY['observed_base','reason','state','approved_by','decided_at','decision_reason','movement_id']) OR
  (OLD.state='uncounted' AND NEW.state NOT IN ('submitted','cancelled')) OR
  (OLD.state='submitted' AND (NEW.state NOT IN ('approved','rejected','cancelled') OR NEW.observed_base<>OLD.observed_base OR NEW.reason<>OLD.reason))
 THEN RAISE EXCEPTION 'immutable_count_history';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_count_history_guard BEFORE UPDATE OR DELETE ON public.count_requests FOR EACH ROW EXECUTE FUNCTION public.jana_count_history_guard();

CREATE FUNCTION public.jana_count_start(p_token text,p_location text,p_lot_ids jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;sid text:='cnt-'||replace(gen_random_uuid()::text,'-','');l public.inventory_lots;n int;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF length(trim(coalesce(p_location,''))) NOT BETWEEN 2 AND 140 OR jsonb_typeof(p_lot_ids) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lot_ids) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'count_validation';END IF;
 SELECT count(DISTINCT value) INTO n FROM jsonb_array_elements_text(p_lot_ids);
 IF n<>jsonb_array_length(p_lot_ids) THEN RAISE EXCEPTION 'count_validation';END IF;
 PERFORM 1 FROM public.stock_balances WHERE stock_id IN(SELECT stock_id FROM public.inventory_lots WHERE id IN(SELECT jsonb_array_elements_text(p_lot_ids))) ORDER BY stock_id FOR UPDATE;
 INSERT INTO public.inventory_count_sessions(id,location,state,created_by,created_at) VALUES(sid,trim(p_location),'open',u.id,nowms);
 n=0;
 FOR l IN SELECT * FROM public.inventory_lots WHERE id IN(SELECT jsonb_array_elements_text(p_lot_ids)) ORDER BY stock_id,id FOR UPDATE LOOP
  IF l.inspection_state<>'accepted' THEN RAISE EXCEPTION 'count_requires_accepted_lot';END IF;
  INSERT INTO public.count_requests(id,lot_id,observed_base,expected_base,submitted_by,state,reason,created_at,session_id,system_revision)
  VALUES('cnt-'||replace(gen_random_uuid()::text,'-',''),l.id,l.on_hand_base,l.on_hand_base,u.id,'uncounted','',nowms,sid,l.quantity_revision);n=n+1;
 END LOOP;
 IF n<>jsonb_array_length(p_lot_ids) THEN RAISE EXCEPTION 'lot_not_found';END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'inventory_count_started',sid,jsonb_build_object('role',u.role,'location',trim(p_location),'lots',p_lot_ids),nowms);
 RETURN jsonb_build_object('id',sid,'state','open');
END$$;

CREATE FUNCTION public.jana_count_submit(p_token text,p_session_id text,p_counts jsonb,p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.inventory_count_sessions;c public.count_requests;v jsonb;n int;observed bigint;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO s FROM public.inventory_count_sessions WHERE id=p_session_id FOR UPDATE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'count_not_found';END IF;
 IF u.role<>'admin' AND s.created_by<>u.id THEN RAISE EXCEPTION 'forbidden';END IF;
 IF s.state<>'open' THEN RAISE EXCEPTION 'invalid_count_state';END IF;
 IF jsonb_typeof(p_counts) IS DISTINCT FROM 'array' OR length(trim(coalesce(p_note,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'count_validation';END IF;
 SELECT count(*) INTO n FROM public.count_requests WHERE session_id=s.id;
 IF jsonb_array_length(p_counts)<>n OR (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(p_counts))<>n THEN RAISE EXCEPTION 'count_validation';END IF;
 FOR c IN SELECT * FROM public.count_requests WHERE session_id=s.id ORDER BY id FOR UPDATE LOOP
  SELECT value INTO v FROM jsonb_array_elements(p_counts) WHERE value->>'id'=c.id;
  IF v IS NULL OR jsonb_typeof(v->'observed_base') IS DISTINCT FROM 'number' OR (v->>'observed_base') !~ '^\d+$' THEN RAISE EXCEPTION 'count_validation';END IF;
  observed=(v->>'observed_base')::bigint;IF observed>9000000000000 THEN RAISE EXCEPTION 'count_validation';END IF;
  UPDATE public.count_requests SET observed_base=observed,reason=trim(p_note),state='submitted' WHERE id=c.id;
 END LOOP;
 UPDATE public.inventory_count_sessions SET state='submitted',submitted_at=nowms,note=trim(p_note) WHERE id=s.id;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'inventory_count_submitted',s.id,jsonb_build_object('role',u.role,'counts',p_counts,'reason',trim(p_note)),nowms);
 RETURN jsonb_build_object('id',s.id,'state','submitted');
END$$;

CREATE FUNCTION public.jana_count_decide(p_token text,p_count_id text,p_approve boolean,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.inventory_count_sessions;c public.count_requests;l public.inventory_lots;cid text;lid text;delta bigint;mid text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_approve IS NULL OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'count_validation';END IF;
 SELECT session_id,lot_id INTO cid,lid FROM public.count_requests WHERE id=p_count_id;
 SELECT * INTO s FROM public.inventory_count_sessions WHERE id=cid FOR UPDATE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'count_not_found';END IF;
 IF s.state<>'submitted' THEN RAISE EXCEPTION 'invalid_count_state';END IF;
 PERFORM 1 FROM public.stock_balances WHERE stock_id=(SELECT stock_id FROM public.inventory_lots WHERE id=lid) FOR UPDATE;
 SELECT * INTO l FROM public.inventory_lots WHERE id=lid FOR UPDATE;
 SELECT * INTO c FROM public.count_requests WHERE id=p_count_id FOR UPDATE;
 IF c.state<>'submitted' THEN RAISE EXCEPTION 'invalid_count_state';END IF;
 delta=c.observed_base-c.expected_base;
 IF p_approve THEN
  IF l.quantity_revision<>c.system_revision OR l.on_hand_base<>c.expected_base OR l.inspection_state<>'accepted' THEN RAISE EXCEPTION 'count_stale';END IF;
  IF c.observed_base<l.reserved_base THEN RAISE EXCEPTION 'count_below_reserved';END IF;
  IF delta<>0 THEN
   mid='mov-'||replace(gen_random_uuid()::text,'-','');
   UPDATE public.inventory_lots SET on_hand_base=c.observed_base WHERE id=l.id;
   UPDATE public.stock_balances SET on_hand_base=on_hand_base+delta WHERE stock_id=l.stock_id;
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
   VALUES(mid,l.stock_id,l.id,delta,0,'cycle_count_approved',c.id,u.id,nowms);
  END IF;
 END IF;
 UPDATE public.count_requests SET state=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,approved_by=u.id,decided_at=nowms,decision_reason=trim(p_reason),movement_id=mid WHERE id=c.id;
 IF NOT EXISTS(SELECT 1 FROM public.count_requests WHERE session_id=s.id AND state='submitted') THEN UPDATE public.inventory_count_sessions SET state='closed',closed_at=nowms WHERE id=s.id;END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN p_approve THEN 'inventory_count_approved' ELSE 'inventory_count_rejected' END,c.id,jsonb_build_object('role',u.role,'session_id',s.id,'lot_id',l.id,'old_quantity',l.on_hand_base,'observed_quantity',c.observed_base,'delta',CASE WHEN p_approve THEN delta ELSE 0 END,'reason',trim(p_reason),'movement_id',mid),nowms);
 RETURN jsonb_build_object('id',c.id,'state',CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,'delta',CASE WHEN p_approve THEN delta ELSE 0 END,'movement_id',mid);
END$$;

CREATE FUNCTION public.jana_count_cancel(p_token text,p_session_id text,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.inventory_count_sessions;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO s FROM public.inventory_count_sessions WHERE id=p_session_id FOR UPDATE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'count_not_found';END IF;
 IF u.role<>'admin' AND s.created_by<>u.id THEN RAISE EXCEPTION 'forbidden';END IF;
 IF s.state NOT IN ('open','submitted') OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_count_state';END IF;
 UPDATE public.count_requests SET state='cancelled',approved_by=u.id,decided_at=nowms,decision_reason=trim(p_reason) WHERE session_id=s.id AND state IN ('uncounted','submitted');
 UPDATE public.inventory_count_sessions SET state='cancelled',closed_at=nowms WHERE id=s.id;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'inventory_count_cancelled',s.id,jsonb_build_object('role',u.role,'reason',trim(p_reason)),nowms);
 RETURN jsonb_build_object('id',s.id,'state','cancelled');
END$$;

CREATE FUNCTION public.jana_inventory_counts(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(s)||jsonb_build_object('counts',coalesce((SELECT jsonb_agg(to_jsonb(c)||jsonb_build_object('stock_name',st.name,'base_unit',st.base_unit,'current_base',l.on_hand_base,'current_reserved',l.reserved_base,'stale',l.quantity_revision<>c.system_revision) ORDER BY c.id) FROM public.count_requests c JOIN public.inventory_lots l ON l.id=c.lot_id JOIN public.stock_items st ON st.id=l.stock_id WHERE c.session_id=s.id),'[]'::jsonb)) ORDER BY s.created_at DESC) FROM (SELECT * FROM public.inventory_count_sessions ORDER BY created_at DESC LIMIT 100)s),'[]'::jsonb);
END$$;

CREATE FUNCTION public.jana_inventory_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;prior public.idempotency_records;scope_key text;req_hash text;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') OR (p_operation='count.decide' AND u.role<>'admin') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation IS NULL OR p_operation NOT IN ('count.start','count.submit','count.decide','count.cancel','lot.receive','lot.inspect','lot.adjust','stock.update','supplier.update') THEN RAISE EXCEPTION 'invalid_operation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='inventory:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 CASE p_operation
 WHEN 'count.start' THEN r=public.jana_count_start(p_token,p_payload->>'location',p_payload->'lot_ids');
 WHEN 'count.submit' THEN r=public.jana_count_submit(p_token,p_payload->>'session_id',p_payload->'counts',p_payload->>'note');
 WHEN 'count.decide' THEN
  IF jsonb_typeof(p_payload->'approve') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'count_validation';END IF;
  r=public.jana_count_decide(p_token,p_payload->>'count_id',(p_payload->>'approve')::boolean,p_payload->>'reason');
 WHEN 'count.cancel' THEN r=public.jana_count_cancel(p_token,p_payload->>'session_id',p_payload->>'reason');
 WHEN 'lot.receive' THEN r=public.jana_inventory_receive_lot(p_token,p_payload->>'stock_id',nullif(p_payload->>'supplier_id',''),(p_payload->>'received_base')::bigint,(p_payload->>'total_cost_halalas')::bigint,(p_payload->>'expires_at')::bigint);
  IF length(coalesce(p_payload->>'receipt_reference',''))>180 THEN RAISE EXCEPTION 'receipt_validation';END IF;
  UPDATE public.inventory_lots SET receipt_reference=trim(coalesce(p_payload->>'receipt_reference','')) WHERE id=r->>'id';
 WHEN 'lot.inspect' THEN r=public.jana_inventory_inspect_lot(p_token,p_payload->>'lot_id',p_payload->>'state',p_payload->>'note');
 WHEN 'stock.update' THEN r=public.jana_update_stock(p_token,p_payload->>'stock_id',p_payload->'changes');
 WHEN 'supplier.update' THEN r=public.jana_update_supplier(p_token,p_payload->>'supplier_id',p_payload->'changes');
 WHEN 'lot.adjust' THEN r=public.jana_inventory_adjust_lot(p_token,p_payload->>'lot_id',(p_payload->>'new_on_hand')::bigint,p_payload->>'reason');
 END CASE;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,req_hash,r,(extract(epoch from clock_timestamp())*1000)::bigint);
 RETURN r;
END$$;

DO $privs$ DECLARE r record;BEGIN
 FOR r IN SELECT oid::regprocedure sig,proname FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=ANY(ARRAY['jana_lot_quantity_revision','jana_count_history_guard','jana_count_start','jana_count_submit','jana_count_decide','jana_count_cancel','jana_inventory_counts','jana_inventory_write']) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.sig);
  IF r.proname NOT IN ('jana_lot_quantity_revision','jana_count_history_guard') THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',r.sig);END IF;
 END LOOP;
END $privs$;

CREATE FUNCTION public.jana_stock_health()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.name),'[]'::jsonb) FROM (
 SELECT s.*,coalesce(b.on_hand_base,0) on_hand_base,coalesce(b.reserved_base,0) reserved_base,
 coalesce(b.on_hand_base-b.reserved_base,0) available_base,coalesce(a.sellable_base,0) sellable_base,
 CASE WHEN coalesce(a.sellable_base,0)=0 THEN 'out_of_stock' WHEN s.reorder_base IS NULL THEN 'threshold_not_set' WHEN a.sellable_base<=s.reorder_base THEN 'low' ELSE 'normal' END stock_status
 FROM public.stock_items s LEFT JOIN public.stock_balances b ON b.stock_id=s.id LEFT JOIN (
 SELECT stock_id,sum(on_hand_base-reserved_base) sellable_base FROM public.inventory_lots WHERE inspection_state='accepted' AND expires_at>extract(epoch from now())*1000 GROUP BY stock_id
 )a ON a.stock_id=s.id)x;
$$;

CREATE FUNCTION public.jana_update_stock(p_token text,p_stock_id text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.stock_items;r public.stock_items;threshold bigint;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO s FROM public.stock_items WHERE id=p_stock_id FOR UPDATE;IF s.id IS NULL THEN RAISE EXCEPTION 'stock_not_found';END IF;
 IF p_payload?'base_unit' AND p_payload->>'base_unit' IS DISTINCT FROM s.base_unit THEN RAISE EXCEPTION 'stock_unit_immutable';END IF;
 threshold=CASE WHEN p_payload?'reorder_base' THEN (p_payload->>'reorder_base')::bigint ELSE s.reorder_base END;
 IF threshold<0 OR threshold>9000000000000 OR length(trim(coalesce(p_payload->>'name',s.name))) NOT BETWEEN 2 AND 140 OR length(coalesce(p_payload->>'name_en',''))>140 OR length(coalesce(p_payload->>'category',''))>80 OR (p_payload?'active' AND jsonb_typeof(p_payload->'active') IS DISTINCT FROM 'boolean') THEN RAISE EXCEPTION 'stock_validation';END IF;
 UPDATE public.stock_items SET name=trim(coalesce(p_payload->>'name',s.name)),name_en=CASE WHEN p_payload?'name_en' THEN nullif(trim(p_payload->>'name_en'),'') ELSE name_en END,category=coalesce(p_payload->>'category',category),reorder_base=threshold,active=coalesce((p_payload->>'active')::boolean,active),updated_at=nowms WHERE id=s.id RETURNING * INTO r;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'stock_master_updated',s.id,jsonb_build_object('role',u.role,'before',to_jsonb(s),'after',to_jsonb(r)),nowms);
 RETURN to_jsonb(r);
END$$;

ALTER TABLE public.suppliers ALTER COLUMN created_at SET DEFAULT ((extract(epoch from clock_timestamp())*1000)::bigint);
CREATE FUNCTION public.jana_update_supplier(p_token text,p_supplier_id text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.suppliers;r public.suppliers;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO s FROM public.suppliers WHERE id=p_supplier_id FOR UPDATE;IF s.id IS NULL THEN RAISE EXCEPTION 'supplier_not_found';END IF;
 IF length(trim(coalesce(p_payload->>'name',s.name))) NOT BETWEEN 2 AND 140 OR length(coalesce(p_payload->>'phone',''))>30 OR length(coalesce(p_payload->>'notes',''))>4000 OR length(coalesce(p_payload->>'email',''))>254 OR (nullif(trim(p_payload->>'email'),'') IS NOT NULL AND p_payload->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') OR (p_payload?'active' AND jsonb_typeof(p_payload->'active') IS DISTINCT FROM 'boolean') THEN RAISE EXCEPTION 'supplier_validation';END IF;
 UPDATE public.suppliers SET name=trim(coalesce(p_payload->>'name',name)),phone=coalesce(p_payload->>'phone',phone),email=CASE WHEN p_payload?'email' THEN nullif(trim(p_payload->>'email'),'') ELSE email END,notes=coalesce(p_payload->>'notes',notes),active=coalesce((p_payload->>'active')::boolean,active) WHERE id=s.id RETURNING * INTO r;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'supplier_updated',s.id,jsonb_build_object('role',u.role,'before',to_jsonb(s),'after',to_jsonb(r)),nowms);
 RETURN to_jsonb(r);
END$$;

ALTER FUNCTION public.jana_admin_catalog(text) RENAME TO jana_admin_catalog_products_base;
CREATE FUNCTION public.jana_admin_catalog(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;BEGIN r=public.jana_admin_catalog_products_base(p_token);RETURN r||jsonb_build_object('stock',public.jana_stock_health());END$$;
ALTER FUNCTION public.jana_admin_reports(text) RENAME TO jana_admin_reports_finance_base;
CREATE FUNCTION public.jana_admin_reports(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;health jsonb;BEGIN r=public.jana_admin_reports_finance_base(p_token);health=public.jana_stock_health();RETURN r||jsonb_build_object(
 'low_stock',coalesce((SELECT jsonb_agg(x||jsonb_build_object('available_base',(x->>'sellable_base')::bigint)) FROM jsonb_array_elements(health) x WHERE x->>'stock_status' IN ('out_of_stock','low') AND (x->>'active')::boolean),'[]'::jsonb),
 'stock_thresholds_missing',(SELECT count(*) FROM jsonb_array_elements(health) x WHERE x->>'reorder_base' IS NULL AND (x->>'active')::boolean));END$$;
REVOKE ALL ON FUNCTION public.jana_stock_health(),public.jana_update_stock(text,text,jsonb),public.jana_update_supplier(text,text,jsonb),public.jana_admin_catalog(text),public.jana_admin_reports(text),public.jana_admin_catalog_products_base(text),public.jana_admin_reports_finance_base(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_stock_health(),public.jana_admin_catalog_products_base(text),public.jana_admin_reports_finance_base(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.jana_update_stock(text,text,jsonb),public.jana_update_supplier(text,text,jsonb),public.jana_admin_catalog(text),public.jana_admin_reports(text) TO service_role;

-- Receipt/rejection have explicit zero-balance movements; inspection shares the balance-first lock order.
create or replace function public.jana_inventory_receive_lot(p_token text,p_stock_id text,p_supplier_id text,p_received_base bigint,p_total_cost_halalas bigint,p_expires_at bigint)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; lid text:='lot-'||replace(gen_random_uuid()::text,'-',''); nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; st public.stock_items;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 select * into st from public.stock_items where id=p_stock_id and active=true; if st.id is null then raise exception 'stock_not_found'; end if;
 if p_supplier_id is not null and not exists(select 1 from public.suppliers where id=p_supplier_id and active=true) then raise exception 'supplier_not_found'; end if;
 if p_received_base is null or p_received_base<=0 or p_received_base>9000000000000 or p_total_cost_halalas<0 or p_expires_at is null or p_expires_at<=nowms then raise exception 'validation'; end if;
 insert into public.inventory_lots(id,stock_id,supplier_id,received_base,on_hand_base,reserved_base,total_cost_halalas,remaining_cost_halalas,expires_at,inspection_state,received_by,inspected_by,inspection_note,created_at)
 values(lid,p_stock_id,p_supplier_id,p_received_base,0,0,p_total_cost_halalas,p_total_cost_halalas,p_expires_at,'pending',u.id,null,'',nowms);
 insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),p_stock_id,lid,0,0,'receipt_pending_inspection',lid,u.id,nowms);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'lot_received_pending_inspection',lid,jsonb_build_object('stock_id',p_stock_id,'received_base',p_received_base,'cost_halalas',p_total_cost_halalas),nowms);
 return jsonb_build_object('id',lid,'stock_id',p_stock_id,'received_base',p_received_base,'inspection_state','pending','expires_at',p_expires_at);
end$$;

create or replace function public.jana_inventory_inspect_lot(p_token text,p_lot_id text,p_state text,p_note text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; l public.inventory_lots; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 if p_state is null or p_state not in ('accepted','rejected') or (p_state='rejected' and length(trim(coalesce(p_note,'')))<3) then raise exception 'validation'; end if;
 perform 1 from public.stock_balances where stock_id=(select stock_id from public.inventory_lots where id=p_lot_id) for update;
 select * into l from public.inventory_lots where id=p_lot_id for update; if l.id is null then raise exception 'lot_not_found'; end if;
 if l.inspection_state<>'pending' then raise exception 'already_inspected'; end if;
 if p_state='accepted' then
   update public.inventory_lots set inspection_state='accepted',inspected_by=u.id,inspection_note=left(coalesce(p_note,''),1000),on_hand_base=received_base where id=l.id;
   update public.stock_balances set on_hand_base=on_hand_base+l.received_base where stock_id=l.stock_id;
   insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),l.stock_id,l.id,l.received_base,0,'goods_receipt_accepted',l.id,u.id,nowms);
 else
   update public.inventory_lots set inspection_state='rejected',inspected_by=u.id,inspection_note=left(coalesce(p_note,''),1000),remaining_cost_halalas=0 where id=l.id;
   insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),l.stock_id,l.id,0,0,'inspection_rejected',l.id,u.id,nowms);
 end if;
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'lot_inspected',l.id,jsonb_build_object('state',p_state,'note',left(coalesce(p_note,''),1000)),nowms);
 return jsonb_build_object('id',l.id,'inspection_state',p_state,'stock_id',l.stock_id,'received_base',l.received_base);
end$$;

