
-- Policy fields form part of each immutable sellable version. Existing definitions
-- retain their prior lower-weight behavior and disallow overfill by default.
ALTER TABLE public.offerings ADD COLUMN weight_under_bps integer NOT NULL DEFAULT 10000 CHECK(weight_under_bps BETWEEN 0 AND 10000);
ALTER TABLE public.offerings ADD COLUMN weight_over_bps integer NOT NULL DEFAULT 0 CHECK(weight_over_bps BETWEEN 0 AND 2000);
ALTER TABLE public.offerings ADD CONSTRAINT weight_policy_components CHECK(
 (weight_under_bps=10000 AND weight_over_bps=0) OR (json_array_length(components)=1 AND components->0->>'base_unit'='gram'));

CREATE FUNCTION public.jana_weight_terms(p_offering_id text,p_qty integer)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
 SELECT coalesce((SELECT jsonb_build_object('weight_policy',jsonb_build_object(
 'under_bps',o.weight_under_bps,'over_bps',o.weight_over_bps,
 'target_base',(o.components->0->>'base_qty')::bigint*p_qty,
 'min_base',greatest(1,ceil((o.components->0->>'base_qty')::numeric*p_qty*(10000-o.weight_under_bps)/10000)::bigint),
 'max_base',floor((o.components->0->>'base_qty')::numeric*p_qty*(10000+o.weight_over_bps)/10000)::bigint,
 'base_unit','gram','overage_pricing','included')) FROM public.offerings o
 WHERE o.id=p_offering_id AND p_qty BETWEEN 1 AND 20 AND json_array_length(o.components)=1 AND o.components->0->>'base_unit'='gram'),'{}'::jsonb);
$$;


