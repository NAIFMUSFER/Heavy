create or replace function public.jana_customer_coverage(p_token text,p_address_id text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; a public.addresses; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; zones jsonb; slots jsonb;
begin
 u=public.jana_auth_user(p_token);
 select * into a from public.addresses where id=p_address_id and user_id=u.id;
 if a.id is null then raise exception 'invalid_address'; end if;
 begin perform a.latitude::numeric; perform a.longitude::numeric; exception when others then raise exception 'invalid_coordinates'; end;
 select coalesce(jsonb_agg(jsonb_build_object('id',z.id,'name',z.name,'fee_halalas',z.fee_halalas,'minimum_halalas',z.minimum_halalas)),'[]'::jsonb)
 into zones from public.delivery_zones z where z.active and z.geom is not null and st_covers(z.geom,st_setsrid(st_point(a.longitude::numeric,a.latitude::numeric),4326));
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'zone_id',s.zone_id,'starts_at',s.starts_at,'ends_at',s.ends_at,'cutoff_at',s.cutoff_at,'capacity',s.capacity,'booked',s.booked,'available',greatest(s.capacity-s.booked,0),'zone_name',z.name,'fee_halalas',z.fee_halalas,'minimum_halalas',z.minimum_halalas) order by s.starts_at),'[]'::jsonb)
 into slots from public.delivery_slots s join public.delivery_zones z on z.id=s.zone_id
 where s.active and z.active and s.cutoff_at>nowms and s.booked<s.capacity and z.geom is not null and st_covers(z.geom,st_setsrid(st_point(a.longitude::numeric,a.latitude::numeric),4326));
 return jsonb_build_object('covered',jsonb_array_length(zones)>0,'zones',zones,'slots',slots,'reason',case when jsonb_array_length(zones)>0 then '' else 'العنوان خارج نطاق التغطية الحالي' end);
end $$;

create or replace function public.jana_quote_detail(p_token text,p_quote_id text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; q public.quotes; begin
 u=public.jana_auth_user(p_token); select * into q from public.quotes where id=p_quote_id and user_id=u.id; if q.id is null then raise exception 'quote_not_found'; end if;
 return jsonb_build_object('id',q.id,'state',q.state,'expires_at',q.expires_at,'created_at',q.created_at)||coalesce(q.snapshot,'{}'::jsonb);
end $$;

create or replace function public.jana_cancel_quote(p_token text,p_quote_id text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; q public.quotes; a jsonb; rec record; begin
 u=public.jana_auth_user(p_token); select * into q from public.quotes where id=p_quote_id and user_id=u.id for update; if q.id is null then raise exception 'quote_not_found'; end if;
 if q.state='active' then
   for a in select value from jsonb_array_elements(coalesce(q.snapshot->'allocations','[]'::jsonb)) loop update public.inventory_lots set reserved_base=greatest(0,reserved_base-(a->>'base_qty')::bigint) where id=a->>'lot_id'; end loop;
   for rec in select x->>'stock_id' stock_id,sum((x->>'base_qty')::bigint)::bigint qty from jsonb_array_elements(coalesce(q.snapshot->'allocations','[]'::jsonb)) x group by x->>'stock_id' loop update public.stock_balances set reserved_base=greatest(0,reserved_base-rec.qty) where stock_id=rec.stock_id; end loop;
   update public.delivery_slots set booked=greatest(0,booked-1) where id=q.slot_id; update public.quotes set state='cancelled' where id=q.id;
 end if;
 return jsonb_build_object('id',q.id,'state',(select state from public.quotes where id=q.id));
end $$;

create or replace function public.jana_set_favorite(p_token text,p_family_id text,p_present boolean)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; begin
 u=public.jana_auth_user(p_token);
 if p_present then insert into public.favorites(user_id,offering_family_id,created_at) values(u.id,p_family_id,nowms) on conflict do nothing; else delete from public.favorites where user_id=u.id and offering_family_id=p_family_id; end if;
 return jsonb_build_object('offering_family_id',p_family_id,'present',p_present);
end $$;

create or replace function public.jana_shopping_lists(p_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; outv jsonb; begin
 u=public.jana_auth_user(p_token);
 select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,'created_at',l.created_at,'updated_at',l.updated_at,'items',coalesce((select jsonb_agg(jsonb_build_object('offering_family_id',i->>'offering_family_id','quantity',(i->>'quantity')::int,'available',o.id is not null,'offering_id',o.id,'version',o.version,'name',o.name,'price_halalas',o.price_halalas,'emoji',o.emoji,'size_label',o.size_label,'sale_unit',o.sale_unit) order by i.ord) from jsonb_array_elements(l.items) with ordinality i(value,ord) left join lateral (select * from public.offerings oo where oo.family_id=i.value->>'offering_family_id' and oo.active order by oo.version desc limit 1) o on true),'[]'::jsonb)) order by l.updated_at desc),'[]'::jsonb) into outv from public.shopping_lists l where l.user_id=u.id;
 return outv;
