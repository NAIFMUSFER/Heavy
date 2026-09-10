-- Physical customer/courier returns remain outside sellable balances until inspection.
-- A return never records a refund, COD collection or settlement.
CREATE TABLE public.customer_return_receipts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 order_id varchar(36) NOT NULL REFERENCES public.orders(id),
 source_movement_id varchar(36) NOT NULL REFERENCES public.stock_movements(id),
 stock_id varchar(36) NOT NULL REFERENCES public.stock_items(id),
 lot_id varchar(36) NOT NULL REFERENCES public.inventory_lots(id),
 quantity_base bigint NOT NULL CHECK(quantity_base BETWEEN 1 AND 9000000000000),
 reference text NOT NULL CHECK(length(reference) BETWEEN 1 AND 180),
 reason text NOT NULL CHECK(length(reason) BETWEEN 3 AND 1000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),actor_role text NOT NULL CHECK(actor_role IN ('admin','inventory')),
 movement_id varchar(36) NOT NULL UNIQUE REFERENCES public.stock_movements(id),created_at bigint NOT NULL,
 UNIQUE(source_movement_id,reference)
);
CREATE INDEX jana_customer_returns_page ON public.customer_return_receipts(created_at DESC,id DESC);
CREATE INDEX jana_customer_returns_order ON public.customer_return_receipts(order_id,created_at DESC);
CREATE TABLE public.customer_return_inspections(
 return_id uuid PRIMARY KEY REFERENCES public.customer_return_receipts(id),
 accepted_base bigint NOT NULL CHECK(accepted_base>=0),rejected_base bigint NOT NULL CHECK(rejected_base>=0),
 note text NOT NULL CHECK(length(note) BETWEEN 3 AND 1000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),actor_role text NOT NULL CHECK(actor_role IN ('admin','inventory')),
 movement_id varchar(36) NOT NULL UNIQUE REFERENCES public.stock_movements(id) DEFERRABLE INITIALLY DEFERRED,
 before_on_hand bigint NOT NULL CHECK(before_on_hand>=0),after_on_hand bigint NOT NULL CHECK(after_on_hand>=0),
 restored_cost_halalas bigint CHECK(restored_cost_halalas>=0),cost_basis text CHECK(cost_basis IN ('recorded','estimated','unknown')),
 created_at bigint NOT NULL,
 CHECK(accepted_base+rejected_base>0),CHECK(after_on_hand-before_on_hand=accepted_base),
 CHECK((accepted_base=0 AND restored_cost_halalas IS NULL AND cost_basis IS NULL) OR
  (accepted_base>0 AND cost_basis IS NOT NULL AND ((cost_basis='unknown')=(restored_cost_halalas IS NULL))))
);
ALTER TABLE public.customer_return_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_return_inspections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_return_receipts,public.customer_return_inspections FROM PUBLIC,anon,authenticated;
CREATE TRIGGER jana_immutable_customer_return_receipts BEFORE UPDATE OR DELETE ON public.customer_return_receipts FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();
CREATE TRIGGER jana_immutable_customer_return_inspections BEFORE UPDATE OR DELETE ON public.customer_return_inspections FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_customer_return_receive(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;m public.stock_movements;o public.orders;prev public.idempotency_records;
 k text;h text;qty bigint;received bigint;ref text;why text;result jsonb;rid uuid:=gen_random_uuid();
 mid text:='mov-'||replace(gen_random_uuid()::text,'-','');nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'return_validation';END IF;
 k='customer-return-receive:'||u.id||':'||p_idem_key;h=encode(digest(p_payload::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(k,0));
 SELECT * INTO prev FROM public.idempotency_records WHERE scope=k;
 IF prev.scope IS NOT NULL THEN IF prev.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prev.response::jsonb;END IF;
 IF jsonb_typeof(p_payload->'source_movement_id') IS DISTINCT FROM 'string' OR length(p_payload->>'source_movement_id') NOT BETWEEN 1 AND 36
 OR jsonb_typeof(p_payload->'quantity_base') IS DISTINCT FROM 'number' OR (p_payload->>'quantity_base')!~'^[0-9]{1,13}$'
 OR jsonb_typeof(p_payload->'reference') IS DISTINCT FROM 'string' OR jsonb_typeof(p_payload->'reason') IS DISTINCT FROM 'string'
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) x WHERE x NOT IN ('source_movement_id','quantity_base','reference','reason')) THEN RAISE EXCEPTION 'return_validation';END IF;
 qty=(p_payload->>'quantity_base')::bigint;ref=trim(p_payload->>'reference');why=trim(p_payload->>'reason');
 IF qty NOT BETWEEN 1 AND 9000000000000 OR length(ref) NOT BETWEEN 1 AND 180 OR length(why) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'return_validation';END IF;
 -- Serializes physical receipts for this exact original outbound allocation. No usable stock changes here.
 SELECT * INTO m FROM public.stock_movements WHERE id=p_payload->>'source_movement_id';
 IF m.id IS NULL OR m.reason<>'order_picked' OR m.on_hand_delta>=0 OR m.lot_id IS NULL THEN RAISE EXCEPTION 'return_source_invalid';END IF;
 SELECT * INTO o FROM public.orders WHERE id=m.reference FOR UPDATE;
 PERFORM 1 FROM public.stock_movements WHERE id=m.id FOR UPDATE;
 IF o.id IS NULL OR o.fulfillment_state<>'ready' OR o.delivery_state NOT IN ('delivered','failed') THEN RAISE EXCEPTION 'return_order_ineligible';END IF;
 IF EXISTS(SELECT 1 FROM public.customer_return_receipts WHERE source_movement_id=m.id AND reference=ref) THEN RAISE EXCEPTION 'return_reference_exists';END IF;
 SELECT coalesce(sum(quantity_base),0) INTO received FROM public.customer_return_receipts WHERE source_movement_id=m.id;
 IF qty>(-m.on_hand_delta)-received THEN RAISE EXCEPTION 'return_exceeds_shipped';END IF;
 INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
 VALUES(mid,m.stock_id,m.lot_id,0,0,'customer_return_received',rid::text,u.id,nowms);
 INSERT INTO public.customer_return_receipts(id,order_id,source_movement_id,stock_id,lot_id,quantity_base,reference,reason,actor_id,actor_role,movement_id,created_at)
 VALUES(rid,o.id,m.id,m.stock_id,m.lot_id,qty,ref,why,u.id,u.role,mid,nowms);
 result=jsonb_build_object('id',rid,'order_id',o.id,'order_number',o.number,'lot_id',m.lot_id,'stock_id',m.stock_id,'quantity_base',qty,'state','pending','reference',ref,'movement_id',mid,'created_at',nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'customer_return_received',rid::text,jsonb_build_object('entity_type','customer_return','role',u.role,'reason',why,'after',result,'source_movement_id',m.id),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(k,u.id,p_idem_key,h,result,nowms);
 RETURN result;
END$$;

CREATE FUNCTION public.jana_customer_return_inspect(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;r public.customer_return_receipts;l public.inventory_lots;m public.stock_movements;c public.inventory_cost_entries;prev public.idempotency_records;
 k text;h text;accepted bigint;previously_accepted bigint;cost bigint;basis text;note text;result jsonb;rid uuid;
 mid text:='mov-'||replace(gen_random_uuid()::text,'-','');nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'return_validation';END IF;
 k='customer-return-inspect:'||u.id||':'||p_idem_key;h=encode(digest(p_payload::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(k,0));
 SELECT * INTO prev FROM public.idempotency_records WHERE scope=k;
 IF prev.scope IS NOT NULL THEN IF prev.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prev.response::jsonb;END IF;
 IF jsonb_typeof(p_payload->'return_id') IS DISTINCT FROM 'string' OR (p_payload->>'return_id')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 OR jsonb_typeof(p_payload->'accepted_base') IS DISTINCT FROM 'number' OR (p_payload->>'accepted_base')!~'^[0-9]{1,13}$'
 OR jsonb_typeof(p_payload->'note') IS DISTINCT FROM 'string'
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) x WHERE x NOT IN ('return_id','accepted_base','note')) THEN RAISE EXCEPTION 'return_validation';END IF;
 rid=(p_payload->>'return_id')::uuid;accepted=(p_payload->>'accepted_base')::bigint;note=trim(p_payload->>'note');
 IF accepted>9000000000000 OR length(note) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'return_validation';END IF;
 SELECT * INTO r FROM public.customer_return_receipts WHERE id=rid;
 IF r.id IS NULL THEN RAISE EXCEPTION 'return_not_found';END IF;
 -- Same balance-first ordering as reservation/counts/disposal, then source and lot.
 PERFORM 1 FROM public.stock_balances WHERE stock_id=r.stock_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid';END IF;
 SELECT * INTO m FROM public.stock_movements WHERE id=r.source_movement_id FOR UPDATE;
 SELECT * INTO l FROM public.inventory_lots WHERE id=r.lot_id FOR UPDATE;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 IF EXISTS(SELECT 1 FROM public.customer_return_inspections WHERE return_id=rid) THEN RAISE EXCEPTION 'return_already_inspected';END IF;
 IF accepted>r.quantity_base THEN RAISE EXCEPTION 'return_validation';END IF;
 IF accepted>0 AND (l.inspection_state<>'accepted' OR (l.expires_at IS NOT NULL AND l.expires_at<=nowms)) THEN RAISE EXCEPTION 'return_lot_not_restockable';END IF;
 IF accepted>0 THEN
  SELECT * INTO c FROM public.inventory_cost_entries WHERE movement_id=m.id;
  IF c.id IS NOT NULL AND (c.quantity_delta<>m.on_hand_delta OR c.lot_id<>r.lot_id OR c.stock_id<>r.stock_id OR c.order_id IS DISTINCT FROM r.order_id) THEN RAISE EXCEPTION 'return_cost_source_invalid';END IF;
  basis=coalesce(c.cost_basis,'unknown');
  SELECT coalesce(sum(i.accepted_base),0) INTO previously_accepted FROM public.customer_return_inspections i JOIN public.customer_return_receipts x ON x.id=i.return_id WHERE x.source_movement_id=m.id;
  IF basis<>'unknown' THEN
   -- Cumulative rounding restores no more than the original recorded consumption cost, exactly at full return.
   cost=round((-c.value_delta_halalas)::numeric*(previously_accepted+accepted)/(-m.on_hand_delta))::bigint-round((-c.value_delta_halalas)::numeric*previously_accepted/(-m.on_hand_delta))::bigint;
  END IF;
 END IF;
 INSERT INTO public.customer_return_inspections(return_id,accepted_base,rejected_base,note,actor_id,actor_role,movement_id,before_on_hand,after_on_hand,restored_cost_halalas,cost_basis,created_at)
 VALUES(rid,accepted,r.quantity_base-accepted,note,u.id,u.role,mid,l.on_hand_base,l.on_hand_base+accepted,cost,basis,nowms);
 IF accepted>0 THEN
  UPDATE public.inventory_lots SET on_hand_base=on_hand_base+accepted WHERE id=l.id;
  UPDATE public.stock_balances SET on_hand_base=on_hand_base+accepted WHERE stock_id=r.stock_id;
 END IF;
 INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
 VALUES(mid,r.stock_id,r.lot_id,accepted,0,CASE WHEN accepted>0 THEN 'customer_return_accepted' ELSE 'customer_return_rejected' END,rid::text,u.id,nowms);
 result=jsonb_build_object('id',rid,'accepted_base',accepted,'rejected_base',r.quantity_base-accepted,'restored_cost_halalas',cost,'cost_basis',basis,'before_on_hand',l.on_hand_base,'after_on_hand',l.on_hand_base+accepted,'movement_id',mid,'state','inspected','created_at',nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'customer_return_inspected',rid::text,jsonb_build_object('entity_type','customer_return','role',u.role,'note',note,'before',jsonb_build_object('state','pending'),'after',result),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(k,u.id,p_idem_key,h,result,nowms);
 RETURN result;
END$$;

CREATE FUNCTION public.jana_customer_return_context(p_token text,p_order_number text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;o public.orders;items jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_order_number=trim(coalesce(p_order_number,''));IF length(p_order_number) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'return_validation';END IF;
 SELECT * INTO o FROM public.orders WHERE number=p_order_number;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF o.fulfillment_state<>'ready' OR o.delivery_state NOT IN ('delivered','failed') THEN RAISE EXCEPTION 'return_order_ineligible';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('source_movement_id',m.id,'lot_id',m.lot_id,'stock_id',m.stock_id,'stock_name',s.name,'base_unit',s.base_unit,'shipped_base',-m.on_hand_delta,'received_return_base',coalesce(r.qty,0),'returnable_base',-m.on_hand_delta-coalesce(r.qty,0),'expires_at',l.expires_at,'receipt_reference',l.receipt_reference) ORDER BY m.created_at,m.id),'[]') INTO items
 FROM public.stock_movements m JOIN public.stock_items s ON s.id=m.stock_id JOIN public.inventory_lots l ON l.id=m.lot_id
 LEFT JOIN (SELECT source_movement_id,sum(quantity_base) qty FROM public.customer_return_receipts WHERE order_id=o.id GROUP BY source_movement_id) r ON r.source_movement_id=m.id
 WHERE m.reason='order_picked' AND m.reference=o.id AND m.on_hand_delta<0;
 RETURN jsonb_build_object('order_id',o.id,'number',o.number,'delivery_state',o.delivery_state,'items',items);
END$$;

CREATE FUNCTION public.jana_customer_returns(p_token text,p_before_at bigint DEFAULT NULL,p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;rows jsonb;cursor_row jsonb;summary jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory','finance','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 THEN RAISE EXCEPTION 'return_validation';END IF;
 WITH page AS(SELECT * FROM public.customer_return_receipts WHERE p_before_at IS NULL OR (created_at,id)<(p_before_at,p_before_id) ORDER BY created_at DESC,id DESC LIMIT 51)
 SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('stock_name',s.name,'base_unit',s.base_unit,'order_number',o.number,'actor_name',a.name,'expires_at',l.expires_at,'inspection',CASE WHEN i.return_id IS NOT NULL THEN (CASE WHEN u.role='support' THEN to_jsonb(i)-'restored_cost_halalas'-'cost_basis' ELSE to_jsonb(i) END)||jsonb_build_object('actor_name',ia.name) ELSE NULL END) ORDER BY r.created_at DESC,r.id DESC),'[]') INTO rows
 FROM page r JOIN public.stock_items s ON s.id=r.stock_id JOIN public.inventory_lots l ON l.id=r.lot_id JOIN public.orders o ON o.id=r.order_id JOIN public.users a ON a.id=r.actor_id LEFT JOIN public.customer_return_inspections i ON i.return_id=r.id LEFT JOIN public.users ia ON ia.id=i.actor_id;
 IF jsonb_array_length(rows)>50 THEN cursor_row=rows->49;rows=rows-50;END IF;
 SELECT jsonb_build_object('pending_receipts',count(*) FILTER(WHERE i.return_id IS NULL),'inspected_receipts',count(*) FILTER(WHERE i.return_id IS NOT NULL),'rejected_receipts',count(*) FILTER(WHERE i.rejected_base>0)) INTO summary FROM public.customer_return_receipts r LEFT JOIN public.customer_return_inspections i ON i.return_id=r.id;
 RETURN jsonb_build_object('items',rows,'summary',summary,'next',CASE WHEN cursor_row IS NULL THEN NULL ELSE jsonb_build_object('before_at',cursor_row->'created_at','before_id',cursor_row->'id') END);
