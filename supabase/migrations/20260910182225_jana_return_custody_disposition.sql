-- Custody of rejected physical returns is separate from sellable stock and cash.
-- These append-only documents record completed disposal/handover, not permission to perform it.
CREATE TABLE public.customer_return_dispositions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 return_id uuid NOT NULL REFERENCES public.customer_return_inspections(return_id),
 kind text NOT NULL CHECK(kind IN ('destroyed','supplier_handover')),
 quantity_base bigint NOT NULL CHECK(quantity_base BETWEEN 1 AND 9000000000000),
 reference text NOT NULL CHECK(length(reference) BETWEEN 1 AND 180),
 recipient text,
 note text NOT NULL CHECK(length(note) BETWEEN 3 AND 1000),
 actor_id varchar(36) NOT NULL REFERENCES public.users(id),
 actor_role text NOT NULL CHECK(actor_role IN ('admin','inventory')),
 created_at bigint NOT NULL,
 CHECK((kind='destroyed' AND recipient IS NULL) OR
       (kind='supplier_handover' AND recipient IS NOT NULL AND length(recipient) BETWEEN 3 AND 180)),
 UNIQUE(return_id,reference)
);
CREATE INDEX jana_return_dispositions_page ON public.customer_return_dispositions(return_id,created_at DESC,id DESC);
CREATE INDEX jana_return_dispositions_actor ON public.customer_return_dispositions(actor_id);
ALTER TABLE public.customer_return_dispositions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_return_dispositions FROM PUBLIC,anon,authenticated;
CREATE TRIGGER jana_immutable_return_dispositions BEFORE UPDATE OR DELETE ON public.customer_return_dispositions
 FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();

CREATE FUNCTION public.jana_customer_return_dispose(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;i public.customer_return_inspections;prev public.idempotency_records;
 rid uuid;did uuid:=gen_random_uuid();qty bigint;disposed bigint;k text;h text;kind text;ref text;recipient text;note text;
 nowms bigint;result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','inventory') THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'return_disposition_validation';END IF;
 k='customer-return-dispose:'||u.id||':'||p_idem_key;h=encode(digest(p_payload::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(k,0));
 SELECT * INTO prev FROM public.idempotency_records WHERE scope=k;
 IF prev.scope IS NOT NULL THEN
  IF prev.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prev.response::jsonb;
 END IF;
 IF jsonb_typeof(p_payload->'return_id') IS DISTINCT FROM 'string'
 OR (p_payload->>'return_id')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 OR jsonb_typeof(p_payload->'quantity_base') IS DISTINCT FROM 'number'
 OR (p_payload->>'quantity_base')!~'^[0-9]{1,13}$'
 OR jsonb_typeof(p_payload->'kind') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p_payload->'reference') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p_payload->'note') IS DISTINCT FROM 'string'
 OR (p_payload ? 'recipient' AND jsonb_typeof(p_payload->'recipient') NOT IN ('string','null'))
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) x WHERE x NOT IN ('return_id','quantity_base','kind','reference','recipient','note'))
 THEN RAISE EXCEPTION 'return_disposition_validation';END IF;
 rid=(p_payload->>'return_id')::uuid;qty=(p_payload->>'quantity_base')::bigint;kind=p_payload->>'kind';
 ref=trim(p_payload->>'reference');recipient=nullif(trim(p_payload->>'recipient'),'');note=trim(p_payload->>'note');
 IF qty NOT BETWEEN 1 AND 9000000000000 OR kind NOT IN ('destroyed','supplier_handover')
 OR length(ref) NOT BETWEEN 1 AND 180 OR length(note) NOT BETWEEN 3 AND 1000
 OR (kind='destroyed' AND recipient IS NOT NULL)
 OR (kind='supplier_handover' AND (recipient IS NULL OR length(recipient) NOT BETWEEN 3 AND 180))
 THEN RAISE EXCEPTION 'return_disposition_validation';END IF;
 -- Every disposition for this immutable inspection serializes on the same row.
 -- No stock, lot, cash, order or cost row is modified or locked here.
 SELECT * INTO i FROM public.customer_return_inspections WHERE return_id=rid FOR UPDATE;
 IF i.return_id IS NULL OR i.rejected_base=0 THEN RAISE EXCEPTION 'return_disposition_requires_rejection';END IF;
 IF EXISTS(SELECT 1 FROM public.customer_return_dispositions d WHERE d.return_id=rid AND d.reference=ref)
 THEN RAISE EXCEPTION 'return_disposition_reference_exists';END IF;
 SELECT coalesce(sum(d.quantity_base),0) INTO disposed FROM public.customer_return_dispositions d WHERE d.return_id=rid;
 IF qty>i.rejected_base-disposed THEN RAISE EXCEPTION 'return_disposition_exceeds_remaining';END IF;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 INSERT INTO public.customer_return_dispositions(id,return_id,kind,quantity_base,reference,recipient,note,actor_id,actor_role,created_at)
 VALUES(did,rid,kind,qty,ref,recipient,note,u.id,u.role,nowms);
 result=jsonb_build_object('id',did,'return_id',rid,'kind',kind,'quantity_base',qty,'reference',ref,
  'recipient',recipient,'note',note,'actor_id',u.id,'actor_role',u.role,'created_at',nowms,
  'remaining_base',i.rejected_base-disposed-qty,'state',CASE WHEN qty=i.rejected_base-disposed THEN 'closed' ELSE 'partial' END);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'customer_return_disposed',did::text,
  jsonb_build_object('entity_type','customer_return_disposition','return_id',rid,'before_remaining_base',i.rejected_base-disposed,'after',result),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(k,u.id,p_idem_key,h,result,nowms);
 RETURN result;
