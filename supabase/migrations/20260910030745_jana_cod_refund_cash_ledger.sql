-- Never guess which party funded a historical refund.
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.orders WHERE refunded_halalas>0) OR EXISTS(SELECT 1 FROM public.refunds WHERE state='completed') THEN RAISE EXCEPTION 'historical_refund_source_review_required';END IF;
 IF EXISTS(SELECT 1 FROM public.orders WHERE collected_halalas>0 AND courier_id IS NULL) THEN RAISE EXCEPTION 'historical_courier_review_required';END IF;
END$$;
ALTER TABLE public.orders ADD COLUMN settled_halalas bigint NOT NULL DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN courier_refunded_halalas bigint NOT NULL DEFAULT 0;
UPDATE public.orders SET settled_halalas=collected_halalas WHERE cash_state='settled';
ALTER TABLE public.orders ADD CONSTRAINT courier_cash_bounds CHECK(settled_halalas>=0 AND courier_refunded_halalas>=0 AND courier_refunded_halalas<=refunded_halalas AND settled_halalas+courier_refunded_halalas<=collected_halalas);
ALTER TABLE public.refunds ADD COLUMN payment_source text CHECK(payment_source IN ('courier','finance'));
ALTER TABLE public.refunds ADD COLUMN completed_at bigint;
ALTER TABLE public.refunds ADD COLUMN decision_note text;
CREATE UNIQUE INDEX refund_payment_reference_once ON public.refunds(order_id,reference) WHERE state='completed';
CREATE TABLE public.cash_entries(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id varchar(36) NOT NULL REFERENCES public.orders(id),courier_id varchar(36) NOT NULL REFERENCES public.users(id),
 kind text NOT NULL CHECK(kind IN ('collection','settlement','refund')),amount_halalas bigint NOT NULL CHECK(amount_halalas>=0),
 refund_id varchar(36) REFERENCES public.refunds(id),reference varchar(180) NOT NULL,actor_id varchar(36) REFERENCES public.users(id),created_at bigint NOT NULL,
 CHECK((kind='refund')=(refund_id IS NOT NULL)),CHECK(length(trim(reference))>=3)
);
CREATE INDEX cash_entries_order_idx ON public.cash_entries(order_id);
CREATE INDEX cash_entries_courier_idx ON public.cash_entries(courier_id,created_at);
CREATE UNIQUE INDEX cash_collection_once ON public.cash_entries(order_id) WHERE kind='collection';
CREATE UNIQUE INDEX cash_refund_once ON public.cash_entries(refund_id) WHERE kind='refund';
CREATE UNIQUE INDEX cash_settlement_reference_once ON public.cash_entries(order_id,reference) WHERE kind='settlement';
ALTER TABLE public.cash_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cash_entries FROM PUBLIC,anon,authenticated;
INSERT INTO public.cash_entries(order_id,courier_id,kind,amount_halalas,reference,created_at)
 SELECT id,courier_id,'collection',collected_halalas,'legacy-collection-'||id,created_at FROM public.orders WHERE collected_halalas>0;
INSERT INTO public.cash_entries(order_id,courier_id,kind,amount_halalas,reference,created_at)
 SELECT id,courier_id,'settlement',settled_halalas,'legacy-settlement-'||id,created_at FROM public.orders WHERE settled_halalas>0;
CREATE TRIGGER immutable_cash_entries BEFORE UPDATE OR DELETE ON public.cash_entries FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();
CREATE FUNCTION public.jana_cash_collection_entry() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.collected_halalas IS DISTINCT FROM OLD.collected_halalas OR (OLD.payment_state='awaiting_collection' AND NEW.payment_state='collected') THEN
  IF OLD.collected_halalas<>0 OR NEW.collected_halalas<0 OR NEW.courier_id IS NULL OR NEW.delivery_state<>'delivered' THEN RAISE EXCEPTION 'invalid_cash_collection';END IF;
  INSERT INTO public.cash_entries(order_id,courier_id,kind,amount_halalas,reference,actor_id,created_at)
  VALUES(NEW.id,NEW.courier_id,'collection',NEW.collected_halalas,NEW.id,coalesce(nullif(current_setting('jana.actor_id',true),''),NEW.courier_id),(extract(epoch from clock_timestamp())*1000)::bigint);
 END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_cash_collection_entry AFTER UPDATE OF collected_halalas,payment_state ON public.orders FOR EACH ROW EXECUTE FUNCTION public.jana_cash_collection_entry();
