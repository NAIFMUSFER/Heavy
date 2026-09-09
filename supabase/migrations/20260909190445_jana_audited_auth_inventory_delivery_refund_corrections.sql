DO $source_guard$ BEGIN
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_admin_refund') IS DISTINCT FROM '99424200b1b109aa04acb503d837d3af' THEN RAISE EXCEPTION 'JANA source changed: jana_admin_refund'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_cancel_quote') IS DISTINCT FROM 'd6b39b3eccce5957d9b3f6b0795cdae6' THEN RAISE EXCEPTION 'JANA source changed: jana_cancel_quote'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_confirm_order') IS DISTINCT FROM '4d0c82eb891d197ae1d6f9c9b87def87' THEN RAISE EXCEPTION 'JANA source changed: jana_confirm_order'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_create_quote') IS DISTINCT FROM '499a0bb5d4dbb36c7e4186262403a102' THEN RAISE EXCEPTION 'JANA source changed: jana_create_quote'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_create_quote_idempotent') IS DISTINCT FROM '7ba6998fa7857eb64d8bf7975d8bbdc2' THEN RAISE EXCEPTION 'JANA source changed: jana_create_quote_idempotent'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_finalize_picking') IS DISTINCT FROM 'd9d969d0c68ed3a79000714e1935da94' THEN RAISE EXCEPTION 'JANA source changed: jana_finalize_picking'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_finance_settle') IS DISTINCT FROM '5004e0c376123f48a2f07558dc17e6c0' THEN RAISE EXCEPTION 'JANA source changed: jana_finance_settle'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_login') IS DISTINCT FROM 'e5bd4079a1fb3c72b4efea15dcd5777d' THEN RAISE EXCEPTION 'JANA source changed: jana_login'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_ops_transition') IS DISTINCT FROM '2163fd57f8523a1c4cddde5b1d66f0c9' THEN RAISE EXCEPTION 'JANA source changed: jana_ops_transition'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_picker_record_actual') IS DISTINCT FROM 'fe81fd3232c599d4d3b678b5c5ee3d1f' THEN RAISE EXCEPTION 'JANA source changed: jana_picker_record_actual'; END IF;
IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_public_catalog') IS DISTINCT FROM '3331c371b4cac099dfd63c77e6baeaa2' THEN RAISE EXCEPTION 'JANA source changed: jana_public_catalog'; END IF;
END $source_guard$;
-- JANA security and transaction corrections, supported by rollback-only regression fixtures.
CREATE OR REPLACE FUNCTION public.jana_login(p_email text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE u public.users; tok text; csrf text; nowms bigint; expms bigint; k text; rc int;
BEGIN
 p_email=lower(trim(coalesce(p_email,''))); nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 IF length(p_email)<3 OR length(p_email)>254 THEN RETURN jsonb_build_object('_error','invalid_credentials','status',401); END IF;
 k='login:'||encode(digest(p_email,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(k,0));
 INSERT INTO public.rate_windows(key,count,expires_at) VALUES(k,0,nowms+900000)
 ON CONFLICT(key) DO UPDATE SET count=CASE WHEN rate_windows.expires_at<=nowms THEN 0 ELSE rate_windows.count END,
 expires_at=CASE WHEN rate_windows.expires_at<=nowms THEN excluded.expires_at ELSE rate_windows.expires_at END;
 SELECT count INTO rc FROM public.rate_windows WHERE key=k FOR UPDATE;
 IF rc>=10 THEN RETURN jsonb_build_object('_error','too_many_attempts','status',429); END IF;
 SELECT * INTO u FROM public.users WHERE email=p_email AND active;
 IF p_password IS NULL OR length(p_password)=0 OR octet_length(p_password)>72 OR u.id IS NULL
    OR u.password_hash IS NULL OR crypt(p_password,u.password_hash) IS DISTINCT FROM u.password_hash THEN
  UPDATE public.rate_windows SET count=count+1 WHERE key=k;
  RETURN jsonb_build_object('_error','invalid_credentials','status',401);
 END IF;
 DELETE FROM public.rate_windows WHERE key=k;
 expms=nowms+2592000000; tok=encode(gen_random_bytes(32),'hex');csrf=encode(gen_random_bytes(24),'hex');
 INSERT INTO public.sessions(token_hash,user_id,csrf_hash,expires_at,created_at)
 VALUES(encode(digest(tok,'sha256'),'hex'),u.id,encode(digest(csrf,'sha256'),'hex'),expms,nowms);
 RETURN jsonb_build_object('token',tok,'csrf',csrf,'expires_at',expms,'user',jsonb_build_object('id',u.id,'email',u.email,'name',u.name,'role',u.role));
END $function$;
CREATE OR REPLACE FUNCTION public.jana_create_quote(p_token text, p_slot_id text, p_address_id text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
 u public.users; a public.addresses; s public.delivery_slots; z public.delivery_zones;
 qid text; nowms bigint; expms bigint; subtotal bigint; delivery_fee bigint; total bigint;
 lines jsonb; allocations jsonb='[]'::jsonb; rec record; lotrec record; need bigint; take bigint;
begin
 u=public.jana_auth_user(p_token);
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>40 then raise exception 'invalid_cart'; end if;
 select * into a from public.addresses where id=p_address_id and user_id=u.id; if a.id is null then raise exception 'invalid_address'; end if;
 begin perform a.latitude::numeric; perform a.longitude::numeric; exception when others then raise exception 'invalid_coordinates'; end;
 select * into s from public.delivery_slots where id=p_slot_id for update; if s.id is null or not s.active then raise exception 'slot_unavailable'; end if;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 if s.cutoff_at<=nowms or s.booked>=s.capacity then raise exception 'slot_unavailable'; end if;
 select * into z from public.delivery_zones where id=s.zone_id and active;
 if z.id is null then raise exception 'zone_unavailable'; end if;
 if z.geom is null or not st_covers(z.geom,st_setsrid(st_point(a.longitude::numeric,a.latitude::numeric),4326)) then raise exception 'outside_zone'; end if;
 with item as (
   select e->>'offering_id' oid, (e->>'qty')::int qty from jsonb_array_elements(p_items) e
 ), valid as (
   select i.oid,i.qty,o.* from item i join public.offerings o on o.id=i.oid and o.active where i.qty between 1 and 20
 )
 select coalesce(sum(price_halalas*qty),0)::bigint,
        coalesce(jsonb_agg(jsonb_build_object('line_id','ln-'||replace(gen_random_uuid()::text,'-',''),'offering_id',id,'family_id',family_id,'version',version,'kind',kind,'name',name,'sale_unit',sale_unit,'unit_price_halalas',price_halalas,'qty',qty,'line_total_halalas',price_halalas*qty,'components',components)),'[]'::jsonb)
 into subtotal,lines from valid;
 if jsonb_array_length(lines)<>jsonb_array_length(p_items) then raise exception 'invalid_cart'; end if;
 if subtotal<z.minimum_halalas then raise exception 'below_minimum'; end if;
 qid='q-'||replace(gen_random_uuid()::text,'-','');
 for rec in
   with item as (select e->>'offering_id' oid,(e->>'qty')::int qty from jsonb_array_elements(p_items)e),
   req as (select c->>'stock_id' stock_id,sum(((c->>'base_qty')::bigint)*i.qty)::bigint base_qty from item i join public.offerings o on o.id=i.oid cross join lateral json_array_elements(o.components)c group by c->>'stock_id')
   select * from req order by stock_id
 loop
   if not exists(select 1 from public.stock_items where id=rec.stock_id and active) then raise exception 'insufficient_stock'; end if;
   perform 1 from public.stock_balances where stock_id=rec.stock_id for update;
   if not found or (select on_hand_base-reserved_base from public.stock_balances where stock_id=rec.stock_id)<rec.base_qty then raise exception 'insufficient_stock'; end if;
   need=rec.base_qty;
   for lotrec in select id,(on_hand_base-reserved_base) avail from public.inventory_lots where stock_id=rec.stock_id and inspection_state='accepted' and expires_at>s.ends_at and on_hand_base>reserved_base order by expires_at,id for update loop
     exit when need<=0; take=least(need,lotrec.avail); update public.inventory_lots set reserved_base=reserved_base+take where id=lotrec.id; allocations=allocations||jsonb_build_array(jsonb_build_object('stock_id',rec.stock_id,'lot_id',lotrec.id,'base_qty',take)); need=need-take; insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),rec.stock_id,lotrec.id,0,take,'quote_reserved',qid,u.id,nowms);
   end loop;
   if need>0 then raise exception 'insufficient_lot_stock'; end if;
   update public.stock_balances set reserved_base=reserved_base+rec.base_qty where stock_id=rec.stock_id;
 end loop;
 update public.delivery_slots set booked=booked+1 where id=s.id;
 delivery_fee=z.fee_halalas; total=subtotal+delivery_fee; expms=least(nowms+900000,s.cutoff_at);
 insert into public.quotes(id,user_id,slot_id,coupon_id,snapshot,state,expires_at,created_at)
 values(qid,u.id,s.id,null,jsonb_build_object('lines',lines,'allocations',allocations,'subtotal_halalas',subtotal,'delivery_fee_halalas',delivery_fee,'total_halalas',total,'address',to_jsonb(a),'slot',jsonb_build_object('id',s.id,'starts_at',s.starts_at,'ends_at',s.ends_at,'zone_id',z.id,'zone_name',z.name)),'active',expms,nowms);
 return jsonb_build_object('id',qid,'state','active','expires_at',expms,'subtotal_halalas',subtotal,'delivery_fee_halalas',delivery_fee,'total_halalas',total,'lines',lines,'slot',jsonb_build_object('id',s.id,'starts_at',s.starts_at,'ends_at',s.ends_at,'zone_name',z.name));
end$function$;
CREATE OR REPLACE FUNCTION public.jana_create_quote_idempotent(p_token text, p_idem_key text, p_slot_id text, p_address_id text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  u public.users;
  scope_key text;
  req_hash text;
  prior public.idempotency_records%rowtype;
  result jsonb;
  nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
  u=public.jana_auth_user(p_token);
  p_idem_key=trim(coalesce(p_idem_key,''));
  IF length(p_idem_key)<8 OR length(p_idem_key)>128 THEN RAISE EXCEPTION 'invalid_idempotency_key'; END IF;
  scope_key='quote:'||u.id||':'||p_idem_key;
  req_hash=encode(digest(jsonb_build_object('slot_id',p_slot_id,'address_id',p_address_id,'items',p_items)::text,'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
  SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
  IF prior.scope IS NOT NULL THEN
    IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict'; END IF;
    RETURN prior.response::jsonb;
  END IF;
  result=public.jana_create_quote(p_token,p_slot_id,p_address_id,p_items);
  INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
  VALUES(scope_key,u.id,p_idem_key,req_hash,result::json,nowms);
  RETURN result;
END$function$;
CREATE OR REPLACE FUNCTION public.jana_public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
with b as (
  select l.stock_id, sum(l.on_hand_base-l.reserved_base)::bigint available_base from public.inventory_lots l join public.stock_items s on s.id=l.stock_id and s.active where l.inspection_state='accepted' and l.expires_at>(extract(epoch from clock_timestamp())*1000)::bigint group by l.stock_id
), o as (
  select x.*, coalesce((
    select min(floor(coalesce(b.available_base,0)::numeric/greatest((c->>'base_qty')::numeric,1)))
    from json_array_elements(x.components) c left join b on b.stock_id=c->>'stock_id'
  ),0)::bigint available_units
  from public.offerings x where x.active
)
select coalesce(jsonb_agg(jsonb_build_object('id',id,'family_id',family_id,'version',version,'kind',kind,'name',name,'description',description,'category',category,'size_label',size_label,'emoji',emoji,'image_url',image_url,'sale_unit',sale_unit,'price_halalas',price_halalas,'components',components,'available_units',available_units) order by created_at),'[]'::jsonb) from o$function$;
CREATE OR REPLACE FUNCTION public.jana_confirm_order(p_token text, p_quote_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare u public.users; q public.quotes; existing public.orders; oid text; ono text; code text; nowms bigint; total bigint;
begin
 u=public.jana_auth_user(p_token);
 select * into q from public.quotes where id=p_quote_id and user_id=u.id for update;
 select * into existing from public.orders where quote_id=p_quote_id and user_id=u.id limit 1;
 if existing.id is not null then return jsonb_build_object('id',existing.id,'number',existing.number,'total_halalas',existing.total_halalas,'status',existing.status,'payment_state',existing.payment_state,'fulfillment_state',existing.fulfillment_state,'delivery_state',existing.delivery_state,'idempotent_replay',true); end if;
 nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 if q.id is null then raise exception 'quote_not_found'; end if; if q.state<>'active' or q.expires_at<=nowms then raise exception 'quote_expired'; end if;
 total=(q.snapshot->>'total_halalas')::bigint; oid='ord-'||replace(gen_random_uuid()::text,'-',''); ono='JN-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)); code=lpad(((('x'||encode(gen_random_bytes(4),'hex'))::bit(32)::bigint)%1000000)::text,6,'0');
 insert into public.orders(id,number,quote_id,user_id,slot_id,status,payment_state,fulfillment_state,delivery_state,snapshot,original_snapshot,total_halalas,collected_halalas,refunded_halalas,cash_state,picker_id,courier_id,code_cipher,code_hash,code_attempts,code_expires_at,created_at)
 values(oid,ono,q.id,u.id,q.slot_id,'active','awaiting_collection','queued','unassigned',q.snapshot,q.snapshot,total,0,0,'uncollected',null,null,null,encode(digest(code,'sha256'),'hex'),0,nowms+172800000,nowms);
 update public.quotes set state='converted' where id=q.id;
 insert into public.order_events(id,order_id,actor_id,event,reason,states,created_at) values('evt-'||replace(gen_random_uuid()::text,'-',''),oid,u.id,'order_created','customer_confirmed',jsonb_build_object('status','active','payment_state','awaiting_collection','fulfillment_state','queued','delivery_state','unassigned'),nowms);
 insert into public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) values('ntf-'||replace(gen_random_uuid()::text,'-',''),u.id,'order-created-'||oid,'تم تأكيد طلبك','رقم الطلب '||ono,oid,false,nowms);
 return jsonb_build_object('id',oid,'number',ono,'total_halalas',total,'status','active','payment_state','awaiting_collection','fulfillment_state','queued','delivery_state','unassigned','delivery_code',code,'idempotent_replay',false);
end$function$;
CREATE OR REPLACE FUNCTION public.jana_cancel_quote(p_token text,p_quote_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE u public.users;q public.quotes;a jsonb;rec record;nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);
 SELECT * INTO q FROM public.quotes WHERE id=p_quote_id AND user_id=u.id FOR UPDATE;
 IF q.id IS NULL THEN RAISE EXCEPTION 'quote_not_found'; END IF;
 IF q.state='active' THEN
  PERFORM 1 FROM public.delivery_slots WHERE id=q.slot_id FOR UPDATE;
  PERFORM 1 FROM public.stock_balances WHERE stock_id IN (SELECT value->>'stock_id' FROM jsonb_array_elements(coalesce(q.snapshot::jsonb->'allocations','[]'::jsonb))) ORDER BY stock_id FOR UPDATE;
  FOR a IN SELECT value FROM jsonb_array_elements(coalesce(q.snapshot::jsonb->'allocations','[]'::jsonb)) ORDER BY value->>'lot_id' LOOP
   UPDATE public.inventory_lots SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE id=a->>'lot_id' AND reserved_base>=(a->>'base_qty')::bigint;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   UPDATE public.stock_balances SET reserved_base=reserved_base-(a->>'base_qty')::bigint WHERE stock_id=a->>'stock_id' AND reserved_base>=(a->>'base_qty')::bigint;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
   VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),a->>'stock_id',a->>'lot_id',0,-(a->>'base_qty')::bigint,'quote_released',q.id,u.id,nowms);
  END LOOP;
  UPDATE public.delivery_slots SET booked=booked-1 WHERE id=q.slot_id AND booked>0;
  IF NOT FOUND THEN RAISE EXCEPTION 'slot_allocation_invalid'; END IF;
  UPDATE public.quotes SET state='cancelled' WHERE id=q.id;
 END IF;
 RETURN jsonb_build_object('id',q.id,'state',(SELECT state FROM public.quotes WHERE id=q.id));
END $function$;
CREATE OR REPLACE FUNCTION public.jana_picker_record_actual(p_token text, p_order_id text, p_line_id text, p_actual_base bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE uid varchar; r varchar; o public.orders; lines jsonb; line jsonb; newlines jsonb='[]'::jsonb; comp jsonb; planned bigint; old_total bigint; new_total bigint; subtotal bigint:=0; delivery bigint; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint; found boolean:=false;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF r='picker' AND o.picker_id IS DISTINCT FROM uid THEN RAISE EXCEPTION 'order_not_assigned'; END IF;
 IF o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 lines=o.snapshot->'lines';
 FOR line IN SELECT value FROM jsonb_array_elements(lines) LOOP
   IF line->>'line_id'=p_line_id THEN
     found=true;
     IF jsonb_array_length((line->'components')::jsonb)<>1 THEN RAISE EXCEPTION 'actual_weight_not_supported'; END IF;
     comp=(line->'components')->0;
     planned=((comp->>'base_qty')::bigint)*((line->>'qty')::bigint);
     IF p_actual_base<=0 OR p_actual_base>planned THEN RAISE EXCEPTION 'invalid_actual_weight'; END IF;
     old_total=(line->>'unit_price_halalas')::bigint*(line->>'qty')::bigint;
     new_total=greatest(1,round(old_total::numeric*p_actual_base::numeric/planned::numeric)::bigint);
     line=jsonb_set(line,'{actual_base_qty}',to_jsonb(p_actual_base),true);
     line=jsonb_set(line,'{line_total_halalas}',to_jsonb(new_total),true);
     line=jsonb_set(line,'{actual_recorded_at}',to_jsonb(nowms),true);
   END IF;
   subtotal=subtotal+COALESCE((line->>'line_total_halalas')::bigint,0);
   newlines=newlines||jsonb_build_array(line);
 END LOOP;
 IF NOT found THEN RAISE EXCEPTION 'line_not_found'; END IF;
 delivery=COALESCE((o.snapshot->>'delivery_fee_halalas')::bigint,0);
 UPDATE public.orders SET snapshot=jsonb_set(jsonb_set(o.snapshot::jsonb,'{lines}',newlines,true),'{subtotal_halalas}',to_jsonb(subtotal),true), total_halalas=subtotal+delivery WHERE id=o.id;
 UPDATE public.orders SET snapshot=jsonb_set(snapshot::jsonb,'{total_halalas}',to_jsonb(total_halalas),true) WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'actual_weight_recorded',p_line_id,jsonb_build_object('actual_base_qty',p_actual_base,'total_halalas',subtotal+delivery),nowms);
 RETURN (SELECT jsonb_build_object('id',id,'number',number,'total_halalas',total_halalas,'snapshot',snapshot) FROM public.orders WHERE id=o.id);
END$function$;
CREATE OR REPLACE FUNCTION public.jana_finalize_picking(p_token text, p_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE uid varchar; r varchar; o public.orders; alloc jsonb; rec record; need bigint; take bigint; used bigint; remain bigint; consumed jsonb:='{}'::jsonb; lotid text; stockid text; allocbase bigint; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','picker') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF r='picker' AND o.picker_id IS DISTINCT FROM uid THEN RAISE EXCEPTION 'order_not_assigned'; END IF;
 IF o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 PERFORM 1 FROM public.stock_balances WHERE stock_id IN (SELECT value->>'stock_id' FROM jsonb_array_elements(o.snapshot::jsonb->'allocations')) ORDER BY stock_id FOR UPDATE;
 FOR rec IN
   WITH ln AS (SELECT value l FROM jsonb_array_elements(o.snapshot::jsonb->'lines')),
   req AS (SELECT c->>'stock_id' stock_id,sum(CASE WHEN jsonb_array_length((l->'components')::jsonb)=1 AND l ? 'actual_base_qty' THEN (l->>'actual_base_qty')::bigint ELSE ((c->>'base_qty')::bigint)*((l->>'qty')::bigint) END)::bigint need FROM ln CROSS JOIN LATERAL jsonb_array_elements((l->'components')::jsonb)c GROUP BY c->>'stock_id') SELECT * FROM req
 LOOP
   need=rec.need;
   FOR alloc IN SELECT value FROM jsonb_array_elements(o.snapshot::jsonb->'allocations') WHERE value->>'stock_id'=rec.stock_id LOOP
     EXIT WHEN need<=0;
     lotid=alloc->>'lot_id'; stockid=alloc->>'stock_id'; allocbase=(alloc->>'base_qty')::bigint; used=COALESCE((consumed->>lotid)::bigint,0); take=least(need,allocbase-used);
     IF take>0 THEN
       UPDATE public.inventory_lots SET on_hand_base=on_hand_base-take,reserved_base=reserved_base-take WHERE id=lotid AND reserved_base>=take AND on_hand_base>=take AND inspection_state='accepted' AND expires_at>nowms;
       IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
       UPDATE public.stock_balances SET on_hand_base=on_hand_base-take,reserved_base=reserved_base-take WHERE stock_id=stockid AND reserved_base>=take AND on_hand_base>=take;
       IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
       consumed=jsonb_set(consumed,ARRAY[lotid],to_jsonb(used+take),true);
       INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),stockid,lotid,-take,-take,'order_picked',o.id,uid,nowms);
       need=need-take;
     END IF;
   END LOOP;
   IF need>0 THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
 END LOOP;
 FOR alloc IN SELECT value FROM jsonb_array_elements(o.snapshot::jsonb->'allocations') LOOP
   lotid=alloc->>'lot_id'; stockid=alloc->>'stock_id'; allocbase=(alloc->>'base_qty')::bigint; used=COALESCE((consumed->>lotid)::bigint,0); remain=GREATEST(allocbase-used,0);
   IF remain>0 THEN
     UPDATE public.inventory_lots SET reserved_base=reserved_base-remain WHERE id=lotid AND reserved_base>=remain;
     IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
     UPDATE public.stock_balances SET reserved_base=reserved_base-remain WHERE stock_id=stockid AND reserved_base>=remain;
     IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
     INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),stockid,lotid,0,-remain,'order_reservation_release',o.id,uid,nowms);
   END IF;
 END LOOP;
 UPDATE public.orders SET fulfillment_state='ready',picker_id=COALESCE(picker_id,uid) WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'ready','picking_finalized',jsonb_build_object('fulfillment_state','ready','total_halalas',(SELECT total_halalas FROM public.orders WHERE id=o.id)),nowms);
 RETURN (SELECT jsonb_build_object('id',id,'number',number,'fulfillment_state',fulfillment_state,'delivery_state',delivery_state,'total_halalas',total_halalas) FROM public.orders WHERE id=o.id);
