-- Additive read-only recovery contract; existing quote/order writes stay intact.
CREATE OR REPLACE FUNCTION public.jana_quote_detail(p_token text,p_quote_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;q public.quotes;result_order jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 SELECT * INTO q FROM public.quotes WHERE id=p_quote_id AND user_id=u.id;
 IF q.id IS NULL THEN RAISE EXCEPTION 'quote_not_found'; END IF;
 SELECT jsonb_build_object('id',o.id,'number',o.number,'status',o.status,
  'total_halalas',o.total_halalas,'payment_state',o.payment_state,
  'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state)
 INTO result_order FROM public.orders o WHERE o.quote_id=q.id AND o.user_id=u.id;
 -- Metadata follows the immutable snapshot so stored JSON cannot override the
 -- authoritative lifecycle, server clock or associated order. No code is read.
 RETURN coalesce(q.snapshot::jsonb,'{}'::jsonb)||jsonb_build_object(
  'id',q.id,'state',q.state,'expires_at',q.expires_at,'created_at',q.created_at,
  'server_now',(extract(epoch FROM clock_timestamp())*1000)::bigint,'order',result_order);
END $$;
REVOKE ALL ON FUNCTION public.jana_quote_detail(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_quote_detail(text,text) TO service_role;
