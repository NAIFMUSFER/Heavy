-- Order -> slot -> sorted stock balances -> lots. No inventory changes before customer consent.
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.substitutions WHERE state='pending') THEN
  RAISE EXCEPTION 'pending_legacy_substitutions_require_review';
 END IF;
END $$;
ALTER TABLE public.substitutions ADD COLUMN decided_at bigint;
ALTER TABLE public.substitutions ADD COLUMN decision_result jsonb;
ALTER TABLE public.substitutions DROP CONSTRAINT no_implicit_consent;
ALTER TABLE public.substitutions ADD CONSTRAINT no_implicit_consent CHECK(default_action IN ('remove_entire_line','hold_for_resolution'));
CREATE UNIQUE INDEX jana_one_pending_substitution_per_order ON public.substitutions(order_id) WHERE state='pending';
CREATE TABLE public.picking_line_issues (
 order_id varchar(36) NOT NULL REFERENCES public.orders(id),line_id varchar(36) NOT NULL,
 state text NOT NULL CHECK(state IN ('open','replaced','restored')),reason text NOT NULL CHECK(length(reason) BETWEEN 3 AND 1000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),created_at bigint NOT NULL,updated_at bigint NOT NULL,
 PRIMARY KEY(order_id,line_id)
);
CREATE INDEX jana_picking_issue_actor ON public.picking_line_issues(actor_id);
ALTER TABLE public.picking_line_issues ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.picking_line_issues FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.picking_line_issues TO service_role;

CREATE FUNCTION public.jana_substitution_history_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' OR OLD.state<>'pending' OR
  (to_jsonb(NEW)-ARRAY['state','decided_at','decision_result']) IS DISTINCT FROM
  (to_jsonb(OLD)-ARRAY['state','decided_at','decision_result']) OR
  NEW.state NOT IN ('accepted','rejected','expired') OR NEW.decided_at IS NULL OR NEW.decision_result IS NULL
 THEN RAISE EXCEPTION 'immutable_substitution_history'; END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_substitution_history_guard BEFORE UPDATE OR DELETE ON public.substitutions
 FOR EACH ROW EXECUTE FUNCTION public.jana_substitution_history_guard();

CREATE FUNCTION public.jana_picking_issue(p_token text,p_order_id text,p_line_id text,p_reason text,p_restore boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; o public.orders; before_issue jsonb; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 IF p_restore IS NULL OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'picking_reason_required';END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(o.snapshot::jsonb->'lines') l WHERE l->>'line_id'=p_line_id) THEN RAISE EXCEPTION 'line_not_found';END IF;
 SELECT to_jsonb(i) INTO before_issue FROM public.picking_line_issues i WHERE i.order_id=o.id AND i.line_id=p_line_id;
 IF p_restore AND coalesce(before_issue->>'state','')<>'open' THEN RAISE EXCEPTION 'line_not_unavailable';END IF;
 INSERT INTO public.picking_line_issues(order_id,line_id,state,reason,actor_id,created_at,updated_at)
 VALUES(o.id,p_line_id,CASE WHEN p_restore THEN 'restored' ELSE 'open' END,trim(p_reason),u.id,nowms,nowms)
 ON CONFLICT(order_id,line_id) DO UPDATE SET state=excluded.state,reason=excluded.reason,actor_id=excluded.actor_id,updated_at=excluded.updated_at;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,CASE WHEN p_restore THEN 'picking_original_restored' ELSE 'picking_line_unavailable' END,o.id,
 jsonb_build_object('role',u.role,'line_id',p_line_id,'before',before_issue,'reason',trim(p_reason)),nowms);
 RETURN jsonb_build_object('order_id',o.id,'line_id',p_line_id,'state',CASE WHEN p_restore THEN 'restored' ELSE 'open' END);
END$$;

