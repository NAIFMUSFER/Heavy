CREATE OR REPLACE FUNCTION public.jana_admin_reports(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar; nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','finance','inventory','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 RETURN jsonb_build_object(
  'sales_7d_halalas',(SELECT coalesce(sum(total_halalas),0) FROM public.orders WHERE created_at>=nowms-604800000 AND status='completed'),
  'orders_7d',(SELECT count(*) FROM public.orders WHERE created_at>=nowms-604800000),
  'completed_7d',(SELECT count(*) FROM public.orders WHERE created_at>=nowms-604800000 AND status='completed'),
  'refunds_7d_halalas',(SELECT coalesce(sum(amount_halalas),0) FROM public.refunds WHERE created_at>=nowms-604800000 AND state='completed'),
  'cash_unsettled_halalas',(SELECT coalesce(sum(collected_halalas-refunded_halalas),0) FROM public.orders WHERE cash_state='with_courier'),
  'top_items',COALESCE((SELECT jsonb_agg(x) FROM (SELECT l->>'name' name,sum((l->>'qty')::int) qty FROM public.orders o CROSS JOIN LATERAL jsonb_array_elements(o.snapshot->'lines') l WHERE o.created_at>=nowms-604800000 GROUP BY l->>'name' ORDER BY qty DESC LIMIT 5)x),'[]'::jsonb),
  'low_stock',COALESCE((SELECT jsonb_agg(x) FROM (SELECT si.id,si.name,(sb.on_hand_base-sb.reserved_base) available_base FROM public.stock_items si JOIN public.stock_balances sb ON sb.stock_id=si.id ORDER BY available_base ASC LIMIT 10)x),'[]'::jsonb)
 );
END$$;
REVOKE ALL ON FUNCTION public.jana_admin_reports(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_reports(text) TO service_role;