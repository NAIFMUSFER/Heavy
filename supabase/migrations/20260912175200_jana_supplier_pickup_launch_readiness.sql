-- Replace warehouse/inventory launch admission with the completed supplier-pickup
-- workflow. Legacy warehouse readiness remains visible for compatibility only.

ALTER FUNCTION public.jana_storefront_readiness()
 RENAME TO jana_storefront_readiness_pre_supplier_pickup_launch;

CREATE FUNCTION public.jana_storefront_readiness() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 r jsonb;nowms bigint:=(extract(epoch from statement_timestamp())*1000)::bigint;
 orderable_count bigint;site_count bigint;supplier_count bigint;picker_count bigint;courier_count bigint;slot_count bigint;
 launch_ok boolean;
BEGIN
 r=public.jana_storefront_readiness_pre_supplier_pickup_launch();
 SELECT count(*) INTO orderable_count FROM jsonb_array_elements(public.jana_public_catalog()) item
  WHERE item->>'orderable'='true' AND item->>'fulfillment_model'='supplier_pickup';
 SELECT count(*),count(DISTINCT s.id) INTO site_count,supplier_count
  FROM public.supplier_pickup_sites p JOIN public.suppliers s ON s.id=p.supplier_id
  WHERE p.active AND s.active;
 SELECT count(*) INTO picker_count FROM public.users WHERE active AND role='picker';
 SELECT count(*) INTO courier_count FROM public.users WHERE active AND role='courier';
 SELECT count(*) INTO slot_count FROM public.delivery_slots sl
  JOIN public.delivery_zones z ON z.id=sl.zone_id
  WHERE sl.active AND z.active AND sl.cutoff_at>nowms AND sl.booked<sl.capacity;
 launch_ok=coalesce((r->>'profile_published')::boolean,false)
  AND coalesce((r->>'tax_supported')::boolean,false)
  AND coalesce((r->>'preview_products')::bigint,0)=0
  AND orderable_count>0 AND site_count>0 AND picker_count>0 AND courier_count>0 AND slot_count>0
  AND coalesce((r->'health'->>'ok')::boolean,false);
 RETURN r||jsonb_build_object(
  'fulfillment_model','supplier_pickup','warehouse_required',false,'inventory_required',false,
  'legacy_available_products',r->'available_products','legacy_available_slots',r->'available_slots',
  'orderable_products',orderable_count,'available_products',orderable_count,
  'active_supplier_pickup_sites',site_count,'active_suppliers_with_pickup',supplier_count,
  'active_purchasing_staff',picker_count,'active_couriers',courier_count,
  'available_delivery_slots',slot_count,'available_slots',slot_count,
  'supplier_pickup_launch_ready',launch_ok);
END$$;

ALTER FUNCTION public.jana_admin_storefront(text)
 RENAME TO jana_admin_storefront_pre_supplier_pickup_launch;

