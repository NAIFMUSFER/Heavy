-- A cart is an explicit saved selection, never a stock or slot reservation.
CREATE TABLE public.customer_carts(
 user_id varchar(36) PRIMARY KEY REFERENCES public.users(id),
 items jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(items)='array' AND jsonb_array_length(items)<=40),
 revision bigint NOT NULL CHECK(revision>0),
 updated_at bigint NOT NULL
);
ALTER TABLE public.customer_carts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_carts FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.jana_customer_cart(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u public.users;c public.customer_carts;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO c FROM public.customer_carts WHERE user_id=u.id;
 RETURN jsonb_build_object('revision',coalesce(c.revision,0),'updated_at',c.updated_at,'items',public.jana_saved_items_view(coalesce(c.items,'[]'),public.jana_public_catalog()));
END$$;

CREATE FUNCTION public.jana_save_customer_cart(p_token text,p_key text,p_revision bigint,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;c public.customer_carts;prior public.idempotency_records;scope_key text;req_hash text;canonical jsonb;r jsonb;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);PERFORM 1 FROM public.users WHERE id=u.id FOR UPDATE;u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_key=trim(coalesce(p_key,''));IF length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='cart:'||u.id||':'||p_key;req_hash=encode(digest(jsonb_build_object('revision',p_revision,'items',p_items)::text,'sha256'),'hex');
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 SELECT * INTO c FROM public.customer_carts WHERE user_id=u.id FOR UPDATE;
 IF p_revision IS DISTINCT FROM coalesce(c.revision,0) THEN RAISE EXCEPTION 'cart_changed';END IF;
 canonical=public.jana_saved_items(p_items);IF jsonb_array_length(canonical)>40 THEN RAISE EXCEPTION 'invalid_cart';END IF;
 INSERT INTO public.customer_carts(user_id,items,revision,updated_at) VALUES(u.id,canonical,1,nowms)
 ON CONFLICT(user_id) DO UPDATE SET items=EXCLUDED.items,revision=customer_carts.revision+1,updated_at=EXCLUDED.updated_at RETURNING * INTO c;
 r=jsonb_build_object('revision',c.revision,'updated_at',c.updated_at,'saved',true);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_key,req_hash,r,nowms);
 RETURN r;
END$$;
REVOKE ALL ON FUNCTION public.jana_customer_cart(text),public.jana_save_customer_cart(text,text,bigint,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_customer_cart(text),public.jana_save_customer_cart(text,text,bigint,jsonb) TO service_role;
