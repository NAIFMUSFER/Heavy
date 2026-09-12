-- Dormant phase-2 supplier-pickup admission primitives.
-- They reserve delivery capacity, never warehouse inventory. No Edge route calls
-- these functions until collection, shortage and handover are complete.
CREATE TABLE public.procurement_jobs (
 id varchar(36) PRIMARY KEY,
 order_id varchar(36) NOT NULL UNIQUE REFERENCES public.orders(id),
 assigned_to varchar(36) REFERENCES public.users(id),
 state varchar(24) NOT NULL DEFAULT 'unassigned'
  CHECK(state IN ('unassigned','assigned','collecting','awaiting_customer','ready','cancelled')),
 requested_lines jsonb NOT NULL CHECK(jsonb_typeof(requested_lines)='array' AND jsonb_array_length(requested_lines)>0),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 assigned_at bigint,
 created_at bigint NOT NULL,
 updated_at bigint NOT NULL
);
CREATE INDEX jana_procurement_assignee_state ON public.procurement_jobs(assigned_to,state,created_at DESC,id DESC);
ALTER TABLE public.procurement_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_jobs FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.procurement_jobs TO service_role;

CREATE FUNCTION public.jana_procurement_job_identity_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.id IS DISTINCT FROM OLD.id OR NEW.order_id IS DISTINCT FROM OLD.order_id
  OR NEW.requested_lines IS DISTINCT FROM OLD.requested_lines
  OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
  RAISE EXCEPTION 'procurement_identity_immutable';
 END IF;
 RETURN NEW;