END$function$;
CREATE OR REPLACE FUNCTION public.jana_ops_transition(p_token text, p_order_id text, p_action text, p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  uid varchar; r varchar; o orders%rowtype;
  nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
  action text := lower(trim(coalesce(p_action,'')));
  amount bigint;
BEGIN
  SELECT s.user_id,u.role INTO uid,r
  FROM sessions s JOIN users u ON u.id=s.user_id
  WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex')
    AND s.expires_at>nowms AND u.active=true LIMIT 1;
  IF uid IS NULL OR r NOT IN ('admin','picker','courier') THEN RAISE EXCEPTION 'unauthorized'; END IF;

  IF action IN ('claim','start') THEN action='start_picking'; END IF;
  IF action='dispatch' THEN action='out_for_delivery'; END IF;
  IF action='deliver' THEN action='delivered'; END IF;
  IF action='fail' THEN action='delivery_failed'; END IF;

  SELECT * INTO o FROM orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;

  IF r='picker' AND o.picker_id IS NOT NULL AND o.picker_id<>uid THEN RAISE EXCEPTION 'order_not_assigned'; END IF;
  IF r='courier' AND o.courier_id IS NOT NULL AND o.courier_id<>uid THEN RAISE EXCEPTION 'order_not_assigned'; END IF;
  IF r='courier' AND action IN ('delivered','delivery_failed','collect') AND o.courier_id IS DISTINCT FROM uid THEN RAISE EXCEPTION 'order_not_assigned'; END IF;
  IF action='start_picking' THEN
    IF r NOT IN ('admin','picker') OR o.fulfillment_state<>'queued' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET picker_id=COALESCE(picker_id,uid), fulfillment_state='picking' WHERE id=o.id;

  ELSIF action='ready' THEN
    IF r NOT IN ('admin','picker') OR o.fulfillment_state<>'picking' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    RETURN public.jana_finalize_picking(p_token,p_order_id);

  ELSIF action='assign_courier' THEN
    IF r<>'admin' OR o.fulfillment_state<>'ready' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET delivery_state='assigned' WHERE id=o.id;

  ELSIF action='out_for_delivery' THEN
    IF r NOT IN ('admin','courier') OR o.fulfillment_state<>'ready' OR o.delivery_state NOT IN ('assigned','unassigned','failed') THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET courier_id=CASE WHEN r='courier' THEN uid ELSE courier_id END, delivery_state='out_for_delivery' WHERE id=o.id;

  ELSIF action='delivered' THEN
    IF r NOT IN ('admin','courier') OR o.delivery_state<>'out_for_delivery' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    IF o.code_attempts>=5 THEN RETURN jsonb_build_object('_error','delivery_code_locked','status',429); END IF;
    IF o.code_hash IS NULL OR p_code IS NULL OR o.code_expires_at IS NULL OR o.code_expires_at<nowms OR encode(digest(COALESCE(p_code,''),'sha256'),'hex')<>o.code_hash THEN
      UPDATE orders SET code_attempts=code_attempts+1 WHERE id=o.id;
      RETURN jsonb_build_object('_error','invalid_delivery_code','status',409);
    END IF;
    UPDATE orders SET courier_id=COALESCE(courier_id,CASE WHEN r='courier' THEN uid ELSE courier_id END), delivery_state='delivered', status='completed' WHERE id=o.id;

  ELSIF action='delivery_failed' THEN
    IF length(trim(coalesce(p_code,'')))<3 THEN RAISE EXCEPTION 'delivery_failure_reason_required'; END IF;
    IF r NOT IN ('admin','courier') OR o.delivery_state<>'out_for_delivery' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    UPDATE orders SET courier_id=COALESCE(courier_id,CASE WHEN r='courier' THEN uid ELSE courier_id END), delivery_state='failed' WHERE id=o.id;

  ELSIF action='collect' THEN
    IF r NOT IN ('admin','courier') OR o.delivery_state<>'delivered' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
    IF o.payment_state<>'awaiting_collection' OR o.collected_halalas<>0 THEN RAISE EXCEPTION 'already_collected'; END IF;
    BEGIN amount := p_code::bigint; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'invalid_collection_amount'; END;
    IF amount<>o.total_halalas THEN RAISE EXCEPTION 'invalid_collection_amount'; END IF;
    UPDATE orders SET payment_state='collected', collected_halalas=amount, cash_state='with_courier' WHERE id=o.id;

  ELSE
    RAISE EXCEPTION 'invalid_action';
  END IF;

  INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at)
  VALUES ('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,action,CASE WHEN action='delivery_failed' THEN left(trim(p_code),1000) ELSE '' END,jsonb_build_object('role',r),nowms);

  RETURN (SELECT jsonb_build_object('id',id,'number',number,'status',status,'fulfillment_state',fulfillment_state,'delivery_state',delivery_state,'payment_state',payment_state,'cash_state',cash_state,'collected_halalas',collected_halalas,'total_halalas',total_halalas) FROM orders WHERE id=o.id);
END$function$;
CREATE OR REPLACE FUNCTION public.jana_admin_refund(p_token text, p_order_id text, p_amount_halalas bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE uid varchar; r varchar; o public.orders; rid text; nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM public.sessions s JOIN public.users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','finance','support') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE; IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'refund_reason_required'; END IF;
 IF p_amount_halalas IS NULL OR p_amount_halalas<=0 OR p_amount_halalas>(o.collected_halalas-o.refunded_halalas) THEN RAISE EXCEPTION 'invalid_refund_amount'; END IF;
 rid='ref-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.refunds(id,order_id,component_id,amount_halalas,reason,state,requested_by,approved_by,reference,created_at) VALUES(rid,o.id,'order',p_amount_halalas,trim(p_reason),'completed',uid,uid,rid,nowms);
 UPDATE public.orders SET refunded_halalas=refunded_halalas+p_amount_halalas,payment_state=CASE WHEN refunded_halalas+p_amount_halalas=collected_halalas THEN 'refunded' ELSE 'partially_refunded' END WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'refund_completed',coalesce(p_reason,''),jsonb_build_object('refund_halalas',p_amount_halalas),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),uid,'refund_completed',o.id,jsonb_build_object('amount_halalas',p_amount_halalas,'reason',coalesce(p_reason,'')),nowms);
 RETURN jsonb_build_object('refund_id',rid,'order_id',o.id,'amount_halalas',p_amount_halalas,'refunded_total_halalas',o.refunded_halalas+p_amount_halalas);
