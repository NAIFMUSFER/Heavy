-- Browser acceptance found the inventory supplier form called an admin-only RPC.
-- Keep server authorization and add persisted retry handling to supplier creation.
create or replace function public.jana_admin_create_supplier(p_token text,p_name text,p_phone text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $$
declare u public.users; sid text; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin u=public.jana_auth_user(p_token); if u.role not in ('admin','inventory') then raise exception 'forbidden'; end if;
 p_name=trim(coalesce(p_name,'')); p_phone=trim(coalesce(p_phone,'')); if length(p_name)<2 or length(p_name)>120 then raise exception 'invalid_supplier'; end if; if length(p_phone)>30 then raise exception 'invalid_supplier'; end if;
 sid='sup-'||replace(gen_random_uuid()::text,'-',''); insert into public.suppliers(id,name,phone,active) values(sid,p_name,p_phone,true);
 insert into public.audit_log(id,actor_id,action,entity_id,detail,created_at) values('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'supplier_created',sid,jsonb_build_object('name',p_name),nowms);
 return jsonb_build_object('id',sid,'name',p_name,'phone',p_phone,'active',true); end$$;


CREATE OR REPLACE FUNCTION public.jana_inventory_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;prior public.idempotency_records;scope_key text;req_hash text;r jsonb;
BEGIN
 u=public.jana_auth_user(p_token);PERFORM 1 FROM public.users WHERE id=u.id FOR SHARE;u=public.jana_auth_user(p_token);IF u.role NOT IN ('admin','inventory') OR (p_operation='count.decide' AND u.role<>'admin') THEN RAISE EXCEPTION 'forbidden';END IF;
 IF p_operation IS NULL OR p_operation NOT IN ('count.start','count.submit','count.decide','count.cancel','lot.receive','lot.inspect','lot.adjust','stock.update','supplier.update','supplier.create') THEN RAISE EXCEPTION 'invalid_operation';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='inventory:'||u.id||':'||p_idem_key;req_hash=encode(digest(jsonb_build_object('operation',p_operation,'payload',p_payload)::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;RETURN prior.response::jsonb;END IF;
 CASE p_operation
 WHEN 'supplier.create' THEN r=public.jana_admin_create_supplier(p_token,p_payload->>'name',p_payload->>'phone');
 WHEN 'count.start' THEN r=public.jana_count_start(p_token,p_payload->>'location',p_payload->'lot_ids');
 WHEN 'count.submit' THEN r=public.jana_count_submit(p_token,p_payload->>'session_id',p_payload->'counts',p_payload->>'note');
 WHEN 'count.decide' THEN
  IF jsonb_typeof(p_payload->'approve') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'count_validation';END IF;
  r=public.jana_count_decide(p_token,p_payload->>'count_id',(p_payload->>'approve')::boolean,p_payload->>'reason');
 WHEN 'count.cancel' THEN r=public.jana_count_cancel(p_token,p_payload->>'session_id',p_payload->>'reason');
 WHEN 'lot.receive' THEN r=public.jana_inventory_receive_lot(p_token,p_payload->>'stock_id',nullif(p_payload->>'supplier_id',''),(p_payload->>'received_base')::bigint,(p_payload->>'total_cost_halalas')::bigint,(p_payload->>'expires_at')::bigint);
  IF length(coalesce(p_payload->>'receipt_reference',''))>180 THEN RAISE EXCEPTION 'receipt_validation';END IF;
  UPDATE public.inventory_lots SET receipt_reference=trim(coalesce(p_payload->>'receipt_reference','')) WHERE id=r->>'id';
 WHEN 'lot.inspect' THEN r=public.jana_inventory_inspect_lot(p_token,p_payload->>'lot_id',p_payload->>'state',p_payload->>'note');
 WHEN 'stock.update' THEN r=public.jana_update_stock(p_token,p_payload->>'stock_id',p_payload->'changes');
 WHEN 'supplier.update' THEN r=public.jana_update_supplier(p_token,p_payload->>'supplier_id',p_payload->'changes');
 WHEN 'lot.adjust' THEN r=public.jana_inventory_adjust_lot(p_token,p_payload->>'lot_id',(p_payload->>'new_on_hand')::bigint,p_payload->>'reason');
 END CASE;
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at) VALUES(scope_key,u.id,p_idem_key,req_hash,r,(extract(epoch from clock_timestamp())*1000)::bigint);
 RETURN r;
END$$;

REVOKE ALL ON FUNCTION public.jana_admin_create_supplier(text,text,text),public.jana_inventory_write(text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_create_supplier(text,text,text),public.jana_inventory_write(text,text,text,jsonb) TO service_role;
