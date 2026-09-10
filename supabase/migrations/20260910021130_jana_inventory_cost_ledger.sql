-- Purchase costs remain nullable. Never interpret an unknown source cost as free stock.
ALTER TABLE public.inventory_lots ADD COLUMN cost_basis text NOT NULL DEFAULT 'unknown'
 CHECK(cost_basis IN ('recorded','estimated','unknown'));
UPDATE public.inventory_lots SET cost_basis=CASE WHEN remaining_cost_halalas IS NULL THEN 'unknown'
 WHEN on_hand_base=received_base OR inspection_state IN ('pending','rejected') THEN 'recorded' ELSE 'estimated' END;
ALTER TABLE public.inventory_lots ADD CONSTRAINT remaining_lot_cost_nonnegative CHECK(remaining_cost_halalas IS NULL OR remaining_cost_halalas>=0);
CREATE TABLE public.inventory_cost_entries(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),movement_id varchar(36) NOT NULL UNIQUE REFERENCES public.stock_movements(id),
 lot_id varchar(36) NOT NULL REFERENCES public.inventory_lots(id),stock_id varchar(36) NOT NULL REFERENCES public.stock_items(id),
 order_id varchar(36) REFERENCES public.orders(id),quantity_delta bigint NOT NULL,
 value_delta_halalas bigint,cost_basis text NOT NULL CHECK(cost_basis IN ('recorded','estimated','unknown')),
 created_at bigint NOT NULL, CHECK((cost_basis='unknown')=(value_delta_halalas IS NULL))
);
CREATE INDEX inventory_cost_order_idx ON public.inventory_cost_entries(order_id) WHERE order_id IS NOT NULL;
CREATE INDEX inventory_cost_lot_idx ON public.inventory_cost_entries(lot_id,created_at);
CREATE INDEX inventory_cost_stock_idx ON public.inventory_cost_entries(stock_id,created_at);
ALTER TABLE public.inventory_cost_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_cost_entries FROM PUBLIC,anon,authenticated;
CREATE TRIGGER immutable_inventory_cost_entries BEFORE UPDATE OR DELETE ON public.inventory_cost_entries
 FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();
CREATE FUNCTION public.jana_initial_lot_cost_basis()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN NEW.cost_basis=CASE WHEN NEW.total_cost_halalas IS NULL THEN 'unknown' ELSE 'recorded' END;RETURN NEW;END$$;
CREATE TRIGGER jana_initial_lot_cost_basis BEFORE INSERT ON public.inventory_lots
 FOR EACH ROW EXECUTE FUNCTION public.jana_initial_lot_cost_basis();

CREATE FUNCTION public.jana_post_inventory_cost()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE l public.inventory_lots; previous_qty bigint; cost_delta bigint; basis text; oid varchar(36);
BEGIN
 IF NEW.on_hand_delta=0 OR NEW.lot_id IS NULL THEN RETURN NEW; END IF;
 SELECT * INTO l FROM public.inventory_lots WHERE id=NEW.lot_id FOR UPDATE;
 IF l.id IS NULL OR l.stock_id IS DISTINCT FROM NEW.stock_id THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
 previous_qty=l.on_hand_base-NEW.on_hand_delta;basis=l.cost_basis;
 IF NEW.reason='goods_receipt_accepted' THEN
  cost_delta=l.remaining_cost_halalas;
 ELSE
  IF l.remaining_cost_halalas IS NULL THEN cost_delta=NULL;basis='unknown';
  ELSIF NEW.on_hand_delta<0 THEN
   IF previous_qty<=0 THEN RAISE EXCEPTION 'inventory_cost_invalid'; END IF;
   cost_delta=-least(l.remaining_cost_halalas,round(l.remaining_cost_halalas::numeric*(-NEW.on_hand_delta)/previous_qty)::bigint);
  ELSE
   -- Found stock is valued as an estimate and is never presented as an additional invoice.
   basis='estimated';
   IF previous_qty>0 THEN cost_delta=round(l.remaining_cost_halalas::numeric*NEW.on_hand_delta/previous_qty)::bigint;
   ELSIF l.total_cost_halalas IS NOT NULL THEN cost_delta=round(l.total_cost_halalas::numeric*NEW.on_hand_delta/l.received_base)::bigint;
   ELSE cost_delta=NULL;basis='unknown';END IF;
  END IF;
  UPDATE public.inventory_lots SET remaining_cost_halalas=CASE WHEN cost_delta IS NULL THEN NULL ELSE remaining_cost_halalas+cost_delta END,cost_basis=basis WHERE id=l.id;
 END IF;
 IF NEW.reason='order_picked' THEN oid=NEW.reference; END IF;
 INSERT INTO public.inventory_cost_entries(movement_id,lot_id,stock_id,order_id,quantity_delta,value_delta_halalas,cost_basis,created_at)
 VALUES(NEW.id,l.id,l.stock_id,oid,NEW.on_hand_delta,cost_delta,basis,NEW.created_at);
 RETURN NEW;