end $$;

create or replace function public.jana_create_shopping_list(p_token text,p_name text,p_items jsonb)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; lid text='lst-'||replace(gen_random_uuid()::text,'-',''); nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; begin
 u=public.jana_auth_user(p_token); p_name=trim(p_name); if length(p_name)<1 or length(p_name)>100 then raise exception 'invalid_list_name'; end if; if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>60 then raise exception 'invalid_list_items'; end if;
 insert into public.shopping_lists(id,user_id,name,items,created_at,updated_at) values(lid,u.id,p_name,p_items,nowms,nowms); return jsonb_build_object('id',lid,'name',p_name);
end $$;

create or replace function public.jana_delete_shopping_list(p_token text,p_list_id text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$ declare u public.users; n int; begin u=public.jana_auth_user(p_token); delete from public.shopping_lists where id=p_list_id and user_id=u.id; get diagnostics n=row_count; if n=0 then raise exception 'list_not_found'; end if; return jsonb_build_object('deleted',true); end $$;

create or replace function public.jana_recurring_list(p_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$ declare u public.users; outv jsonb; begin u=public.jana_auth_user(p_token); select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'address_id',r.address_id,'cart',r.cart,'interval_days',r.interval_days,'next_at',r.next_at,'state',r.state,'last_notice_at',r.last_notice_at) order by r.next_at),'[]'::jsonb) into outv from public.recurring_plans r where r.user_id=u.id; return outv; end $$;

create or replace function public.jana_recurring_create(p_token text,p_address_id text,p_cart jsonb,p_interval_days int,p_next_at bigint)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$ declare u public.users; rid text='rec-'||replace(gen_random_uuid()::text,'-',''); begin u=public.jana_auth_user(p_token); if not exists(select 1 from public.addresses where id=p_address_id and user_id=u.id) then raise exception 'invalid_address'; end if; if p_interval_days<1 or p_interval_days>90 then raise exception 'invalid_interval'; end if; if jsonb_typeof(p_cart)<>'array' or jsonb_array_length(p_cart)<1 then raise exception 'invalid_cart'; end if; insert into public.recurring_plans(id,user_id,address_id,cart,interval_days,next_at,state,last_notice_at) values(rid,u.id,p_address_id,p_cart,p_interval_days,p_next_at,'active',null); return jsonb_build_object('id',rid,'state','active'); end $$;

