-- Operational evidence only: fixed multi-component lines must match the sold
-- component quantities. Variances do not silently change price or usable stock.
ALTER TABLE public.orders ADD COLUMN picking_revision bigint NOT NULL DEFAULT 0 CHECK(picking_revision>=0);

CREATE FUNCTION public.jana_order_picking_revision() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN NEW.picking_revision=OLD.picking_revision+1;RETURN NEW;END$$;
CREATE TRIGGER jana_order_picking_revision BEFORE UPDATE ON public.orders
 FOR EACH ROW EXECUTE FUNCTION public.jana_order_picking_revision();

CREATE FUNCTION public.jana_issue_picking_revision() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN UPDATE public.orders SET picking_revision=picking_revision+1 WHERE id=NEW.order_id;RETURN NEW;END$$;
CREATE TRIGGER jana_issue_picking_revision AFTER INSERT OR UPDATE ON public.picking_line_issues
 FOR EACH ROW EXECUTE FUNCTION public.jana_issue_picking_revision();

CREATE FUNCTION public.jana_basket_components_match(p_line jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_typeof(p_line->'component_check'->'items')='array'
  AND jsonb_array_length(p_line->'component_check'->'items')=jsonb_array_length(p_line->'components')
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_line->'components') c WHERE NOT EXISTS(
   SELECT 1 FROM jsonb_array_elements(p_line->'component_check'->'items') a
   WHERE a->>'stock_id'=c->>'stock_id'
    AND (a->>'actual_base')::bigint=(c->>'base_qty')::bigint*(p_line->>'qty')::bigint)),false);
$$;

CREATE FUNCTION public.jana_picker_record_components(p_token text,p_idem_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;prior public.idempotency_records;scope_key text;req_hash text;
 target jsonb;c jsonb;a jsonb;items jsonb:='[]';entry jsonb;line jsonb;newlines jsonb;result jsonb;
 nowms bigint;ready boolean;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'invalid_component_check';END IF;
 IF NOT p_payload ?& ARRAY['order_id','line_id','revision','items']
  OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('order_id','line_id','revision','items'))
  OR jsonb_typeof(p_payload->'order_id')<>'string' OR length(p_payload->>'order_id') NOT BETWEEN 1 AND 36
  OR jsonb_typeof(p_payload->'line_id')<>'string' OR length(p_payload->>'line_id') NOT BETWEEN 1 AND 36
  OR jsonb_typeof(p_payload->'revision')<>'number' OR p_payload->>'revision' !~ '^[0-9]{1,15}$'
  OR jsonb_typeof(p_payload->'items')<>'array' THEN RAISE EXCEPTION 'invalid_component_check';END IF;
 IF jsonb_array_length(p_payload->'items') NOT BETWEEN 2 AND 50 THEN RAISE EXCEPTION 'invalid_component_check';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='basket-check:'||u.id||':'||p_idem_key;req_hash=encode(digest(p_payload::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO o FROM public.orders WHERE id=p_payload->>'order_id' FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;
 END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 IF o.picking_revision<>(p_payload->>'revision')::bigint THEN RAISE EXCEPTION 'component_check_changed';END IF;
 SELECT value INTO target FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WHERE value->>'line_id'=p_payload->>'line_id';
 IF target IS NULL THEN RAISE EXCEPTION 'line_not_found';END IF;
 IF EXISTS(SELECT 1 FROM public.picking_line_issues WHERE order_id=o.id AND line_id=p_payload->>'line_id' AND state='open') THEN RAISE EXCEPTION 'unresolved_picking_items';END IF;
 IF jsonb_array_length(target->'components')<2 OR jsonb_array_length(target->'components')<>jsonb_array_length(p_payload->'items') THEN RAISE EXCEPTION 'invalid_component_check';END IF;
 FOR a IN SELECT value FROM jsonb_array_elements(p_payload->'items') LOOP
  IF jsonb_typeof(a)<>'object' THEN RAISE EXCEPTION 'invalid_component_check';END IF;
  IF NOT a ?& ARRAY['stock_id','actual_base']
   OR EXISTS(SELECT 1 FROM jsonb_object_keys(a) k WHERE k NOT IN ('stock_id','actual_base'))
   OR jsonb_typeof(a->'stock_id')<>'string' OR length(a->>'stock_id') NOT BETWEEN 1 AND 36
   OR jsonb_typeof(a->'actual_base')<>'number' OR a->>'actual_base' !~ '^[0-9]{1,11}$'
   OR (a->>'actual_base')::bigint>20000000000
   OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(target->'components') sold_component WHERE sold_component->>'stock_id'=a->>'stock_id')
   OR (SELECT count(*) FROM jsonb_array_elements(p_payload->'items') x WHERE x->>'stock_id'=a->>'stock_id')<>1 THEN RAISE EXCEPTION 'invalid_component_check';END IF;
 END LOOP;
 -- Store in the sold component order, with canonical units and required totals.
 FOR c IN SELECT value FROM jsonb_array_elements(target->'components') LOOP
  SELECT value INTO a FROM jsonb_array_elements(p_payload->'items') WHERE value->>'stock_id'=c->>'stock_id';
  entry=jsonb_build_object('stock_id',c->>'stock_id','actual_base',(a->>'actual_base')::bigint,
   'planned_base',(c->>'base_qty')::bigint*(target->>'qty')::bigint,'base_unit',c->>'base_unit');
  items=items||jsonb_build_array(entry);
 END LOOP;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 line=target||jsonb_build_object('component_check',jsonb_build_object('items',items,'actor_id',u.id,'recorded_at',nowms));
 ready=public.jana_basket_components_match(line);
 SELECT jsonb_agg(CASE WHEN x->>'line_id'=target->>'line_id' THEN line ELSE x END ORDER BY n)
  INTO newlines FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY e(x,n);
 UPDATE public.orders SET snapshot=jsonb_set(o.snapshot::jsonb,'{lines}',newlines)::json WHERE id=o.id RETURNING * INTO o;
 result=jsonb_build_object('id',o.id,'line_id',target->>'line_id','revision',o.picking_revision,'matches',ready,'component_check',line->'component_check','total_halalas',o.total_halalas);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'basket_components_recorded',target->>'line_id',result,nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'basket_components_recorded',o.id,
  jsonb_build_object('role',u.role,'line_id',target->>'line_id','before',target->'component_check','after',line->'component_check','matches',ready),nowms);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