END$$;
CREATE TRIGGER jana_post_inventory_cost AFTER INSERT ON public.stock_movements
 FOR EACH ROW EXECUTE FUNCTION public.jana_post_inventory_cost();
REVOKE ALL ON FUNCTION public.jana_post_inventory_cost(),public.jana_initial_lot_cost_basis() FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.jana_admin_reports(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
 startms bigint; todayms bigint; sales bigint; cogs bigint; direct_costs bigint; refunds_total bigint; completed_count bigint; unknown_orders bigint; estimated_orders bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','finance') THEN RAISE EXCEPTION 'forbidden';END IF;
 todayms=(extract(epoch from (date_trunc('day',clock_timestamp() AT TIME ZONE 'Asia/Riyadh') AT TIME ZONE 'Asia/Riyadh'))*1000)::bigint;
 startms=todayms-6*86400000;
 SELECT coalesce(sum(total_halalas),0),count(*) INTO sales,completed_count FROM public.orders WHERE created_at>=startms AND status='completed';
 SELECT coalesce(sum(-c.value_delta_halalas),0) INTO cogs FROM public.inventory_cost_entries c JOIN public.orders o ON o.id=c.order_id WHERE o.created_at>=startms AND o.status='completed';
 SELECT coalesce(sum(c.amount_halalas),0) INTO direct_costs FROM public.order_costs c JOIN public.orders o ON o.id=c.order_id WHERE o.created_at>=startms AND o.status='completed';
 SELECT count(*) INTO unknown_orders FROM public.orders o WHERE o.created_at>=startms AND o.status='completed' AND
  (NOT EXISTS(SELECT 1 FROM public.inventory_cost_entries c WHERE c.order_id=o.id) OR EXISTS(SELECT 1 FROM public.inventory_cost_entries c WHERE c.order_id=o.id AND c.cost_basis='unknown'));
 SELECT count(DISTINCT o.id) INTO estimated_orders FROM public.orders o JOIN public.inventory_cost_entries c ON c.order_id=o.id WHERE o.created_at>=startms AND o.status='completed' AND c.cost_basis='estimated';
 SELECT coalesce(sum(amount_halalas),0) INTO refunds_total FROM public.refunds WHERE created_at>=startms AND state='completed';
 RETURN jsonb_build_object(
  'today_orders',(SELECT count(*) FROM public.orders WHERE created_at>=todayms),
  'today_sales_halalas',(SELECT coalesce(sum(total_halalas),0) FROM public.orders WHERE created_at>=todayms AND status='completed'),
  'sales_7d_halalas',sales,'completed_7d',completed_count,'orders_7d',(SELECT count(*) FROM public.orders WHERE created_at>=startms),
  'avg_completed_order_halalas',CASE WHEN completed_count>0 THEN sales/completed_count ELSE 0 END,
  'refunds_7d_halalas',refunds_total,'known_cogs_7d_halalas',cogs,'recorded_cogs_7d_halalas',(SELECT coalesce(sum(-c.value_delta_halalas),0) FROM public.inventory_cost_entries c JOIN public.orders o ON o.id=c.order_id WHERE o.created_at>=startms AND o.status='completed' AND c.cost_basis='recorded'),'estimated_cogs_7d_halalas',(SELECT coalesce(sum(-c.value_delta_halalas),0) FROM public.inventory_cost_entries c JOIN public.orders o ON o.id=c.order_id WHERE o.created_at>=startms AND o.status='completed' AND c.cost_basis='estimated'),'recognized_costs_7d_halalas',cogs+direct_costs,
  'recorded_direct_costs_7d_halalas',direct_costs,'orders_with_unknown_cost',unknown_orders,'orders_with_estimated_cost',estimated_orders,
  'cost_status',CASE WHEN unknown_orders>0 THEN 'unknown' WHEN estimated_orders>0 THEN 'estimated' ELSE 'recorded' END,
  'gross_profit_7d_halalas',CASE WHEN unknown_orders=0 THEN sales-cogs-direct_costs-refunds_total ELSE NULL END,
  'gross_margin_bps',CASE WHEN unknown_orders=0 AND sales>0 THEN round((sales-cogs-direct_costs-refunds_total)::numeric*10000/sales)::bigint ELSE NULL END,
  'profit_note','تقدير بعد تكلفة البضاعة والتكاليف المباشرة المسجلة؛ لا يشمل المصروفات غير المسجلة.',
  'cash_unsettled_halalas',(SELECT coalesce(sum(collected_halalas-refunded_halalas),0) FROM public.orders WHERE cash_state='with_courier'),
  'inventory_value_halalas',(SELECT coalesce(sum(remaining_cost_halalas),0) FROM public.inventory_lots WHERE inspection_state='accepted' AND on_hand_base>0 AND cost_basis<>'unknown'),
  'inventory_unknown_cost_lots',(SELECT count(*) FROM public.inventory_lots WHERE inspection_state='accepted' AND on_hand_base>0 AND cost_basis='unknown'),
  'inventory_estimated_cost_lots',(SELECT count(*) FROM public.inventory_lots WHERE inspection_state='accepted' AND on_hand_base>0 AND cost_basis='estimated'),
  'status_distribution',(SELECT coalesce(jsonb_agg(x),'[]') FROM (SELECT status,count(*) count FROM public.orders WHERE created_at>=startms GROUP BY status)x),
  'expiring_7d',(SELECT coalesce(jsonb_agg(x),'[]') FROM (SELECT l.id,l.stock_id,si.name,l.on_hand_base,l.expires_at FROM public.inventory_lots l JOIN public.stock_items si ON si.id=l.stock_id WHERE l.inspection_state='accepted' AND l.on_hand_base>0 AND l.expires_at BETWEEN nowms AND nowms+604800000 ORDER BY l.expires_at LIMIT 25)x),
  'expired_lots',(SELECT count(*) FROM public.inventory_lots WHERE inspection_state='accepted' AND on_hand_base>0 AND expires_at<=nowms),
  'low_stock',(SELECT coalesce(jsonb_agg(x),'[]') FROM (SELECT si.id,si.name,si.base_unit,sb.on_hand_base-sb.reserved_base available_base FROM public.stock_items si JOIN public.stock_balances sb ON sb.stock_id=si.id ORDER BY available_base,si.id LIMIT 10)x),
  'top_items',(SELECT coalesce(jsonb_agg(x),'[]') FROM (SELECT line->>'name' item_name,sum((line->>'qty')::integer) qty FROM public.orders o CROSS JOIN LATERAL jsonb_array_elements(o.snapshot::jsonb->'lines') line WHERE o.created_at>=startms AND o.status='completed' GROUP BY line->>'name' ORDER BY qty DESC LIMIT 5)x),
  'daily',(SELECT jsonb_agg(jsonb_build_object('report_day',to_char(to_timestamp(d.ms/1000) AT TIME ZONE 'Asia/Riyadh','YYYY-MM-DD'),'order_count',coalesce(o.n,0),'sales_halalas',coalesce(o.sales,0)) ORDER BY d.ms)
   FROM generate_series(startms,todayms,86400000) d(ms) LEFT JOIN
    (SELECT todayms+floor((created_at-todayms)::numeric/86400000)::bigint*86400000 dayms,count(*) n,sum(CASE WHEN status='completed' THEN total_halalas ELSE 0 END) sales FROM public.orders WHERE created_at>=startms GROUP BY dayms)o ON o.dayms=d.ms)
 );
END$$;
REVOKE ALL ON FUNCTION public.jana_admin_reports(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_reports(text) TO service_role;