CREATE FUNCTION public.jana_admin_storefront(p_token text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;review jsonb;
BEGIN
 r=public.jana_admin_storefront_pre_supplier_pickup_launch(p_token);
 SELECT jsonb_build_object(
   'recorded_at',a.created_at,
   'storefront_revision',a.detail::jsonb->'after_revision',
   'published_id',a.detail::jsonb->>'published_id',
   'reference',a.detail::jsonb->'payload'->>'reference',
   'reviewed',a.detail::jsonb->'payload'->'reviewed',
   'actor',jsonb_build_object('id',a.actor_id,'name',u.name)
 ) INTO review
 FROM public.audit_log a JOIN public.users u ON u.id=a.actor_id
 WHERE a.action='storefront_supplier_pickup_intake_set'
  AND a.detail::jsonb->'payload'->'accepting_orders'='true'::jsonb
  AND a.detail::jsonb->'payload'->'reviewed'='{"catalog":true,"supplier_sites":true,"procurement":true,"delivery":true,"tax":true,"operations":true}'::jsonb
  AND jsonb_typeof(a.detail::jsonb->'payload'->'reference')='string'
 ORDER BY CASE
   WHEN jsonb_typeof(a.detail::jsonb->'after_revision')='number'
    AND a.detail::jsonb->>'after_revision'~'^[0-9]{1,15}$'
   THEN (a.detail::jsonb->>'after_revision')::bigint ELSE -1
  END DESC,a.created_at DESC,a.id DESC
 LIMIT 1;
 RETURN r||jsonb_build_object(
  'last_opening_review',review,
  'opening_review_matches_published',review IS NOT NULL AND review->>'published_id'=r->>'published_id');
END$$;

ALTER FUNCTION public.jana_storefront_write(text,text,text,jsonb)
 RENAME TO jana_storefront_write_pre_supplier_pickup_launch;

CREATE FUNCTION public.jana_storefront_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;prior public.idempotency_records;readiness jsonb;result jsonb;legacy_payload jsonb;canonical_payload jsonb;
 scope_key text;req_hash text;legacy_key text;before_revision bigint;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation='intake.set' AND jsonb_typeof(p_payload)='object'
  AND jsonb_typeof(p_payload->'accepting_orders')='boolean' AND (p_payload->>'accepting_orders')::boolean THEN
  IF p_payload->'reviewed' IS DISTINCT FROM '{"catalog":true,"supplier_sites":true,"procurement":true,"delivery":true,"tax":true,"operations":true}'::jsonb
   OR jsonb_typeof(p_payload->'reference') IS DISTINCT FROM 'string'
   OR length(trim(p_payload->>'reference')) NOT BETWEEN 5 AND 180 THEN
   RAISE EXCEPTION 'storefront_review_required';
  END IF;
  p_idem_key=trim(coalesce(p_idem_key,''));
  IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
  scope_key='storefront-supplier-pickup:'||u.id||':'||p_idem_key;
  req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
  SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
  IF prior.scope IS NOT NULL THEN
   IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
   RETURN prior.response::jsonb;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('jana-storefront-admission',0));
  -- Hold every launch prerequisite stable through the state transition.
  PERFORM 1 FROM public.supplier_pickup_sites p JOIN public.suppliers s ON s.id=p.supplier_id
   WHERE p.active AND s.active FOR SHARE OF p,s;
  PERFORM 1 FROM public.users WHERE active AND role IN ('picker','courier') FOR SHARE;
  PERFORM 1 FROM public.offerings WHERE active FOR SHARE;
  PERFORM 1 FROM public.delivery_slots sl JOIN public.delivery_zones z ON z.id=sl.zone_id
   WHERE sl.active AND z.active FOR SHARE OF sl,z;
  readiness=public.jana_storefront_readiness();
  IF NOT coalesce((readiness->>'supplier_pickup_launch_ready')::boolean,false) THEN
   IF NOT coalesce((readiness->>'tax_supported')::boolean,false) THEN RAISE EXCEPTION 'storefront_tax_setup_required';END IF;
   RAISE EXCEPTION 'storefront_not_ready';
  END IF;
  canonical_payload=jsonb_set(p_payload,'{reference}',to_jsonb(trim(p_payload->>'reference')),true);
  legacy_payload=jsonb_set(canonical_payload,'{reviewed}',
   '{"catalog":true,"inventory":true,"coverage":true,"tax":true,"operations":true}'::jsonb,true);
  legacy_key=encode(digest('supplier-pickup-launch:'||p_idem_key,'sha256'),'hex');
  SELECT revision INTO before_revision FROM public.storefront_state WHERE singleton FOR SHARE;
  -- Call the original commercial write directly: the warehouse wrapper is now
  -- compatibility-only, while all original profile, tax, preview and health checks remain.
  result=public.jana_storefront_write_pre_warehouse(p_token,legacy_key,p_operation,legacy_payload);
  INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES
  ('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'storefront_supplier_pickup_intake_set','storefront',
   jsonb_build_object('role',u.role,'before_revision',before_revision,'after_revision',result->'revision',
    'published_id',result->'published_id','payload',canonical_payload,'fulfillment_model','supplier_pickup',
    'warehouse_required',false,'inventory_required',false),nowms);
  INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
   VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
  RETURN result;
 END IF;
 RETURN public.jana_storefront_write_pre_supplier_pickup_launch(p_token,p_idem_key,p_operation,p_payload);
END$$;

REVOKE ALL ON FUNCTION
 public.jana_storefront_readiness_pre_supplier_pickup_launch(),
 public.jana_admin_storefront_pre_supplier_pickup_launch(text),
 public.jana_storefront_write_pre_supplier_pickup_launch(text,text,text,jsonb),
 public.jana_storefront_readiness(),public.jana_admin_storefront(text),public.jana_storefront_write(text,text,text,jsonb)
FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.jana_admin_storefront(text),public.jana_storefront_write(text,text,text,jsonb)
TO service_role;
