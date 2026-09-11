-- Bound staff order reads in PostgreSQL without changing task or cash eligibility.
CREATE INDEX IF NOT EXISTS jana_orders_ops_page_idx ON public.orders(created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS jana_orders_picker_page_idx ON public.orders(picker_id,created_at DESC,id DESC)
 WHERE status='active' AND fulfillment_state IN ('queued','picking','awaiting_customer');
CREATE INDEX IF NOT EXISTS jana_orders_courier_page_idx ON public.orders(courier_id,created_at DESC,id DESC)
 WHERE (status='active' AND fulfillment_state='ready') OR
 (delivery_state='delivered' AND (payment_state='awaiting_collection' OR collected_halalas-settled_halalas-courier_refunded_halalas>0));

CREATE OR REPLACE FUNCTION public.jana_ops_orders_page(p_token text,p_limit integer DEFAULT 50,p_before_at bigint DEFAULT NULL,p_before_id text DEFAULT NULL,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; result jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role NOT IN ('admin','finance','support','picker','courier') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 1000000
 OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR p_before_at<0 OR p_before_at>9007199254740991
 OR (p_before_id IS NOT NULL AND (length(p_before_id) NOT BETWEEN 1 AND 128 OR p_offset<>0)) THEN RAISE EXCEPTION 'invalid_orders_page';END IF;
 WITH candidates AS MATERIALIZED (
  SELECT o.id,o.number,o.status,o.fulfillment_state,o.delivery_state,o.payment_state,o.total_halalas,
   o.picker_id,o.courier_id,o.snapshot,o.created_at,o.cash_state,o.collected_halalas,o.settled_halalas,
   o.refunded_halalas,o.courier_refunded_halalas,
   o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas AS cash_liability_halalas
  FROM public.orders o
  WHERE (p_before_at IS NULL OR (o.created_at,o.id)<(p_before_at,p_before_id)) AND (
   u.role IN ('admin','finance','support') OR
   (u.role='picker' AND o.status='active' AND o.fulfillment_state IN ('queued','picking','awaiting_customer')
    AND (o.picker_id=u.id OR (o.picker_id IS NULL AND o.fulfillment_state='queued'))) OR
   (u.role='courier' AND
    (o.courier_id=u.id OR (o.courier_id IS NULL AND o.status='active' AND o.fulfillment_state='ready')) AND
    ((o.status='active' AND o.fulfillment_state='ready') OR
     (o.delivery_state='delivered' AND (o.payment_state='awaiting_collection' OR o.collected_halalas-o.settled_halalas-o.courier_refunded_halalas>0))))
  ) ORDER BY o.created_at DESC,o.id DESC LIMIT p_limit+1 OFFSET p_offset
 ), selected AS (SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT p_limit)
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id DESC) FROM selected s),'[]'::jsonb),
  'next',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN (SELECT jsonb_build_object('before_at',created_at,'before_id',id) FROM selected ORDER BY created_at,id LIMIT 1) ELSE NULL END,
  'next_offset',CASE WHEN p_before_at IS NULL AND (SELECT count(*) FROM candidates)>p_limit THEN p_offset+p_limit ELSE NULL END) INTO result;
 RETURN result;
END$$;
REVOKE ALL ON FUNCTION public.jana_ops_orders_page(text,integer,bigint,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_ops_orders_page(text,integer,bigint,text,integer) TO service_role;
