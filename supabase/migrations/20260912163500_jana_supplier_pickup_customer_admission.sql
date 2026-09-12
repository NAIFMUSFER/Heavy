-- Route customer admission through the completed supplier-pickup workflow.
-- Legacy inventory-backed quotes and orders remain readable and confirmable;
-- new quotes reserve delivery capacity only and never touch warehouse stock.

ALTER FUNCTION public.jana_catalog_page(integer,integer,text,text)
 RENAME TO jana_catalog_page_pre_supplier_pickup;

CREATE FUNCTION public.jana_catalog_page(p_offset integer DEFAULT 0,p_limit integer DEFAULT 50,p_query text DEFAULT '',p_category text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;items jsonb;
BEGIN
 r=public.jana_catalog_page_pre_supplier_pickup(p_offset,p_limit,p_query,p_category);
 SELECT coalesce(jsonb_agg(x.item||jsonb_build_object(
  'fulfillment_model','supplier_pickup','inventory_required',false,
  'orderable',true,'max_order_quantity',20,
  'availability_status','to_be_purchased','legacy_available_units',x.item->'available_units'
 ) ORDER BY x.ord),'[]'::jsonb)
 INTO items FROM jsonb_array_elements(r->'items') WITH ORDINALITY x(item,ord);
 RETURN jsonb_set(r,'{items}',items);
END$$;

ALTER FUNCTION public.jana_public_catalog()
 RENAME TO jana_public_catalog_pre_supplier_pickup;

CREATE FUNCTION public.jana_public_catalog() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(x.item||jsonb_build_object(
  'fulfillment_model','supplier_pickup','inventory_required',false,
  'orderable',true,'max_order_quantity',20,
  'availability_status','to_be_purchased','legacy_available_units',x.item->'available_units'
 ) ORDER BY x.ord),'[]'::jsonb)
 FROM jsonb_array_elements(public.jana_public_catalog_pre_supplier_pickup()) WITH ORDINALITY x(item,ord);
$$;

CREATE FUNCTION public.jana_supplier_pickup_quote_gateway(
 p_token text,p_idem_key text,p_slot_id text,p_address_id text,p_items jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;
BEGIN
 r=public.jana_supplier_pickup_quote_idempotent(p_token,p_idem_key,p_slot_id,p_address_id,p_items);
 RETURN r||jsonb_build_object('order_flow_ready',true);
END$$;

CREATE FUNCTION public.jana_order_confirm_gateway(
 p_token text,p_idem_key text,p_quote_id text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;q public.quotes;prior public.idempotency_records;
 scope_key text;req_hash text;result jsonb;
 nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='order-confirm-gateway:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('quote_id',p_quote_id)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO q FROM public.quotes WHERE id=p_quote_id AND user_id=u.id FOR UPDATE;
 IF q.id IS NULL THEN RAISE EXCEPTION 'quote_not_found';END IF;
 IF q.snapshot::jsonb->>'fulfillment_model'='supplier_pickup' THEN
  result=public.jana_supplier_pickup_order_confirm(p_token,p_quote_id)
   ||jsonb_build_object('fulfillment_model','supplier_pickup','inventory_reserved',false);
 ELSE
  -- Compatibility only for already-issued warehouse-backed quotes.
  result=public.jana_critical_write(p_token,p_idem_key,'order.confirm',jsonb_build_object('quote_id',p_quote_id));
 END IF;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
END$$;

REVOKE ALL ON FUNCTION
 public.jana_catalog_page_pre_supplier_pickup(integer,integer,text,text),
 public.jana_public_catalog_pre_supplier_pickup(),
 public.jana_supplier_pickup_quote_gateway(text,text,text,text,jsonb),
 public.jana_order_confirm_gateway(text,text,text)
FROM PUBLIC,anon,authenticated,service_role;

REVOKE ALL ON FUNCTION
 public.jana_catalog_page(integer,integer,text,text),
 public.jana_public_catalog(),
 public.jana_supplier_pickup_quote_gateway(text,text,text,text,jsonb),
 public.jana_order_confirm_gateway(text,text,text)
FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION
 public.jana_catalog_page(integer,integer,text,text),
 public.jana_public_catalog(),
 public.jana_supplier_pickup_quote_gateway(text,text,text,text,jsonb),
 public.jana_order_confirm_gateway(text,text,text)
TO service_role;