CREATE OR REPLACE FUNCTION public.jana_admin_create_product_version(p_token text,p_family_id text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; fam public.product_families; source public.product_versions; v public.product_versions;
 body jsonb; items jsonb; item jsonb; component jsonb; components jsonb; stock public.stock_items;
 oid text; lineage text; n integer; units bigint; price bigint; refprice bigint; key text; title text; under_bps integer; over_bps integer;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'validation';END IF;
 body=p_payload;
 IF nullif(p_family_id,'') IS NULL THEN
  title=trim(coalesce(body->>'title',''));IF length(title)<2 OR length(title)>140 THEN RAISE EXCEPTION 'validation';END IF;
  INSERT INTO public.product_families(id,name,created_at,created_by) VALUES('fam-'||replace(gen_random_uuid()::text,'-',''),title,nowms,u.id) RETURNING * INTO fam;
 ELSE
  SELECT * INTO fam FROM public.product_families WHERE id=p_family_id FOR UPDATE;
  IF fam.id IS NULL THEN RAISE EXCEPTION 'family_not_found';END IF;
 END IF;
 IF nullif(body->>'copy_version_id','') IS NOT NULL THEN
  SELECT * INTO source FROM public.product_versions WHERE id=(body->>'copy_version_id')::uuid AND family_id=fam.id;
  IF source.id IS NULL THEN RAISE EXCEPTION 'product_version_not_found';END IF;
  SELECT jsonb_agg(to_jsonb(o)||jsonb_build_object('sellable_key',m.sellable_key) ORDER BY m.sellable_key) INTO items
   FROM public.product_version_offerings m JOIN public.offerings o ON o.id=m.offering_id WHERE m.version_id=source.id;
  body=(to_jsonb(source)||jsonb_build_object('offerings',items))||body;
 END IF;
 title=trim(coalesce(body->>'title',''));items=body->'offerings';
 IF length(title)<2 OR length(title)>140 OR items IS NULL OR jsonb_typeof(items)<>'array' OR jsonb_array_length(items) NOT BETWEEN 1 AND 30
  OR length(coalesce(body->>'description',''))>10000 OR length(coalesce(body->>'category','')) NOT BETWEEN 1 AND 40
  OR coalesce(body->>'kind','') NOT IN ('individual','basket','sized','usage','bulk','gift')
  OR length(coalesce(body->>'emoji',''))>20 OR length(coalesce(body->>'image_url',''))>300
  OR (coalesce(body->>'image_url','')<>'' AND body->>'image_url' !~ '^https://') THEN RAISE EXCEPTION 'validation';END IF;
 SELECT coalesce(max(version),0)+1 INTO n FROM public.product_versions WHERE family_id=fam.id;
 INSERT INTO public.product_versions(family_id,version,title,description,category,kind,emoji,image_url,state,created_at,created_by)
 VALUES(fam.id,n,title,coalesce(body->>'description',''),body->>'category',body->>'kind',coalesce(body->>'emoji',''),coalesce(body->>'image_url',''),'draft',nowms,u.id) RETURNING * INTO v;
 FOR item IN SELECT value FROM jsonb_array_elements(items) LOOP
  IF jsonb_typeof(item)<>'object' THEN RAISE EXCEPTION 'validation';END IF;
  key=item->>'sellable_key';price=(item->>'price_halalas')::bigint;
  IF key IS NULL OR key !~ '^[a-z0-9][a-z0-9_-]{0,39}$' OR price IS NULL OR price NOT BETWEEN 1 AND 9000000000000
   OR length(trim(coalesce(item->>'size_label',''))) NOT BETWEEN 1 AND 40
   OR coalesce(item->>'sale_unit','') NOT IN ('kg','piece','pack','package','basket')
   OR item->'components' IS NULL OR jsonb_typeof(item->'components')<>'array' OR jsonb_array_length(item->'components') NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'validation';END IF;
  IF EXISTS(SELECT 1 FROM public.product_version_offerings WHERE version_id=v.id AND sellable_key=key) THEN RAISE EXCEPTION 'invalid_duplicate_offering';END IF;
  components='[]'::jsonb;
  FOR component IN SELECT value FROM jsonb_array_elements(item->'components') LOOP
   SELECT * INTO stock FROM public.stock_items WHERE id=component->>'stock_id' AND active FOR SHARE;
   units=(component->>'base_qty')::bigint;refprice=coalesce((component->>'list_price_halalas')::bigint,0);
   IF stock.id IS NULL OR units IS NULL OR units NOT BETWEEN 1 AND 1000000000 OR refprice NOT BETWEEN 0 AND 9000000000000
    OR EXISTS(SELECT 1 FROM jsonb_array_elements(components) c WHERE c->>'stock_id'=stock.id) THEN RAISE EXCEPTION 'invalid_component';END IF;
   components=components||jsonb_build_array(jsonb_build_object('stock_id',stock.id,'name',stock.name,'base_unit',stock.base_unit,'base_qty',units,'list_price_halalas',refprice));
  END LOOP;
  IF (item?'weight_under_bps' AND (jsonb_typeof(item->'weight_under_bps')<>'number' OR item->>'weight_under_bps' !~ '^[0-9]{1,5}$'))
   OR (item?'weight_over_bps' AND (jsonb_typeof(item->'weight_over_bps')<>'number' OR item->>'weight_over_bps' !~ '^[0-9]{1,4}$')) THEN RAISE EXCEPTION 'invalid_weight_policy';END IF;
  under_bps=coalesce((item->>'weight_under_bps')::integer,10000);over_bps=coalesce((item->>'weight_over_bps')::integer,0);
  IF under_bps NOT BETWEEN 0 AND 10000 OR over_bps NOT BETWEEN 0 AND 2000 OR
   ((under_bps<>10000 OR over_bps<>0) AND (jsonb_array_length(components)<>1 OR components->0->>'base_unit'<>'gram')) THEN RAISE EXCEPTION 'invalid_weight_policy';END IF;
  SELECT o.family_id INTO lineage FROM public.product_version_offerings m JOIN public.product_versions pv ON pv.id=m.version_id JOIN public.offerings o ON o.id=m.offering_id
   WHERE pv.family_id=fam.id AND m.sellable_key=key ORDER BY pv.version DESC LIMIT 1;
  lineage=coalesce(lineage,'sku-'||replace(gen_random_uuid()::text,'-',''));oid='off-'||replace(gen_random_uuid()::text,'-','');
  INSERT INTO public.offerings(id,family_id,version,kind,name,description,category,size_label,emoji,image_url,sale_unit,price_halalas,components,active,created_at,weight_under_bps,weight_over_bps)
  VALUES(oid,lineage,n,v.kind,v.title,v.description,v.category,trim(item->>'size_label'),v.emoji,v.image_url,item->>'sale_unit',price,components::json,false,nowms,under_bps,over_bps);
  INSERT INTO public.product_version_offerings(version_id,offering_id,sellable_key) VALUES(v.id,oid,key);
 END LOOP;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'product_version_created',v.id::text,jsonb_build_object('family_id',fam.id,'version',n,'state','draft','offering_count',jsonb_array_length(items),'role',u.role),nowms);
 RETURN to_jsonb(v)||jsonb_build_object('offerings',(SELECT jsonb_agg(to_jsonb(o)||jsonb_build_object('sellable_key',m.sellable_key) ORDER BY m.sellable_key) FROM public.product_version_offerings m JOIN public.offerings o ON o.id=m.offering_id WHERE m.version_id=v.id));
