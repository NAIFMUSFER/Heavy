-- Select one bounded page before computing component inventory. Historical
-- catalog RPCs remain compatible for existing server-side saved-list callers.
CREATE INDEX jana_offerings_active_catalog_order ON public.offerings(created_at,id) WHERE active;
CREATE INDEX jana_offerings_active_category_order ON public.offerings(category,created_at,id) WHERE active;
CREATE FUNCTION public.jana_catalog_page(p_offset integer DEFAULT 0,p_limit integer DEFAULT 50,p_query text DEFAULT '',p_category text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 IF p_offset IS NULL OR p_limit IS NULL OR p_offset NOT BETWEEN 0 AND 100000 OR p_limit NOT BETWEEN 1 AND 100 OR p_query IS NULL OR length(p_query)>200 OR p_category IS NULL OR length(p_category)>100 THEN RAISE EXCEPTION 'invalid_catalog_page';END IF;
 p_query=trim(p_query);p_category=trim(p_category);
 WITH candidates AS MATERIALIZED (
  SELECT o.* FROM public.offerings o
  WHERE o.active AND (p_query='' OR strpos(o.name,p_query)>0) AND (p_category='' OR o.category=p_category)
  ORDER BY o.created_at,o.id LIMIT p_limit+1 OFFSET p_offset
 ), selected AS MATERIALIZED (
  SELECT * FROM candidates ORDER BY created_at,id LIMIT p_limit
 ), stocks AS MATERIALIZED (
  SELECT DISTINCT c->>'stock_id' AS stock_id FROM selected o CROSS JOIN LATERAL json_array_elements(o.components) c
 ), balances AS MATERIALIZED (
  SELECT l.stock_id,sum(l.on_hand_base-l.reserved_base)::bigint AS available_base
  FROM stocks t JOIN public.stock_items s ON s.id=t.stock_id AND s.active
  JOIN public.inventory_lots l ON l.stock_id=s.id
  WHERE l.inspection_state='accepted' AND l.expires_at>nowms GROUP BY l.stock_id
 ), items AS (
  SELECT o.created_at,o.id,jsonb_build_object('id',o.id,'family_id',o.family_id,'version',o.version,'kind',o.kind,'name',o.name,'description',o.description,'category',o.category,'size_label',o.size_label,'emoji',o.emoji,'image_url',o.image_url,'sale_unit',o.sale_unit,'price_halalas',o.price_halalas,'components',o.components,
   'available_units',coalesce((SELECT min(floor(coalesce(b.available_base,0)::numeric/greatest((c->>'base_qty')::numeric,1))) FROM json_array_elements(o.components) c LEFT JOIN balances b ON b.stock_id=c->>'stock_id'),0)::bigint)
   ||CASE WHEN v.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) END AS item
  FROM selected o LEFT JOIN public.product_version_offerings m ON m.offering_id=o.id LEFT JOIN public.product_versions v ON v.id=m.version_id
 )
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(item ORDER BY created_at,id) FROM items),'[]'::jsonb),'next_offset',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN p_offset+p_limit ELSE NULL END) INTO result;
 RETURN result;
END$$;
REVOKE ALL ON FUNCTION public.jana_catalog_page(integer,integer,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_catalog_page(integer,integer,text,text) TO service_role;
