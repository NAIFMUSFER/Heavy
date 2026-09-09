-- Follow-up corrections from expanded real PostgreSQL regression tests.
CREATE OR REPLACE FUNCTION public.jana_change_password(p_token text, p_current text, p_new text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE u public.users; th text; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token); IF p_new IS NULL OR length(p_new)<12 OR length(p_new)>128 THEN RAISE EXCEPTION 'weak_password'; END IF;
 IF p_current IS NULL OR crypt(p_current,u.password_hash) IS DISTINCT FROM u.password_hash THEN RAISE EXCEPTION 'invalid_credentials'; END IF;
 UPDATE public.users SET password_hash=crypt(p_new,gen_salt('bf',12)) WHERE id=u.id; th=encode(digest(p_token,'sha256'),'hex'); DELETE FROM public.sessions WHERE user_id=u.id AND token_hash<>th;
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at) VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'password_changed',u.id,'{}'::jsonb,nowms);
 RETURN jsonb_build_object('ok',true,'other_sessions_revoked',true);
END$function$;
CREATE OR REPLACE FUNCTION public.jana_cancel_order(p_token text, p_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE u public.users; o public.orders; a jsonb; lotid text; stockid text; base bigint; nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token); SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.status<>'active' OR o.fulfillment_state<>'queued' OR o.delivery_state<>'unassigned' THEN RAISE EXCEPTION 'order_not_cancellable'; END IF;
 PERFORM 1 FROM public.delivery_slots WHERE id=o.slot_id FOR UPDATE;
 PERFORM 1 FROM public.stock_balances WHERE stock_id IN (SELECT value->>'stock_id' FROM jsonb_array_elements(o.snapshot::jsonb->'allocations')) ORDER BY stock_id FOR UPDATE;
 FOR a IN SELECT value FROM jsonb_array_elements(o.snapshot::jsonb->'allocations') LOOP
   lotid=a->>'lot_id'; stockid=a->>'stock_id'; base=(a->>'base_qty')::bigint;
   UPDATE public.inventory_lots SET reserved_base=reserved_base-base WHERE id=lotid AND reserved_base>=base;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   UPDATE public.stock_balances SET reserved_base=reserved_base-base WHERE stock_id=stockid AND reserved_base>=base;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
   VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),stockid,lotid,0,-base,'order_cancelled',o.id,u.id,nowms);
 END LOOP;
 UPDATE public.delivery_slots SET booked=GREATEST(booked-1,0) WHERE id=o.slot_id;
 UPDATE public.orders SET status='cancelled',payment_state='cancelled',fulfillment_state='cancelled',delivery_state='cancelled',code_hash=NULL,code_expires_at=NULL WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'cancelled','customer_request',jsonb_build_object('status','cancelled'),nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at) VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),u.id,'cancel-'||o.id,'تم إلغاء الطلب','تم إلغاء الطلب '||o.number,o.id,false,nowms) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('id',o.id,'number',o.number,'status','cancelled');
END$function$;
CREATE OR REPLACE FUNCTION public.jana_expire_quotes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare q record; a jsonb; rec record; n integer=0; nowms bigint=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
  for q in select id,slot_id,snapshot from public.quotes where state='active' and expires_at<=nowms for update skip locked loop
    perform 1 from public.delivery_slots where id=q.slot_id for update;
    perform 1 from public.stock_balances where stock_id in (select value->>'stock_id' from jsonb_array_elements(coalesce(q.snapshot::jsonb->'allocations','[]'::jsonb))) order by stock_id for update;
    for a in select value from jsonb_array_elements(coalesce(q.snapshot::jsonb->'allocations','[]'::jsonb)) loop
      update public.inventory_lots set reserved_base=greatest(0,reserved_base-(a->>'base_qty')::bigint) where id=a->>'lot_id';
      insert into public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) values('mov-'||replace(gen_random_uuid()::text,'-',''),a->>'stock_id',a->>'lot_id',0,-(a->>'base_qty')::bigint,'quote_expired',q.id,null,nowms);
    end loop;
    for rec in select a->>'stock_id' stock_id,sum((a->>'base_qty')::bigint)::bigint qty from jsonb_array_elements(coalesce(q.snapshot::jsonb->'allocations','[]'::jsonb)) a group by a->>'stock_id' loop
      update public.stock_balances set reserved_base=greatest(0,reserved_base-rec.qty) where stock_id=rec.stock_id;
    end loop;
    update public.delivery_slots set booked=greatest(0,booked-1) where id=q.slot_id;
    update public.quotes set state='expired' where id=q.id; n=n+1;
  end loop;
  return n;
