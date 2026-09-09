create or replace function public.jana_expire_quotes()
returns integer language plpgsql security definer set search_path=public,extensions as $$
declare q record; a jsonb; rec record; n integer=0; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
  for q in select id,slot_id,snapshot from public.quotes where state='active' and expires_at<=nowms for update skip locked loop
    for a in select value from jsonb_array_elements(coalesce(q.snapshot->'allocations','[]'::jsonb)) loop
      update public.inventory_lots set reserved_base=greatest(0,reserved_base-(a->>'base_qty')::bigint) where id=a->>'lot_id';
    end loop;
    for rec in select a->>'stock_id' stock_id,sum((a->>'base_qty')::bigint)::bigint qty from jsonb_array_elements(coalesce(q.snapshot->'allocations','[]'::jsonb)) a group by a->>'stock_id' loop
      update public.stock_balances set reserved_base=greatest(0,reserved_base-rec.qty) where stock_id=rec.stock_id;
    end loop;
    update public.delivery_slots set booked=greatest(0,booked-1) where id=q.slot_id;
    update public.quotes set state='expired' where id=q.id; n=n+1;
  end loop;
  return n;
end$$;
revoke all on function public.jana_expire_quotes() from public,authenticated;
grant execute on function public.jana_expire_quotes() to anon,service_role;