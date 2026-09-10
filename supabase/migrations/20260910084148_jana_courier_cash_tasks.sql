-- A delivered order is commercially completed but can still need cash collection.
-- The previous active-only query hid that required task from its courier.
CREATE OR REPLACE FUNCTION public.jana_ops_orders(p_token text,p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);
 IF p_role IS NULL OR p_role NOT IN ('picker','courier') OR (u.role<>'admin' AND u.role<>p_role) THEN RAISE EXCEPTION 'forbidden';END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
  'id',o.id,'number',o.number,'status',o.status,'fulfillment_state',o.fulfillment_state,
  'delivery_state',o.delivery_state,'payment_state',o.payment_state,'total_halalas',o.total_halalas,
  'picker_id',o.picker_id,'courier_id',o.courier_id,'snapshot',o.snapshot,'created_at',o.created_at,
  'cash_state',o.cash_state,'collected_halalas',o.collected_halalas,'settled_halalas',o.settled_halalas,
  'refunded_halalas',o.refunded_halalas,'courier_refunded_halalas',o.courier_refunded_halalas,
  'cash_liability_halalas',o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas
 ) ORDER BY o.created_at DESC,o.id DESC) FROM public.orders o WHERE
  (p_role='picker' AND o.status='active' AND o.fulfillment_state IN ('queued','picking','awaiting_customer')
    AND (u.role='admin' OR o.picker_id=u.id OR (o.picker_id IS NULL AND o.fulfillment_state='queued')))
  OR
  (p_role='courier' AND
    (u.role='admin' OR o.courier_id=u.id OR (o.courier_id IS NULL AND o.status='active' AND o.fulfillment_state='ready'))
    AND ((o.status='active' AND o.fulfillment_state='ready') OR
      (o.delivery_state='delivered' AND (o.payment_state='awaiting_collection' OR o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas>0))))
 ),'[]'::jsonb);
END$$;
REVOKE ALL ON FUNCTION public.jana_ops_orders(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ops_orders(text,text) TO service_role;
