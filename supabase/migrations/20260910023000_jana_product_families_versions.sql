-- Canonical product identity is separate from the existing stable sellable lineage.
-- Existing offering rows and historical order snapshots are not rewritten.
CREATE TABLE public.product_families(
 id varchar(36) PRIMARY KEY,name varchar(140) NOT NULL CHECK(length(trim(name))>=2),
 created_at bigint NOT NULL,created_by varchar(36) REFERENCES public.users(id)
);
CREATE TABLE public.product_versions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),family_id varchar(36) NOT NULL REFERENCES public.product_families(id),
 version integer NOT NULL CHECK(version>0),title varchar(140) NOT NULL CHECK(length(trim(title))>=2),
 description text NOT NULL,category varchar(40) NOT NULL,kind varchar(20) NOT NULL CHECK(kind IN ('individual','basket','sized','usage','bulk','gift')),
 emoji varchar(20) NOT NULL,image_url varchar(300) NOT NULL,
 state text NOT NULL CHECK(state IN ('draft','active','retired')),created_at bigint NOT NULL,created_by varchar(36) REFERENCES public.users(id),
 UNIQUE(family_id,version)
);
CREATE UNIQUE INDEX product_one_active_version ON public.product_versions(family_id) WHERE state='active';
CREATE TABLE public.product_version_offerings(
 version_id uuid NOT NULL REFERENCES public.product_versions(id),offering_id varchar(36) NOT NULL UNIQUE REFERENCES public.offerings(id),
 sellable_key varchar(40) NOT NULL CHECK(sellable_key ~ '^[a-z0-9][a-z0-9_-]{0,39}$'),
 PRIMARY KEY(version_id,sellable_key)
);
INSERT INTO public.product_families(id,name,created_at)
 SELECT DISTINCT ON(family_id) family_id,name,created_at FROM public.offerings ORDER BY family_id,version;
INSERT INTO public.product_versions(family_id,version,title,description,category,kind,emoji,image_url,state,created_at)
 SELECT family_id,version,name,description,category,kind,emoji,image_url,CASE WHEN active THEN 'active' ELSE 'retired' END,created_at FROM public.offerings;
INSERT INTO public.product_version_offerings(version_id,offering_id,sellable_key)
 SELECT v.id,o.id,'default' FROM public.offerings o JOIN public.product_versions v ON v.family_id=o.family_id AND v.version=o.version;
ALTER TABLE public.product_families ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_version_offerings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_families,public.product_versions,public.product_version_offerings FROM PUBLIC,anon,authenticated;
CREATE TRIGGER immutable_product_family BEFORE UPDATE OR DELETE ON public.product_families FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();
CREATE TRIGGER immutable_product_offering_link BEFORE UPDATE OR DELETE ON public.product_version_offerings FOR EACH ROW EXECUTE FUNCTION public.jana_append_only();
CREATE FUNCTION public.jana_product_version_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'create_a_new_product_version';END IF;
 IF (to_jsonb(NEW)-'state') IS DISTINCT FROM (to_jsonb(OLD)-'state') THEN RAISE EXCEPTION 'create_a_new_product_version';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER immutable_product_version BEFORE UPDATE OR DELETE ON public.product_versions FOR EACH ROW EXECUTE FUNCTION public.jana_product_version_immutable();

CREATE FUNCTION public.jana_product_offering_link_guard() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.product_versions WHERE id=NEW.version_id AND state='draft') THEN RAISE EXCEPTION 'create_a_new_product_version';END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER guard_product_offering_link BEFORE INSERT ON public.product_version_offerings FOR EACH ROW EXECUTE FUNCTION public.jana_product_offering_link_guard();

CREATE FUNCTION public.jana_admin_create_product_version(p_token text,p_family_id text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; fam public.product_families; source public.product_versions; v public.product_versions;
 body jsonb; items jsonb; item jsonb; component jsonb; components jsonb; stock public.stock_items;
 oid text; lineage text; n integer; units bigint; price bigint; refprice bigint; key text; title text;
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
  SELECT o.family_id INTO lineage FROM public.product_version_offerings m JOIN public.product_versions pv ON pv.id=m.version_id JOIN public.offerings o ON o.id=m.offering_id
   WHERE pv.family_id=fam.id AND m.sellable_key=key ORDER BY pv.version DESC LIMIT 1;
  lineage=coalesce(lineage,'sku-'||replace(gen_random_uuid()::text,'-',''));oid='off-'||replace(gen_random_uuid()::text,'-','');
  INSERT INTO public.offerings(id,family_id,version,kind,name,description,category,size_label,emoji,image_url,sale_unit,price_halalas,components,active,created_at)
  VALUES(oid,lineage,n,v.kind,v.title,v.description,v.category,trim(item->>'size_label'),v.emoji,v.image_url,item->>'sale_unit',price,components::json,false,nowms);
  INSERT INTO public.product_version_offerings(version_id,offering_id,sellable_key) VALUES(v.id,oid,key);
 END LOOP;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'product_version_created',v.id::text,jsonb_build_object('family_id',fam.id,'version',n,'state','draft','offering_count',jsonb_array_length(items),'role',u.role),nowms);
 RETURN to_jsonb(v)||jsonb_build_object('offerings',(SELECT jsonb_agg(to_jsonb(o)||jsonb_build_object('sellable_key',m.sellable_key) ORDER BY m.sellable_key) FROM public.product_version_offerings m JOIN public.offerings o ON o.id=m.offering_id WHERE m.version_id=v.id));
