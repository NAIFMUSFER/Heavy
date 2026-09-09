create or replace function public.jana_admin_create_supplier(p_token text,p_name text,p_phone text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; sid text; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 p_name=trim(coalesce(p_name,'')); p_phone=trim(coalesce(p_phone,'')); if length(p_name)<2 or length(p_name)>120 then raise exception 'invalid_supplier'; end if; if length(p_phone)>30 then raise exception 'invalid_supplier'; end if;
 sid='sup-'||replace(gen_random_uuid()::text,'-',''); insert into public.suppliers(id,name,phone,active) values(sid,p_name,p_phone,true);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'supplier_created',sid,jsonb_build_object('name',p_name),nowms);
 return jsonb_build_object('id',sid,'name',p_name,'phone',p_phone,'active',true); end$$;

create or replace function public.jana_admin_create_coupon(p_token text,p_code text,p_amount_halalas bigint,p_minimum_halalas bigint,p_max_uses integer,p_expires_at bigint)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; cid text; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; code text;
begin u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 code=upper(trim(coalesce(p_code,''))); if code !~ '^[A-Z0-9_-]{3,24}$' then raise exception 'invalid_coupon'; end if; if p_amount_halalas<=0 or p_minimum_halalas<0 or p_max_uses<=0 or p_max_uses>100000 or p_expires_at<=nowms then raise exception 'invalid_coupon'; end if;
 cid='cpn-'||replace(gen_random_uuid()::text,'-',''); insert into public.coupons(id,code,amount_halalas,minimum_halalas,max_uses,reserved,redeemed,expires_at,active) values(cid,code,p_amount_halalas,p_minimum_halalas,p_max_uses,0,0,p_expires_at,true);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'coupon_created',cid,jsonb_build_object('code',code,'amount_halalas',p_amount_halalas),nowms);
 return jsonb_build_object('id',cid,'code',code,'amount_halalas',p_amount_halalas,'minimum_halalas',p_minimum_halalas,'max_uses',p_max_uses,'expires_at',p_expires_at,'active',true); end$$;

create or replace function public.jana_admin_create_slot(p_token text,p_zone_id text,p_starts_at bigint,p_ends_at bigint,p_cutoff_at bigint,p_capacity integer)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; sid text; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 if not exists(select 1 from public.delivery_zones where id=p_zone_id and active) then raise exception 'zone_not_found'; end if; if p_capacity<=0 or p_capacity>10000 or p_starts_at<=nowms or p_ends_at<=p_starts_at or p_cutoff_at>p_starts_at then raise exception 'invalid_slot'; end if;
 sid='slot-'||replace(gen_random_uuid()::text,'-',''); insert into public.delivery_slots(id,zone_id,starts_at,ends_at,cutoff_at,capacity,booked,active) values(sid,p_zone_id,p_starts_at,p_ends_at,p_cutoff_at,p_capacity,0,true);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'slot_created',sid,jsonb_build_object('zone_id',p_zone_id,'starts_at',p_starts_at,'capacity',p_capacity),nowms);
 return jsonb_build_object('id',sid,'zone_id',p_zone_id,'starts_at',p_starts_at,'ends_at',p_ends_at,'cutoff_at',p_cutoff_at,'capacity',p_capacity,'booked',0,'active',true); end$$;