END$$;

CREATE OR REPLACE FUNCTION public.jana_create_quote(p_token text,p_slot_id text,p_address_id text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;lines jsonb;
BEGIN
 r=public.jana_create_quote_base(p_token,p_slot_id,p_address_id,p_items);
 SELECT jsonb_agg(x.item||public.jana_weight_terms(x.item->>'offering_id',(x.item->>'qty')::integer)||CASE WHEN v.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) END ORDER BY x.ord)
 INTO lines FROM jsonb_array_elements(r->'lines') WITH ORDINALITY x(item,ord)
 LEFT JOIN public.product_version_offerings m ON m.offering_id=x.item->>'offering_id' LEFT JOIN public.product_versions v ON v.id=m.version_id;
 UPDATE public.quotes SET snapshot=jsonb_set(snapshot::jsonb,'{lines}',lines)::json WHERE id=r->>'id';
 RETURN r||jsonb_build_object('lines',lines);
END$$;

CREATE OR REPLACE FUNCTION public.jana_propose_substitution(p_token text,p_order_id text,p_line_id text,p_offering_id text,p_qty int DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;po public.offerings;target jsonb;replacement jsonb;identity jsonb;terms jsonb;sid text;subtotal bigint;discount bigint;total bigint;nowms bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 SELECT value INTO target FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WHERE value->>'line_id'=p_line_id;
 IF target IS NULL THEN RAISE EXCEPTION 'line_not_found';END IF;
 SELECT * INTO po FROM public.offerings WHERE id=p_offering_id AND active;
 IF po.id IS NULL OR p_qty IS NULL OR p_qty NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'invalid_substitution';END IF;
 IF po.id=target->>'offering_id' AND p_qty=(target->>'qty')::int THEN RAISE EXCEPTION 'substitution_unchanged';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(po.components::jsonb) c LEFT JOIN public.stock_items st ON st.id=c->>'stock_id' WHERE st.id IS NULL OR NOT st.active) THEN RAISE EXCEPTION 'invalid_substitution';END IF;
 SELECT jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) INTO identity
 FROM public.product_version_offerings m JOIN public.product_versions v ON v.id=m.version_id WHERE m.offering_id=po.id;
 replacement=jsonb_build_object('line_id',p_line_id,'offering_id',po.id,'family_id',po.family_id,'version',po.version,'kind',po.kind,'name',po.name,'size_label',po.size_label,'sale_unit',po.sale_unit,'unit_price_halalas',po.price_halalas,'qty',p_qty,'line_total_halalas',po.price_halalas*p_qty,'components',po.components,'substituted_from',target->>'offering_id')||coalesce(identity,'{}'::jsonb)||public.jana_weight_terms(po.id,p_qty);
 subtotal=(o.snapshot->>'subtotal_halalas')::bigint-(target->>'line_total_halalas')::bigint+po.price_halalas*p_qty;
 discount=public.jana_coupon_discount(o.original_snapshot::jsonb->'coupon',subtotal);
 total=subtotal-discount+(o.snapshot->>'delivery_fee_halalas')::bigint;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;sid='sub-'||replace(gen_random_uuid()::text,'-','');
 terms=jsonb_build_object('offering_id',po.id,'qty',p_qty,'name',po.name,'original_line',target,'replacement_line',replacement,
 'order_snapshot_hash',encode(digest(o.snapshot::jsonb::text,'sha256'),'hex'),'original_total_halalas',o.total_halalas,
 'subtotal_halalas',subtotal,'discount_halalas',discount,'total_halalas',total,'price_difference_halalas',total-o.total_halalas,'inventory_reserved',false);
 PERFORM public.jana_picking_issue(p_token,o.id,p_line_id,'بانتظار بديل يوافق عليه العميل',false);
 INSERT INTO public.substitutions(id,order_id,line_id,component_id,proposed,default_action,state,expires_at,actor_id,created_at)
 VALUES(sid,o.id,p_line_id,po.id,terms,'hold_for_resolution','pending',nowms+900000,u.id,nowms);
 UPDATE public.orders SET fulfillment_state='awaiting_customer' WHERE id=o.id;
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),o.user_id,'sub-'||sid,'بديل يحتاج موافقتك','راجع الصنف والكمية والإجمالي الجديد قبل الموافقة. عدم الرد لا يعني الموافقة.',o.id,false,nowms);
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'substitution_proposed',p_line_id,jsonb_build_object('substitution_id',sid,'price_difference_halalas',total-o.total_halalas),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'substitution_proposed',sid,jsonb_build_object('role',u.role,'order_id',o.id,'original',target,'proposed',replacement,'price_difference_halalas',total-o.total_halalas),nowms);
 RETURN jsonb_build_object('id',sid,'order_id',o.id,'line_id',p_line_id,'state','pending','expires_at',nowms+900000,'proposed',terms);
