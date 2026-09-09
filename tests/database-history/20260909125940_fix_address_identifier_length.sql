create or replace function public.jana_add_address(p_token text,p_label text,p_details text,p_latitude text,p_longitude text,p_recipient_name text,p_recipient_phone text,p_default boolean default true)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; aid text;
begin
  u=public.jana_auth_user(p_token); if length(trim(p_details))<5 then raise exception 'invalid_address'; end if;
  if p_default then update public.addresses set is_default=false where user_id=u.id; end if;
  aid='adr-'||replace(gen_random_uuid()::text,'-','');
  insert into public.addresses(id,user_id,label,details,latitude,longitude,recipient_name,recipient_phone,is_default)
  values(aid,u.id,left(coalesce(nullif(trim(p_label),''),'المنزل'),40),left(trim(p_details),500),trim(p_latitude),trim(p_longitude),left(trim(p_recipient_name),80),left(trim(p_recipient_phone),30),p_default);
  return jsonb_build_object('id',aid,'label',p_label,'details',p_details,'latitude',p_latitude,'longitude',p_longitude,'recipient_name',p_recipient_name,'recipient_phone',p_recipient_phone,'is_default',p_default);
end $$;
revoke all on function public.jana_add_address(text,text,text,text,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.jana_add_address(text,text,text,text,text,text,text,boolean) to service_role;