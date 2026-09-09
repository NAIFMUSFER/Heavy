create or replace function public.jana_admin_new_offering_version(p_token text,p_family_id text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; prev public.offerings; nid text:='off-'||replace(gen_random_uuid()::text,'-',''); nv int; raw_comps jsonb; canon_comps jsonb:='[]'::jsonb; c jsonb; s public.stock_items; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; price bigint; qty bigint; lp bigint;
begin
 u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 select * into prev from public.offerings where family_id=p_family_id order by version desc limit 1 for update; if prev.id is null then raise exception 'family_not_found'; end if;
 nv=prev.version+1; raw_comps=coalesce(p_payload->'components',prev.components::jsonb); price=coalesce((p_payload->>'price_halalas')::bigint,prev.price_halalas);
 if price<=0 or price>9000000000000 or jsonb_typeof(raw_comps)<>'array' or jsonb_array_length(raw_comps)=0 then raise exception 'validation'; end if;
 for c in select value from jsonb_array_elements(raw_comps) loop
   qty=coalesce((c->>'base_qty')::bigint,0); lp=coalesce((c->>'list_price_halalas')::bigint,0);
   select * into s from public.stock_items where id=c->>'stock_id' and active=true;
   if s.id is null or qty<=0 or lp<0 then raise exception 'invalid_component'; end if;
   canon_comps=canon_comps||jsonb_build_array(jsonb_build_object('stock_id',s.id,'name',s.name,'base_unit',s.base_unit,'base_qty',qty,'list_price_halalas',lp));
 end loop;
 if length(trim(coalesce(p_payload->>'name',prev.name)))<2 then raise exception 'validation'; end if;
 update public.offerings set active=false where family_id=p_family_id and active=true;
 insert into public.offerings(id,family_id,version,kind,name,description,category,size_label,emoji,image_url,sale_unit,price_halalas,components,active,created_at)
 values(nid,p_family_id,nv,coalesce(p_payload->>'kind',prev.kind),coalesce(nullif(trim(p_payload->>'name'),''),prev.name),coalesce(p_payload->>'description',prev.description),coalesce(p_payload->>'category',prev.category),coalesce(p_payload->>'size_label',prev.size_label),coalesce(p_payload->>'emoji',prev.emoji),coalesce(p_payload->>'image_url',prev.image_url),coalesce(p_payload->>'sale_unit',prev.sale_unit),price,canon_comps::json,true,nowms);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'offering_version_created',nid,jsonb_build_object('family_id',p_family_id,'version',nv,'previous_id',prev.id,'component_count',jsonb_array_length(canon_comps)),nowms);
 return (select to_jsonb(o) from public.offerings o where id=nid);
end$$;
revoke all on function public.jana_admin_new_offering_version(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.jana_admin_new_offering_version(text,text,jsonb) to service_role;