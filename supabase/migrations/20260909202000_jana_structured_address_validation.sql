ALTER TABLE public.addresses ADD COLUMN city text NOT NULL DEFAULT '';
ALTER TABLE public.addresses ADD COLUMN district text NOT NULL DEFAULT '';
ALTER TABLE public.addresses ADD COLUMN street text NOT NULL DEFAULT '';
ALTER TABLE public.addresses ADD COLUMN building text NOT NULL DEFAULT '';
ALTER TABLE public.addresses ADD COLUMN floor text NOT NULL DEFAULT '';
ALTER TABLE public.addresses ADD COLUMN apartment text NOT NULL DEFAULT '';
ALTER TABLE public.addresses ADD COLUMN notes text NOT NULL DEFAULT '';

CREATE FUNCTION public.jana_save_address(p_token text,p_address_id text,p_address jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users; old_address public.addresses; saved public.addresses;
 v jsonb; lat numeric; lng numeric; aid text; field_name text; make_default boolean;
BEGIN
 u=public.jana_auth_user(p_token);
 IF p_address IS NULL OR jsonb_typeof(p_address)<>'object' THEN RAISE EXCEPTION 'address_validation'; END IF;
 -- All address mutations for a customer use this lock to protect the default address.
 PERFORM 1 FROM public.users WHERE id=u.id FOR UPDATE;
 IF p_address_id IS NOT NULL THEN
  SELECT * INTO old_address FROM public.addresses WHERE id=p_address_id AND user_id=u.id FOR UPDATE;
  IF old_address.id IS NULL THEN RAISE EXCEPTION 'invalid_address'; END IF;
  v=to_jsonb(old_address)||p_address;aid=old_address.id;
 ELSE
  IF (SELECT count(*) FROM public.addresses WHERE user_id=u.id)>=20 THEN RAISE EXCEPTION 'address_limit'; END IF;
  v=p_address;aid='adr-'||replace(gen_random_uuid()::text,'-','');
 END IF;
 IF v->>'latitude' IS NULL OR v->>'longitude' IS NULL OR trim(v->>'latitude')='' OR trim(v->>'longitude')='' THEN RAISE EXCEPTION 'invalid_coordinates'; END IF;
 BEGIN lat=(v->>'latitude')::numeric;lng=(v->>'longitude')::numeric;
 EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN RAISE EXCEPTION 'invalid_coordinates'; END;
 IF lat NOT BETWEEN -90 AND 90 OR lng NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'invalid_coordinates'; END IF;
 FOREACH field_name IN ARRAY ARRAY['label','details','recipient_name','recipient_phone','city','district','street','building','floor','apartment','notes'] LOOP
  IF v ? field_name AND jsonb_typeof(v->field_name) NOT IN ('string','null') THEN RAISE EXCEPTION 'address_validation'; END IF;
  v=jsonb_set(v,ARRAY[field_name],to_jsonb(trim(coalesce(v->>field_name,''))),true);
  IF length(v->>field_name)>CASE WHEN field_name IN ('details','notes') THEN 500 ELSE 100 END THEN RAISE EXCEPTION 'address_validation'; END IF;
 END LOOP;
 IF length(v->>'label')<1 OR length(v->>'label')>40 OR length(v->>'details')<3 OR length(v->>'recipient_name')<2 OR length(v->>'recipient_name')>80 OR
  v->>'recipient_phone' !~ '^(05[0-9]{8}|\+9665[0-9]{8})$' THEN RAISE EXCEPTION 'address_validation'; END IF;
 IF v ? 'is_default' AND jsonb_typeof(v->'is_default')<>'boolean' THEN RAISE EXCEPTION 'address_validation'; END IF;
 make_default=coalesce((v->>'is_default')::boolean,false) OR NOT EXISTS(SELECT 1 FROM public.addresses WHERE user_id=u.id AND id<>aid);
 -- Unsetting the only default selects another saved address deterministically.
 IF make_default THEN UPDATE public.addresses SET is_default=false WHERE user_id=u.id AND is_default; END IF;
 INSERT INTO public.addresses(id,user_id,label,details,latitude,longitude,recipient_name,recipient_phone,is_default,city,district,street,building,floor,apartment,notes)
 VALUES(aid,u.id,v->>'label',v->>'details',lat::text,lng::text,v->>'recipient_name',v->>'recipient_phone',make_default,v->>'city',v->>'district',v->>'street',v->>'building',v->>'floor',v->>'apartment',v->>'notes')
 ON CONFLICT(id) DO UPDATE SET label=EXCLUDED.label,details=EXCLUDED.details,latitude=EXCLUDED.latitude,longitude=EXCLUDED.longitude,
  recipient_name=EXCLUDED.recipient_name,recipient_phone=EXCLUDED.recipient_phone,is_default=EXCLUDED.is_default,city=EXCLUDED.city,district=EXCLUDED.district,
  street=EXCLUDED.street,building=EXCLUDED.building,floor=EXCLUDED.floor,apartment=EXCLUDED.apartment,notes=EXCLUDED.notes
 RETURNING * INTO saved;
 IF NOT EXISTS(SELECT 1 FROM public.addresses WHERE user_id=u.id AND is_default) THEN
  UPDATE public.addresses SET is_default=true WHERE id=(SELECT id FROM public.addresses WHERE user_id=u.id ORDER BY id LIMIT 1);
 END IF;
 RETURN (SELECT to_jsonb(a) FROM public.addresses a WHERE id=aid);
END$$;

CREATE OR REPLACE FUNCTION public.jana_add_address(p_token text,p_label text,p_details text,p_latitude text,p_longitude text,p_recipient_name text,p_recipient_phone text,p_default boolean DEFAULT true)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.jana_save_address(p_token,NULL,jsonb_build_object('label',p_label,'details',p_details,'latitude',p_latitude,'longitude',p_longitude,'recipient_name',p_recipient_name,'recipient_phone',p_recipient_phone,'is_default',p_default));
$$;
CREATE OR REPLACE FUNCTION public.jana_update_address(p_token text,p_address_id text,p_label text,p_details text,p_latitude text,p_longitude text,p_recipient_name text,p_recipient_phone text,p_default boolean)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.jana_save_address(p_token,p_address_id,jsonb_build_object('label',p_label,'details',p_details,'latitude',p_latitude,'longitude',p_longitude,'recipient_name',p_recipient_name,'recipient_phone',p_recipient_phone,'is_default',p_default));
$$;
CREATE OR REPLACE FUNCTION public.jana_delete_address(p_token text,p_address_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;
BEGIN
 u=public.jana_auth_user(p_token);PERFORM 1 FROM public.users WHERE id=u.id FOR UPDATE;
 DELETE FROM public.addresses WHERE id=p_address_id AND user_id=u.id;
 IF NOT FOUND THEN RAISE EXCEPTION 'invalid_address'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.addresses WHERE user_id=u.id AND is_default) THEN
  UPDATE public.addresses SET is_default=true WHERE id=(SELECT id FROM public.addresses WHERE user_id=u.id ORDER BY id LIMIT 1);
 END IF;
 RETURN jsonb_build_object('ok',true);
END$$;
REVOKE ALL ON FUNCTION public.jana_save_address(text,text,jsonb),public.jana_add_address(text,text,text,text,text,text,text,boolean),public.jana_update_address(text,text,text,text,text,text,text,text,boolean),public.jana_delete_address(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_save_address(text,text,jsonb),public.jana_add_address(text,text,text,text,text,text,text,boolean),public.jana_update_address(text,text,text,text,text,text,text,text,boolean),public.jana_delete_address(text,text) TO service_role;
