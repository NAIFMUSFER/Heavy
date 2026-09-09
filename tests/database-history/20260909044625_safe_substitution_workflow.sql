CREATE OR REPLACE FUNCTION public.jana_propose_substitution(p_token text,p_order_id text,p_line_id text,p_offering_id text,p_qty int DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid varchar; r varchar; o public.orders; target jsonb; po public.offerings; sid text; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint; bad boolean;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 SELECT value INTO target FROM jsonb_array_elements(o.snapshot->'lines') WHERE value->>'line_id'=p_line_id LIMIT 1; IF target IS NULL THEN RAISE EXCEPTION 'line_not_found'; END IF;
 SELECT * INTO po FROM offerings WHERE id=p_offering_id AND active; IF po.id IS NULL OR p_qty<1 OR p_qty>20 THEN RAISE EXCEPTION 'invalid_substitution'; END IF;
 SELECT EXISTS(
   SELECT 1 FROM jsonb_array_elements(po.components::jsonb) pc
   WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements((target->'components')::jsonb) oc WHERE oc->>'stock_id'=pc->>'stock_id' AND ((oc->>'base_qty')::bigint)*((target->>'qty')::bigint) >= ((pc->>'base_qty')::bigint)*p_qty)
 ) INTO bad;
 IF bad THEN RAISE EXCEPTION 'substitution_requires_requote'; END IF;
 sid='sub-'||substr(replace(gen_random_uuid()::text,'-',''),1,32);
 INSERT INTO substitutions(id,order_id,line_id,component_id,proposed,default_action,state,expires_at,actor_id,created_at)
 VALUES(sid,o.id,p_line_id,left(po.id,36),jsonb_build_object('offering_id',po.id,'qty',p_qty,'name',po.name,'price_halalas',po.price_halalas,'components',po.components),'remove_entire_line','pending',nowms+900000,uid,nowms);
 UPDATE orders SET fulfillment_state='awaiting_customer' WHERE id=o.id;
 INSERT INTO notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) VALUES('ntf-'||substr(replace(gen_random_uuid()::text,'-',''),1,32),o.user_id,'sub-'||sid,'بديل يحتاج موافقتك','تم اقتراح '||po.name||' كبديل. افتح مركز الطلب لاتخاذ القرار.',o.id,false,nowms);
 INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||substr(replace(gen_random_uuid()::text,'-',''),1,32),o.id,uid,'substitution_proposed',p_line_id,jsonb_build_object('substitution_id',sid,'offering_id',po.id),nowms);
 RETURN jsonb_build_object('id',sid,'order_id',o.id,'line_id',p_line_id,'state','pending','expires_at',nowms+900000,'proposed',jsonb_build_object('offering_id',po.id,'qty',p_qty,'name',po.name,'price_halalas',po.price_halalas));
END$$;

CREATE OR REPLACE FUNCTION public.jana_my_substitutions(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=jana_auth_user(p_token);
 IF NOT EXISTS(SELECT 1 FROM orders WHERE id=p_order_id AND user_id=u.id) THEN RAISE EXCEPTION 'order_not_found'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',s.id,'line_id',s.line_id,'proposed',s.proposed,'state',s.state,'expires_at',s.expires_at,'created_at',s.created_at) ORDER BY s.created_at DESC) FROM substitutions s WHERE s.order_id=p_order_id),'[]'::jsonb);
END$$;

CREATE OR REPLACE FUNCTION public.jana_decide_substitution(p_token text,p_substitution_id text,p_accept boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; s public.substitutions; o public.orders; po public.offerings; line jsonb; newlines jsonb='[]'::jsonb; subtotal bigint:=0; delivery bigint; qty int; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=jana_auth_user(p_token);
 SELECT * INTO s FROM substitutions WHERE id=p_substitution_id FOR UPDATE; IF s.id IS NULL THEN RAISE EXCEPTION 'substitution_not_found'; END IF;
 SELECT * INTO o FROM orders WHERE id=s.order_id AND user_id=u.id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF s.state<>'pending' THEN RAISE EXCEPTION 'substitution_already_decided'; END IF;
 IF s.expires_at<=nowms THEN UPDATE substitutions SET state='expired' WHERE id=s.id; UPDATE orders SET fulfillment_state='picking' WHERE id=o.id; RAISE EXCEPTION 'substitution_expired'; END IF;
 IF p_accept THEN
   SELECT * INTO po FROM offerings WHERE id=s.proposed->>'offering_id' AND active; IF po.id IS NULL THEN RAISE EXCEPTION 'invalid_substitution'; END IF; qty=(s.proposed->>'qty')::int;
   FOR line IN SELECT value FROM jsonb_array_elements(o.snapshot->'lines') LOOP
     IF line->>'line_id'=s.line_id THEN
       line=jsonb_build_object('line_id',s.line_id,'offering_id',po.id,'family_id',po.family_id,'version',po.version,'kind',po.kind,'name',po.name,'sale_unit',po.sale_unit,'unit_price_halalas',po.price_halalas,'qty',qty,'line_total_halalas',po.price_halalas*qty,'components',po.components,'substituted_from',line->>'offering_id');
     END IF;
     subtotal=subtotal+COALESCE((line->>'line_total_halalas')::bigint,0); newlines=newlines||jsonb_build_array(line);
   END LOOP;
   delivery=COALESCE((o.snapshot->>'delivery_fee_halalas')::bigint,0);
   UPDATE orders SET snapshot=jsonb_set(jsonb_set(jsonb_set(o.snapshot,'{lines}',newlines,true),'{subtotal_halalas}',to_jsonb(subtotal),true),'{total_halalas}',to_jsonb(subtotal+delivery),true),total_halalas=subtotal+delivery WHERE id=o.id;
   UPDATE substitutions SET state='accepted' WHERE id=s.id;
 ELSE
   UPDATE substitutions SET state='rejected' WHERE id=s.id;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM substitutions WHERE order_id=o.id AND state='pending' AND id<>s.id) THEN UPDATE orders SET fulfillment_state='picking' WHERE id=o.id; END IF;
 INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||substr(replace(gen_random_uuid()::text,'-',''),1,32),o.id,u.id,CASE WHEN p_accept THEN 'substitution_accepted' ELSE 'substitution_rejected' END,s.id,jsonb_build_object('total_halalas',(SELECT total_halalas FROM orders WHERE id=o.id)),nowms);
 RETURN jsonb_build_object('id',s.id,'state',CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END,'order_id',o.id,'total_halalas',(SELECT total_halalas FROM orders WHERE id=o.id));
END$$;

REVOKE ALL ON FUNCTION public.jana_propose_substitution(text,text,text,text,int) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_my_substitutions(text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_decide_substitution(text,text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_propose_substitution(text,text,text,text,int) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_my_substitutions(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jana_decide_substitution(text,text,boolean) TO service_role;