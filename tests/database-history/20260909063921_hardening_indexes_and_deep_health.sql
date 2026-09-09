create index if not exists courier_positions_courier_id_idx on public.courier_positions(courier_id);

revoke execute on function public.st_estimatedextent(text,text) from anon, authenticated;
revoke execute on function public.st_estimatedextent(text,text,text) from anon, authenticated;
revoke execute on function public.st_estimatedextent(text,text,text,boolean) from anon, authenticated;

create or replace function public.jana_deep_health()
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
  neg_stock int;
  bad_reserved int;
  overbooked int;
  duplicate_quotes int;
  bad_cash int;
  expired_sessions int;
begin
  select count(*) into neg_stock from public.stock_balances where on_hand_base < 0 or reserved_base < 0;
  select count(*) into bad_reserved from public.stock_balances where reserved_base > on_hand_base;
  select count(*) into overbooked from public.delivery_slots where booked < 0 or booked > capacity;
  select count(*) into duplicate_quotes from (select quote_id from public.orders where quote_id is not null group by quote_id having count(*) > 1) d;
  select count(*) into bad_cash from public.orders where (cash_state='settled' and payment_state<>'collected') or refunded_halalas > collected_halalas;
  select count(*) into expired_sessions from public.sessions where expires_at <= nowms;
  return jsonb_build_object(
    'ok', neg_stock=0 and bad_reserved=0 and overbooked=0 and duplicate_quotes=0 and bad_cash=0,
    'negative_stock',neg_stock,
    'reserved_gt_on_hand',bad_reserved,
    'overbooked_slots',overbooked,
    'duplicate_quote_orders',duplicate_quotes,
    'cash_invariant_violations',bad_cash,
    'expired_sessions',expired_sessions,
    'catalog_active',(select count(*) from public.offerings where active),
    'slots_active',(select count(*) from public.delivery_slots where active),
    'checked_at',nowms
  );
end$$;
revoke all on function public.jana_deep_health() from public,anon,authenticated;
grant execute on function public.jana_deep_health() to service_role;