END$$;

CREATE FUNCTION public.jana_admin_activate_product_version(p_token text,p_version_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;v public.product_versions;fid text;previous uuid;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT family_id INTO fid FROM public.product_versions WHERE id=p_version_id;IF fid IS NULL THEN RAISE EXCEPTION 'product_version_not_found';END IF;
 PERFORM 1 FROM public.product_families WHERE id=fid FOR UPDATE;
 SELECT * INTO v FROM public.product_versions WHERE id=p_version_id FOR UPDATE;
 IF v.state='active' THEN RETURN to_jsonb(v);END IF;
 IF v.state<>'draft' THEN RAISE EXCEPTION 'invalid_product_version_state';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.product_version_offerings WHERE version_id=v.id) THEN RAISE EXCEPTION 'validation';END IF;
 IF EXISTS(SELECT 1 FROM public.product_version_offerings m JOIN public.offerings o ON o.id=m.offering_id CROSS JOIN LATERAL json_array_elements(o.components) c
  WHERE m.version_id=v.id AND NOT EXISTS(SELECT 1 FROM public.stock_items s WHERE s.id=c->>'stock_id' AND s.active)) THEN RAISE EXCEPTION 'invalid_component';END IF;
 SELECT id INTO previous FROM public.product_versions WHERE family_id=fid AND state='active';
 UPDATE public.product_versions SET state='retired' WHERE family_id=fid AND state='active';
 UPDATE public.offerings SET active=false WHERE id IN (SELECT m.offering_id FROM public.product_version_offerings m JOIN public.product_versions pv ON pv.id=m.version_id WHERE pv.family_id=fid) AND active;
 UPDATE public.product_versions SET state='active' WHERE id=v.id;
 UPDATE public.offerings SET active=true WHERE id IN (SELECT offering_id FROM public.product_version_offerings WHERE version_id=v.id);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'product_version_activated',v.id::text,jsonb_build_object('family_id',fid,'previous_version_id',previous,'new_version_id',v.id,'role',u.role),nowms);
 RETURN to_jsonb(v)||jsonb_build_object('state','active');
END$$;

