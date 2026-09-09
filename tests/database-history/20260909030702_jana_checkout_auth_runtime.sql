create extension if not exists pgcrypto;

create or replace function public.jana_auth_user(p_token text)
returns public.users
language plpgsql security definer set search_path=public,extensions
as $$
declare u public.users; th text;
begin
  if p_token is null or length(p_token)<32 then raise exception 'unauthorized'; end if;
  th=encode(digest(p_token,'sha256'),'hex');
  select x.* into u from public.sessions s join public.users x on x.id=s.user_id where s.token_hash=th and s.expires_at>(extract(epoch from clock_timestamp())*1000)::bigint and x.active limit 1;
  if u.id is null then raise exception 'unauthorized'; end if;
  return u;
end$$;

create or replace function public.jana_register(p_email text,p_name text,p_password text,p_phone text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid text; tok text; csrf text; nowms bigint; expms bigint;
begin
  p_email=lower(trim(p_email)); p_name=trim(p_name);
  if p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'invalid_email'; end if;
  if length(p_name)<2 or length(p_name)>80 then raise exception 'invalid_name'; end if;
  if length(p_password)<10 or length(p_password)>128 then raise exception 'weak_password'; end if;
  if exists(select 1 from public.users where email=p_email) then raise exception 'email_exists'; end if;
  uid='usr-'||replace(gen_random_uuid()::text,'-',''); nowms=(extract(epoch from clock_timestamp())*1000)::bigint; expms=nowms+2592000000;
  insert into public.users(id,email,phone,name,password_hash,role,verified_phone,active,created_at)
  values(uid,p_email,nullif(trim(p_phone),''),p_name,crypt(p_password,gen_salt('bf',12)),'customer',false,true,nowms);
  tok=encode(gen_random_bytes(32),'hex'); csrf=encode(gen_random_bytes(24),'hex');
  insert into public.sessions(token_hash,user_id,csrf_hash,expires_at,created_at) values(encode(digest(tok,'sha256'),'hex'),uid,encode(digest(csrf,'sha256'),'hex'),expms,nowms);
  return jsonb_build_object('token',tok,'csrf',csrf,'expires_at',expms,'user',jsonb_build_object('id',uid,'email',p_email,'name',p_name,'role','customer'));
end$$;

create or replace function public.jana_login(p_email text,p_password text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare u public.users; tok text; csrf text; nowms bigint; expms bigint;
begin
  select * into u from public.users where email=lower(trim(p_email)) and active limit 1;
  if u.id is null or u.password_hash is null or crypt(p_password,u.password_hash)<>u.password_hash then raise exception 'invalid_credentials'; end if;
  nowms=(extract(epoch from clock_timestamp())*1000)::bigint; expms=nowms+2592000000; tok=encode(gen_random_bytes(32),'hex'); csrf=encode(gen_random_bytes(24),'hex');
  insert into public.sessions(token_hash,user_id,csrf_hash,expires_at,created_at) values(encode(digest(tok,'sha256'),'hex'),u.id,encode(digest(csrf,'sha256'),'hex'),expms,nowms);
  return jsonb_build_object('token',tok,'csrf',csrf,'expires_at',expms,'user',jsonb_build_object('id',u.id,'email',u.email,'name',u.name,'role',u.role));
end$$;

create or replace function public.jana_me(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$ declare u public.users; begin u=public.jana_auth_user(p_token); return jsonb_build_object('id',u.id,'email',u.email,'phone',u.phone,'name',u.name,'role',u.role,'verified_phone',u.verified_phone); end$$;

create or replace function public.jana_add_address(p_token text,p_label text,p_details text,p_latitude text,p_longitude text,p_recipient_name text,p_recipient_phone text,p_default boolean default true)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare u public.users; aid text;
begin
  u=public.jana_auth_user(p_token); if length(trim(p_details))<5 then raise exception 'invalid_address'; end if;
  if p_default then update public.addresses set is_default=false where user_id=u.id; end if;
  aid='addr-'||replace(gen_random_uuid()::text,'-','');
  insert into public.addresses(id,user_id,label,details,latitude,longitude,recipient_name,recipient_phone,is_default)
  values(aid,u.id,left(coalesce(nullif(trim(p_label),''),'المنزل'),40),left(trim(p_details),500),trim(p_latitude),trim(p_longitude),left(trim(p_recipient_name),80),left(trim(p_recipient_phone),30),p_default);
  return jsonb_build_object('id',aid,'label',p_label,'details',p_details,'latitude',p_latitude,'longitude',p_longitude,'is_default',p_default);
end$$;

create or replace function public.jana_list_addresses(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare u public.users; r jsonb; begin u=public.jana_auth_user(p_token); select coalesce(jsonb_agg(to_jsonb(a) order by a.is_default desc,a.label),'[]'::jsonb) into r from public.addresses a where a.user_id=u.id; return r; end$$;

create or replace function public.jana_public_slots()
returns jsonb language sql security definer set search_path=public as $$
select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'zone_id',s.zone_id,'zone_name',z.name,'starts_at',s.starts_at,'ends_at',s.ends_at,'cutoff_at',s.cutoff_at,'capacity',s.capacity,'available',greatest(s.capacity-s.booked,0),'fee_halalas',z.fee_halalas,'minimum_halalas',z.minimum_halalas) order by s.starts_at),'[]'::jsonb)
from public.delivery_slots s join public.delivery_zones z on z.id=s.zone_id where s.active and z.active and s.cutoff_at>(extract(epoch from clock_timestamp())*1000)::bigint and s.booked<s.capacity$$;

revoke all on function public.jana_auth_user(text) from public,anon,authenticated;
revoke all on function public.jana_register(text,text,text,text) from public,anon,authenticated;
revoke all on function public.jana_login(text,text) from public,anon,authenticated;
revoke all on function public.jana_me(text) from public,anon,authenticated;
revoke all on function public.jana_add_address(text,text,text,text,text,text,text,boolean) from public,anon,authenticated;
revoke all on function public.jana_list_addresses(text) from public,anon,authenticated;
revoke all on function public.jana_public_slots() from public,anon,authenticated;
grant execute on function public.jana_register(text,text,text,text) to service_role;
grant execute on function public.jana_login(text,text) to service_role;
grant execute on function public.jana_me(text) to service_role;
grant execute on function public.jana_add_address(text,text,text,text,text,text,text,boolean) to service_role;
grant execute on function public.jana_list_addresses(text) to service_role;
grant execute on function public.jana_public_slots() to service_role;