END$$;

CREATE FUNCTION public.jana_reallocate_order(p_order_id text,p_lines jsonb,p_actor_id text,p_reason_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE o public.orders;slot_end bigint;rec record;lotrec record;a jsonb;need bigint;take bigint;allocations jsonb:='[]';nowms bigint;
BEGIN
 IF p_reason_kind IS NULL OR p_reason_kind NOT IN ('substitution','weight') THEN RAISE EXCEPTION 'invalid_operation';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.fulfillment_state NOT IN ('picking','awaiting_customer') THEN RAISE EXCEPTION 'invalid_transition';END IF;
 SELECT ends_at INTO slot_end FROM public.delivery_slots WHERE id=o.slot_id FOR UPDATE;
 PERFORM 1 FROM public.stock_balances WHERE stock_id IN (
 SELECT value->>'stock_id' FROM jsonb_array_elements(o.snapshot::jsonb->'allocations')
 UNION SELECT c->>'stock_id' FROM jsonb_array_elements(p_lines) l CROSS JOIN LATERAL jsonb_array_elements(l->'components') c
 ) ORDER BY stock_id FOR UPDATE;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 FOR a IN SELECT value FROM jsonb_array_elements(o.snapshot::jsonb->'allocations') LOOP
  UPDATE public.inventory_lots SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE id=a->>'lot_id' AND stock_id=a->>'stock_id' AND reserved_base>=(a->>'base_qty')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid';END IF;
  UPDATE public.stock_balances SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE stock_id=a->>'stock_id' AND reserved_base>=(a->>'base_qty')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid';END IF;
  INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
  VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),a->>'stock_id',a->>'lot_id',0,-(a->>'base_qty')::bigint,p_reason_kind||'_reservation_release',o.id,p_actor_id,nowms);
 END LOOP;
 FOR rec IN SELECT c->>'stock_id' stock_id,sum(CASE WHEN jsonb_array_length(l->'components')=1 AND l?'actual_base_qty' THEN (l->>'actual_base_qty')::bigint ELSE (c->>'base_qty')::bigint*(l->>'qty')::bigint END)::bigint required
  FROM jsonb_array_elements(p_lines) l CROSS JOIN LATERAL jsonb_array_elements(l->'components') c GROUP BY c->>'stock_id' ORDER BY c->>'stock_id'
 LOOP
  IF NOT EXISTS(SELECT 1 FROM public.stock_items WHERE id=rec.stock_id AND active) OR NOT EXISTS(SELECT 1 FROM public.stock_balances WHERE stock_id=rec.stock_id AND on_hand_base-reserved_base>=rec.required) THEN RAISE EXCEPTION 'insufficient_stock';END IF;
  need=rec.required;
  FOR lotrec IN SELECT id,on_hand_base-reserved_base available FROM public.inventory_lots WHERE stock_id=rec.stock_id AND inspection_state='accepted' AND expires_at>greatest(nowms,slot_end) AND on_hand_base>reserved_base ORDER BY expires_at,id FOR UPDATE LOOP
   EXIT WHEN need<=0;take=least(need,lotrec.available);
   UPDATE public.inventory_lots SET reserved_base=reserved_base+take WHERE id=lotrec.id;
   allocations=allocations||jsonb_build_array(jsonb_build_object('stock_id',rec.stock_id,'lot_id',lotrec.id,'base_qty',take));
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
   VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),rec.stock_id,lotrec.id,0,take,p_reason_kind||'_reserved',o.id,p_actor_id,nowms);need=need-take;
  END LOOP;
  IF need>0 THEN RAISE EXCEPTION 'insufficient_lot_stock';END IF;
  UPDATE public.stock_balances SET reserved_base=reserved_base+rec.required WHERE stock_id=rec.stock_id;
 END LOOP;
 RETURN allocations;
