create or replace function public.jana_create_quote(p_token text,p_slot_id text,p_address_id text,p_items jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
 u public.users; a public.addresses; s public.delivery_slots; z public.delivery_zones;
 qid text; nowms bigint; expms bigint; subtotal bigint; delivery_fee bigint; total bigint;
 lines jsonb; allocations jsonb='[]'::jsonb; rec record; lotrec record; need bigint; take bigint;
begin
 u=public.jana_auth_user(p_token);
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>40 then raise exception 'invalid_cart'; end if;
 select * into a from public.addresses where id=p_address_id and user_id=u.id; if a.id is null then raise exception 'invalid_address'; end if;
 begin perform a.latitude::numeric; perform a.longitude::numeric; exception when others then raise exception 'invalid_coordinates'; end;
 select * into s from public.delivery_slots where id=p_slot_id for update; if s.id is null or not s.active then raise exception 'slot_unavailable'; end if;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 if s.cutoff_at<=nowms or s.booked>=s.capacity then raise exception 'slot_unavailable'; end if;
 select * into z from public.delivery_zones where id=s.zone_id and active;
 if z.id is null then raise exception 'zone_unavailable'; end if;
 if z.geom is not null and not st_covers(z.geom,st_setsrid(st_point(a.longitude::numeric,a.latitude::numeric),4326)) then raise exception 'outside_zone'; end if;
 with item as (
   select e->>'offering_id' oid, (e->>'qty')::int qty from jsonb_array_elements(p_items) e
 ), valid as (
   select i.oid,i.qty,o.* from item i join public.offerings o on o.id=i.oid and o.active where i.qty between 1 and 20
 )
 select coalesce(sum(price_halalas*qty),0)::bigint,
        coalesce(jsonb_agg(jsonb_build_object('line_id','ln-'||replace(gen_random_uuid()::text,'-',''),'offering_id',id,'family_id',family_id,'version',version,'kind',kind,'name',name,'sale_unit',sale_unit,'unit_price_halalas',price_halalas,'qty',qty,'line_total_halalas',price_halalas*qty,'components',components)),'[]'::jsonb)
 into subtotal,lines from valid;
 if jsonb_array_length(lines)<>jsonb_array_length(p_items) then raise exception 'invalid_cart'; end if;
 if subtotal<z.minimum_halalas then raise exception 'below_minimum'; end if;
 for rec in
   with item as (select e->>'offering_id' oid,(e->>'qty')::int qty from jsonb_array_elements(p_items)e),
   req as (select c->>'stock_id' stock_id,sum(((c->>'base_qty')::bigint)*i.qty)::bigint base_qty from item i join public.offerings o on o.id=i.oid cross join lateral json_array_elements(o.components)c group by c->>'stock_id')
   select * from req order by stock_id
 loop
   perform 1 from public.stock_balances where stock_id=rec.stock_id for update;
   if not found or (select on_hand_base-reserved_base from public.stock_balances where stock_id=rec.stock_id)<rec.base_qty then raise exception 'insufficient_stock'; end if;
   need=rec.base_qty;
   for lotrec in select id,(on_hand_base-reserved_base) avail from public.inventory_lots where stock_id=rec.stock_id and inspection_state='accepted' and on_hand_base>reserved_base order by expires_at,id for update loop
     exit when need<=0; take=least(need,lotrec.avail); update public.inventory_lots set reserved_base=reserved_base+take where id=lotrec.id; allocations=allocations||jsonb_build_array(jsonb_build_object('stock_id',rec.stock_id,'lot_id',lotrec.id,'base_qty',take)); need=need-take;
   end loop;
   if need>0 then raise exception 'insufficient_lot_stock'; end if;
   update public.stock_balances set reserved_base=reserved_base+rec.base_qty where stock_id=rec.stock_id;
 end loop;
 update public.delivery_slots set booked=booked+1 where id=s.id;
 delivery_fee=z.fee_halalas; total=subtotal+delivery_fee; qid='q-'||replace(gen_random_uuid()::text,'-',''); expms=least(nowms+900000,s.cutoff_at);
 insert into public.quotes(id,user_id,slot_id,coupon_id,snapshot,state,expires_at,created_at)
 values(qid,u.id,s.id,null,jsonb_build_object('lines',lines,'allocations',allocations,'subtotal_halalas',subtotal,'delivery_fee_halalas',delivery_fee,'total_halalas',total,'address',to_jsonb(a),'slot',jsonb_build_object('id',s.id,'starts_at',s.starts_at,'ends_at',s.ends_at,'zone_id',z.id,'zone_name',z.name)),'active',expms,nowms);
 return jsonb_build_object('id',qid,'state','active','expires_at',expms,'subtotal_halalas',subtotal,'delivery_fee_halalas',delivery_fee,'total_halalas',total,'lines',lines,'slot',jsonb_build_object('id',s.id,'starts_at',s.starts_at,'ends_at',s.ends_at,'zone_name',z.name));
end$$;

create or replace function public.jana_confirm_order(p_token text,p_quote_id text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare u public.users; q public.quotes; existing public.orders; oid text; ono text; code text; nowms bigint; total bigint;
begin
 u=public.jana_auth_user(p_token);
 select * into existing from public.orders where quote_id=p_quote_id and user_id=u.id limit 1;
 if existing.id is not null then return jsonb_build_object('id',existing.id,'number',existing.number,'total_halalas',existing.total_halalas,'status',existing.status,'payment_state',existing.payment_state,'fulfillment_state',existing.fulfillment_state,'delivery_state',existing.delivery_state,'idempotent_replay',true); end if;
 select * into q from public.quotes where id=p_quote_id and user_id=u.id for update;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 if q.id is null then raise exception 'quote_not_found'; end if; if q.state<>'active' or q.expires_at<=nowms then raise exception 'quote_expired'; end if;
 total=(q.snapshot->>'total_halalas')::bigint; oid='ord-'||replace(gen_random_uuid()::text,'-',''); ono='JN-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)); code=lpad((floor(random()*1000000))::int::text,6,'0');
 insert into public.orders(id,number,quote_id,user_id,slot_id,status,payment_state,fulfillment_state,delivery_state,snapshot,original_snapshot,total_halalas,collected_halalas,refunded_halalas,cash_state,picker_id,courier_id,code_cipher,code_hash,code_attempts,code_expires_at,created_at)
 values(oid,ono,q.id,u.id,q.slot_id,'active','awaiting_collection','queued','unassigned',q.snapshot,q.snapshot,total,0,0,'uncollected',null,null,null,encode(digest(code,'sha256'),'hex'),0,nowms+172800000,nowms);
 update public.quotes set state='converted' where id=q.id;
 insert into public.order_events(id,order_id,actor_id,event,reason,states,created_at) values('evt-'||replace(gen_random_uuid()::text,'-',''),oid,u.id,'order_created','customer_confirmed',jsonb_build_object('status','active','payment_state','awaiting_collection','fulfillment_state','queued','delivery_state','unassigned'),nowms);
 insert into public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) values('ntf-'||replace(gen_random_uuid()::text,'-',''),u.id,'order-created-'||oid,'تم تأكيد طلبك','رقم الطلب '||ono,oid,false,nowms);
 return jsonb_build_object('id',oid,'number',ono,'total_halalas',total,'status','active','payment_state','awaiting_collection','fulfillment_state','queued','delivery_state','unassigned','delivery_code',code,'idempotent_replay',false);
end$$;

create or replace function public.jana_my_orders(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$ declare u public.users; r jsonb; begin u=public.jana_auth_user(p_token); select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'payment_state',o.payment_state,'fulfillment_state',o.fulfillment_state,'delivery_state',o.delivery_state,'total_halalas',o.total_halalas,'created_at',o.created_at,'snapshot',o.snapshot) order by o.created_at desc),'[]'::jsonb) into r from public.orders o where o.user_id=u.id; return r; end$$;

revoke all on function public.jana_create_quote(text,text,text,jsonb) from public,authenticated; revoke all on function public.jana_confirm_order(text,text) from public,authenticated; revoke all on function public.jana_my_orders(text) from public,authenticated;
grant execute on function public.jana_create_quote(text,text,text,jsonb) to anon,service_role; grant execute on function public.jana_confirm_order(text,text) to anon,service_role; grant execute on function public.jana_my_orders(text) to anon,service_role;