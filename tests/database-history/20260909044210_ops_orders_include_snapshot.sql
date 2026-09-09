CREATE OR REPLACE FUNCTION public.jana_ops_orders(p_token text, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at > (extract(epoch from now())*1000)::bigint AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker','courier','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF p_role='picker' AND r NOT IN ('admin','picker') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF p_role='courier' AND r NOT IN ('admin','courier') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,'payment_state',o.payment_state,'total_halalas',o.total_halalas,'picker_id',o.picker_id,'courier_id',o.courier_id,'snapshot',o.snapshot,'created_at',o.created_at) ORDER BY o.created_at DESC) FROM orders o WHERE o.status='active' AND (r='admin' OR (p_role='picker' AND (o.picker_id IS NULL OR o.picker_id=uid)) OR (p_role='courier' AND (o.courier_id IS NULL OR o.courier_id=uid)))), '[]'::jsonb);
END$$;