create or replace function public.jana_inventory_create_stock(p_token text,p_name text,p_base_unit text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; sid text:='stk-'||replace(gen_random_uuid()::text,'-',''); nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 if length(trim(coalesce(p_name,'')))<2 or p_base_unit not in ('gram','piece') then raise exception 'validation'; end if;
 insert into public.stock_items(id,name,base_unit,active) values(sid,trim(p_name),p_base_unit,true);
 insert into public.stock_balances(stock_id,on_hand_base,reserved_base) values(sid,0,0);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'stock_created',sid,jsonb_build_object('name',trim(p_name),'base_unit',p_base_unit),nowms);
 return jsonb_build_object('id',sid,'name',trim(p_name),'base_unit',p_base_unit,'active',true,'on_hand_base',0,'reserved_base',0);
end$$;

create or replace function public.jana_inventory_receive_lot(p_token text,p_stock_id text,p_supplier_id text,p_received_base bigint,p_total_cost_halalas bigint,p_expires_at bigint)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; lid text:='lot-'||replace(gen_random_uuid()::text,'-',''); nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; st public.stock_items;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 select * into st from public.stock_items where id=p_stock_id and active=true; if st.id is null then raise exception 'stock_not_found'; end if;
 if p_supplier_id is not null and not exists(select 1 from public.suppliers where id=p_supplier_id and active=true) then raise exception 'supplier_not_found'; end if;
 if p_received_base<=0 or p_total_cost_halalas<0 or p_expires_at<=nowms then raise exception 'validation'; end if;
 insert into public.inventory_lots(id,stock_id,supplier_id,received_base,on_hand_base,reserved_base,total_cost_halalas,remaining_cost_halalas,expires_at,inspection_state,received_by,inspected_by,inspection_note,created_at)
 values(lid,p_stock_id,p_supplier_id,p_received_base,0,0,p_total_cost_halalas,p_total_cost_halalas,p_expires_at,'pending',u.id,null,'',nowms);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'lot_received_pending_inspection',lid,jsonb_build_object('stock_id',p_stock_id,'received_base',p_received_base,'cost_halalas',p_total_cost_halalas),nowms);
 return jsonb_build_object('id',lid,'stock_id',p_stock_id,'received_base',p_received_base,'inspection_state','pending','expires_at',p_expires_at);
end$$;

create or replace function public.jana_inventory_inspect_lot(p_token text,p_lot_id text,p_state text,p_note text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; l public.inventory_lots; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 if p_state not in ('accepted','rejected') then raise exception 'validation'; end if;
 select * into l from public.inventory_lots where id=p_lot_id for update; if l.id is null then raise exception 'lot_not_found'; end if;
 if l.inspection_state<>'pending' then raise exception 'already_inspected'; end if;
 if p_state='accepted' then
   update public.inventory_lots set inspection_state='accepted',inspected_by=u.id,inspection_note=left(coalesce(p_note,''),1000),on_hand_base=received_base where id=l.id;
   update public.stock_balances set on_hand_base=on_hand_base+l.received_base where stock_id=l.stock_id;
   insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),l.stock_id,l.id,l.received_base,0,'goods_receipt_accepted',l.id,u.id,nowms);
 else
   update public.inventory_lots set inspection_state='rejected',inspected_by=u.id,inspection_note=left(coalesce(p_note,''),1000),remaining_cost_halalas=0 where id=l.id;
 end if;
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'lot_inspected',l.id,jsonb_build_object('state',p_state,'note',left(coalesce(p_note,''),1000)),nowms);
 return jsonb_build_object('id',l.id,'inspection_state',p_state,'stock_id',l.stock_id,'received_base',l.received_base);
end$$;