END$$;


CREATE OR REPLACE FUNCTION public.jana_reallocate_order(p_order_id text,p_lines jsonb,p_actor_id text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.jana_reallocate_order(p_order_id,p_lines,p_actor_id,'substitution');
$$;



CREATE OR REPLACE FUNCTION public.jana_picker_record_actual(p_token text,p_order_id text,p_line_id text,p_actual_base bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.orders;target jsonb;line jsonb;newlines jsonb;allocations jsonb;planned bigint;minimum bigint;maximum bigint;
 price bigint;subtotal bigint;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','picker') THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF u.role='picker' AND o.picker_id IS DISTINCT FROM u.id THEN RAISE EXCEPTION 'order_not_assigned';END IF;
 IF EXISTS(SELECT 1 FROM public.picking_line_issues WHERE order_id=o.id AND line_id=p_line_id AND state='open') THEN RAISE EXCEPTION 'unresolved_picking_items';END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition';END IF;
 SELECT value INTO target FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WHERE value->>'line_id'=p_line_id;
 IF target IS NULL THEN RAISE EXCEPTION 'line_not_found';END IF;
 IF jsonb_array_length(target->'components')<>1 THEN RAISE EXCEPTION 'actual_weight_not_supported';END IF;
 planned=(target->'components'->0->>'base_qty')::bigint*(target->>'qty')::bigint;
 -- Read only the policy accepted with this line, including customer-approved substitutes.
 minimum=coalesce((target->'weight_policy'->>'min_base')::bigint,1);
 maximum=coalesce((target->'weight_policy'->>'max_base')::bigint,planned);
 IF p_actual_base IS NULL OR p_actual_base<minimum OR p_actual_base>maximum THEN RAISE EXCEPTION 'invalid_actual_weight';END IF;
 price=(target->>'unit_price_halalas')::bigint*(target->>'qty')::bigint;
 price=least(price,greatest(1,round(price::numeric*p_actual_base/planned)::bigint));
 line=target||jsonb_build_object('actual_base_qty',p_actual_base,'line_total_halalas',price,'actual_recorded_at',nowms);
 SELECT jsonb_agg(CASE WHEN x->>'line_id'=p_line_id THEN line ELSE x END ORDER BY n) INTO newlines FROM jsonb_array_elements(o.snapshot::jsonb->'lines') WITH ORDINALITY e(x,n);
 allocations=o.snapshot::jsonb->'allocations';
 -- Lower weights preserve the existing reservation-until-picking behavior.
 -- Overfill must acquire real FEFO stock before any weight/price update succeeds.
 IF p_actual_base>planned OR coalesce((target->>'actual_base_qty')::bigint,planned)>planned THEN
  allocations=public.jana_reallocate_order(o.id,newlines,u.id,'weight');
 END IF;
 SELECT sum((x->>'line_total_halalas')::bigint) INTO subtotal FROM jsonb_array_elements(newlines) x;
 UPDATE public.orders SET snapshot=o.snapshot::jsonb||jsonb_build_object('lines',newlines,'allocations',allocations,'subtotal_halalas',subtotal,'total_halalas',subtotal+(o.snapshot->>'delivery_fee_halalas')::bigint),
 total_halalas=subtotal+(o.snapshot->>'delivery_fee_halalas')::bigint WHERE id=o.id RETURNING * INTO o;
 -- The existing pricing trigger applies original coupon terms and writes the total.
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'actual_weight_recorded',p_line_id,jsonb_build_object('before_base_qty',coalesce((target->>'actual_base_qty')::bigint,planned),'actual_base_qty',p_actual_base,'total_halalas',o.total_halalas),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'actual_weight_recorded',o.id,jsonb_build_object('role',u.role,'line_id',p_line_id,'before',target,'after',line,'total_halalas',o.total_halalas),nowms);
 RETURN jsonb_build_object('id',o.id,'number',o.number,'total_halalas',o.total_halalas,'snapshot',o.snapshot);
END$$;


CREATE OR REPLACE FUNCTION public.jana_catalog_page(p_offset integer DEFAULT 0,p_limit integer DEFAULT 50,p_query text DEFAULT '',p_category text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 IF p_offset IS NULL OR p_limit IS NULL OR p_offset NOT BETWEEN 0 AND 100000 OR p_limit NOT BETWEEN 1 AND 100 OR p_query IS NULL OR length(p_query)>200 OR p_category IS NULL OR length(p_category)>100 THEN RAISE EXCEPTION 'invalid_catalog_page';END IF;
 p_query=trim(p_query);p_category=trim(p_category);
 WITH candidates AS MATERIALIZED (
  SELECT o.* FROM public.offerings o
  WHERE o.active AND (p_query='' OR strpos(o.name,p_query)>0) AND (p_category='' OR o.category=p_category)
  ORDER BY o.created_at,o.id LIMIT p_limit+1 OFFSET p_offset
 ), selected AS MATERIALIZED (
  SELECT * FROM candidates ORDER BY created_at,id LIMIT p_limit
 ), stocks AS MATERIALIZED (
  SELECT DISTINCT c->>'stock_id' AS stock_id FROM selected o CROSS JOIN LATERAL json_array_elements(o.components) c
 ), balances AS MATERIALIZED (
  SELECT l.stock_id,sum(l.on_hand_base-l.reserved_base)::bigint AS available_base
  FROM stocks t JOIN public.stock_items s ON s.id=t.stock_id AND s.active
  JOIN public.inventory_lots l ON l.stock_id=s.id
  WHERE l.inspection_state='accepted' AND l.expires_at>nowms GROUP BY l.stock_id
 ), items AS (
  SELECT o.created_at,o.id,jsonb_build_object('id',o.id,'family_id',o.family_id,'version',o.version,'kind',o.kind,'name',o.name,'description',o.description,'category',o.category,'size_label',o.size_label,'emoji',o.emoji,'image_url',o.image_url,'sale_unit',o.sale_unit,'price_halalas',o.price_halalas,'components',o.components,
   'available_units',coalesce((SELECT min(floor(coalesce(b.available_base,0)::numeric/greatest((c->>'base_qty')::numeric,1))) FROM json_array_elements(o.components) c LEFT JOIN balances b ON b.stock_id=c->>'stock_id'),0)::bigint)
   ||public.jana_weight_terms(o.id,1)||CASE WHEN v.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) END AS item
  FROM selected o LEFT JOIN public.product_version_offerings m ON m.offering_id=o.id LEFT JOIN public.product_versions v ON v.id=m.version_id
 )
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(item ORDER BY created_at,id) FROM items),'[]'::jsonb),'next_offset',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN p_offset+p_limit ELSE NULL END) INTO result;
 RETURN result;