END$function$;
CREATE OR REPLACE FUNCTION public.jana_finance_settle(p_token text, p_order_id text, p_reference text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE uid varchar; r varchar; o orders%rowtype; nowms bigint := (extract(epoch from now())*1000)::bigint;
BEGIN
 SELECT s.user_id,u.role INTO uid,r FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=encode(digest(p_token,'sha256'),'hex') AND s.expires_at>nowms AND u.active=true LIMIT 1;
 IF uid IS NULL OR r NOT IN ('admin','finance') THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF length(trim(coalesce(p_reference,'')))<3 OR length(p_reference)>180 THEN RAISE EXCEPTION 'settlement_reference_required'; END IF;
 SELECT * INTO o FROM orders WHERE id=p_order_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.status<>'completed' OR o.payment_state NOT IN ('collected','partially_refunded','refunded') OR o.cash_state<>'with_courier' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 UPDATE orders SET cash_state='settled' WHERE id=o.id;
 INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,uid,'cash_settled',coalesce(p_reference,''),jsonb_build_object('cash_state','settled'),nowms);
 INSERT INTO audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),uid,'cash_settled',o.id,jsonb_build_object('reference',coalesce(p_reference,''),'amount_halalas',o.collected_halalas-o.refunded_halalas),nowms);
 RETURN jsonb_build_object('id',o.id,'number',o.number,'cash_state','settled','settled_halalas',o.collected_halalas-o.refunded_halalas);