CREATE OR REPLACE FUNCTION public.jana_propose_substitution(p_token text,p_order_id text,p_line_id text,p_offering_id text,p_qty int DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;po public.offerings;target jsonb;replacement jsonb;identity jsonb;terms jsonb;sid text;subtotal bigint;discount bigint;total bigint;nowms bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 SELECT value INTO target FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WHERE value->>'line_id'=p_line_id;
 IF target IS NULL THEN RAISE EXCEPTION 'line_not_found';END IF;
 SELECT * INTO po FROM public.offerings WHERE id=p_offering_id AND active;
 IF po.id IS NULL OR p_qty IS NULL OR p_qty NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'invalid_substitution';END IF;
 IF po.id=target->>'offering_id' AND p_qty=(target->>'qty')::int THEN RAISE EXCEPTION 'substitution_unchanged';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(po.components::jsonb) c LEFT JOIN public.stock_items st ON st.id=c->>'stock_id' WHERE st.id IS NULL OR NOT st.active) THEN RAISE EXCEPTION 'invalid_substitution';END IF;
 SELECT jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) INTO identity
 FROM public.product_version_offerings m JOIN public.product_versions v ON v.id=m.version_id WHERE m.offering_id=po.id;
 replacement=jsonb_build_object('line_id',p_line_id,'offering_id',po.id,'family_id',po.family_id,'version',po.version,'kind',po.kind,'name',po.name,'size_label',po.size_label,'sale_unit',po.sale_unit,'unit_price_halalas',po.price_halalas,'qty',p_qty,'line_total_halalas',po.price_halalas*p_qty,'components',po.components,'substituted_from',target->>'offering_id')||coalesce(identity,'{}'::jsonb);
 subtotal=(o.snapshot->>'subtotal_halalas')::bigint-(target->>'line_total_halalas')::bigint+po.price_halalas*p_qty;
 discount=public.jana_coupon_discount(o.original_snapshot::jsonb->'coupon',subtotal);
 total=subtotal-discount+(o.snapshot->>'delivery_fee_halalas')::bigint;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;sid='sub-'||replace(gen_random_uuid()::text,'-','');
 terms=jsonb_build_object('offering_id',po.id,'qty',p_qty,'name',po.name,'original_line',target,'replacement_line',replacement,
 'order_snapshot_hash',encode(digest(o.snapshot::jsonb::text,'sha256'),'hex'),'original_total_halalas',o.total_halalas,
 'subtotal_halalas',subtotal,'discount_halalas',discount,'total_halalas',total,'price_difference_halalas',total-o.total_halalas,'inventory_reserved',false);
 PERFORM public.jana_picking_issue(p_token,o.id,p_line_id,'بانتظار بديل يوافق عليه العميل',false);
 INSERT INTO public.substitutions(id,order_id,line_id,component_id,proposed,default_action,state,expires_at,actor_id,created_at)
 VALUES(sid,o.id,p_line_id,po.id,terms,'hold_for_resolution','pending',nowms+900000,u.id,nowms);
 UPDATE public.orders SET fulfillment_state='awaiting_customer' WHERE id=o.id;
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'sub-'||sid,'بديل يحتاج موافقتك','راجع الصنف والكمية والإجمالي الجديد قبل الموافقة. عدم الرد لا يعني الموافقة.',o.id,false,nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'substitution_proposed',p_line_id,jsonb_build_object('substitution_id',sid,'price_difference_halalas',total-o.total_halalas),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'substitution_proposed',sid,jsonb_build_object('role',u.role,'order_id',o.id,'original',target,'proposed',replacement,'price_difference_halalas',total-o.total_halalas),nowms);
 RETURN jsonb_build_object('id',sid,'order_id',o.id,'line_id',p_line_id,'state','pending','expires_at',nowms+900000,'proposed',terms);
END$$;