ALTER FUNCTION public.jana_ops_transition(text,text,text,text) RENAME TO jana_ops_transition_base;
CREATE FUNCTION public.jana_ops_transition(p_token text,p_order_id text,p_action text,p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;
BEGIN u=public.jana_auth_user(p_token);PERFORM set_config('jana.actor_id',u.id,true);RETURN public.jana_ops_transition_base(p_token,p_order_id,p_action,p_code);END$$;

CREATE FUNCTION public.jana_open_refund(p_token text,p_order_id text,p_amount_halalas bigint,p_reason text,p_staff boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;held bigint;rid text:='rfd-'||replace(gen_random_uuid()::text,'-','');nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF p_staff AND u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id AND (p_staff OR user_id=u.id) FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF o.delivery_state<>'delivered' THEN RAISE EXCEPTION 'not_delivered';END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'refund_reason_required';END IF;
 SELECT coalesce(sum(amount_halalas),0) INTO held FROM public.refunds WHERE order_id=o.id AND state IN ('requested','processing','completed');
 IF p_amount_halalas IS NULL OR p_amount_halalas<=0 OR p_amount_halalas>o.collected_halalas-held THEN RAISE EXCEPTION 'refund_amount_invalid';END IF;
 INSERT INTO public.refunds(id,order_id,component_id,amount_halalas,reason,state,requested_by,reference,created_at)
 VALUES(rid,o.id,'order',p_amount_halalas,trim(p_reason),'requested',u.id,'',nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'refund_requested',rid,jsonb_build_object('role',u.role,'order_id',o.id,'amount_halalas',p_amount_halalas),nowms);
 RETURN jsonb_build_object('id',rid,'order_id',o.id,'state','requested','amount_halalas',p_amount_halalas);
END$$;
CREATE OR REPLACE FUNCTION public.jana_request_refund(p_token text,p_order_id text,p_component_id text,p_amount_halalas bigint,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF coalesce(p_component_id,'order') NOT IN ('','order') THEN RAISE EXCEPTION 'refund_order_scope_required';END IF;
 RETURN public.jana_open_refund(p_token,p_order_id,p_amount_halalas,p_reason,false);
END$$;
CREATE FUNCTION public.jana_complete_refund(p_token text,p_refund_id text,p_reference text,p_payment_source text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;rf public.refunds;oid text;due bigint;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF length(trim(coalesce(p_reference,''))) NOT BETWEEN 3 AND 180 THEN RAISE EXCEPTION 'refund_reference_required';END IF;
 IF p_payment_source IS NULL OR p_payment_source NOT IN ('courier','finance') THEN RAISE EXCEPTION 'refund_source_required';END IF;
 SELECT order_id INTO oid FROM public.refunds WHERE id=p_refund_id;IF oid IS NULL THEN RAISE EXCEPTION 'refund_not_found';END IF;
 SELECT * INTO o FROM public.orders WHERE id=oid FOR UPDATE;
 SELECT * INTO rf FROM public.refunds WHERE id=p_refund_id FOR UPDATE;
 IF rf.state='completed' THEN
  IF rf.reference<>trim(p_reference) OR rf.payment_source<>p_payment_source THEN RAISE EXCEPTION 'refund_already_completed';END IF;
  RETURN jsonb_build_object('refund_id',rf.id,'order_id',o.id,'state','completed','amount_halalas',rf.amount_halalas,'payment_source',rf.payment_source,'reference',rf.reference);
 END IF;
 IF rf.state NOT IN ('requested','processing') THEN RAISE EXCEPTION 'invalid_refund_state';END IF;
 IF rf.amount_halalas>o.collected_halalas-o.refunded_halalas THEN RAISE EXCEPTION 'refund_amount_invalid';END IF;
 due=o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas;
 IF p_payment_source='courier' AND (rf.amount_halalas>due OR o.courier_id IS NULL OR o.cash_state<>'with_courier') THEN RAISE EXCEPTION 'courier_liability_exceeded';END IF;
 UPDATE public.refunds SET state='completed',approved_by=u.id,reference=trim(p_reference),payment_source=p_payment_source,completed_at=nowms WHERE id=rf.id;
 UPDATE public.orders SET refunded_halalas=refunded_halalas+rf.amount_halalas,courier_refunded_halalas=courier_refunded_halalas+CASE WHEN p_payment_source='courier' THEN rf.amount_halalas ELSE 0 END,
  payment_state=CASE WHEN refunded_halalas+rf.amount_halalas=collected_halalas THEN 'refunded' ELSE 'partially_refunded' END WHERE id=o.id;
 IF p_payment_source='courier' THEN INSERT INTO public.cash_entries(order_id,courier_id,kind,amount_halalas,refund_id,reference,actor_id,created_at) VALUES(o.id,o.courier_id,'refund',rf.amount_halalas,rf.id,trim(p_reference),u.id,nowms);END IF;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'refund_completed',rf.reason,jsonb_build_object('refund_id',rf.id,'amount_halalas',rf.amount_halalas,'payment_source',p_payment_source),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'refund_completed',rf.id,jsonb_build_object('role',u.role,'order_id',o.id,'amount_halalas',rf.amount_halalas,'payment_source',p_payment_source,'reference',trim(p_reference)),nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'refund-complete-'||rf.id,'تحديث الاسترداد','سُجّل إرجاع مبلغ الاسترداد. يمكنك مراجعة التفاصيل في الطلب.',o.id,false,nowms);
 RETURN jsonb_build_object('refund_id',rf.id,'order_id',o.id,'state','completed','amount_halalas',rf.amount_halalas,'refunded_total_halalas',o.refunded_halalas+rf.amount_halalas,'payment_source',p_payment_source,'reference',trim(p_reference));
END$$;
CREATE FUNCTION public.jana_record_paid_refund(p_token text,p_order_id text,p_amount_halalas bigint,p_reason text,p_reference text,p_payment_source text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;
BEGIN r=public.jana_open_refund(p_token,p_order_id,p_amount_halalas,p_reason,true);RETURN public.jana_complete_refund(p_token,r->>'id',p_reference,p_payment_source);END$$;
CREATE OR REPLACE FUNCTION public.jana_admin_refund(p_token text,p_order_id text,p_amount_halalas bigint,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN PERFORM public.jana_auth_user(p_token);RAISE EXCEPTION 'refund_reference_required';END$$;
CREATE FUNCTION public.jana_reject_refund(p_token text,p_refund_id text,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;rf public.refunds;oid text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'refund_reason_required';END IF;
 SELECT order_id INTO oid FROM public.refunds WHERE id=p_refund_id;IF oid IS NULL THEN RAISE EXCEPTION 'refund_not_found';END IF;
 PERFORM 1 FROM public.orders WHERE id=oid FOR UPDATE;SELECT * INTO rf FROM public.refunds WHERE id=p_refund_id FOR UPDATE;
 IF rf.state NOT IN ('requested','processing') THEN RAISE EXCEPTION 'invalid_refund_state';END IF;
 UPDATE public.refunds SET state='rejected',approved_by=u.id,decision_note=trim(p_reason) WHERE id=rf.id;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'refund_rejected',rf.id,jsonb_build_object('role',u.role,'reason',trim(p_reason),'order_id',oid),nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) SELECT 'ntf-'||replace(gen_random_uuid()::text,'-',''),user_id,'refund-rejected-'||rf.id,'تحديث طلب الاسترداد',left(trim(p_reason),180),oid,false,nowms FROM public.orders WHERE id=oid;
 RETURN jsonb_build_object('id',rf.id,'state','rejected');
END$$;
CREATE FUNCTION public.jana_finance_settle_amount(p_token text,p_order_id text,p_amount_halalas bigint,p_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;o public.orders;due bigint;amount bigint;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF length(trim(coalesce(p_reference,''))) NOT BETWEEN 3 AND 180 THEN RAISE EXCEPTION 'settlement_reference_required';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF o.status<>'completed' OR o.payment_state NOT IN ('collected','partially_refunded','refunded') OR o.cash_state<>'with_courier' OR o.courier_id IS NULL THEN RAISE EXCEPTION 'invalid_transition';END IF;
 due=o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas;amount=coalesce(p_amount_halalas,due);
 IF amount<0 OR amount>due OR (amount=0 AND due<>0) THEN RAISE EXCEPTION 'courier_liability_exceeded';END IF;
 UPDATE public.orders SET settled_halalas=settled_halalas+amount,cash_state=CASE WHEN amount=due THEN 'settled' ELSE 'with_courier' END WHERE id=o.id;
 INSERT INTO public.cash_entries(order_id,courier_id,kind,amount_halalas,reference,actor_id,created_at) VALUES(o.id,o.courier_id,'settlement',amount,trim(p_reference),u.id,nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'cash_settled',trim(p_reference),jsonb_build_object('amount_halalas',amount,'remaining_liability_halalas',due-amount),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'cash_settled',o.id,jsonb_build_object('role',u.role,'reference',trim(p_reference),'amount_halalas',amount,'remaining_liability_halalas',due-amount),nowms);
 RETURN jsonb_build_object('id',o.id,'number',o.number,'cash_state',CASE WHEN amount=due THEN 'settled' ELSE 'with_courier' END,'settled_halalas',amount,'settled_total_halalas',o.settled_halalas+amount,'remaining_liability_halalas',due-amount);
END$$;
CREATE OR REPLACE FUNCTION public.jana_finance_settle(p_token text,p_order_id text,p_reference text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.jana_finance_settle_amount(p_token,p_order_id,NULL,p_reference);
$$;
ALTER TABLE public.refunds ADD CONSTRAINT completed_refund_evidence CHECK(state<>'completed' OR (payment_source IS NOT NULL AND approved_by IS NOT NULL AND completed_at IS NOT NULL AND length(trim(reference))>=3));
CREATE FUNCTION public.jana_refund_history_guard() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_refund_history';END IF;
 IF OLD.state IN ('completed','rejected','failed') AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN RAISE EXCEPTION 'immutable_refund_history';END IF;
 IF (to_jsonb(NEW)-ARRAY['state','approved_by','reference','payment_source','completed_at','decision_note']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['state','approved_by','reference','payment_source','completed_at','decision_note']) THEN RAISE EXCEPTION 'immutable_refund_history';END IF;
 IF NEW.state<>OLD.state AND NOT ((OLD.state='requested' AND NEW.state IN ('processing','completed','rejected')) OR (OLD.state='processing' AND NEW.state IN ('completed','rejected','failed'))) THEN RAISE EXCEPTION 'invalid_refund_state';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER immutable_refund_history BEFORE UPDATE OR DELETE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.jana_refund_history_guard();
CREATE FUNCTION public.jana_cash_matches(p_order_id text) RETURNS boolean LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
 SELECT o.collected_halalas=coalesce(c.collected,0) AND o.settled_halalas=coalesce(c.settled,0) AND o.courier_refunded_halalas=coalesce(c.refunded,0)
  AND o.refunded_halalas=coalesce(r.refunded,0) AND o.courier_refunded_halalas=coalesce(r.courier_refunded,0)
  AND (o.cash_state<>'settled' OR o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas=0)
  AND NOT EXISTS(SELECT 1 FROM public.cash_entries e WHERE e.order_id=o.id AND e.courier_id IS DISTINCT FROM o.courier_id)
  AND NOT EXISTS(SELECT 1 FROM public.cash_entries e JOIN public.refunds rf ON rf.id=e.refund_id WHERE e.order_id=o.id AND (rf.order_id<>e.order_id OR rf.payment_source<>'courier' OR rf.amount_halalas<>e.amount_halalas OR rf.state<>'completed'))
 FROM public.orders o
 LEFT JOIN LATERAL (SELECT sum(amount_halalas) FILTER(WHERE kind='collection') collected,sum(amount_halalas) FILTER(WHERE kind='settlement') settled,sum(amount_halalas) FILTER(WHERE kind='refund') refunded FROM public.cash_entries WHERE order_id=o.id)c ON true
 LEFT JOIN LATERAL (SELECT sum(amount_halalas) refunded,sum(amount_halalas) FILTER(WHERE payment_source='courier') courier_refunded FROM public.refunds WHERE order_id=o.id AND state='completed')r ON true
 WHERE o.id=p_order_id;
$$;
CREATE FUNCTION public.jana_cash_reconcile_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE oid text;
BEGIN
 IF TG_TABLE_NAME='orders' THEN oid=NEW.id;ELSE oid=NEW.order_id;END IF;
 PERFORM 1 FROM public.orders WHERE id=oid FOR UPDATE;
 IF NOT coalesce(public.jana_cash_matches(oid),false) THEN RAISE EXCEPTION 'cash_ledger_mismatch';END IF;
 RETURN NEW;
END$$;
CREATE CONSTRAINT TRIGGER reconcile_order_cash AFTER INSERT OR UPDATE ON public.orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.jana_cash_reconcile_guard();
CREATE CONSTRAINT TRIGGER reconcile_cash_entry AFTER INSERT ON public.cash_entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.jana_cash_reconcile_guard();
CREATE CONSTRAINT TRIGGER reconcile_refund_cash AFTER INSERT OR UPDATE ON public.refunds DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.jana_cash_reconcile_guard();

CREATE OR REPLACE FUNCTION public.jana_admin_orders(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,'payment_state',o.payment_state,'cash_state',o.cash_state,'total_halalas',o.total_halalas,'collected_halalas',o.collected_halalas,'refunded_halalas',o.refunded_halalas,'settled_halalas',o.settled_halalas,'courier_refunded_halalas',o.courier_refunded_halalas,'cash_liability_halalas',o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas,'courier_id',o.courier_id,'picker_id',o.picker_id,'snapshot',o.snapshot,'created_at',o.created_at) ORDER BY o.created_at DESC),'[]') FROM public.orders o);
END$$;
CREATE FUNCTION public.jana_finance_overview(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN jsonb_build_object(
 'couriers',(SELECT coalesce(jsonb_agg(x ORDER BY x.liability_halalas DESC),'[]') FROM (SELECT cu.id,cu.name,sum(o.collected_halalas) collected_halalas,sum(o.settled_halalas) settled_halalas,sum(o.courier_refunded_halalas) courier_refunded_halalas,sum(o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas) liability_halalas FROM public.orders o JOIN public.users cu ON cu.id=o.courier_id WHERE o.payment_state IN ('collected','partially_refunded','refunded') GROUP BY cu.id,cu.name)x),
 'refunds',(SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('order_number',o.number) ORDER BY r.created_at DESC),'[]') FROM public.refunds r JOIN public.orders o ON o.id=r.order_id),
 'cash_entries',(SELECT coalesce(jsonb_agg(x ORDER BY x.created_at DESC),'[]') FROM (SELECT e.*,o.number order_number,cu.name courier_name FROM public.cash_entries e JOIN public.orders o ON o.id=e.order_id JOIN public.users cu ON cu.id=e.courier_id ORDER BY e.created_at DESC LIMIT 500)x));
END$$;
ALTER FUNCTION public.jana_admin_reports(text) RENAME TO jana_admin_reports_cost_base;
CREATE FUNCTION public.jana_admin_reports(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;
BEGIN r=public.jana_admin_reports_cost_base(p_token);RETURN r||jsonb_build_object('cash_unsettled_halalas',(SELECT coalesce(sum(collected_halalas-settled_halalas-courier_refunded_halalas),0) FROM public.orders));END$$;
ALTER FUNCTION public.jana_deep_health() RENAME TO jana_deep_health_base;
CREATE FUNCTION public.jana_deep_health() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;bad integer;
BEGIN
 r=public.jana_deep_health_base();SELECT count(*) INTO bad FROM public.orders WHERE NOT coalesce(public.jana_cash_matches(id),false);
 RETURN r||jsonb_build_object('ok',(r->>'ok')::boolean AND bad=0,'cash_ledger_mismatches',bad,'cash_invariant_violations',(r->>'cash_invariant_violations')::integer+bad);
END$$;

CREATE OR REPLACE FUNCTION public.jana_critical_write(p_token text,p_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $fn$
DECLARE u public.users; scope_key text; request_hash_value text; prior public.idempotency_records; result jsonb; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);
 IF p_key IS NULL OR length(trim(p_key))<8 OR length(trim(p_key))>128 THEN RAISE EXCEPTION 'invalid_idempotency_key'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'invalid_payload'; END IF;
 IF p_operation IN ('order.confirm','refund.request') THEN
  IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden'; END IF;
 ELSIF p_operation IN ('order.deliver','cod.collect') THEN
  IF u.role NOT IN ('admin','courier') THEN RAISE EXCEPTION 'forbidden'; END IF;
 ELSIF p_operation IN ('cod.settle','refund.create','refund.complete','refund.reject') THEN
  IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden'; END IF;
 ELSE RAISE EXCEPTION 'invalid_operation'; END IF;
 scope_key='critical:'||u.id||':'||trim(p_key);
 request_hash_value=encode(extensions.digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF FOUND THEN
  IF prior.request_hash<>request_hash_value THEN RAISE EXCEPTION 'idempotency_conflict'; END IF;
  RETURN prior.response::jsonb;
 END IF;
 CASE p_operation
  WHEN 'order.confirm' THEN result=public.jana_confirm_order(p_token,p_payload->>'quote_id');
  WHEN 'order.deliver' THEN result=public.jana_ops_transition(p_token,p_payload->>'order_id','deliver',p_payload->>'code');
  WHEN 'cod.collect' THEN result=public.jana_ops_transition(p_token,p_payload->>'order_id','collect',p_payload->>'amount_halalas');
  WHEN 'cod.settle' THEN result=public.jana_finance_settle_amount(p_token,p_payload->>'order_id',(p_payload->>'amount_halalas')::bigint,p_payload->>'reference');
  WHEN 'refund.create' THEN result=public.jana_record_paid_refund(p_token,p_payload->>'order_id',(p_payload->>'amount_halalas')::bigint,p_payload->>'reason',p_payload->>'reference',p_payload->>'payment_source');
  WHEN 'refund.complete' THEN result=public.jana_complete_refund(p_token,p_payload->>'refund_id',p_payload->>'reference',p_payload->>'payment_source');
  WHEN 'refund.reject' THEN result=public.jana_reject_refund(p_token,p_payload->>'refund_id',p_payload->>'reason');
  WHEN 'refund.request' THEN result=public.jana_request_refund(p_token,p_payload->>'order_id',p_payload->>'component_id',(p_payload->>'amount_halalas')::bigint,p_payload->>'reason');
 END CASE;
 -- Preserve committed failed-attempt counters; unsuccessful OTP attempts are not cached as success.
 IF result ? '_error' THEN RETURN result; END IF;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,trim(p_key),request_hash_value,result::json,nowms);
 RETURN result;
END $fn$;
REVOKE ALL ON FUNCTION public.jana_critical_write(text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_critical_write(text,text,text,jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.jana_cash_collection_entry(),public.jana_refund_history_guard(),public.jana_cash_matches(text),public.jana_cash_reconcile_guard(),public.jana_ops_transition_base(text,text,text,text),public.jana_open_refund(text,text,bigint,text,boolean),public.jana_admin_reports_cost_base(text),public.jana_deep_health_base(),public.jana_ops_transition(text,text,text,text),public.jana_request_refund(text,text,text,bigint,text),public.jana_complete_refund(text,text,text,text),public.jana_record_paid_refund(text,text,bigint,text,text,text),public.jana_admin_refund(text,text,bigint,text),public.jana_reject_refund(text,text,text),public.jana_finance_settle_amount(text,text,bigint,text),public.jana_finance_settle(text,text,text),public.jana_admin_orders(text),public.jana_finance_overview(text),public.jana_admin_reports(text),public.jana_deep_health() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_cash_collection_entry(),public.jana_refund_history_guard(),public.jana_cash_matches(text),public.jana_cash_reconcile_guard(),public.jana_ops_transition_base(text,text,text,text),public.jana_open_refund(text,text,bigint,text,boolean),public.jana_admin_reports_cost_base(text),public.jana_deep_health_base() FROM service_role;
GRANT EXECUTE ON FUNCTION public.jana_ops_transition(text,text,text,text),public.jana_request_refund(text,text,text,bigint,text),public.jana_complete_refund(text,text,text,text),public.jana_record_paid_refund(text,text,bigint,text,text,text),public.jana_admin_refund(text,text,bigint,text),public.jana_reject_refund(text,text,text),public.jana_finance_settle_amount(text,text,bigint,text),public.jana_finance_settle(text,text,text),public.jana_admin_orders(text),public.jana_finance_overview(text),public.jana_admin_reports(text),public.jana_deep_health() TO service_role;
