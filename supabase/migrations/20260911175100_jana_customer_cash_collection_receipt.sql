-- Customer-visible proof of an actual COD collection. This is deliberately not a tax invoice.
ALTER FUNCTION public.jana_order_detail(text,text) RENAME TO jana_order_detail_pre_cash_receipt;

CREATE OR REPLACE FUNCTION public.jana_order_detail(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;
 o public.orders;
 collection public.cash_entries;
 result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 result=public.jana_order_detail_pre_cash_receipt(p_token,p_order_id);
 SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 SELECT * INTO collection FROM public.cash_entries WHERE order_id=o.id AND kind='collection' ORDER BY created_at,id LIMIT 1;
 RETURN result||jsonb_build_object('payment_receipt',CASE WHEN collection.id IS NULL THEN NULL ELSE jsonb_build_object(
  'receipt_id',collection.id,
  'kind','cash_collection_receipt',
  'tax_invoice',false,
  'payment_method','cash_on_delivery',
  'collected_at',collection.created_at,
  'collected_halalas',collection.amount_halalas,
  'refunded_halalas',o.refunded_halalas,
  'net_collected_halalas',collection.amount_halalas-o.refunded_halalas
 ) END);
END$$;

REVOKE ALL ON FUNCTION public.jana_order_detail_pre_cash_receipt(text,text) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_order_detail(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_order_detail(text,text) TO service_role;
