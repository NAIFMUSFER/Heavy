-- Typed, immutable outbound inventory records. Existing stock and costs are not backfilled.
CREATE TABLE public.inventory_disposals(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 lot_id varchar(36) NOT NULL REFERENCES public.inventory_lots(id),
 stock_id varchar(36) NOT NULL REFERENCES public.stock_items(id),
 kind text NOT NULL CHECK(kind IN ('waste','damage','supplier_return')),
 quantity_base bigint NOT NULL CHECK(quantity_base>0),
 reason text NOT NULL CHECK(length(reason) BETWEEN 3 AND 1000),
 reference text NOT NULL CHECK(length(reference) BETWEEN 1 AND 180),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),
 actor_role text NOT NULL CHECK(actor_role IN ('admin','inventory')),
 before_on_hand bigint NOT NULL,after_on_hand bigint NOT NULL CHECK(after_on_hand>=0),
 movement_id varchar(36) NOT NULL UNIQUE REFERENCES public.stock_movements(id),
 created_at bigint NOT NULL,
 CHECK(before_on_hand-after_on_hand=quantity_base),
 UNIQUE(lot_id,kind,reference)
);
CREATE INDEX jana_disposals_page ON public.inventory_disposals(created_at DESC,id DESC);
ALTER TABLE public.inventory_disposals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_disposals FROM PUBLIC,anon,authenticated;
CREATE TRIGGER jana_immutable_disposals BEFORE UPDATE OR DELETE ON public.inventory_disposals
 FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_inventory_dispose(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;l public.inventory_lots;previous public.idempotency_records;result jsonb;
 scope_key text;request_hash text;qty bigint;expected_revision bigint;event_kind text;event_reason text;event_reference text;
 mid text:='mov-'||replace(gen_random_uuid()::text,'-','');did uuid:=gen_random_uuid();nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'disposal_validation';END IF;
 scope_key='inventory-disposal:'||u.id||':'||p_idem_key;
 request_hash=encode(digest(p_payload::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO previous FROM public.idempotency_records WHERE scope=scope_key;
 IF previous.scope IS NOT NULL THEN IF previous.request_hash<>request_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN previous.response::jsonb;END IF;
 IF jsonb_typeof(p_payload->'quantity_base') IS DISTINCT FROM 'number' OR (p_payload->>'quantity_base')!~'^[0-9]{1,13}$'
 OR jsonb_typeof(p_payload->'revision') IS DISTINCT FROM 'number' OR (p_payload->>'revision')!~'^[0-9]{1,15}$'
 OR jsonb_typeof(p_payload->'lot_id') IS DISTINCT FROM 'string' OR length(p_payload->>'lot_id') NOT BETWEEN 1 AND 36
 OR jsonb_typeof(p_payload->'kind') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p_payload->'reason') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p_payload->'reference') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'disposal_validation';END IF;
 qty=(p_payload->>'quantity_base')::bigint;expected_revision=(p_payload->>'revision')::bigint;
 event_kind=p_payload->>'kind';event_reason=trim(p_payload->>'reason');event_reference=trim(p_payload->>'reference');
 IF qty NOT BETWEEN 1 AND 9000000000000 OR expected_revision<0 OR event_kind NOT IN ('waste','damage','supplier_return')
 OR length(event_reason) NOT BETWEEN 3 AND 1000 OR length(event_reference) NOT BETWEEN 1 AND 180 THEN RAISE EXCEPTION 'disposal_validation';END IF;
 -- Same balance-first lock order as reservation, FEFO picking and physical count approval.
 PERFORM 1 FROM public.stock_balances WHERE stock_id=(SELECT stock_id FROM public.inventory_lots WHERE id=p_payload->>'lot_id') FOR UPDATE;
 SELECT * INTO l FROM public.inventory_lots WHERE id=p_payload->>'lot_id' FOR UPDATE;
 IF l.id IS NULL THEN RAISE EXCEPTION 'lot_not_found';END IF;
 IF EXISTS(SELECT 1 FROM public.inventory_disposals WHERE lot_id=l.id AND kind=event_kind AND reference=event_reference) THEN RAISE EXCEPTION 'disposal_reference_exists';END IF;
 IF l.inspection_state<>'accepted' THEN RAISE EXCEPTION 'disposal_requires_accepted_lot';END IF;
 IF l.quantity_revision<>expected_revision THEN RAISE EXCEPTION 'disposal_stale';END IF;
 IF event_kind='supplier_return' AND l.supplier_id IS NULL THEN RAISE EXCEPTION 'disposal_supplier_required';END IF;
 IF qty>l.on_hand_base-l.reserved_base THEN RAISE EXCEPTION 'disposal_exceeds_unreserved';END IF;
 UPDATE public.inventory_lots SET on_hand_base=on_hand_base-qty WHERE id=l.id;
 UPDATE public.stock_balances SET on_hand_base=on_hand_base-qty WHERE stock_id=l.stock_id;
 INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
 VALUES(mid,l.stock_id,l.id,-qty,0,event_kind,did::text,u.id,nowms);
 -- The existing cost trigger recognizes this movement at recorded/estimated/unknown lot cost.
 INSERT INTO public.inventory_disposals(id,lot_id,stock_id,kind,quantity_base,reason,reference,actor_id,actor_role,before_on_hand,after_on_hand,movement_id,created_at)
 VALUES(did,l.id,l.stock_id,event_kind,qty,event_reason,event_reference,u.id,u.role,l.on_hand_base,l.on_hand_base-qty,mid,nowms);
 SELECT jsonb_build_object('id',d.id,'lot_id',d.lot_id,'stock_id',d.stock_id,'kind',d.kind,'quantity_base',d.quantity_base,
 'before_on_hand',d.before_on_hand,'after_on_hand',d.after_on_hand,'reference',d.reference,'movement_id',d.movement_id,
 'value_halalas',-c.value_delta_halalas,'cost_basis',c.cost_basis,'created_at',d.created_at)
 INTO result FROM public.inventory_disposals d JOIN public.inventory_cost_entries c ON c.movement_id=d.movement_id WHERE d.id=did;
 IF result IS NULL THEN RAISE EXCEPTION 'disposal_cost_entry_missing';END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'inventory_disposed',did::text,
 jsonb_build_object('role',u.role,'reason',event_reason,'before',jsonb_build_object('on_hand_base',l.on_hand_base,'reserved_base',l.reserved_base,'quantity_revision',l.quantity_revision),'after',result,'entity_type','inventory_disposal'),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,request_hash,result,nowms);
 RETURN result;