create or replace function public.jana_recurring_update(p_token text,p_plan_id text,p_state text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$ declare u public.users; n int; begin u=public.jana_auth_user(p_token); if p_state not in ('active','paused','cancelled') then raise exception 'invalid_state'; end if; update public.recurring_plans set state=p_state where id=p_plan_id and user_id=u.id; get diagnostics n=row_count; if n=0 then raise exception 'plan_not_found'; end if; return jsonb_build_object('id',p_plan_id,'state',p_state); end $$;

create or replace function public.jana_customer_ticket_reply(p_token text,p_ticket_id text,p_message text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$ declare u public.users; t public.tickets; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; begin u=public.jana_auth_user(p_token); select * into t from public.tickets where id=p_ticket_id and user_id=u.id for update; if t.id is null then raise exception 'ticket_not_found'; end if; if length(trim(p_message))<2 or length(p_message)>3000 then raise exception 'invalid_message'; end if; update public.tickets set messages=coalesce(messages,'[]'::json)||json_build_array(json_build_object('actor','customer','text',trim(p_message),'at',nowms)),updated_at=nowms,state='open' where id=t.id; return jsonb_build_object('id',t.id,'state','open'); end $$;

create or replace function public.jana_request_refund(p_token text,p_order_id text,p_component_id text,p_amount_halalas bigint,p_reason text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$ declare u public.users; o public.orders; comp jsonb; already bigint; rid text='rfd-'||replace(gen_random_uuid()::text,'-',''); nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; maxamt bigint; begin u=public.jana_auth_user(p_token); select * into o from public.orders where id=p_order_id and user_id=u.id for update; if o.id is null then raise exception 'order_not_found'; end if; if o.delivery_state<>'delivered' then raise exception 'not_delivered'; end if; select c into comp from jsonb_array_elements(coalesce(o.snapshot->'lines','[]'::jsonb)) l cross join lateral jsonb_array_elements(coalesce(l->'components','[]'::jsonb)) c where c->>'id'=p_component_id limit 1; if comp is null then raise exception 'component_not_found'; end if; maxamt=coalesce((comp->>'charge_halalas')::bigint,0); select coalesce(sum(amount_halalas),0) into already from public.refunds where order_id=o.id and component_id=p_component_id and state in ('requested','processing','completed'); if p_amount_halalas<=0 or p_amount_halalas>greatest(maxamt-already,0) then raise exception 'refund_amount_invalid'; end if; insert into public.refunds(id,order_id,component_id,amount_halalas,reason,state,requested_by,approved_by,reference,created_at) values(rid,o.id,p_component_id,p_amount_halalas,left(trim(p_reason),1000),'requested',u.id,null,'',nowms); return jsonb_build_object('id',rid,'state','requested','amount_halalas',p_amount_halalas); end $$;

create or replace function public.jana_anonymize_account(p_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$ declare u public.users; begin u=public.jana_auth_user(p_token); if exists(select 1 from public.orders where user_id=u.id and status='active') then raise exception 'active_orders'; end if; if exists(select 1 from public.quotes where user_id=u.id and state='active') then raise exception 'active_quotes'; end if; delete from public.sessions where user_id=u.id; delete from public.recurring_plans where user_id=u.id; delete from public.favorites where user_id=u.id; delete from public.shopping_lists where user_id=u.id; delete from public.addresses where user_id=u.id; update public.users set name='حساب محذوف',email=u.id||'@deleted.invalid',phone=null,password_hash=crypt(encode(gen_random_bytes(32),'hex'),gen_salt('bf',12)),active=false where id=u.id; return jsonb_build_object('state','anonymized','retained','سجلات الطلبات والعمليات المالية محفوظة للمراجعة'); end $$;

revoke all on function public.jana_customer_coverage(text,text) from public,anon,authenticated;
revoke all on function public.jana_quote_detail(text,text) from public,anon,authenticated;
revoke all on function public.jana_cancel_quote(text,text) from public,anon,authenticated;
revoke all on function public.jana_set_favorite(text,text,boolean) from public,anon,authenticated;
revoke all on function public.jana_shopping_lists(text) from public,anon,authenticated;
revoke all on function public.jana_create_shopping_list(text,text,jsonb) from public,anon,authenticated;
revoke all on function public.jana_delete_shopping_list(text,text) from public,anon,authenticated;
revoke all on function public.jana_recurring_list(text) from public,anon,authenticated;
revoke all on function public.jana_recurring_create(text,text,jsonb,int,bigint) from public,anon,authenticated;
revoke all on function public.jana_recurring_update(text,text,text) from public,anon,authenticated;
revoke all on function public.jana_customer_ticket_reply(text,text,text) from public,anon,authenticated;
revoke all on function public.jana_request_refund(text,text,text,bigint,text) from public,anon,authenticated;
revoke all on function public.jana_anonymize_account(text) from public,anon,authenticated;
grant execute on function public.jana_customer_coverage(text,text),public.jana_quote_detail(text,text),public.jana_cancel_quote(text,text),public.jana_set_favorite(text,text,boolean),public.jana_shopping_lists(text),public.jana_create_shopping_list(text,text,jsonb),public.jana_delete_shopping_list(text,text),public.jana_recurring_list(text),public.jana_recurring_create(text,text,jsonb,int,bigint),public.jana_recurring_update(text,text,text),public.jana_customer_ticket_reply(text,text,text),public.jana_request_refund(text,text,text,bigint,text),public.jana_anonymize_account(text) to service_role;