END$$;
CREATE TRIGGER jana_procurement_job_identity_immutable
BEFORE UPDATE ON public.procurement_jobs FOR EACH ROW
EXECUTE FUNCTION public.jana_procurement_job_identity_guard();
REVOKE ALL ON FUNCTION public.jana_procurement_job_identity_guard() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.jana_supplier_pickup_quote_create(p_token text,p_slot_id text,p_address_id text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE
 u public.users;a public.addresses;s public.delivery_slots;z public.delivery_zones;
 storefront public.storefront_state;profile public.storefront_profiles;
 qid text;nowms bigint;expms bigint;subtotal bigint;delivery_fee bigint;total bigint;
 lines jsonb;terms jsonb;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 40 THEN RAISE EXCEPTION 'invalid_cart';END IF;
 SELECT * INTO storefront FROM public.storefront_state WHERE singleton FOR SHARE;
 IF NOT storefront.accepting_orders OR storefront.published_id IS NULL THEN RAISE EXCEPTION 'storefront_closed';END IF;
 SELECT * INTO profile FROM public.storefront_profiles WHERE id=storefront.published_id;
 IF profile.id IS NULL THEN RAISE EXCEPTION 'storefront_closed';END IF;
 SELECT * INTO a FROM public.addresses WHERE id=p_address_id AND user_id=u.id;
 IF a.id IS NULL THEN RAISE EXCEPTION 'invalid_address';END IF;
 BEGIN PERFORM a.latitude::numeric;PERFORM a.longitude::numeric;EXCEPTION WHEN others THEN RAISE EXCEPTION 'invalid_coordinates';END;
 SELECT * INTO s FROM public.delivery_slots WHERE id=p_slot_id FOR UPDATE;
 IF s.id IS NULL OR NOT s.active THEN RAISE EXCEPTION 'slot_unavailable';END IF;
 nowms=(extract(epoch FROM clock_timestamp())*1000)::bigint;
 IF s.cutoff_at<=nowms OR s.booked>=s.capacity THEN RAISE EXCEPTION 'slot_unavailable';END IF;
 SELECT * INTO z FROM public.delivery_zones WHERE id=s.zone_id AND active;
 IF z.id IS NULL THEN RAISE EXCEPTION 'zone_unavailable';END IF;
 IF z.geom IS NULL OR NOT st_covers(z.geom,st_setsrid(st_point(a.longitude::numeric,a.latitude::numeric),4326)) THEN RAISE EXCEPTION 'outside_zone';END IF;
 BEGIN
  WITH item AS (
   SELECT e->>'offering_id' oid,(e->>'qty')::integer qty,ord
   FROM jsonb_array_elements(p_items) WITH ORDINALITY x(e,ord)
  ),valid AS (
   SELECT i.ord,i.qty,o.*,pv.family_id product_family_id,pv.id product_version_id,m.sellable_key
   FROM item i JOIN public.offerings o ON o.id=i.oid AND o.active
   LEFT JOIN public.product_version_offerings m ON m.offering_id=o.id
   LEFT JOIN public.product_versions pv ON pv.id=m.version_id
   WHERE i.qty BETWEEN 1 AND 20
  )
  SELECT coalesce(sum(price_halalas*qty),0)::bigint,
   coalesce(jsonb_agg(jsonb_build_object(
    'line_id','ln-'||replace(gen_random_uuid()::text,'-',''),'offering_id',id,'family_id',family_id,
    'version',version,'kind',kind,'name',name,'size_label',size_label,'sale_unit',sale_unit,
    'unit_price_halalas',price_halalas,'qty',qty,'line_total_halalas',price_halalas*qty,
    'components',components,'product_family_id',product_family_id,'product_version_id',product_version_id,
    'sellable_key',sellable_key,'availability_status','to_be_purchased'
   )||public.jana_weight_terms(id,qty) ORDER BY ord),'[]'::jsonb)
  INTO subtotal,lines FROM valid;
 EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN RAISE EXCEPTION 'invalid_cart';
 END;
 IF jsonb_array_length(lines)<>jsonb_array_length(p_items) THEN RAISE EXCEPTION 'invalid_cart';END IF;
 IF subtotal<z.minimum_halalas THEN RAISE EXCEPTION 'below_minimum';END IF;
 qid='q-'||replace(gen_random_uuid()::text,'-','');
 delivery_fee=z.fee_halalas;total=subtotal+delivery_fee;expms=least(nowms+900000,s.cutoff_at);
 terms=jsonb_build_object('id',profile.id,'version',profile.version,'display_name',profile.profile->>'display_name',
  'legal_name',profile.profile->>'legal_name','registration_type',profile.profile->>'registration_type',
  'registration_number',profile.profile->>'registration_number','tax_status',profile.profile->>'tax_status');
 UPDATE public.delivery_slots SET booked=booked+1 WHERE id=s.id;
 INSERT INTO public.quotes(id,user_id,slot_id,coupon_id,snapshot,state,expires_at,created_at)
 VALUES(qid,u.id,s.id,NULL,jsonb_build_object(
  'fulfillment_model','supplier_pickup','inventory_reserved',false,'procurement_state','pending_assignment',
  'lines',lines,'allocations','[]'::jsonb,'subtotal_halalas',subtotal,'delivery_fee_halalas',delivery_fee,
  'total_halalas',total,'address',to_jsonb(a),'slot',jsonb_build_object('id',s.id,'starts_at',s.starts_at,
  'ends_at',s.ends_at,'zone_id',z.id,'zone_name',z.name),'store_profile',terms
 ),'active',expms,nowms);
 RETURN jsonb_build_object('id',qid,'state','active','expires_at',expms,'subtotal_halalas',subtotal,
  'delivery_fee_halalas',delivery_fee,'total_halalas',total,'lines',lines,
  'slot',jsonb_build_object('id',s.id,'starts_at',s.starts_at,'ends_at',s.ends_at,'zone_name',z.name),
  'store_profile',terms,'fulfillment_model','supplier_pickup','inventory_reserved',false,'order_flow_ready',false);
END$$;

CREATE FUNCTION public.jana_supplier_pickup_quote_idempotent(p_token text,p_idem_key text,p_slot_id text,p_address_id text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;scope_key text;req_hash text;prior public.idempotency_records;result jsonb;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));IF length(p_idem_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'invalid_idempotency_key';END IF;
 scope_key='supplier-pickup-quote:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('slot_id',p_slot_id,'address_id',p_address_id,'items',p_items)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 result=public.jana_supplier_pickup_quote_create(p_token,p_slot_id,p_address_id,p_items);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
END$$;

CREATE FUNCTION public.jana_supplier_pickup_order_confirm(p_token text,p_quote_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;q public.quotes;existing public.orders;job public.procurement_jobs;oid text;ono text;code text;nowms bigint;total bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'customer' THEN RAISE EXCEPTION 'forbidden';END IF;
 SELECT * INTO q FROM public.quotes WHERE id=p_quote_id AND user_id=u.id FOR UPDATE;
 SELECT * INTO existing FROM public.orders WHERE quote_id=p_quote_id AND user_id=u.id;
 IF existing.id IS NOT NULL THEN
  SELECT * INTO job FROM public.procurement_jobs WHERE order_id=existing.id;
  RETURN jsonb_build_object('id',existing.id,'number',existing.number,'total_halalas',existing.total_halalas,
   'status',existing.status,'payment_state',existing.payment_state,'fulfillment_state',existing.fulfillment_state,
   'delivery_state',existing.delivery_state,'procurement_job_id',job.id,'idempotent_replay',true);
 END IF;
 nowms=(extract(epoch FROM clock_timestamp())*1000)::bigint;
 IF q.id IS NULL THEN RAISE EXCEPTION 'quote_not_found';END IF;
 IF q.state<>'active' OR q.expires_at<=nowms THEN RAISE EXCEPTION 'quote_expired';END IF;
 IF q.snapshot::jsonb->>'fulfillment_model'<>'supplier_pickup' OR coalesce((q.snapshot::jsonb->>'inventory_reserved')::boolean,true) THEN RAISE EXCEPTION 'invalid_fulfillment_model';END IF;
 total=(q.snapshot->>'total_halalas')::bigint;oid='ord-'||replace(gen_random_uuid()::text,'-','');
 ono='JN-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
 code=lpad(((('x'||encode(gen_random_bytes(4),'hex'))::bit(32)::bigint)%1000000)::text,6,'0');
 INSERT INTO public.orders(id,number,quote_id,user_id,slot_id,status,payment_state,fulfillment_state,delivery_state,
  snapshot,original_snapshot,total_halalas,collected_halalas,refunded_halalas,cash_state,picker_id,courier_id,
  code_cipher,code_hash,code_attempts,code_expires_at,created_at)
 VALUES(oid,ono,q.id,u.id,q.slot_id,'active','awaiting_collection','queued','unassigned',q.snapshot,q.snapshot,total,
  0,0,'uncollected',NULL,NULL,NULL,encode(digest(code,'sha256'),'hex'),0,nowms+172800000,nowms);
 INSERT INTO public.procurement_jobs(id,order_id,requested_lines,created_at,updated_at)
 VALUES('prc-'||replace(gen_random_uuid()::text,'-',''),oid,q.snapshot::jsonb->'lines',nowms,nowms) RETURNING * INTO job;
 UPDATE public.quotes SET state='converted' WHERE id=q.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),oid,u.id,'supplier_pickup_order_created','customer_confirmed',
  jsonb_build_object('status','active','fulfillment_state','queued','procurement_state','unassigned','inventory_reserved',false),nowms);
 INSERT INTO public.notifications(id,user_id,dedupe_key,title,body,order_id,is_read,created_at)
 VALUES('ntf-'||replace(gen_random_uuid()::text,'-',''),u.id,'order-created-'||oid,'تم تأكيد طلبك','رقم الطلب '||ono,oid,false,nowms);
 RETURN jsonb_build_object('id',oid,'number',ono,'total_halalas',total,'status','active','payment_state','awaiting_collection',
  'fulfillment_state','queued','delivery_state','unassigned','delivery_code',code,'procurement_job_id',job.id,
  'inventory_reserved',false,'idempotent_replay',false);
