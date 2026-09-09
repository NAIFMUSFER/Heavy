ALTER FUNCTION public.jana_ops_transition(text,text,text,text) SET search_path = public, extensions, pg_temp;
ALTER FUNCTION public.jana_admin_dashboard(text) SET search_path = public, extensions, pg_temp;
ALTER FUNCTION public.jana_admin_orders(text) SET search_path = public, extensions, pg_temp;
ALTER FUNCTION public.jana_finance_settle(text,text,text) SET search_path = public, extensions, pg_temp;