end$function$;
CREATE OR REPLACE FUNCTION public.jana_rotate_delivery_code(p_token text, p_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE u public.users; o public.orders; code text; nowms bigint;
BEGIN
 u=public.jana_auth_user(p_token); nowms=(extract(epoch from clock_timestamp())*1000)::bigint;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id AND user_id=u.id FOR UPDATE;
 IF o.id IS NULL THEN RAISE EXCEPTION 'order_not_found'; END IF;
 IF o.status<>'active' OR o.delivery_state='delivered' THEN RAISE EXCEPTION 'invalid_transition'; END IF;
 code=lpad(((('x'||encode(gen_random_bytes(4),'hex'))::bit(32)::bigint)%1000000)::text,6,'0');
 UPDATE public.orders SET code_hash=encode(digest(code,'sha256'),'hex'),code_attempts=0,code_expires_at=nowms+172800000 WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'delivery_code_rotated','customer_request',jsonb_build_object('delivery_state',o.delivery_state),nowms);
 RETURN jsonb_build_object('order_id',o.id,'delivery_code',code,'expires_at',nowms+172800000);
END$function$;
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
 IF p_password IS NULL OR length(p_password)=0 OR length(p_password)>128 OR u.id IS NULL
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

-- Keep standard PostGIS definitions and RLS untouched; restrict client API privileges only.
REVOKE SELECT ON public.spatial_ref_sys FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.spatial_ref_sys TO service_role;
REVOKE EXECUTE ON FUNCTION public.st_estimatedextent(text,text),public.st_estimatedextent(text,text,text),public.st_estimatedextent(text,text,text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.st_estimatedextent(text,text),public.st_estimatedextent(text,text,text),public.st_estimatedextent(text,text,text,boolean) TO service_role;
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


  BEGIN PERFORM public.jana_change_password(t,NULL,'new-fixture-password!');ok=false;RAISE EXCEPTION USING ERRCODE='JA002';
  EXCEPTION WHEN SQLSTATE 'JA002' THEN NULL;WHEN OTHERS THEN ok=SQLERRM='invalid_credentials'; END;
  results=results||jsonb_build_array(jsonb_build_object('test','password_change_requires_current_password','pass',ok));

  BEGIN UPDATE public.stock_balances SET on_hand_base=-1 WHERE stock_id=p||'st';ok=false;
  EXCEPTION WHEN check_violation THEN ok=true; END;
  results=results||jsonb_build_array(jsonb_build_object('test','negative_stock_constraint','pass',ok));
  BEGIN UPDATE public.stock_balances SET reserved_base=on_hand_base+1 WHERE stock_id=p||'st';ok=false;
  EXCEPTION WHEN check_violation THEN ok=true; END;
  results=results||jsonb_build_array(jsonb_build_object('test','reserved_exceeds_on_hand_constraint','pass',ok));
  BEGIN UPDATE public.delivery_slots SET booked=capacity+1 WHERE id=p||'s';ok=false;
  EXCEPTION WHEN check_violation THEN ok=true; END;
  results=results||jsonb_build_array(jsonb_build_object('test','slot_capacity_constraint','pass',ok));
  SELECT reserved_base INTO before_n FROM public.stock_balances WHERE stock_id=p||'st';
  BEGIN PERFORM public.jana_create_quote(t,p||'s',p||'addr',jsonb_build_array(jsonb_build_object('offering_id',p||'off','qty',20)));ok=false;
  EXCEPTION WHEN OTHERS THEN ok=SQLERRM='insufficient_stock'; END;
  SELECT reserved_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';
  results=results||jsonb_build_array(jsonb_build_object('test','insufficient_stock_rolls_back','pass',ok AND n=before_n));

  SELECT on_hand_base INTO before_n FROM public.stock_balances WHERE stock_id=p||'st';
  r=public.jana_inventory_receive_lot(atok,p||'st',NULL,500,NULL,nowms+86400000);
  SELECT on_hand_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';
  results=results||jsonb_build_array(jsonb_build_object('test','pending_inspection_unavailable','pass',n=before_n));
  r=public.jana_inventory_inspect_lot(atok,r->>'id','accepted','Audit acceptance');
  SELECT on_hand_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';
  results=results||jsonb_build_array(jsonb_build_object('test','accepted_lot_adds_once','pass',n=before_n+500));
  BEGIN PERFORM public.jana_inventory_inspect_lot(atok,r->>'id','accepted','Audit duplicate acceptance');ok=false;
  EXCEPTION WHEN OTHERS THEN ok=SQLERRM='already_inspected'; END;
  SELECT on_hand_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';
  results=results||jsonb_build_array(jsonb_build_object('test','duplicate_inspection_rejected','pass',ok AND n=before_n+500));
  before_n=n;
  r=public.jana_inventory_receive_lot(atok,p||'st',NULL,500,NULL,nowms+86400000);
  PERFORM public.jana_inventory_inspect_lot(atok,r->>'id','rejected','Audit rejection');
  SELECT on_hand_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';
  results=results||jsonb_build_array(jsonb_build_object('test','rejected_lot_never_available','pass',n=before_n));

  q=public.jana_create_quote(t,p||'s',p||'addr',jsonb_build_array(jsonb_build_object('offering_id',p||'off','qty',1)));
  o=public.jana_confirm_order(t,q->>'id');
  SELECT reserved_base INTO before_n FROM public.stock_balances WHERE stock_id=p||'st';
  BEGIN r=public.jana_cancel_order(t,o->>'id');SELECT reserved_base INTO n FROM public.stock_balances WHERE stock_id=p||'st';ok=n=before_n-1000;detail='released';
  EXCEPTION WHEN OTHERS THEN ok=false;detail=SQLSTATE||':'||SQLERRM;END;
  results=results||jsonb_build_array(jsonb_build_object('test','cancel_order_releases_resources','pass',ok,'detail',detail));

  BEGIN PERFORM coalesce(('{}'::json)->'allocations','[]'::jsonb);ok=true;
  EXCEPTION WHEN OTHERS THEN ok=false;detail=SQLSTATE;END;
  -- This type probe documents why the old expiry worker needs an explicit cast.
  results=results||jsonb_build_array(jsonb_build_object('test','json_to_jsonb_requires_explicit_cast','pass',NOT ok,'detail',detail));

  RAISE EXCEPTION USING ERRCODE='JA001',MESSAGE='rollback all audit fixtures';
 EXCEPTION WHEN SQLSTATE 'JA001' THEN NULL;
 END;
 IF EXISTS(SELECT 1 FROM public.users WHERE id=p||'u') THEN RAISE EXCEPTION 'audit fixture rollback failed'; END IF;
 PERFORM set_config('jana.audit_results',results::text,false);
END $audit$;
SELECT current_setting('jana.audit_results')::jsonb AS results;

DO $gate$ BEGIN IF EXISTS(SELECT 1 FROM jsonb_array_elements(current_setting('jana.audit_results')::jsonb) e WHERE e->>'pass' <> 'true') THEN RAISE EXCEPTION 'JANA regression failure: %',current_setting('jana.audit_results'); END IF; END $gate$;