CREATE FUNCTION public.jana_reallocate_order(p_order_id text,p_lines jsonb,p_actor_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE o public.orders;slot_end bigint;rec record;lotrec record;a jsonb;need bigint;take bigint;allocations jsonb:='[]';nowms bigint;
BEGIN
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.fulfillment_state NOT IN ('picking','awaiting_customer') THEN RAISE EXCEPTION 'invalid_transition';END IF;
 SELECT ends_at INTO slot_end FROM public.delivery_slots WHERE id=o.slot_id FOR UPDATE;
 PERFORM 1 FROM public.stock_balances WHERE stock_id IN (
 SELECT value->>'stock_id' FROM jsonb_array_elements(o.snapshot::jsonb->'allocations')
 UNION SELECT c->>'stock_id' FROM jsonb_array_elements(p_lines) l CROSS JOIN LATERAL jsonb_array_elements(l->'components') c
 ) ORDER BY stock_id FOR UPDATE;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 FOR a IN SELECT value FROM jsonb_array_elements(o.snapshot::jsonb->'allocations') LOOP
  UPDATE public.inventory_lots SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE id=a->>'lot_id' AND stock_id=a->>'stock_id' AND reserved_base>=(a->>'base_qty')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid';END IF;
  UPDATE public.stock_balances SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE stock_id=a->>'stock_id' AND reserved_base>=(a->>'base_qty')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid';END IF;
  INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
  VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),a->>'stock_id',a->>'lot_id',0,-(a->>'base_qty')::bigint,'substitution_reservation_release',o.id,p_actor_id,nowms);
 END LOOP;
 FOR rec IN SELECT c->>'stock_id' stock_id,sum(CASE WHEN jsonb_array_length(l->'components')=1 AND l?'actual_base_qty' THEN (l->>'actual_base_qty')::bigint ELSE (c->>'base_qty')::bigint*(l->>'qty')::bigint END)::bigint required
  FROM jsonb_array_elements(p_lines) l CROSS JOIN LATERAL jsonb_array_elements(l->'components') c GROUP BY c->>'stock_id' ORDER BY c->>'stock_id'
 LOOP
  IF NOT EXISTS(SELECT 1 FROM public.stock_items WHERE id=rec.stock_id AND active) OR NOT EXISTS(SELECT 1 FROM public.stock_balances WHERE stock_id=rec.stock_id AND on_hand_base-reserved_base>=rec.required) THEN RAISE EXCEPTION 'insufficient_stock';END IF;
  need=rec.required;
  FOR lotrec IN SELECT id,on_hand_base-reserved_base available FROM public.inventory_lots WHERE stock_id=rec.stock_id AND inspection_state='accepted' AND expires_at>greatest(nowms,slot_end) AND on_hand_base>reserved_base ORDER BY expires_at,id FOR UPDATE LOOP
   EXIT WHEN need<=0;take=least(need,lotrec.available);
   UPDATE public.inventory_lots SET reserved_base=reserved_base+take WHERE id=lotrec.id;
   allocations=allocations||jsonb_build_array(jsonb_build_object('stock_id',rec.stock_id,'lot_id',lotrec.id,'base_qty',take));
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
   VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),rec.stock_id,lotrec.id,0,take,'substitution_reserved',o.id,p_actor_id,nowms);need=need-take;
  END LOOP;
  IF need>0 THEN RAISE EXCEPTION 'insufficient_lot_stock';END IF;
  UPDATE public.stock_balances SET reserved_base=reserved_base+rec.required WHERE stock_id=rec.stock_id;
 END LOOP;
 RETURN allocations;
END$$;

