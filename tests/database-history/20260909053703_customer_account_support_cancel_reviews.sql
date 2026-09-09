CREATE OR REPLACE FUNCTION public.jana_logout(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE th text;
BEGIN
 IF p_token IS NULL OR length(p_token)<32 THEN RETURN jsonb_build_object('ok',true); END IF;
 th=encode(digest(p_token,'sha256'),'hex'); DELETE FROM public.sessions WHERE token_hash=th;
 RETURN jsonb_build_object('ok',true);
END$$;

CREATE OR REPLACE FUNCTION public.jana_cancel_order(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; o public.orders; a jsonb; lotid text; stockid text; base bigint; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token); SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'queued' OR o.delivery_state<>'unassigned' THEN RAISE EXCEPTION 'order_not_cancellable'; END IF;
 FOR a IN SELECT value FROM jsonb_array_elements(o.snapshot->'allocations') LOOP
   lotid=a->>'lot_id'; stockid=a->>'stock_id'; base=(a->>'base_qty')::bigint;
   UPDATE public.inventory_lots SET reserved_base=reserved_base-base WHERE id=lotid AND reserved_base>=base;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   UPDATE public.stock_balances SET reserved_base=reserved_base-base WHERE stock_id=stockid AND reserved_base>=base;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
   VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),stockid,lotid,0,-base,'order_cancelled',o.id,u.id,nowms);
 END LOOP;
 UPDATE public.delivery_slots SET booked=GREATEST(booked-1,0) WHERE id=o.slot_id;
 UPDATE public.orders SET status='cancelled',payment_state='cancelled',fulfillment_state='cancelled',delivery_state='cancelled',code_hash=NULL,code_expires_at=NULL WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'cancelled','customer_request',jsonb_build_object('status','cancelled'),nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),u.id,'cancel-'||o.id,'تم إلغاء الطلب','تم إلغاء الطلب '||o.number,o.id,false,nowms) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('id',o.id,'number',o.number,'status','cancelled');
END$$;

CREATE OR REPLACE FUNCTION public.jana_update_address(p_token text,p_address_id text,p_label text,p_details text,p_latitude text,p_longitude text,p_recipient_name text,p_recipient_phone text,p_default boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; nlat numeric; nlng numeric;
BEGIN
 u=public.jana_auth_user(p_token); BEGIN nlat=p_latitude::numeric; nlng=p_longitude::numeric; EXCEPTION WHEN others THEN RAISE EXCEPTION 'invalid_coordinates'; END;
 IF nlat NOT BETWEEN -90 AND 90 OR nlng NOT BETWEEN -180 AND 180 OR length(trim(p_details))<3 THEN RAISE EXCEPTION 'invalid_address'; END IF;
 IF p_default THEN UPDATE public.addresses SET is_default=false WHERE user_id=u.id; END IF;
 UPDATE public.addresses SET label=left(coalesce(nullif(trim(p_label),''),'المنزل'),60),details=trim(p_details),latitude=nlat::text,longitude=nlng::text,recipient_name=left(trim(coalesce(p_recipient_name,'')),80),recipient_phone=left(trim(coalesce(p_recipient_phone,'')),30),is_default=p_default WHERE id=p_address_id AND user_id=u.id;
 IF NOT FOUND THEN RAISE EXCEPTION 'invalid_address'; END IF;
 RETURN (SELECT to_jsonb(a) FROM public.addresses a WHERE a.id=p_address_id);
END$$;

CREATE OR REPLACE FUNCTION public.jana_delete_address(p_token text,p_address_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; was_default boolean;
BEGIN
 u=public.jana_auth_user(p_token); SELECT is_default INTO was_default FROM public.addresses WHERE id=p_address_id AND user_id=u.id;
 IF NOT FOUND THEN RAISE EXCEPTION 'invalid_address'; END IF;
 DELETE FROM public.addresses WHERE id=p_address_id AND user_id=u.id;
 IF was_default THEN UPDATE public.addresses SET is_default=true WHERE id=(SELECT id FROM public.addresses WHERE user_id=u.id ORDER BY id LIMIT 1); END IF;
 RETURN jsonb_build_object('ok',true);
END$$;

CREATE OR REPLACE FUNCTION public.jana_my_favorites(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN u=public.jana_auth_user(p_token); RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('family_id',f.offering_family_id,'created_at',f.created_at) ORDER BY f.created_at DESC) FROM public.favorites f WHERE f.user_id=u.id),'[]'::jsonb); END$$;
CREATE OR REPLACE FUNCTION public.jana_toggle_favorite(p_token text,p_family_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN u=public.jana_auth_user(p_token); IF EXISTS(SELECT 1 FROM public.favorites WHERE user_id=u.id AND offering_family_id=p_family_id) THEN DELETE FROM public.favorites WHERE user_id=u.id AND offering_family_id=p_family_id; RETURN jsonb_build_object('favorite',false); ELSE INSERT INTO public.favorites(user_id,offering_family_id,created_at) VALUES(u.id,p_family_id,nowms); RETURN jsonb_build_object('favorite',true); END IF; END$$;

CREATE OR REPLACE FUNCTION public.jana_create_ticket(p_token text,p_order_id text,p_subject text,p_message text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; tid text; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token); IF length(trim(p_subject))<3 OR length(trim(p_message))<3 THEN RAISE EXCEPTION 'invalid_ticket'; END IF;
 IF p_order_id IS NOT NULL AND p_order_id<>'' AND NOT EXISTS(SELECT 1 FROM public.orders WHERE id=p_order_id AND user_id=u.id) THEN RAISE EXCEPTION 'order_not_found'; END IF;
 tid='tkt-'||replace(gen_random_uuid()::text,'-',''); INSERT INTO public.tickets(id,user_id,order_id,subject,state,messages,created_at,priority,assigned_to,updated_at) VALUES(tid,u.id,nullif(p_order_id,''),left(trim(p_subject),120),'open',json_build_array(json_build_object('by','customer','message',left(trim(p_message),2000),'at',nowms)),nowms,'normal',NULL,nowms);
 RETURN jsonb_build_object('id',tid,'state','open');
END$$;
CREATE OR REPLACE FUNCTION public.jana_my_tickets(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; BEGIN u=public.jana_auth_user(p_token); RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'order_id',order_id,'subject',subject,'state',state,'messages',messages,'priority',priority,'updated_at',updated_at) ORDER BY updated_at DESC) FROM public.tickets WHERE user_id=u.id),'[]'::jsonb); END$$;

CREATE OR REPLACE FUNCTION public.jana_review_order(p_token text,p_order_id text,p_rating int,p_comment text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; rid text; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token); IF p_rating<1 OR p_rating>5 THEN RAISE EXCEPTION 'invalid_rating'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id=p_order_id AND user_id=u.id AND status='completed') THEN RAISE EXCEPTION 'review_not_allowed'; END IF;
 IF EXISTS(SELECT 1 FROM public.reviews WHERE order_id=p_order_id AND user_id=u.id) THEN RAISE EXCEPTION 'review_exists'; END IF;
 rid='rev-'||replace(gen_random_uuid()::text,'-',''); INSERT INTO public.reviews(id,order_id,user_id,rating,comment,created_at) VALUES(rid,p_order_id,u.id,p_rating,left(trim(coalesce(p_comment,'')),500),nowms);
 RETURN jsonb_build_object('id',rid,'rating',p_rating);
END$$;

DO $$ DECLARE r record; BEGIN FOR r IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'jana_%' LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',r.sig); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',r.sig); END LOOP; END $$;