END$$;
REVOKE ALL ON FUNCTION public.jana_customer_return_receive(text,text,jsonb),public.jana_customer_return_inspect(text,text,jsonb),public.jana_customer_return_context(text,text),public.jana_customer_returns(text,bigint,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_customer_return_receive(text,text,jsonb),public.jana_customer_return_inspect(text,text,jsonb),public.jana_customer_return_context(text,text),public.jana_customer_returns(text,bigint,uuid) TO service_role;

-- Restore the cost of the actual original shipment, rather than pricing returned units as found stock.
CREATE OR REPLACE FUNCTION public.jana_post_inventory_cost()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE l public.inventory_lots; previous_qty bigint; cost_delta bigint; basis text; oid varchar(36); ri public.customer_return_inspections; rr public.customer_return_receipts;
BEGIN
 IF NEW.on_hand_delta=0 OR NEW.lot_id IS NULL THEN RETURN NEW; END IF;
 SELECT * INTO l FROM public.inventory_lots WHERE id=NEW.lot_id FOR UPDATE;
 IF l.id IS NULL OR l.stock_id IS DISTINCT FROM NEW.stock_id THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
 previous_qty=l.on_hand_base-NEW.on_hand_delta;basis=l.cost_basis;
 IF NEW.reason='customer_return_accepted' THEN
  SELECT * INTO ri FROM public.customer_return_inspections WHERE movement_id=NEW.id;
  SELECT * INTO rr FROM public.customer_return_receipts WHERE id=ri.return_id;
  IF rr.id IS NULL OR rr.lot_id<>NEW.lot_id OR rr.stock_id<>NEW.stock_id OR ri.accepted_base<>NEW.on_hand_delta THEN RAISE EXCEPTION 'return_cost_source_invalid';END IF;
  cost_delta=ri.restored_cost_halalas;basis=ri.cost_basis;oid=rr.order_id;
  UPDATE public.inventory_lots SET
   remaining_cost_halalas=CASE WHEN previous_qty=0 THEN cost_delta WHEN remaining_cost_halalas IS NULL OR cost_delta IS NULL THEN NULL ELSE remaining_cost_halalas+cost_delta END,
   cost_basis=CASE WHEN previous_qty=0 THEN basis WHEN remaining_cost_halalas IS NULL OR cost_delta IS NULL THEN 'unknown' WHEN cost_basis='estimated' OR basis='estimated' THEN 'estimated' ELSE 'recorded' END
  WHERE id=l.id;
 ELSIF NEW.reason='goods_receipt_accepted' THEN
  cost_delta=l.remaining_cost_halalas;
 ELSE
  IF l.remaining_cost_halalas IS NULL THEN cost_delta=NULL;basis='unknown';
  ELSIF NEW.on_hand_delta<0 THEN
   IF previous_qty<=0 THEN RAISE EXCEPTION 'inventory_cost_invalid'; END IF;
   cost_delta=-least(l.remaining_cost_halalas,round(l.remaining_cost_halalas::numeric*(-NEW.on_hand_delta)/previous_qty)::bigint);
  ELSE
   -- Found stock is valued as an estimate and is never presented as an additional invoice.
   basis='estimated';
   IF previous_qty>0 THEN cost_delta=round(l.remaining_cost_halalas::numeric*NEW.on_hand_delta/previous_qty)::bigint;
   ELSIF l.total_cost_halalas IS NOT NULL THEN cost_delta=round(l.total_cost_halalas::numeric*NEW.on_hand_delta/l.received_base)::bigint;
   ELSE cost_delta=NULL;basis='unknown';END IF;
  END IF;
  UPDATE public.inventory_lots SET remaining_cost_halalas=CASE WHEN cost_delta IS NULL THEN NULL ELSE remaining_cost_halalas+cost_delta END,cost_basis=basis WHERE id=l.id;
 END IF;
 IF NEW.reason='order_picked' THEN oid=NEW.reference; END IF;
 INSERT INTO public.inventory_cost_entries(movement_id,lot_id,stock_id,order_id,quantity_delta,value_delta_halalas,cost_basis,created_at)
 VALUES(NEW.id,l.id,l.stock_id,oid,NEW.on_hand_delta,cost_delta,basis,NEW.created_at);
 RETURN NEW;
END$$;

-- A failed shipment physically received back cannot be dispatched again as though nothing returned.
CREATE FUNCTION public.jana_return_redispatch_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.delivery_state='out_for_delivery' AND OLD.delivery_state IS DISTINCT FROM NEW.delivery_state
 AND EXISTS(SELECT 1 FROM public.customer_return_receipts WHERE order_id=NEW.id) THEN RAISE EXCEPTION 'return_requires_resolution';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_return_redispatch_guard BEFORE UPDATE OF delivery_state ON public.orders FOR EACH ROW EXECUTE FUNCTION public.jana_return_redispatch_guard();
REVOKE ALL ON FUNCTION public.jana_return_redispatch_guard() FROM PUBLIC,anon,authenticated,service_role;

CREATE INDEX jana_customer_returns_stock ON public.customer_return_receipts(stock_id);
CREATE INDEX jana_customer_returns_lot ON public.customer_return_receipts(lot_id);
CREATE INDEX jana_customer_returns_actor ON public.customer_return_receipts(actor_id);
CREATE INDEX jana_return_inspections_actor ON public.customer_return_inspections(actor_id);

-- Preserve physical return document lookup in the general movement ledger.
CREATE OR REPLACE FUNCTION public.jana_stock_movement_history(p_token text,p_filters jsonb DEFAULT '{}'::jsonb,p_before_at bigint DEFAULT NULL,p_before_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;rows jsonb;cursor_row jsonb;k text;from_ms bigint;to_ms bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_filters) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 FOR k IN SELECT jsonb_object_keys(p_filters) LOOP
  IF k NOT IN ('stock_id','lot_id','reason','reference','from_at','to_at') OR jsonb_typeof(p_filters->k) IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
  IF length(p_filters->>k) NOT BETWEEN 1 AND (CASE WHEN k IN ('stock_id','lot_id') THEN 36 WHEN k IN ('from_at','to_at') THEN 15 ELSE 180 END) THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 END LOOP;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 OR length(p_before_id) NOT BETWEEN 1 AND 36 THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 IF (p_filters ? 'from_at' AND p_filters->>'from_at'!~'^[0-9]{1,15}$') OR (p_filters ? 'to_at' AND p_filters->>'to_at'!~'^[0-9]{1,15}$') THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 from_ms=(p_filters->>'from_at')::bigint;to_ms=(p_filters->>'to_at')::bigint;
 IF from_ms IS NOT NULL AND to_ms IS NOT NULL AND from_ms>=to_ms THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 WITH page AS (
  SELECT m.*,coalesce(d.reference,r.reference,rr.reference) AS document_reference,d.reason AS disposal_reason,coalesce(r.reason,rr.reason) AS return_reason FROM public.stock_movements m
  LEFT JOIN public.inventory_disposals d ON d.movement_id=m.id
  LEFT JOIN public.customer_return_inspections ri ON ri.movement_id=m.id
  LEFT JOIN public.customer_return_receipts r ON r.id=ri.return_id
  LEFT JOIN public.customer_return_receipts rr ON rr.movement_id=m.id
  WHERE (p_before_at IS NULL OR (m.created_at,m.id)<(p_before_at,p_before_id))
  AND (NOT p_filters ? 'stock_id' OR m.stock_id=p_filters->>'stock_id')
  AND (NOT p_filters ? 'lot_id' OR m.lot_id=p_filters->>'lot_id')
  AND (NOT p_filters ? 'reason' OR m.reason=p_filters->>'reason')
  AND (NOT p_filters ? 'reference' OR m.reference=p_filters->>'reference' OR d.reference=p_filters->>'reference' OR r.reference=p_filters->>'reference' OR rr.reference=p_filters->>'reference')
  AND (from_ms IS NULL OR m.created_at>=from_ms) AND (to_ms IS NULL OR m.created_at<to_ms)
  ORDER BY m.created_at DESC,m.id DESC LIMIT 51
 )
 SELECT coalesce(jsonb_agg(to_jsonb(m)||jsonb_build_object('stock_name',s.name,'base_unit',s.base_unit,'actor_name',actor.name,
 'value_delta_halalas',c.value_delta_halalas,'cost_basis',c.cost_basis,'has_cost_entry',c.id IS NOT NULL) ORDER BY m.created_at DESC,m.id DESC),'[]'::jsonb)
 INTO rows FROM page m JOIN public.stock_items s ON s.id=m.stock_id LEFT JOIN public.users actor ON actor.id=m.actor_id
 LEFT JOIN public.inventory_cost_entries c ON c.movement_id=m.id;
 IF jsonb_array_length(rows)>50 THEN cursor_row=rows->49;rows=rows-50;END IF;
 RETURN jsonb_build_object('items',rows,'next',CASE WHEN cursor_row IS NULL THEN NULL ELSE jsonb_build_object('before_at',cursor_row->'created_at','before_id',cursor_row->'id') END);
END$$;
REVOKE ALL ON FUNCTION public.jana_stock_movement_history(text,jsonb,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_stock_movement_history(text,jsonb,bigint,text) TO service_role;
