create or replace function public.jana_admin_reports(p_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare uid varchar; r varchar; nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint; startms bigint := nowms-604800000; sales bigint; costs bigint; refunds_total bigint; completed_count bigint;
begin
 select s.user_id,u.role into uid,r from public.sessions s join public.users u on u.id=s.user_id where s.token_hash=encode(digest(p_token,'sha256'),'hex') and s.expires_at>nowms and u.active=true limit 1;
 if uid is null or r not in ('admin','finance','inventory','support') then raise exception 'unauthorized'; end if;
 select coalesce(sum(o.total_halalas),0),count(*) into sales,completed_count from public.orders o where o.created_at>=startms and o.status='completed';
 select coalesce(sum(c.amount_halalas),0) into costs from public.order_costs c join public.orders o on o.id=c.order_id where o.created_at>=startms and o.status='completed';
 select coalesce(sum(amount_halalas),0) into refunds_total from public.refunds where created_at>=startms and state='completed';
 return jsonb_build_object(
  'sales_7d_halalas',sales,
  'orders_7d',(select count(*) from public.orders where created_at>=startms),
  'completed_7d',completed_count,
  'avg_completed_order_halalas',case when completed_count>0 then sales/completed_count else 0 end,
  'refunds_7d_halalas',refunds_total,
  'recognized_costs_7d_halalas',costs,
  'gross_profit_7d_halalas',sales-costs-refunds_total,
  'gross_margin_bps',case when sales>0 then round(((sales-costs-refunds_total)::numeric/sales::numeric)*10000)::bigint else 0 end,
  'cash_unsettled_halalas',(select coalesce(sum(collected_halalas-refunded_halalas),0) from public.orders where cash_state='with_courier'),
  'inventory_value_halalas',(select coalesce(sum(case when l.on_hand_base>0 and l.remaining_cost_halalas is not null then l.remaining_cost_halalas else 0 end),0) from public.inventory_lots l where l.inspection_state='accepted'),
  'expiring_7d',coalesce((select jsonb_agg(x order by x.expires_at) from (select l.id,l.stock_id,si.name,l.on_hand_base,l.expires_at from public.inventory_lots l join public.stock_items si on si.id=l.stock_id where l.inspection_state='accepted' and l.on_hand_base>0 and l.expires_at between nowms and nowms+604800000 limit 25)x),'[]'::jsonb),
  'top_items',coalesce((select jsonb_agg(x) from (select l->>'name' as item_name,sum((l->>'qty')::int) as qty from public.orders o cross join lateral jsonb_array_elements(o.snapshot::jsonb->'lines') l where o.created_at>=startms group by l->>'name' order by qty desc limit 5)x),'[]'::jsonb),
  'low_stock',coalesce((select jsonb_agg(x) from (select si.id,si.name,(sb.on_hand_base-sb.reserved_base) available_base from public.stock_items si join public.stock_balances sb on sb.stock_id=si.id order by available_base asc limit 10)x),'[]'::jsonb),
  'daily',coalesce((select jsonb_agg(x order by x.report_day) from (select to_char(to_timestamp(o.created_at/1000.0) at time zone 'Asia/Riyadh','YYYY-MM-DD') as report_day,count(*) as order_count,sum(case when o.status='completed' then o.total_halalas else 0 end) as sales_halalas from public.orders o where o.created_at>=startms group by 1)x),'[]'::jsonb)
 );
end$$;
revoke all on function public.jana_admin_reports(text) from public,anon,authenticated;
grant execute on function public.jana_admin_reports(text) to service_role;