CREATE OR REPLACE FUNCTION public.jana_decide_substitution(p_token text,p_substitution_id text,p_accept boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;s public.substitutions;o public.orders;oid text;newlines jsonb;allocations jsonb;result jsonb;nowms bigint;
BEGIN
 u=public.jana_auth_user(p_token);
 SELECT order_id INTO oid FROM public.substitutions WHERE id=p_substitution_id;
 SELECT * INTO o FROM public.orders WHERE id=oid AND user_id=u.id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 SELECT * INTO s FROM public.substitutions WHERE id=p_substitution_id FOR UPDATE;
 IF p_accept IS NULL THEN RAISE EXCEPTION 'invalid_substitution_decision';END IF;
 IF s.state IN ('accepted','rejected') THEN
  IF (s.state='accepted') IS DISTINCT FROM p_accept THEN RAISE EXCEPTION 'substitution_already_decided';END IF;
  RETURN s.decision_result;
 END IF;
 IF s.state='expired' THEN RETURN jsonb_build_object('_error','substitution_expired','status',409);END IF;
 IF s.state<>'pending' OR o.status<>'active' OR o.fulfillment_state<>'awaiting_customer' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 IF s.expires_at<=nowms THEN
  result=jsonb_build_object('_error','substitution_expired','status',409);
  UPDATE public.substitutions SET state='expired',decided_at=nowms,decision_result=result WHERE id=s.id;
  UPDATE public.orders SET fulfillment_state='picking' WHERE id=o.id;
 ELSE
  IF p_accept THEN
   IF s.proposed->>'order_snapshot_hash' IS DISTINCT FROM encode(digest(o.snapshot::jsonb::text,'sha256'),'hex') THEN RAISE EXCEPTION 'substitution_terms_changed';END IF;
   SELECT jsonb_agg(CASE WHEN l->>'line_id'=s.line_id THEN s.proposed::jsonb->'replacement_line' ELSE l END ORDER BY n) INTO newlines FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY e(l,n);
   allocations=public.jana_reallocate_order(o.id,newlines,u.id);
   UPDATE public.orders SET snapshot=o.snapshot::jsonb||jsonb_build_object('lines',newlines,'allocations',allocations,'subtotal_halalas',(s.proposed->>'subtotal_halalas')::bigint,'discount_halalas',(s.proposed->>'discount_halalas')::bigint,'total_halalas',(s.proposed->>'total_halalas')::bigint),total_halalas=(s.proposed->>'total_halalas')::bigint WHERE id=o.id;
   IF (SELECT total_halalas FROM public.orders WHERE id=o.id)<>(s.proposed->>'total_halalas')::bigint THEN RAISE EXCEPTION 'substitution_terms_changed';END IF;
   UPDATE public.picking_line_issues SET state='replaced',updated_at=nowms WHERE order_id=o.id AND line_id=s.line_id;
  END IF;
  result=jsonb_build_object('id',s.id,'order_id',o.id,'state',CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,'total_halalas',(SELECT total_halalas FROM public.orders WHERE id=o.id));
  UPDATE public.substitutions SET state=CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,decided_at=nowms,decision_result=result WHERE id=s.id;
  UPDATE public.orders SET fulfillment_state='picking' WHERE id=o.id;
 END IF;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,CASE WHEN s.expires_at<=nowms THEN 'substitution_expired' WHEN p_accept THEN 'substitution_accepted' ELSE 'substitution_rejected' END,s.id,result,nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'substitution_decision',s.id,jsonb_build_object('role',u.role,'before','pending','after',result),nowms);
 RETURN result;
END$$;

CREATE OR REPLACE FUNCTION public.jana_my_substitutions(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id=p_order_id AND user_id=u.id) THEN RAISE EXCEPTION 'order_not_found';END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'line_id',line_id,'proposed',proposed,'state',state,'expires_at',expires_at,'created_at',created_at,'decided_at',decided_at) ORDER BY created_at DESC) FROM public.substitutions WHERE order_id=p_order_id),'[]'::jsonb);
END$$;

