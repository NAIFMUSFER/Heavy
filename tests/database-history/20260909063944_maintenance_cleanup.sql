create or replace function public.jana_maintenance_cleanup()
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
 nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
 q jsonb; s jsonb; n_sessions int; n_rates int; n_positions int;
begin
 begin q:=public.jana_expire_quotes(); exception when others then q:=null; end;
 begin s:=public.jana_expire_substitutions(); exception when others then s:=null; end;
 delete from public.sessions where expires_at<=nowms; get diagnostics n_sessions=row_count;
 delete from public.rate_windows where expires_at<=nowms; get diagnostics n_rates=row_count;
 delete from public.courier_positions where created_at < nowms-604800000; get diagnostics n_positions=row_count;
 return jsonb_build_object('quotes',q,'substitutions',s,'sessions_deleted',n_sessions,'rate_windows_deleted',n_rates,'positions_deleted',n_positions,'ran_at',nowms);
end$$;
revoke all on function public.jana_maintenance_cleanup() from public,anon,authenticated;
grant execute on function public.jana_maintenance_cleanup() to service_role;