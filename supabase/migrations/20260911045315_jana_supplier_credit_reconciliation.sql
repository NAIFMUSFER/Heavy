-- Immutable supplier credit-note evidence linked to completed physical supplier returns.
-- This records a supplier document; it does not move cash or alter inventory cost.
CREATE TABLE public.supplier_credit_notes(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 disposal_id uuid NOT NULL REFERENCES public.inventory_disposals(id),
 supplier_id varchar(36) NOT NULL REFERENCES public.suppliers(id),
 amount_halalas bigint NOT NULL CHECK(amount_halalas>0),
 reference text NOT NULL CHECK(length(reference) BETWEEN 1 AND 180),
 note text NOT NULL CHECK(length(note) BETWEEN 3 AND 1000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),
 actor_role text NOT NULL CHECK(actor_role IN ('admin','finance')),
 created_at bigint NOT NULL,
 UNIQUE(supplier_id,reference)
);
CREATE INDEX jana_supplier_credits_page_idx ON public.supplier_credit_notes(created_at DESC,id DESC);
CREATE INDEX jana_supplier_credits_disposal_idx ON public.supplier_credit_notes(disposal_id,created_at DESC,id DESC);
ALTER TABLE public.supplier_credit_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_credit_notes FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.jana_supplier_credit_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE actual_supplier varchar(36);actual_kind text;
BEGIN
 SELECT d.kind,l.supplier_id INTO actual_kind,actual_supplier
 FROM public.inventory_disposals d JOIN public.inventory_lots l ON l.id=d.lot_id
 WHERE d.id=NEW.disposal_id;
 IF actual_kind IS DISTINCT FROM 'supplier_return' THEN RAISE EXCEPTION 'supplier_credit_requires_return';END IF;
 IF actual_supplier IS DISTINCT FROM NEW.supplier_id THEN RAISE EXCEPTION 'supplier_credit_supplier_mismatch';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_supplier_credit_validate BEFORE INSERT ON public.supplier_credit_notes
 FOR EACH ROW EXECUTE FUNCTION public.jana_supplier_credit_guard();