CREATE OR REPLACE FUNCTION public.jana_expire_substitutions()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE o public.orders;s public.substitutions;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;n int:=0;
BEGIN
 FOR o IN SELECT * FROM public.orders WHERE id IN(SELECT order_id FROM public.substitutions WHERE state='pending' AND expires_at<=nowms) ORDER BY id FOR UPDATE SKIP LOCKED LOOP
  FOR s IN SELECT * FROM public.substitutions WHERE order_id=o.id AND state='pending' AND expires_at<=nowms FOR UPDATE LOOP
   UPDATE public.substitutions SET state='expired',decided_at=nowms,decision_result=jsonb_build_object('_error','substitution_expired','status',409) WHERE id=s.id;
   IF o.status='active' AND o.fulfillment_state='awaiting_customer' THEN UPDATE public.orders SET fulfillment_state='picking' WHERE id=o.id;END IF;
   INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
   VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'sub-expired-'||s.id,'انتهت مهلة البديل','لم يُعتمد البديل. يظل الصنف بحاجة إلى معالجة من فريق التجهيز.',o.id,false,nowms);
   INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
   VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,null,'substitution_expired',s.id,jsonb_build_object('line_id',s.line_id,'requires_resolution',true),nowms);n=n+1;
  END LOOP;
 END LOOP;
 RETURN n;
END$$;
CREATE OR REPLACE FUNCTION public.jana_expiry_worker()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE q integer;s integer;detail jsonb;nowms bigint;
BEGIN
 q=public.jana_expire_quotes();s=public.jana_expire_substitutions();nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 detail=jsonb_build_object('quotes_expired',q,'substitutions_expired',s,'ran_at',nowms);
 INSERT INTO public.worker_runs(name,last_success_at,detail) VALUES('quote_expiry',nowms,detail)
 ON CONFLICT(name) DO UPDATE SET last_success_at=excluded.last_success_at,detail=excluded.detail;
 RETURN detail;
END$$;

ALTER FUNCTION public.jana_finalize_picking(text,text) RENAME TO jana_finalize_picking_base;
CREATE FUNCTION public.jana_finalize_picking(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF EXISTS(SELECT 1 FROM public.picking_line_issues WHERE order_id=o.id AND state='open') OR EXISTS(SELECT 1 FROM public.substitutions WHERE order_id=o.id AND state='pending') THEN RAISE EXCEPTION 'unresolved_picking_items';END IF;
 RETURN public.jana_finalize_picking_base(p_token,p_order_id);
END$$;

CREATE FUNCTION public.jana_picking_detail(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 RETURN jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'fulfillment_state',o.fulfillment_state,'snapshot',o.snapshot,'total_halalas',o.total_halalas,
 'issues',coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM public.picking_line_issues i WHERE order_id=o.id),'[]'::jsonb),
 'substitutions',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY created_at DESC) FROM public.substitutions s WHERE order_id=o.id),'[]'::jsonb));
END$$;

CREATE FUNCTION public.jana_picking_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;oid text;key_scope text;req_hash text;prior public.idempotency_records;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF p_operation NOT IN ('substitution.propose','substitution.decide','line.unavailable','line.restore','line.actual','picking.finish') OR p_operation IS NULL THEN RAISE EXCEPTION 'invalid_operation';END IF;
 IF p_operation<>'substitution.decide' AND u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation='substitution.decide' THEN SELECT order_id INTO oid FROM public.substitutions WHERE id=p_payload->>'substitution_id';ELSE oid=p_payload->>'order_id';END IF;
 SELECT * INTO o FROM public.orders WHERE id=oid;
 IF o.id IS NULL OR (p_operation='substitution.decide' AND o.user_id<>u.id) THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF p_operation<>'substitution.decide' AND u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 key_scope='picking:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(key_scope,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=key_scope;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 CASE p_operation
 WHEN 'substitution.propose' THEN result=public.jana_propose_substitution(p_token,oid,p_payload->>'line_id',p_payload->>'offering_id',(p_payload->>'qty')::int);
 WHEN 'substitution.decide' THEN
  IF jsonb_typeof(p_payload->'accept') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'invalid_substitution_decision';END IF;
  result=public.jana_decide_substitution(p_token,p_payload->>'substitution_id',(p_payload->>'accept')::boolean);
 WHEN 'line.unavailable' THEN result=public.jana_picking_issue(p_token,oid,p_payload->>'line_id',p_payload->>'reason',false);
 WHEN 'line.restore' THEN result=public.jana_picking_issue(p_token,oid,p_payload->>'line_id',p_payload->>'reason',true);
 WHEN 'line.actual' THEN
  IF EXISTS(SELECT 1 FROM public.picking_line_issues WHERE order_id=oid AND line_id=p_payload->>'line_id' AND state='open') THEN RAISE EXCEPTION 'unresolved_picking_items';END IF;
  result=public.jana_picker_record_actual(p_token,oid,p_payload->>'line_id',(p_payload->>'actual_base')::bigint);
 WHEN 'picking.finish' THEN result=public.jana_finalize_picking(p_token,oid);
 END CASE;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(key_scope,u.id,p_idem_key,req_hash,result,(extract(epoch from clock_timestamp())*1000)::bigint);
 RETURN result;