END$$;

CREATE FUNCTION public.jana_customer_return_dispositions(p_token text,p_return_id uuid,p_before_at bigint DEFAULT NULL,p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;receipt jsonb;rows jsonb;cursor_row jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','inventory','finance','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_return_id IS NULL OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 THEN RAISE EXCEPTION 'return_disposition_validation';END IF;
 SELECT jsonb_build_object('id',r.id,'order_number',o.number,'stock_name',s.name,'base_unit',s.base_unit,'lot_id',r.lot_id,
  'inspection_complete',i.return_id IS NOT NULL,'rejected_base',i.rejected_base,'disposed_base',coalesce(d.qty,0),'remaining_base',i.rejected_base-coalesce(d.qty,0)) INTO receipt
 FROM public.customer_return_receipts r JOIN public.orders o ON o.id=r.order_id JOIN public.stock_items s ON s.id=r.stock_id
 LEFT JOIN public.customer_return_inspections i ON i.return_id=r.id
 LEFT JOIN LATERAL(SELECT sum(quantity_base) qty FROM public.customer_return_dispositions WHERE return_id=r.id) d ON true
 WHERE r.id=p_return_id;
 IF receipt IS NULL THEN RAISE EXCEPTION 'return_not_found';END IF;
 WITH page AS(
  SELECT * FROM public.customer_return_dispositions WHERE return_id=p_return_id
  AND (p_before_at IS NULL OR (created_at,id)<(p_before_at,p_before_id)) ORDER BY created_at DESC,id DESC LIMIT 51
 )
 SELECT coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('actor_name',a.name) ORDER BY d.created_at DESC,d.id DESC),'[]') INTO rows
 FROM page d JOIN public.users a ON a.id=d.actor_id;
 IF jsonb_array_length(rows)>50 THEN cursor_row=rows->49;rows=rows-50;END IF;
 RETURN jsonb_build_object('receipt',receipt,'items',rows,'next',CASE WHEN cursor_row IS NULL THEN NULL
  ELSE jsonb_build_object('before_at',cursor_row->'created_at','before_id',cursor_row->'id') END);
END$$;

CREATE OR REPLACE FUNCTION public.jana_customer_returns(p_token text,p_before_at bigint DEFAULT NULL,p_before_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;rows jsonb;cursor_row jsonb;summary jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory','finance','support') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 THEN RAISE EXCEPTION 'return_validation';END IF;
 WITH page AS(SELECT * FROM public.customer_return_receipts WHERE p_before_at IS NULL OR (created_at,id)<(p_before_at,p_before_id) ORDER BY created_at DESC,id DESC LIMIT 51)
 SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('stock_name',s.name,'base_unit',s.base_unit,'order_number',o.number,'actor_name',a.name,'expires_at',l.expires_at,
  'inspection',CASE WHEN i.return_id IS NOT NULL THEN (CASE WHEN u.role='support' THEN to_jsonb(i)-'restored_cost_halalas'-'cost_basis' ELSE to_jsonb(i) END)||jsonb_build_object('actor_name',ia.name) ELSE NULL END,
  'disposition_summary',jsonb_build_object('disposed_base',coalesce(d.qty,0),'remaining_base',i.rejected_base-coalesce(d.qty,0))) ORDER BY r.created_at DESC,r.id DESC),'[]') INTO rows
 FROM page r JOIN public.stock_items s ON s.id=r.stock_id JOIN public.inventory_lots l ON l.id=r.lot_id JOIN public.orders o ON o.id=r.order_id
 JOIN public.users a ON a.id=r.actor_id LEFT JOIN public.customer_return_inspections i ON i.return_id=r.id LEFT JOIN public.users ia ON ia.id=i.actor_id
 LEFT JOIN LATERAL(SELECT sum(quantity_base) qty FROM public.customer_return_dispositions WHERE return_id=r.id) d ON true;
 IF jsonb_array_length(rows)>50 THEN cursor_row=rows->49;rows=rows-50;END IF;
 SELECT jsonb_build_object('pending_receipts',count(*) FILTER(WHERE i.return_id IS NULL),'inspected_receipts',count(*) FILTER(WHERE i.return_id IS NOT NULL),
  'rejected_receipts',count(*) FILTER(WHERE i.rejected_base>0),
  'open_rejected_receipts',count(*) FILTER(WHERE i.rejected_base>coalesce(d.qty,0)),
  'closed_rejected_receipts',count(*) FILTER(WHERE i.rejected_base>0 AND i.rejected_base=coalesce(d.qty,0))) INTO summary
 FROM public.customer_return_receipts r LEFT JOIN public.customer_return_inspections i ON i.return_id=r.id
 LEFT JOIN(SELECT return_id,sum(quantity_base) qty FROM public.customer_return_dispositions GROUP BY return_id) d ON d.return_id=r.id;
 RETURN jsonb_build_object('items',rows,'summary',summary,'next',CASE WHEN cursor_row IS NULL THEN NULL ELSE jsonb_build_object('before_at',cursor_row->'created_at','before_id',cursor_row->'id') END);
END$$;
REVOKE ALL ON FUNCTION public.jana_customer_return_dispose(text,text,jsonb),public.jana_customer_return_dispositions(text,uuid,bigint,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_customer_return_dispose(text,text,jsonb),public.jana_customer_return_dispositions(text,uuid,bigint,uuid) TO service_role;
