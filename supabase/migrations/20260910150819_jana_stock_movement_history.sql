-- Read-only ledger access; no balances or historical evidence are rewritten.
CREATE INDEX jana_movements_page ON public.stock_movements(created_at DESC,id DESC);
CREATE INDEX jana_movements_stock_page ON public.stock_movements(stock_id,created_at DESC,id DESC);
CREATE INDEX jana_movements_lot_page ON public.stock_movements(lot_id,created_at DESC,id DESC);
CREATE FUNCTION public.jana_stock_movement_history(p_token text,p_filters jsonb DEFAULT '{}'::jsonb,p_before_at bigint DEFAULT NULL,p_before_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;rows jsonb;cursor_row jsonb;k text;from_ms bigint;to_ms bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_filters) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 FOR k IN SELECT jsonb_object_keys(p_filters) LOOP
  IF k NOT IN ('stock_id','lot_id','reason','reference','from_at','to_at') OR jsonb_typeof(p_filters->k) IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
  IF length(p_filters->>k) NOT BETWEEN 1 AND CASE WHEN k IN ('stock_id','lot_id') THEN 36 WHEN k IN ('from_at','to_at') THEN 15 ELSE 180 END THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 END LOOP;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 OR length(p_before_id) NOT BETWEEN 1 AND 36 THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 IF (p_filters ? 'from_at' AND p_filters->>'from_at'!~'^[0-9]{1,15}$') OR (p_filters ? 'to_at' AND p_filters->>'to_at'!~'^[0-9]{1,15}$') THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 from_ms=(p_filters->>'from_at')::bigint;to_ms=(p_filters->>'to_at')::bigint;
 IF from_ms IS NOT NULL AND to_ms IS NOT NULL AND from_ms>=to_ms THEN RAISE EXCEPTION 'movement_filters_invalid';END IF;
 WITH page AS (
  SELECT m.*,d.reference AS document_reference,d.reason AS disposal_reason FROM public.stock_movements m
  LEFT JOIN public.inventory_disposals d ON d.movement_id=m.id
  WHERE (p_before_at IS NULL OR (m.created_at,m.id)<(p_before_at,p_before_id))
  AND (NOT p_filters ? 'stock_id' OR m.stock_id=p_filters->>'stock_id')
  AND (NOT p_filters ? 'lot_id' OR m.lot_id=p_filters->>'lot_id')
  AND (NOT p_filters ? 'reason' OR m.reason=p_filters->>'reason')
  AND (NOT p_filters ? 'reference' OR m.reference=p_filters->>'reference' OR d.reference=p_filters->>'reference')
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
