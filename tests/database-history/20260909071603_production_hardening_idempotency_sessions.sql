CREATE UNIQUE INDEX IF NOT EXISTS ux_orders_quote_id ON public.orders(quote_id);
CREATE INDEX IF NOT EXISTS ix_sessions_user_expiry ON public.sessions(user_id,expires_at);
CREATE INDEX IF NOT EXISTS ix_quotes_state_expiry ON public.quotes(state,expires_at);
CREATE INDEX IF NOT EXISTS ix_substitutions_state_expiry ON public.substitutions(state,expires_at);

CREATE OR REPLACE FUNCTION public.jana_list_sessions(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; current_hash text; BEGIN
 u=public.jana_auth_user(p_token); current_hash=encode(digest(p_token,'sha256'),'hex');
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('created_at',s.created_at,'expires_at',s.expires_at,'current',s.token_hash=current_hash) ORDER BY s.created_at DESC) FROM public.sessions s WHERE s.user_id=u.id AND s.expires_at>(extract(epoch from clock_timestamp())*1000)::bigint),'[]'::jsonb);
END$$;
CREATE OR REPLACE FUNCTION public.jana_logout_others(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; current_hash text; n int; BEGIN
 u=public.jana_auth_user(p_token); current_hash=encode(digest(p_token,'sha256'),'hex');
 DELETE FROM public.sessions WHERE user_id=u.id AND token_hash<>current_hash; GET DIAGNOSTICS n=ROW_COUNT;
 RETURN jsonb_build_object('ok',true,'revoked',n);
END$$;
REVOKE ALL ON FUNCTION public.jana_list_sessions(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_logout_others(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_list_sessions(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_logout_others(text) TO service_role;