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
