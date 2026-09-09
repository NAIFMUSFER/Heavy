create or replace function public.jana_admin_catalog(p_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 return jsonb_build_object(
  'offerings',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.offerings o),'[]'::jsonb),
  'stock',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'base_unit',s.base_unit,'active',s.active,'on_hand_base',coalesce(b.on_hand_base,0),'reserved_base',coalesce(b.reserved_base,0)) order by s.name) from public.stock_items s left join public.stock_balances b on b.stock_id=s.id),'[]'::jsonb),
  'suppliers',coalesce((select jsonb_agg(to_jsonb(s) order by s.name) from public.suppliers s),'[]'::jsonb),
  'lots',coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc) from public.inventory_lots l),'[]'::jsonb),
  'zones',coalesce((select jsonb_agg(jsonb_build_object('id',z.id,'name',z.name,'fee_halalas',z.fee_halalas,'minimum_halalas',z.minimum_halalas,'active',z.active) order by z.name) from public.delivery_zones z),'[]'::jsonb),
  'slots',coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at desc) from public.delivery_slots s),'[]'::jsonb),
  'coupons',coalesce((select jsonb_agg(to_jsonb(c) order by c.expires_at desc) from public.coupons c),'[]'::jsonb)
 );
end$$;

create or replace function public.jana_admin_set_offering_active(p_token text,p_offering_id text,p_active boolean)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; o public.offerings; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 update public.offerings set active=p_active where id=p_offering_id returning * into o; if o.id is null then raise exception 'offering_not_found'; end if;
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'offering_active',o.id,jsonb_build_object('active',p_active),nowms);
 return jsonb_build_object('id',o.id,'active',o.active); end$$;

create or replace function public.jana_admin_set_coupon_active(p_token text,p_coupon_id text,p_active boolean)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; c public.coupons; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 update public.coupons set active=p_active where id=p_coupon_id returning * into c; if c.id is null then raise exception 'coupon_not_found'; end if;
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'coupon_active',c.id,jsonb_build_object('active',p_active),nowms);
 return jsonb_build_object('id',c.id,'active',c.active); end$$;

create or replace function public.jana_admin_set_slot_active(p_token text,p_slot_id text,p_active boolean)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; s public.delivery_slots; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 update public.delivery_slots set active=p_active where id=p_slot_id returning * into s; if s.id is null then raise exception 'slot_not_found'; end if;
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'slot_active',s.id,jsonb_build_object('active',p_active),nowms);
 return jsonb_build_object('id',s.id,'active',s.active); end$$;