END$function$;

DO $privs$ DECLARE r record; BEGIN FOR r IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname = ANY(ARRAY['jana_login','jana_create_quote','jana_create_quote_idempotent','jana_public_catalog','jana_confirm_order','jana_cancel_quote','jana_picker_record_actual','jana_finalize_picking','jana_ops_transition','jana_admin_refund','jana_finance_settle']) LOOP EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.sig); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',r.sig); END LOOP; END $privs$;
-- Real PostgreSQL audit. All fixture data is rolled back by a caught subtransaction.
-- Does not address existing customers, orders, or inventory. Outputs no tokens/PII.
DO $audit$
DECLARE
 p text:='ja'||substr(replace(gen_random_uuid()::text,'-',''),1,16);
 t text:=encode(extensions.gen_random_bytes(32),'hex');
 ct text:=encode(extensions.gen_random_bytes(32),'hex');
 atok text:=encode(extensions.gen_random_bytes(32),'hex');
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
 results jsonb:='[]'; q jsonb; q2 jsonb; o jsonb; r jsonb; n bigint; before_n bigint; ok boolean; detail text;
BEGIN
 BEGIN
  INSERT INTO public.users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES
   (p||'u',p||'u@example.invalid','Audit fixture',extensions.crypt('fixture-only-password!',extensions.gen_salt('bf',4)),'customer',false,true,nowms),
   (p||'a',p||'a@example.invalid','Audit fixture','unused','admin',false,true,nowms),
   (p||'c',p||'c@example.invalid','Audit fixture','unused','courier',false,true,nowms),
   (p||'d',p||'d@example.invalid','Audit fixture','unused','courier',false,true,nowms);
  INSERT INTO public.sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES
   (encode(extensions.digest(t,'sha256'),'hex'),p||'u','unused',nowms+60000,nowms),
   (encode(extensions.digest(ct,'sha256'),'hex'),p||'c','unused',nowms+60000,nowms),
   (encode(extensions.digest(atok,'sha256'),'hex'),p||'a','unused',nowms+60000,nowms);
  INSERT INTO public.delivery_zones(id,name,polygon,fee_halalas,minimum_halalas,active) VALUES
   (p||'z','Audit zone','{"type":"Polygon","coordinates":[[[42,16],[43,16],[43,17],[42,17],[42,16]]]}',0,0,true);
  INSERT INTO public.delivery_slots(id,zone_id,starts_at,ends_at,cutoff_at,capacity,booked,active)
   VALUES(p||'s',p||'z',nowms+7200000,nowms+10800000,nowms+3600000,20,0,true);
  INSERT INTO public.addresses(id,user_id,label,details,latitude,longitude,recipient_name,recipient_phone,is_default)
   VALUES(p||'addr',p||'u','Audit fixture','Audit fixture','16.5','42.5','Audit fixture','0500000000',false);
  INSERT INTO public.stock_items(id,name,base_unit,active) VALUES(p||'st','Audit stock','gram',true);
  INSERT INTO public.stock_balances(stock_id,on_hand_base,reserved_base) VALUES(p||'st',10000,0);
  INSERT INTO public.inventory_lots(id,stock_id,received_base,on_hand_base,reserved_base,total_cost_halalas,remaining_cost_halalas,expires_at,inspection_state,received_by,inspection_note,created_at)
   VALUES(p||'l',p||'st',10000,10000,0,1000,1000,nowms-60000,'accepted',p||'a','Audit fixture',nowms);
  INSERT INTO public.offerings(id,family_id,version,kind,name,description,category,size_label,emoji,image_url,sale_unit,price_halalas,components,active,created_at)
   VALUES(p||'off',p||'fam',1,'individual','Audit product','','fruit','1 kg','','','kg',2000,jsonb_build_array(jsonb_build_object('stock_id',p||'st','base_unit','gram','name','Audit stock','base_qty',1000)),true,nowms);

  BEGIN r=public.jana_login(p||'u@example.invalid',NULL); ok=NOT(r ? 'token'); detail=CASE WHEN ok THEN 'rejected' ELSE 'null password returned a session' END;
  EXCEPTION WHEN OTHERS THEN ok=true; detail=SQLSTATE; END;
  results=results||jsonb_build_array(jsonb_build_object('test','null_password_rejected','pass',ok,'detail',detail));

  BEGIN r=public.jana_login(p||'u@example.invalid','wrong-password'); EXCEPTION WHEN OTHERS THEN NULL; END;
  SELECT coalesce(sum(count),0) INTO n FROM public.rate_windows WHERE key='login:'||encode(extensions.digest(p||'u@example.invalid','sha256'),'hex');
  results=results||jsonb_build_array(jsonb_build_object('test','failed_login_counter_persists','pass',n>=1,'count',n));

  BEGIN q=public.jana_create_quote(t,p||'s',p||'addr',NULL); ok=false; detail='null cart accepted'; RAISE EXCEPTION USING ERRCODE='JA002';
  EXCEPTION WHEN SQLSTATE 'JA002' THEN NULL; WHEN OTHERS THEN ok=true; detail=SQLSTATE; END;
  results=results||jsonb_build_array(jsonb_build_object('test','null_cart_rejected','pass',ok,'detail',detail));

  BEGIN q=public.jana_create_quote(t,p||'s',p||'addr',jsonb_build_array(jsonb_build_object('offering_id',p||'off','qty',1))); ok=false; detail='expired lot reserved'; RAISE EXCEPTION USING ERRCODE='JA002';
  EXCEPTION WHEN SQLSTATE 'JA002' THEN NULL; WHEN OTHERS THEN ok=true; detail=SQLSTATE; END;
  results=results||jsonb_build_array(jsonb_build_object('test','expired_lot_rejected','pass',ok,'detail',detail));

  UPDATE public.inventory_lots SET expires_at=nowms+86400000 WHERE id=p||'l';
  q=public.jana_create_quote_idempotent(t,p||'key',p||'s',p||'addr',jsonb_build_array(jsonb_build_object('offering_id',p||'off','qty',1)));
  q2=public.jana_create_quote_idempotent(t,p||'key',p||'s',p||'addr',jsonb_build_array(jsonb_build_object('offering_id',p||'off','qty',1)));
  SELECT reserved_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';
  results=results||jsonb_build_array(jsonb_build_object('test','quote_retry_reserves_once','pass',q=q2 AND n=1000));
  SELECT count(*) INTO n FROM public.stock_movements WHERE stock_id=p||'st' AND reserved_delta=1000;
  results=results||jsonb_build_array(jsonb_build_object('test','reservation_has_movement','pass',n=1));

  BEGIN PERFORM public.jana_create_quote_idempotent(t,p||'key',p||'s',p||'addr',jsonb_build_array(jsonb_build_object('offering_id',p||'off','qty',2))); ok=false;
  EXCEPTION WHEN OTHERS THEN ok=SQLERRM='idempotency_conflict'; END;
  results=results||jsonb_build_array(jsonb_build_object('test','idempotency_body_conflict','pass',ok));

  BEGIN PERFORM public.jana_cancel_quote(t,q->>'id'); SELECT reserved_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';ok=n=0;detail='released';
  EXCEPTION WHEN OTHERS THEN ok=false;detail=SQLSTATE||':'||SQLERRM; END;
  results=results||jsonb_build_array(jsonb_build_object('test','cancel_quote_releases','pass',ok,'detail',detail));

  q=public.jana_create_quote(t,p||'s',p||'addr',jsonb_build_array(jsonb_build_object('offering_id',p||'off','qty',1)));
  o=public.jana_confirm_order(t,q->>'id');
  r=public.jana_confirm_order(t,q->>'id');
  results=results||jsonb_build_array(jsonb_build_object('test','confirm_retry_one_order','pass',r->>'id'=o->>'id'));

  UPDATE public.orders SET fulfillment_state='picking',picker_id=p||'a' WHERE id=o->>'id';
  BEGIN
   r=public.jana_picker_record_actual(atok,o->>'id',q->'lines'->0->>'line_id',800);
   r=public.jana_picker_record_actual(atok,o->>'id',q->'lines'->0->>'line_id',800);
   SELECT total_halalas INTO n FROM public.orders WHERE id=o->>'id';ok=n=1600;detail=n::text;
  EXCEPTION WHEN OTHERS THEN ok=false;detail=SQLSTATE||':'||SQLERRM; END;
  results=results||jsonb_build_array(jsonb_build_object('test','repeated_actual_weight_stable_price','pass',ok,'detail',detail));

  SELECT on_hand_base INTO before_n FROM public.stock_balances WHERE stock_id=p||'st';
  BEGIN r=public.jana_ops_transition(atok,o->>'id','ready',NULL);SELECT on_hand_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';ok=n<before_n; detail='stock consumption';
  EXCEPTION WHEN OTHERS THEN ok=false;detail=SQLSTATE||':'||SQLERRM; END;
  results=results||jsonb_build_array(jsonb_build_object('test','ready_consumes_stock','pass',ok,'detail',detail));

  UPDATE public.orders SET fulfillment_state='ready',delivery_state='out_for_delivery',courier_id=p||'c',code_hash=encode(extensions.digest('123456','sha256'),'hex'),code_expires_at=nowms+60000 WHERE id=o->>'id';
  BEGIN r=public.jana_ops_transition(ct,o->>'id','delivered','000000'); EXCEPTION WHEN OTHERS THEN NULL; END;
  SELECT code_attempts INTO n FROM public.orders WHERE id=o->>'id';
  results=results||jsonb_build_array(jsonb_build_object('test','wrong_delivery_code_counter_persists','pass',n=1,'count',n));

  UPDATE public.orders SET courier_id=p||'d' WHERE id=o->>'id';
  BEGIN r=public.jana_ops_transition(ct,o->>'id','delivery_failed','customer unavailable');ok=(r ? '_error');
  EXCEPTION WHEN OTHERS THEN ok=SQLERRM IN ('forbidden','order_not_assigned'); END;
  results=results||jsonb_build_array(jsonb_build_object('test','other_courier_cannot_change_order','pass',ok));

  UPDATE public.orders SET status='completed',delivery_state='delivered',payment_state='collected',cash_state='with_courier',courier_id=p||'c',collected_halalas=total_halalas WHERE id=o->>'id';
  BEGIN r=public.jana_admin_refund(atok,o->>'id',100,'Audit refund reason');ok=true;detail='refund recorded';
  EXCEPTION WHEN OTHERS THEN ok=false;detail=SQLSTATE||':'||SQLERRM; END;
  results=results||jsonb_build_array(jsonb_build_object('test','refund_records_required_actor_fields','pass',ok,'detail',detail));

  BEGIN r=public.jana_finance_settle(atok,o->>'id','');ok=false; RAISE EXCEPTION USING ERRCODE='JA002';
  EXCEPTION WHEN SQLSTATE 'JA002' THEN NULL; WHEN OTHERS THEN ok=true; END;
  results=results||jsonb_build_array(jsonb_build_object('test','settlement_reference_required','pass',ok));

  RAISE EXCEPTION USING ERRCODE='JA001',MESSAGE='rollback all audit fixtures';
 EXCEPTION WHEN SQLSTATE 'JA001' THEN NULL;
 END;
 IF EXISTS(SELECT 1 FROM public.users WHERE id=p||'u') THEN RAISE EXCEPTION 'audit fixture rollback failed'; END IF;
 PERFORM set_config('jana.audit_results',results::text,false);
END $audit$;
SELECT current_setting('jana.audit_results')::jsonb AS results;

DO $gate$ BEGIN IF EXISTS(SELECT 1 FROM jsonb_array_elements(current_setting('jana.audit_results')::jsonb) e WHERE e->>'pass' <> 'true') THEN RAISE EXCEPTION 'JANA regression failure: %',current_setting('jana.audit_results'); END IF; END $gate$;
