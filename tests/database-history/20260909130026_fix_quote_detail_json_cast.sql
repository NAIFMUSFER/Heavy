create or replace function public.jana_quote_detail(p_token text,p_quote_id text)
returns jsonb language plpgsql security definer set search_path='public','extensions' as $$
declare u public.users; q public.quotes; begin
 u=public.jana_auth_user(p_token); select * into q from public.quotes where id=p_quote_id and user_id=u.id; if q.id is null then raise exception 'quote_not_found'; end if;
 return jsonb_build_object('id',q.id,'state',q.state,'expires_at',q.expires_at,'created_at',q.created_at) || coalesce(q.snapshot::jsonb,'{}'::jsonb);
end $$;
revoke all on function public.jana_quote_detail(text,text) from public,anon,authenticated;
grant execute on function public.jana_quote_detail(text,text) to service_role;