END$$;

DO $privs$ DECLARE r record;BEGIN
 FOR r IN SELECT oid::regprocedure sig,proname FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=ANY(ARRAY['jana_substitution_history_guard','jana_picking_issue','jana_propose_substitution','jana_reallocate_order','jana_decide_substitution','jana_my_substitutions','jana_expire_substitutions','jana_expiry_worker','jana_finalize_picking','jana_finalize_picking_base','jana_picking_detail','jana_picking_write']) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.sig);
  IF r.proname IN ('jana_substitution_history_guard','jana_reallocate_order','jana_finalize_picking_base') THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role',r.sig);
  ELSE EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',r.sig);END IF;
 END LOOP;
END $privs$;

-- Inventory adjustments acquire the same balance lock before touching a reserved lot.
create or replace function public.jana_inventory_adjust_lot(p_token text,p_lot_id text,p_new_on_hand bigint,p_reason text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; l public.inventory_lots; d bigint; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 perform 1 from public.stock_balances where stock_id=(select stock_id from public.inventory_lots where id=p_lot_id) for update;
 select * into l from public.inventory_lots where id=p_lot_id for update; if l.id is null then raise exception 'lot_not_found'; end if;
 if p_new_on_hand is null or l.inspection_state<>'accepted' or p_new_on_hand<l.reserved_base or p_new_on_hand<0 or length(trim(coalesce(p_reason,'')))<3 then raise exception 'validation'; end if;
 d=p_new_on_hand-l.on_hand_base; if d=0 then return jsonb_build_object('id',l.id,'on_hand_base',l.on_hand_base,'delta',0); end if;
 update public.inventory_lots set on_hand_base=p_new_on_hand where id=l.id;
 update public.stock_balances set on_hand_base=on_hand_base+d where stock_id=l.stock_id;
 insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),l.stock_id,l.id,d,0,'count_adjustment',left(trim(p_reason),200),u.id,nowms);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'inventory_adjustment',l.id,jsonb_build_object('old_on_hand',l.on_hand_base,'new_on_hand',p_new_on_hand,'delta',d,'reason',left(trim(p_reason),200)),nowms);
 return jsonb_build_object('id',l.id,'on_hand_base',p_new_on_hand,'delta',d);
end$$;


-- Recheck unavailable state while holding the order lock even for legacy callers.
ALTER FUNCTION public.jana_picker_record_actual(text,text,text,bigint) RENAME TO jana_picker_record_actual_base;
CREATE FUNCTION public.jana_picker_record_actual(p_token text,p_order_id text,p_line_id text,p_actual_base bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF p_actual_base IS NULL THEN RAISE EXCEPTION 'invalid_actual_weight';END IF;
 IF EXISTS(SELECT 1 FROM public.picking_line_issues WHERE order_id=o.id AND line_id=p_line_id AND state='open') THEN RAISE EXCEPTION 'unresolved_picking_items';END IF;
 RETURN public.jana_picker_record_actual_base(p_token,p_order_id,p_line_id,p_actual_base);
END$$;
REVOKE ALL ON FUNCTION public.jana_picker_record_actual(text,text,text,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_picker_record_actual_base(text,text,text,bigint) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.jana_picker_record_actual(text,text,text,bigint) TO service_role;