END$$;


CREATE OR REPLACE FUNCTION public.jana_public_catalog() RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(x.item||public.jana_weight_terms(x.item->>'id',1)||CASE WHEN v.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) END ORDER BY x.ord),'[]')
 FROM jsonb_array_elements(public.jana_public_catalog_base()) WITH ORDINALITY x(item,ord)
 LEFT JOIN public.product_version_offerings m ON m.offering_id=x.item->>'id' LEFT JOIN public.product_versions v ON v.id=m.version_id;
$$;
REVOKE ALL ON FUNCTION public.jana_weight_terms(text,integer),public.jana_reallocate_order(text,jsonb,text,text),public.jana_reallocate_order(text,jsonb,text) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_admin_create_product_version(text,text,jsonb),public.jana_create_quote(text,text,text,jsonb),public.jana_propose_substitution(text,text,text,text,integer),public.jana_picker_record_actual(text,text,text,bigint),public.jana_catalog_page(integer,integer,text,text),public.jana_public_catalog() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_create_product_version(text,text,jsonb),public.jana_create_quote(text,text,text,jsonb),public.jana_propose_substitution(text,text,text,text,integer),public.jana_picker_record_actual(text,text,text,bigint),public.jana_catalog_page(integer,integer,text,text),public.jana_public_catalog() TO service_role;