END$$;

CREATE FUNCTION public.jana_procurement_job_assign(p_token text,p_idem_key text,p_order_id text,p_employee_id text,p_expected_revision bigint,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE u public.users;employee public.users;o public.orders;job public.procurement_jobs;prior public.idempotency_records;
 scope_key text;req_hash text;result jsonb;nowms bigint:=(extract(epoch FROM clock_timestamp())*1000)::bigint;
BEGIN
 u=public.jana_auth_user(p_token);IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;
 p_idem_key=trim(coalesce(p_idem_key,''));p_reason=trim(coalesce(p_reason,''));
 IF length(p_idem_key) NOT BETWEEN 8 AND 128 OR length(p_reason) NOT BETWEEN 3 AND 1000 OR p_expected_revision IS NULL OR p_expected_revision<1 THEN RAISE EXCEPTION 'procurement_validation';END IF;
 scope_key='procurement-assign:'||u.id||':'||p_idem_key;
 req_hash=encode(digest(jsonb_build_object('order_id',p_order_id,'employee_id',p_employee_id,'revision',p_expected_revision,'reason',p_reason)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
 SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
 IF prior.scope IS NOT NULL THEN
  IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict';END IF;
  RETURN prior.response::jsonb;
 END IF;
 SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF o.id IS NULL OR o.status<>'active' OR o.snapshot::jsonb->>'fulfillment_model'<>'supplier_pickup' THEN RAISE EXCEPTION 'procurement_order_invalid';END IF;
 SELECT * INTO job FROM public.procurement_jobs WHERE order_id=o.id FOR UPDATE;
 IF job.id IS NULL THEN RAISE EXCEPTION 'procurement_job_not_found';END IF;
 IF job.revision<>p_expected_revision THEN RAISE EXCEPTION 'procurement_changed';END IF;
 IF job.state NOT IN ('unassigned','assigned') OR job.assigned_to IS NOT DISTINCT FROM p_employee_id THEN RAISE EXCEPTION 'procurement_assignment_invalid';END IF;
 SELECT * INTO employee FROM public.users WHERE id=p_employee_id AND active AND role IN ('admin','picker') FOR SHARE;
 IF employee.id IS NULL THEN RAISE EXCEPTION 'procurement_employee_invalid';END IF;
 UPDATE public.procurement_jobs SET assigned_to=employee.id,state='assigned',revision=revision+1,assigned_at=nowms,updated_at=nowms
 WHERE id=job.id RETURNING * INTO job;
 UPDATE public.orders SET picker_id=employee.id WHERE id=o.id;
 INSERT INTO public.order_events(id,order_id,actor_id,event,reason,states,created_at)
 VALUES('evt-'||replace(gen_random_uuid()::text,'-',''),o.id,u.id,'procurement_assigned',p_reason,
  jsonb_build_object('job_id',job.id,'employee_id',employee.id,'revision',job.revision),nowms);
 INSERT INTO public.audit_log(id,actor_id,action,entity_id,detail,created_at)
 VALUES('aud-'||replace(gen_random_uuid()::text,'-',''),u.id,'procurement_assigned',job.id,
  jsonb_build_object('role',u.role,'order_id',o.id,'employee_id',employee.id,'reason',p_reason,'revision',job.revision),nowms);
 result=jsonb_build_object('id',job.id,'order_id',o.id,'assigned_to',job.assigned_to,'state',job.state,'revision',job.revision,'assigned_at',job.assigned_at);
 INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
 VALUES(scope_key,u.id,p_idem_key,req_hash,result,nowms);
 RETURN result;
END$$;

-- Deliberately dormant: PostgreSQL-owner tests exercise these functions directly.
-- A later migration will grant only the functions whose complete Edge/UI journey is ready.
REVOKE ALL ON FUNCTION
 public.jana_supplier_pickup_quote_create(text,text,text,jsonb),
 public.jana_supplier_pickup_quote_idempotent(text,text,text,text,jsonb),
 public.jana_supplier_pickup_order_confirm(text,text),
 public.jana_procurement_job_assign(text,text,text,text,bigint,text)
FROM PUBLIC,anon,authenticated,service_role;