-- Preserve the old single-offering editor; a change now creates a full version
-- containing the unchanged sibling offerings as well as the edited offering.
CREATE OR REPLACE FUNCTION public.jana_admin_new_offering_version(p_token text,p_family_id text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;v public.product_versions;target public.product_version_offerings;items jsonb;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT m.* INTO target FROM public.product_version_offerings m JOIN public.offerings o ON o.id=m.offering_id WHERE o.family_id=p_family_id ORDER BY o.version DESC LIMIT 1;
 IF target.offering_id IS NULL THEN RAISE EXCEPTION 'family_not_found';END IF;
 SELECT * INTO v FROM public.product_versions WHERE id=target.version_id;
 PERFORM 1 FROM public.product_families WHERE id=v.family_id FOR UPDATE;
 SELECT jsonb_agg((to_jsonb(o)||jsonb_build_object('sellable_key',m.sellable_key))||CASE WHEN m.sellable_key=target.sellable_key THEN p_payload-'name'-'description' ELSE '{}'::jsonb END ORDER BY m.sellable_key)
 INTO items FROM public.product_version_offerings m JOIN public.offerings o ON o.id=m.offering_id WHERE m.version_id=v.id;
 r=public.jana_admin_create_product_version(p_token,v.family_id,(to_jsonb(v)||p_payload)||jsonb_build_object('title',coalesce(p_payload->>'name',v.title),'offerings',items));
 PERFORM public.jana_admin_activate_product_version(p_token,(r->>'id')::uuid);
 RETURN (SELECT to_jsonb(o) FROM public.product_version_offerings m JOIN public.offerings o ON o.id=m.offering_id WHERE m.version_id=(r->>'id')::uuid AND m.sellable_key=target.sellable_key);
END$$;

CREATE OR REPLACE FUNCTION public.jana_admin_set_offering_active(p_token text,p_offering_id text,p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;o public.offerings;v public.product_versions;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_active IS NULL THEN RAISE EXCEPTION 'validation';END IF;
 SELECT pv.* INTO v FROM public.product_version_offerings m JOIN public.product_versions pv ON pv.id=m.version_id WHERE m.offering_id=p_offering_id;
 IF v.id IS NOT NULL THEN
  PERFORM 1 FROM public.product_families WHERE id=v.family_id FOR UPDATE;
  SELECT * INTO v FROM public.product_versions WHERE id=v.id;
  IF p_active AND v.state<>'active' THEN RAISE EXCEPTION 'invalid_product_version_state';END IF;
 END IF;
 UPDATE public.offerings SET active=p_active WHERE id=p_offering_id RETURNING * INTO o;
 IF o.id IS NULL THEN RAISE EXCEPTION 'offering_not_found';END IF;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'offering_active',o.id,jsonb_build_object('active',p_active,'role',u.role),nowms);
 RETURN jsonb_build_object('id',o.id,'active',o.active);
END$$;

ALTER FUNCTION public.jana_admin_catalog(text) RENAME TO jana_admin_catalog_base;
CREATE FUNCTION public.jana_admin_catalog(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;
BEGIN
 r=public.jana_admin_catalog_base(p_token);
 RETURN r||jsonb_build_object('product_families',(SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.created_at),'[]') FROM public.product_families f),
 'product_versions',(SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC),'[]') FROM public.product_versions v),
 'offerings',(SELECT coalesce(jsonb_agg(to_jsonb(o)||CASE WHEN v.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'product_version_state',v.state,'sellable_key',m.sellable_key) END ORDER BY o.created_at DESC),'[]') FROM public.offerings o LEFT JOIN public.product_version_offerings m ON m.offering_id=o.id LEFT JOIN public.product_versions v ON v.id=m.version_id));
END$$;
ALTER FUNCTION public.jana_public_catalog() RENAME TO jana_public_catalog_base;
CREATE FUNCTION public.jana_public_catalog() RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(x.item||CASE WHEN v.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) END ORDER BY x.ord),'[]')
 FROM jsonb_array_elements(public.jana_public_catalog_base()) WITH ORDINALITY x(item,ord)
 LEFT JOIN public.product_version_offerings m ON m.offering_id=x.item->>'id' LEFT JOIN public.product_versions v ON v.id=m.version_id;
$$;
ALTER FUNCTION public.jana_create_quote(text,text,text,jsonb) RENAME TO jana_create_quote_base;
CREATE FUNCTION public.jana_create_quote(p_token text,p_slot_id text,p_address_id text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r jsonb;lines jsonb;
BEGIN
 r=public.jana_create_quote_base(p_token,p_slot_id,p_address_id,p_items);
 SELECT jsonb_agg(x.item||CASE WHEN v.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('product_family_id',v.family_id,'product_version_id',v.id,'sellable_key',m.sellable_key) END ORDER BY x.ord)
 INTO lines FROM jsonb_array_elements(r->'lines') WITH ORDINALITY x(item,ord)
 LEFT JOIN public.product_version_offerings m ON m.offering_id=x.item->>'offering_id' LEFT JOIN public.product_versions v ON v.id=m.version_id;
 UPDATE public.quotes SET snapshot=jsonb_set(snapshot::jsonb,'{lines}',lines)::json WHERE id=r->>'id';
 RETURN r||jsonb_build_object('lines',lines);
END$$;
REVOKE ALL ON FUNCTION public.jana_product_offering_link_guard(),public.jana_product_version_immutable(),public.jana_admin_create_product_version(text,text,jsonb),public.jana_admin_activate_product_version(text,uuid),public.jana_admin_new_offering_version(text,text,jsonb),public.jana_admin_set_offering_active(text,text,boolean),public.jana_admin_catalog(text),public.jana_public_catalog(),public.jana_create_quote(text,text,text,jsonb),public.jana_admin_catalog_base(text),public.jana_public_catalog_base(),public.jana_create_quote_base(text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jana_admin_catalog_base(text),public.jana_public_catalog_base(),public.jana_create_quote_base(text,text,text,jsonb) FROM service_role;
GRANT EXECUTE ON FUNCTION public.jana_admin_create_product_version(text,text,jsonb),public.jana_admin_activate_product_version(text,uuid),public.jana_admin_new_offering_version(text,text,jsonb),public.jana_admin_set_offering_active(text,text,boolean),public.jana_admin_catalog(text),public.jana_public_catalog(),public.jana_create_quote(text,text,text,jsonb) TO service_role;
