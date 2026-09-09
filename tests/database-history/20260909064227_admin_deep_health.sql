create or replace function public.jana_admin_deep_health(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare u public.users;
begin
 u=public.jana_auth_user(p_token);
 if u.role<>'admin' then raise exception 'unauthorized'; end if;
 return public.jana_deep_health();
end$$;
revoke all on function public.jana_admin_deep_health(text) from public,authenticated;
grant execute on function public.jana_admin_deep_health(text) to anon;