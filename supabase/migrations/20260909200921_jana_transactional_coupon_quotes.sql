-- Compatible coupon checkout. Existing four/five-argument quote RPCs remain unchanged.
-- Lock order: idempotency -> slot -> sorted stock -> lots -> coupon.
ALTER TABLE public.coupons ADD COLUMN discount_type text NOT NULL DEFAULT 'fixed';
ALTER TABLE public.coupons ADD COLUMN percentage_bps integer;
ALTER TABLE public.coupons ADD CONSTRAINT coupon_discount_rule CHECK
 ((discount_type='fixed' AND percentage_bps IS NULL) OR
  (discount_type='percentage' AND percentage_bps BETWEEN 1 AND 10000));

CREATE FUNCTION public.jana_coupon_discount(p_terms jsonb,p_subtotal bigint)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
BEGIN
 IF p_terms IS NULL OR p_terms='null'::jsonb THEN RETURN 0; END IF;
 IF p_subtotal IS NULL OR p_subtotal<0 THEN RAISE EXCEPTION 'invalid_subtotal'; END IF;
 IF p_terms->>'discount_type'='percentage' THEN
  RETURN least(p_subtotal,round(p_subtotal::numeric*(p_terms->>'percentage_bps')::numeric/10000)::bigint);
 END IF;
 RETURN least(p_subtotal,(p_terms->>'amount_halalas')::bigint);
END$$;

CREATE FUNCTION public.jana_create_quote_with_coupon(p_token text,p_idem_key text,p_slot_id text,p_address_id text,p_items jsonb,p_coupon_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; c public.coupons; prior public.idempotency_records; q jsonb;
 scope_key text; req_hash text; normalized_code text; terms jsonb; discount bigint; total bigint; expms bigint;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 normalized_code=upper(trim(coalesce(p_coupon_code,'')));
 IF normalized_code='' THEN RETURN public.jana_create_quote_idempotent(p_token,p_idem_key,p_slot_id,p_address_id,p_items); END IF;
 u=public.jana_auth_user(p_token);
 IF normalized_code !~ '^[A-Z0-9_-]{3,24}$' THEN RAISE EXCEPTION 'invalid_coupon'; END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));
 IF length(p_idem_key)<8 OR length(p_idem_key)>128 THEN RAISE EXCEPTION 'invalid_idempotency_key'; END IF;
 scope_key='quote:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('slot_id',p_slot_id,'address_id',p_address_id,'items',p_items,'coupon_code',normalized_code)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict'; END IF;
  RETURN prior.response::jsonb;
 END IF;
 -- Any coupon validation failure rolls back the stock and slot acquired here.
 q=public.jana_create_quote(p_token,p_slot_id,p_address_id,p_items);
 SELECT * INTO c FROM public.coupons WHERE coupons.code=normalized_code FOR UPDATE;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 IF c.id IS NULL OR NOT c.active THEN RAISE EXCEPTION 'coupon_unavailable'; END IF;
 IF c.expires_at<=nowms THEN RAISE EXCEPTION 'coupon_expired'; END IF;
 IF c.reserved+c.redeemed>=c.max_uses THEN RAISE EXCEPTION 'coupon_exhausted'; END IF;
 IF (q->>'subtotal_halalas')::bigint<c.minimum_halalas THEN RAISE EXCEPTION 'coupon_minimum'; END IF;
 terms=jsonb_build_object('id',c.id,'code',c.code,'discount_type',c.discount_type,
  'amount_halalas',c.amount_halalas,'percentage_bps',c.percentage_bps,'minimum_halalas',c.minimum_halalas);
 discount=public.jana_coupon_discount(terms,(q->>'subtotal_halalas')::bigint);
 total=(q->>'subtotal_halalas')::bigint-discount+(q->>'delivery_fee_halalas')::bigint;
 expms=least((q->>'expires_at')::bigint,c.expires_at);
 UPDATE public.coupons SET reserved=reserved+1 WHERE id=c.id;
 UPDATE public.quotes SET coupon_id=c.id,expires_at=expms,
  snapshot=snapshot::jsonb||jsonb_build_object('coupon',terms,'discount_halalas',discount,'total_halalas',total) WHERE id=q->>'id';
 q=q||jsonb_build_object('coupon',terms,'discount_halalas',discount,'total_halalas',total,'expires_at',expms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,q,nowms);
 RETURN q;