create or replace function public.jana_inventory_adjust_lot(p_token text,p_lot_id text,p_new_on_hand bigint,p_reason text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; l public.inventory_lots; d bigint; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
 u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 select * into l from public.inventory_lots where id=p_lot_id for update; if l.id is null then raise exception 'lot_not_found'; end if;
 if l.inspection_state<>'accepted' or p_new_on_hand<l.reserved_base or p_new_on_hand<0 or length(trim(coalesce(p_reason,'')))<3 then raise exception 'validation'; end if;
 d=p_new_on_hand-l.on_hand_base; if d=0 then return jsonb_build_object('id',l.id,'on_hand_base',l.on_hand_base,'delta',0); end if;
 update public.inventory_lots set on_hand_base=p_new_on_hand where id=l.id;
 update public.stock_balances set on_hand_base=on_hand_base+d where stock_id=l.stock_id;
 insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),l.stock_id,l.id,d,0,'count_adjustment',left(trim(p_reason),200),u.id,nowms);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'inventory_adjustment',l.id,jsonb_build_object('old_on_hand',l.on_hand_base,'new_on_hand',p_new_on_hand,'delta',d,'reason',left(trim(p_reason),200)),nowms);
 return jsonb_build_object('id',l.id,'on_hand_base',p_new_on_hand,'delta',d);
end$$;

create or replace function public.jana_admin_new_offering_version(p_token text,p_family_id text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; prev public.offerings; nid text:='off-'||replace(gen_random_uuid()::text,'-',''); nv int; comps jsonb; c jsonb; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint; price bigint;
begin
 u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 select * into prev from public.offerings where family_id=p_family_id order by version desc limit 1 for update; if prev.id is null then raise exception 'family_not_found'; end if;
 nv=prev.version+1; comps=coalesce(p_payload->'components',prev.components::jsonb); price=coalesce((p_payload->>'price_halalas')::bigint,prev.price_halalas);
 if price<=0 or jsonb_typeof(comps)<>'array' or jsonb_array_length(comps)=0 then raise exception 'validation'; end if;
 for c in select value from jsonb_array_elements(comps) loop
   if coalesce((c->>'base_qty')::bigint,0)<=0 or not exists(select 1 from public.stock_items where id=c->>'stock_id' and active=true) then raise exception 'invalid_component'; end if;
 end loop;
 update public.offerings set active=false where family_id=p_family_id and active=true;
 insert into public.offerings(id,family_id,version,kind,name,description,category,size_label,emoji,image_url,sale_unit,price_halalas,components,active,created_at)
 values(nid,p_family_id,nv,coalesce(p_payload->>'kind',prev.kind),coalesce(nullif(trim(p_payload->>'name'),''),prev.name),coalesce(p_payload->>'description',prev.description),coalesce(p_payload->>'category',prev.category),coalesce(p_payload->>'size_label',prev.size_label),coalesce(p_payload->>'emoji',prev.emoji),coalesce(p_payload->>'image_url',prev.image_url),coalesce(p_payload->>'sale_unit',prev.sale_unit),price,comps,true,nowms);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'offering_version_created',nid,jsonb_build_object('family_id',p_family_id,'version',nv,'previous_id',prev.id),nowms);
 return (select to_jsonb(o) from public.offerings o where id=nid);
end$$;

create or replace function public.jana_admin_create_zone(p_token text,p_name text,p_polygon jsonb,p_fee_halalas bigint,p_minimum_halalas bigint)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; zid text:='zone-'||replace(gen_random_uuid()::text,'-',''); nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
 u=public.jana_auth_user(p_token); if u.role<>'admin' then raise exception 'forbidden'; end if;
 if length(trim(coalesce(p_name,'')))<2 or p_fee_halalas<0 or p_minimum_halalas<0 or jsonb_typeof(p_polygon)<>'object' then raise exception 'validation'; end if;
 insert into public.delivery_zones(id,name,polygon,fee_halalas,minimum_halalas,active) values(zid,trim(p_name),p_polygon::json,p_fee_halalas,p_minimum_halalas,true);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'delivery_zone_created',zid,jsonb_build_object('name',trim(p_name),'fee_halalas',p_fee_halalas,'minimum_halalas',p_minimum_halalas),nowms);
 return jsonb_build_object('id',zid,'name',trim(p_name),'fee_halalas',p_fee_halalas,'minimum_halalas',p_minimum_halalas,'active',true);
end$$;