END$$;

CREATE FUNCTION public.jana_inventory_disposals(p_token text,p_before_at bigint DEFAULT NULL,p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;rows jsonb;cursor_row jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) THEN RAISE EXCEPTION 'disposal_validation';END IF;
 WITH page AS(SELECT * FROM public.inventory_disposals WHERE p_before_at IS NULL OR (created_at,id)<(p_before_at,p_before_id) ORDER BY created_at DESC,id DESC LIMIT 51)
 SELECT coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('stock_name',s.name,'base_unit',s.base_unit,'actor_name',actor.name,'supplier_name',sp.name,'value_halalas',-c.value_delta_halalas,'cost_basis',c.cost_basis) ORDER BY d.created_at DESC,d.id DESC),'[]'::jsonb)
 INTO rows FROM page d JOIN public.stock_items s ON s.id=d.stock_id JOIN public.users actor ON actor.id=d.actor_id JOIN public.inventory_lots l ON l.id=d.lot_id LEFT JOIN public.suppliers sp ON sp.id=l.supplier_id JOIN public.inventory_cost_entries c ON c.movement_id=d.movement_id;
 IF jsonb_array_length(rows)>50 THEN cursor_row=rows->49;rows=rows-50;END IF;
 RETURN jsonb_build_object('items',rows,'next',CASE WHEN cursor_row IS NULL THEN NULL ELSE jsonb_build_object('before_at',cursor_row->'created_at','before_id',cursor_row->'id') END);
END$$;
REVOKE ALL ON FUNCTION public.jana_inventory_dispose(text,text,jsonb),public.jana_inventory_disposals(text,bigint,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_inventory_dispose(text,text,jsonb),public.jana_inventory_disposals(text,bigint,uuid) TO service_role;

CREATE FUNCTION public.jana_inventory_disposal_context(p_token text,p_lot_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT jsonb_build_object('id',l.id,'stock_id',l.stock_id,'stock_name',s.name,'base_unit',s.base_unit,
 'supplier_id',l.supplier_id,'supplier_name',sp.name,'inspection_state',l.inspection_state,'on_hand_base',l.on_hand_base,
 'reserved_base',l.reserved_base,'available_base',l.on_hand_base-l.reserved_base,'quantity_revision',l.quantity_revision,
 'remaining_cost_halalas',l.remaining_cost_halalas,'cost_basis',l.cost_basis)
 INTO r FROM public.inventory_lots l JOIN public.stock_items s ON s.id=l.stock_id LEFT JOIN public.suppliers sp ON sp.id=l.supplier_id WHERE l.id=p_lot_id;
 IF r IS NULL THEN RAISE EXCEPTION 'lot_not_found';END IF;RETURN r;
END$$;
REVOKE ALL ON FUNCTION public.jana_inventory_disposal_context(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_inventory_disposal_context(text,text) TO service_role;