END$$;

CREATE OR REPLACE FUNCTION public.jana_picking_detail(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 RETURN jsonb_build_object('id',o.id,'number',o.number,'status',o.status,'fulfillment_state',o.fulfillment_state,'snapshot',o.snapshot,'total_halalas',o.total_halalas,'picking_revision',o.picking_revision,
 'issues',coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM public.picking_line_issues i WHERE order_id=o.id),'[]'::jsonb),
 'substitutions',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY created_at DESC) FROM public.substitutions s WHERE order_id=o.id),'[]'::jsonb));
END$$;

CREATE OR REPLACE FUNCTION public.jana_finalize_picking(p_token text,p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF EXISTS(SELECT 1 FROM public.picking_line_issues WHERE order_id=o.id AND state='open') OR EXISTS(SELECT 1 FROM public.substitutions WHERE order_id=o.id AND state='pending') THEN RAISE EXCEPTION 'unresolved_picking_items';END IF;
 IF o.fulfillment_state='picking' AND EXISTS(SELECT 1 FROM jsonb_array_elements(o.snapshot::jsonb->'lines') l
  WHERE jsonb_array_length(l->'components')>1 AND NOT public.jana_basket_components_match(l)) THEN RAISE EXCEPTION 'basket_components_unresolved';END IF;
 RETURN public.jana_finalize_picking_base(p_token,p_order_id);
END$$;

REVOKE ALL ON FUNCTION public.jana_order_picking_revision(),public.jana_issue_picking_revision(),public.jana_basket_components_match(jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_picker_record_components(text,text,jsonb),public.jana_picking_detail(text,text),public.jana_finalize_picking(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_picker_record_components(text,text,jsonb),public.jana_picking_detail(text,text),public.jana_finalize_picking(text,text) TO service_role;