CREATE TRIGGER jana_supplier_credit_immutable BEFORE UPDATE OR DELETE ON public.supplier_credit_notes
 FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_supplier_credit_record(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;d public.inventory_disposals;l public.inventory_lots;previous public.idempotency_records;
 result jsonb;scope_key text;request_hash text;credit_id uuid:=gen_random_uuid();amount bigint;
 credit_reference text;credit_note text;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
 OR jsonb_typeof(p_payload->'disposal_id') IS DISTINCT FROM 'string'
 OR (p_payload->>'disposal_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
 OR jsonb_typeof(p_payload->'amount_halalas') IS DISTINCT FROM 'number'
 OR (p_payload->>'amount_halalas')!~'^[0-9]{1,13}$'
 OR jsonb_typeof(p_payload->'reference') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p_payload->'note') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'supplier_credit_validation';END IF;
 amount=(p_payload->>'amount_halalas')::bigint;credit_reference=trim(p_payload->>'reference');credit_note=trim(p_payload->>'note');
 IF amount NOT BETWEEN 1 AND 9000000000000 OR length(credit_reference) NOT BETWEEN 1 AND 180 OR length(credit_note) NOT BETWEEN 3 AND 1000
 THEN RAISE EXCEPTION 'supplier_credit_validation';END IF;
 scope_key='supplier-credit:'||u.id||':'||p_idem_key;request_hash=encode(digest(p_payload::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO previous FROM public.idempotency_records WHERE scope=scope_key;
 IF previous.scope IS NOT NULL THEN IF previous.request_hash<>request_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN previous.response::jsonb;END IF;
 SELECT * INTO d FROM public.inventory_disposals WHERE id=(p_payload->>'disposal_id')::uuid FOR SHARE;
 IF d.id IS NULL THEN RAISE EXCEPTION 'supplier_return_not_found';END IF;
 IF d.kind<>'supplier_return' THEN RAISE EXCEPTION 'supplier_credit_requires_return';END IF;
 SELECT * INTO l FROM public.inventory_lots WHERE id=d.lot_id;
 IF l.supplier_id IS NULL THEN RAISE EXCEPTION 'supplier_credit_supplier_required';END IF;
 IF EXISTS(SELECT 1 FROM public.supplier_credit_notes WHERE supplier_id=l.supplier_id AND reference=credit_reference)
 THEN RAISE EXCEPTION 'supplier_credit_reference_exists';END IF;
 INSERT INTO public.supplier_credit_notes(id,disposal_id,supplier_id,amount_halalas,reference,note,actor_id,actor_role,created_at)
 VALUES(credit_id,d.id,l.supplier_id,amount,credit_reference,credit_note,u.id,u.role,nowms);
 SELECT jsonb_build_object('id',n.id,'disposal_id',n.disposal_id,'supplier_id',n.supplier_id,'amount_halalas',n.amount_halalas,
  'reference',n.reference,'note',n.note,'actor_id',n.actor_id,'actor_role',n.actor_role,'actor_name',u.name,'created_at',n.created_at,
  'credited_halalas',(SELECT sum(x.amount_halalas) FROM public.supplier_credit_notes x WHERE x.disposal_id=d.id),
  'inventory_value_halalas',-c.value_delta_halalas,'inventory_cost_basis',c.cost_basis)
 INTO result FROM public.supplier_credit_notes n JOIN public.inventory_cost_entries c ON c.movement_id=d.movement_id WHERE n.id=credit_id;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'supplier_credit_recorded',credit_id::text,
  jsonb_build_object('role',u.role,'disposal_id',d.id,'supplier_id',l.supplier_id,'amount_halalas',amount,'reference',credit_reference,'entity_type','supplier_credit_note'),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,request_hash,result,nowms);
 RETURN result;
END$$;

CREATE FUNCTION public.jana_supplier_credit_reconciliation(p_token text,p_before_at bigint DEFAULT NULL,p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;rows jsonb;cursor_row jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) THEN RAISE EXCEPTION 'supplier_credit_validation';END IF;
 WITH page AS(
  SELECT d.* FROM public.inventory_disposals d
  WHERE d.kind='supplier_return' AND (p_before_at IS NULL OR (d.created_at,d.id)<(p_before_at,p_before_id))
  ORDER BY d.created_at DESC,d.id DESC LIMIT 51
 ), enriched AS(
  SELECT d.id,d.created_at,d.reference AS return_reference,d.reason,d.quantity_base,d.actor_id,
   s.name AS stock_name,s.base_unit,sp.id AS supplier_id,sp.name AS supplier_name,
   -c.value_delta_halalas AS inventory_value_halalas,c.cost_basis AS inventory_cost_basis,
   coalesce(n.credited_halalas,0) AS credited_halalas,coalesce(n.credit_count,0) AS credit_count,coalesce(n.notes,'[]'::jsonb) AS credit_notes,
   actor.name AS return_actor_name
  FROM page d JOIN public.inventory_lots l ON l.id=d.lot_id JOIN public.stock_items s ON s.id=d.stock_id
  JOIN public.suppliers sp ON sp.id=l.supplier_id JOIN public.users actor ON actor.id=d.actor_id
  JOIN public.inventory_cost_entries c ON c.movement_id=d.movement_id
  LEFT JOIN LATERAL(
   SELECT sum(x.amount_halalas) AS credited_halalas,count(*) AS credit_count,
    jsonb_agg(jsonb_build_object('id',x.id,'amount_halalas',x.amount_halalas,'reference',x.reference,'note',x.note,
     'actor_id',x.actor_id,'actor_name',cu.name,'created_at',x.created_at) ORDER BY x.created_at DESC,x.id DESC) AS notes
   FROM public.supplier_credit_notes x JOIN public.users cu ON cu.id=x.actor_id WHERE x.disposal_id=d.id
  ) n ON true
  ORDER BY d.created_at DESC,d.id DESC
 )
 SELECT coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('variance_to_inventory_cost_halalas',
  CASE WHEN e.inventory_value_halalas IS NULL THEN NULL ELSE e.credited_halalas-e.inventory_value_halalas END)
  ORDER BY e.created_at DESC,e.id DESC),'[]'::jsonb) INTO rows FROM enriched e;
 IF jsonb_array_length(rows)>50 THEN cursor_row=rows->49;rows=rows-50;END IF;
 RETURN jsonb_build_object('items',rows,'next',CASE WHEN cursor_row IS NULL THEN NULL ELSE
  jsonb_build_object('before_at',cursor_row->'created_at','before_id',cursor_row->'id') END);
END$$;

REVOKE ALL ON FUNCTION public.jana_supplier_credit_guard(),public.jana_supplier_credit_record(text,text,jsonb),
 public.jana_supplier_credit_reconciliation(text,bigint,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_supplier_credit_guard() FROM service_role;
GRANT EXECUTE ON FUNCTION public.jana_supplier_credit_record(text,text,jsonb),
 public.jana_supplier_credit_reconciliation(text,bigint,uuid) TO service_role;