END$$;

CREATE FUNCTION public.jana_coupon_quote_transition()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF OLD.coupon_id IS NOT NULL AND OLD.state='active' AND NEW.state IN ('converted','cancelled','expired') THEN
  UPDATE public.coupons SET reserved=reserved-1,redeemed=redeemed+CASE WHEN NEW.state='converted' THEN 1 ELSE 0 END
   WHERE id=OLD.coupon_id AND reserved>0;
  IF NOT FOUND THEN RAISE EXCEPTION 'coupon_allocation_invalid'; END IF;
 END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_coupon_quote_transition AFTER UPDATE OF state ON public.quotes
 FOR EACH ROW EXECUTE FUNCTION public.jana_coupon_quote_transition();

-- Recompute from immutable sold coupon terms after actual-weight/substitution changes.
CREATE FUNCTION public.jana_preserve_order_discount()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE terms jsonb; subtotal bigint; discount bigint;
BEGIN
 terms=NEW.original_snapshot::jsonb->'coupon';
 IF terms IS NOT NULL AND terms<>'null'::jsonb THEN
  subtotal=(NEW.snapshot->>'subtotal_halalas')::bigint;
  discount=public.jana_coupon_discount(terms,subtotal);
  NEW.total_halalas=subtotal-discount+(NEW.snapshot->>'delivery_fee_halalas')::bigint;
  NEW.snapshot=NEW.snapshot::jsonb||jsonb_build_object('coupon',terms,'discount_halalas',discount,'total_halalas',NEW.total_halalas);
 END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_preserve_order_discount BEFORE UPDATE OF snapshot,total_halalas ON public.orders
 FOR EACH ROW EXECUTE FUNCTION public.jana_preserve_order_discount();

CREATE FUNCTION public.jana_admin_create_coupon_v2(p_token text,p_code text,p_amount_halalas bigint,p_minimum_halalas bigint,p_max_uses integer,p_expires_at bigint,p_discount_type text,p_percentage_bps integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE c jsonb;
BEGIN
 IF p_discount_type IS NULL OR p_discount_type NOT IN ('fixed','percentage') OR
  (p_discount_type='percentage' AND (p_percentage_bps IS NULL OR p_percentage_bps NOT BETWEEN 1 AND 10000)) OR
  (p_discount_type='fixed' AND p_percentage_bps IS NOT NULL) THEN RAISE EXCEPTION 'invalid_coupon'; END IF;
 c=public.jana_admin_create_coupon(p_token,p_code,CASE WHEN p_discount_type='percentage' THEN 1 ELSE p_amount_halalas END,p_minimum_halalas,p_max_uses,p_expires_at);
 UPDATE public.coupons SET discount_type=p_discount_type,percentage_bps=p_percentage_bps WHERE id=c->>'id';
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),(public.jana_auth_user(p_token)).id,'coupon_discount_rule',c->>'id',jsonb_build_object('discount_type',p_discount_type,'percentage_bps',p_percentage_bps),(extract(epoch from clock_timestamp())*1000)::bigint);
 RETURN c||jsonb_build_object('discount_type',p_discount_type,'percentage_bps',p_percentage_bps);
END$$;
REVOKE ALL ON FUNCTION public.jana_coupon_discount(jsonb,bigint),public.jana_create_quote_with_coupon(text,text,text,text,jsonb,text),public.jana_coupon_quote_transition(),public.jana_preserve_order_discount(),public.jana_admin_create_coupon_v2(text,text,bigint,bigint,integer,bigint,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_create_quote_with_coupon(text,text,text,text,jsonb,text),public.jana_admin_create_coupon_v2(text,text,bigint,bigint,integer,bigint,text,integer) TO service_role;
