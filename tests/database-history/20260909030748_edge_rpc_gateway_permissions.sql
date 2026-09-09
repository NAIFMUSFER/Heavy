grant execute on function public.jana_register(text,text,text,text) to anon;
grant execute on function public.jana_login(text,text) to anon;
grant execute on function public.jana_me(text) to anon;
grant execute on function public.jana_add_address(text,text,text,text,text,text,text,boolean) to anon;
grant execute on function public.jana_list_addresses(text) to anon;
grant execute on function public.jana_public_slots() to anon;
-- Direct table access remains blocked by RLS; only these narrow RPC entrypoints are exposed.