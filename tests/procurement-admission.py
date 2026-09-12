"""Dormant warehouse-free quote/order/assignment in disposable PostgreSQL only."""
from database_support import *
from storefront_fixture import PROFILE,REVIEWED,get_store,intake,write_store
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 r=run(query,False);assert not r['ok'] and code in r['error'],r
f=fixture();p=f['p'];other_token=secrets.token_hex(32)
run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+literal(p+'other')+","+literal(p+'other@example.invalid')+",'Other customer','unused','customer',false,true,extract(epoch from clock_timestamp())::bigint*1000);INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(other_token)+",'sha256'),'hex'),"+literal(p+'other')+",'unused',extract(epoch from clock_timestamp())::bigint*1000+300000,extract(epoch from clock_timestamp())::bigint*1000);")
# Use the existing launch gate only to create an isolated open-store fixture, then
# remove all physical stock before exercising the new dormant path.
s=get_store(f)
if s['accepting_orders']:
 s=intake(f,False)
# The preceding compatibility tests may already have created the sole legacy hub.
# Reuse it only to satisfy the old launch gate; this is not part of the new flow.
w=val("SELECT to_jsonb(w) FROM warehouses w WHERE active ORDER BY id LIMIT 1;")
if w is None:
 w=val(rpc('jana_delivery_admin_write',f['atok'],'procurement-fixture-hub','warehouse.save',dict(id=None,revision=None,reason='Disposable compatibility setup',changes=dict(name='Fixture compatibility hub',city='Fixture city',address_line='Disposable database only',latitude=16.5,longitude=42.5,active=True))))
if val('SELECT count(*) FROM delivery_zone_warehouses WHERE zone_id='+literal(p+'z')+';')==0:
 val(rpc('jana_delivery_admin_write',f['atok'],'procurement-fixture-route','zone.save',dict(id=p+'z',revision=1,reason='Disposable compatibility route',changes=dict(warehouse_id=w['id']))))
s=write_store(f,'draft.save',dict(revision=s['revision'],profile=PROFILE))
s=write_store(f,'profile.publish',dict(revision=s['revision'],confirmed=True))
s=write_store(f,'intake.set',dict(revision=s['revision'],accepting_orders=True,message='Fixture only',reason='Disposable test',reference='FIXTURE-ONLY',reviewed=REVIEWED))
run("UPDATE stock_balances SET on_hand_base=0,reserved_base=0 WHERE stock_id="+literal(p+'st')+";UPDATE inventory_lots SET on_hand_base=0,reserved_base=0 WHERE stock_id="+literal(p+'st')+';')
catalog_offset=val("SELECT count(*) FROM offerings o CROSS JOIN offerings target WHERE target.id="+literal(p+'off')+" AND o.active AND (o.created_at<target.created_at OR (o.created_at=target.created_at AND o.id<target.id));")
catalog=val("SELECT jana_catalog_page("+str(catalog_offset)+",1,'','');")['items']
listed=next(x for x in catalog if x['id']==p+'off')
assert listed['fulfillment_model']=='supplier_pickup' and listed['orderable'] is True and listed['max_order_quantity']==20
assert listed['inventory_required'] is False and listed['legacy_available_units']==0 and listed['availability_status']=='to_be_purchased'
passed('catalog exposes procurement orderability separately from preserved legacy stock facts')
def business():
 return val("SELECT jsonb_build_object('balance',(SELECT to_jsonb(b) FROM stock_balances b WHERE stock_id="+literal(p+'st')+"),'lot',(SELECT to_jsonb(l) FROM inventory_lots l WHERE stock_id="+literal(p+'st')+"),'movements',(SELECT count(*) FROM stock_movements WHERE stock_id="+literal(p+'st')+"),'orders',(SELECT count(*) FROM orders WHERE user_id="+literal(p+'c')+"),'booked',(SELECT booked FROM delivery_slots WHERE id="+literal(p+'s')+'));')
before=business();items=[dict(offering_id=p+'off',qty=2)]
def supplier_quote(key,lines):
 return 'SELECT public.jana_supplier_pickup_quote_idempotent('+','.join(map(literal,[f['t'],key,p+'s',p+'addr']))+','+literal(json.dumps(lines))+'::jsonb)::text;'
create=supplier_quote('procurement-quote-'+uuid.uuid4().hex,items)
q=val(create);after_quote=business()
assert q['fulfillment_model']=='supplier_pickup' and q['inventory_reserved'] is False and q['order_flow_ready'] is False
assert after_quote['balance']==before['balance'] and after_quote['lot']==before['lot'] and after_quote['movements']==before['movements']
assert after_quote['booked']==before['booked']+1
snap=val('SELECT snapshot::jsonb FROM quotes WHERE id='+literal(q['id'])+';')
assert snap['allocations']==[] and snap['fulfillment_model']=='supplier_pickup' and snap['lines'][0]['unit_price_halalas']==q['lines'][0]['unit_price_halalas']
passed('warehouse-free quote freezes displayed retail terms and delivery capacity without stock')
gateway_quote=val('SELECT public.jana_supplier_pickup_quote_gateway('+','.join(map(literal,[f['t'],'procurement-gateway-quote-'+uuid.uuid4().hex,p+'s',p+'addr']))+','+literal(json.dumps(items))+'::jsonb)::text;')
assert gateway_quote['order_flow_ready'] is True and gateway_quote['inventory_reserved'] is False
val(rpc('jana_cancel_quote',f['t'],gateway_quote['id']))
assert business()['booked']==after_quote['booked']
passed('customer quote gateway reserves capacity only and exposes the completed order path')
key='procurement-retry-'+uuid.uuid4().hex
query=supplier_quote(key,items)
rows=successful(race([query]*6));assert len(rows)==6 and all(x==rows[0] for x in rows)
assert business()['booked']==before['booked']+2
fails(supplier_quote(key,[dict(offering_id=p+'off',qty=3)]),'idempotency_conflict')
passed('concurrent quote retries create one capacity reservation and reject conflicting reuse')
cancel_id=rows[0]['id'];cancel_before=business()
c=val(rpc('jana_cancel_quote',f['t'],cancel_id));assert c['state']=='cancelled'
cancel_after=business();assert cancel_after['booked']==cancel_before['booked']-1
assert cancel_after['balance']==cancel_before['balance'] and cancel_after['lot']==cancel_before['lot'] and cancel_after['movements']==cancel_before['movements']
passed('cancelling warehouse-free quote releases only delivery capacity')
confirm_key='procurement-confirm-'+uuid.uuid4().hex
order=val(rpc('jana_order_confirm_gateway',f['t'],confirm_key,q['id']))
again=val(rpc('jana_order_confirm_gateway',f['t'],confirm_key,q['id']))
assert again==order and order['idempotent_replay'] is False and order['inventory_reserved'] is False
job=val('SELECT to_jsonb(j) FROM procurement_jobs j WHERE order_id='+literal(order['id'])+';')
assert job['state']=='unassigned' and job['assigned_to'] is None and len(job['requested_lines'])==1
assert val('SELECT snapshot::jsonb FROM orders WHERE id='+literal(order['id'])+';')['total_halalas']==q['total_halalas']
detail=val(rpc('jana_order_detail',f['t'],order['id']))
assert [e['event'] for e in detail['timeline']]==['supplier_pickup_order_created'] and detail['timeline_has_earlier'] is False
fails('UPDATE procurement_jobs SET requested_lines='+literal(json.dumps([dict(offering_id='tampered',qty=9)]))+'::jsonb WHERE id='+literal(job['id'])+';','procurement_identity_immutable')
assert business()['balance']==before['balance'] and business()['lot']==before['lot'] and business()['movements']==before['movements']
passed('confirmation creates one immutable-request order and procurement job without inventory')
fails(rpc('jana_order_confirm_gateway',f['t'],confirm_key,cancel_id),'idempotency_conflict')
fails(rpc('jana_order_confirm_gateway',other_token,'wrong-owner-confirm-'+uuid.uuid4().hex,q['id']),'quote_not_found')
assert order['fulfillment_model']=='supplier_pickup'
passed('customer gateway confirms supplier pickup idempotently and binds retries to one quote')
assign_key='procurement-assign-'+uuid.uuid4().hex
assigned=val(rpc('jana_ops_procurement_assign',f['atok'],assign_key,job['id'],p+'a',1,'Fixture purchasing assignment'))
assert assigned['state']=='assigned' and assigned['assigned_to']==p+'a' and assigned['revision']==2
assert val('SELECT to_jsonb(picker_id) FROM orders WHERE id='+literal(order['id'])+';')==p+'a'
assert val(rpc('jana_ops_procurement_assign',f['atok'],assign_key,job['id'],p+'a',1,'Fixture purchasing assignment'))==assigned
fails(rpc('jana_ops_procurement_assign',f['atok'],'stale-'+uuid.uuid4().hex,job['id'],p+'a',1,'Stale assignment'),'procurement_changed')
fails(rpc('jana_ops_procurement_assign',f['atok'],'missing-'+uuid.uuid4().hex,'prc-'+'f'*32,p+'a',1,'Missing path job'),'procurement_job_not_found')
passed('path-bound admin assignment is idempotent revisioned and mirrored to legacy picker ownership')
for token in [f['t'],f['ct']]:
 fails(rpc('jana_ops_procurement_assign',token,'forbidden-'+uuid.uuid4().hex,job['id'],p+'a',2,'Unauthorized assignment'),'forbidden')
fails(rpc('jana_supplier_pickup_order_confirm',other_token,q['id']),'quote_not_found')
assert val("SELECT count(*) FROM pg_class WHERE oid='public.procurement_jobs'::regclass AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT');")==1
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_supplier_pickup_quote_create','jana_supplier_pickup_quote_idempotent','jana_supplier_pickup_order_confirm','jana_procurement_job_assign') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_supplier_pickup_quote_gateway','jana_order_confirm_gateway') AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==2
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_ops_procurement_assign','jana_ops_procurement_purchase_record') AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==2
passed('customer isolation private grants and dormant service boundary remain enforced')
assert val("SELECT count(*) FROM audit_log WHERE entity_id="+literal(job['id'])+" AND action='procurement_assigned';")==1
assert val("SELECT count(*) FROM order_events WHERE order_id="+literal(order['id'])+" AND event IN ('supplier_pickup_order_created','procurement_assigned');")==2
assert val('SELECT jana_deep_health();')['ok']
passed('audit events and existing business health remain intact')
# Purchase evidence remains a dormant owner-level primitive. It records actual
# supplier collection without touching the customer price or legacy inventory.
supplier=p+'supplier';run("INSERT INTO suppliers(id,name,phone,active) VALUES("+literal(supplier)+",'Fixture retailer','+966500000001',true);")
site=val(rpc('jana_supplier_pickup_site_write',f['atok'],'procurement-site-create',dict(id=None,revision=None,reason='Disposable retailer',changes=dict(supplier_id=supplier,name='Fixture local shop'))))
site=val(rpc('jana_supplier_pickup_site_write',f['atok'],'procurement-site-active',dict(id=site['id'],revision=1,reason='Disposable reviewed address',changes=dict(city='Fixture city',address_line='Disposable shop only',latitude=16.5,longitude=42.5,active=True))))
customer_total=val('SELECT total_halalas FROM orders WHERE id='+literal(order['id'])+';');line_id=job['requested_lines'][0]['line_id']
def purchase_for(target_order,target_line,key,revision,qty,cost,reference='FIXTURE-RECEIPT-1',token=None,extra=None):
 payload=dict(order_id=target_order,expected_revision=revision,supplier_id=supplier,pickup_site_id=site['id'],document_reference=reference,note='Disposable purchase evidence',lines=[dict(line_id=target_line,collected_qty=qty,actual_cost_halalas=cost,quality_note='Disposable quality accepted')])
 if extra:payload.update(extra)
 return rpc('jana_procurement_purchase_record',token or f['atok'],key,payload)
def purchase(key,revision,qty,cost,reference='FIXTURE-RECEIPT-1',token=None,extra=None):
 return purchase_for(order['id'],line_id,key,revision,qty,cost,reference,token,extra)
def ops_purchase(target_job,target_line,key,revision,qty,cost,reference='FIXTURE-RECEIPT-1',token=None,extra=None):
 payload=dict(expected_revision=revision,supplier_id=supplier,pickup_site_id=site['id'],document_reference=reference,note='Disposable purchase evidence',lines=[dict(line_id=target_line,collected_qty=qty,actual_cost_halalas=cost,quality_note='Disposable quality accepted')])
 if extra:payload.update(extra)
 return rpc('jana_ops_procurement_purchase_record',token or f['atok'],key,target_job,payload)
purchase_key='procurement-purchase-'+uuid.uuid4().hex
first=val(ops_purchase(job['id'],line_id,purchase_key,2,1,500));assert first['state']=='collecting' and first['revision']==3 and not first['collection_complete']
assert val(ops_purchase(job['id'],line_id,purchase_key,2,1,500))==first
fails(ops_purchase(job['id'],line_id,purchase_key,2,1,501),'idempotency_conflict')
fails(ops_purchase(job['id'],line_id,'client-order-'+uuid.uuid4().hex,3,1,500,extra=dict(order_id='client-controlled')),'procurement_purchase_validation')
assert val('SELECT total_halalas FROM orders WHERE id='+literal(order['id'])+';')==customer_total
assert business()['balance']==before['balance'] and business()['lot']==before['lot'] and business()['movements']==before['movements']
passed('path-bound partial supplier purchase is durable and leaves customer price and inventory unchanged')

# A shortage proposal freezes every currently missing quantity and its displayed
# retail reduction. The customer's decision remains evidence only until the
# separate financial-adjustment gate is implemented.
shortage_key='procurement-shortage-'+uuid.uuid4().hex
shortage_query=rpc('jana_procurement_shortage_propose',f['atok'],shortage_key,order['id'],3,'Fixture supplier could not provide the remainder')
shortage=val(shortage_query)
assert shortage['state']=='pending' and shortage['job_state']=='awaiting_customer' and shortage['revision']==4
assert len(shortage['missing_lines'])==1 and shortage['missing_lines'][0]['missing_qty']==1
assert shortage['customer_total_before_halalas']==customer_total and shortage['customer_total_changed'] is False
assert shortage['customer_total_if_approved_halalas']==customer_total-shortage['proposed_reduction_halalas']
assert val(shortage_query)==shortage
fails(rpc('jana_procurement_shortage_propose',f['atok'],shortage_key,order['id'],3,'Conflicting shortage reason'),'idempotency_conflict')
fails(purchase('procurement-while-waiting-'+uuid.uuid4().hex,4,1,500,'FIXTURE-WAITING'),'procurement_custody_required')
passed('shortage proposal freezes all missing quantities and displayed-price reduction without applying it')

decision_key='procurement-shortage-decision-'+uuid.uuid4().hex
fails(rpc('jana_customer_procurement_shortage_decide',f['t'],'wrong-path-'+uuid.uuid4().hex,'order-does-not-match',shortage['id'],4,'reject_removal','The URL order must match the shortage request'),'procurement_shortage_not_found')
assert val('SELECT to_jsonb(state) FROM procurement_shortage_requests WHERE id='+literal(shortage['id'])+';')=='pending'
assert val('SELECT count(*) FROM procurement_shortage_decisions WHERE request_id='+literal(shortage['id'])+';')==0
decision_query=rpc('jana_customer_procurement_shortage_decide',f['t'],decision_key,order['id'],shortage['id'],4,'reject_removal','Please continue purchasing the requested item')
fails(rpc('jana_customer_procurement_shortage_decide',other_token,'wrong-owner-'+uuid.uuid4().hex,order['id'],shortage['id'],4,'reject_removal','Not the order owner'),'procurement_shortage_not_found')
decision=val(decision_query)
assert decision['decision']=='reject_removal' and decision['request_state']=='rejected'
assert decision['job_state']=='collecting' and decision['revision']==5 and decision['customer_total_changed'] is False
assert decision['approved_adjustment_applied'] is False and decision['requires_financial_adjustment'] is False
assert val(decision_query)==decision
fails(rpc('jana_customer_procurement_shortage_decide',f['t'],decision_key,order['id'],shortage['id'],4,'approve_removal','Conflicting decision'),'idempotency_conflict')
assert val('SELECT total_halalas FROM orders WHERE id='+literal(order['id'])+';')==customer_total
passed('only the order customer can explicitly decide the shortage and rejection safely resumes collection')

fails(purchase('procurement-over-'+uuid.uuid4().hex,5,2,900,'FIXTURE-OVER'),'procurement_quantity_exceeded')
fails(purchase('procurement-customer-'+uuid.uuid4().hex,5,1,500,'FIXTURE-CUSTOMER',f['t']),'forbidden')
fails(purchase('procurement-stale-'+uuid.uuid4().hex,4,1,500,'FIXTURE-STALE'),'procurement_changed')
passed('assignment custody revision and requested quantity bounds reject unsafe collection')
second=val(purchase('procurement-finish-'+uuid.uuid4().hex,5,1,550,'FIXTURE-RECEIPT-2'))
assert second['state']=='ready' and second['revision']==6 and second['collection_complete'] and second['customer_total_halalas']==customer_total
assert val('SELECT sum(total_actual_cost_halalas) FROM procurement_purchase_records WHERE job_id='+literal(job['id'])+';')==1050
assert val('SELECT sum(collected_qty) FROM procurement_purchase_lines WHERE job_id='+literal(job['id'])+' AND requested_line_id='+literal(line_id)+';')==2
fails('UPDATE procurement_purchase_records SET note=\'tampered\' WHERE id='+literal(first['id'])+';','append_only')
fails('DELETE FROM procurement_purchase_lines WHERE record_id='+literal(first['id'])+';','append_only')
assert val("SELECT count(*) FROM pg_class WHERE relname IN ('procurement_purchase_records','procurement_purchase_lines') AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT') AND NOT has_table_privilege('service_role',oid,'SELECT');")==2
assert val("SELECT count(*) FROM pg_proc WHERE proname='jana_procurement_purchase_record' AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE')); ")==0
assert val("SELECT count(*) FROM audit_log WHERE entity_id IN ("+literal(first['id'])+','+literal(second['id'])+") AND action='procurement_purchase_recorded';")==2
assert val('SELECT jana_deep_health();')['ok']
passed('complete collection is immutable private audited evidence without settlement or handover')

# Approval blocks collection until the exact approved retail adjustment is
# applied. The adjustment makes procurement ready for handover, not delivery.
approval_quote=val(supplier_quote('procurement-approval-quote-'+uuid.uuid4().hex,items))
approval_order=val(rpc('jana_supplier_pickup_order_confirm',f['t'],approval_quote['id']))
approval_job=val('SELECT to_jsonb(j) FROM procurement_jobs j WHERE order_id='+literal(approval_order['id'])+';')
approval_job=val(rpc('jana_procurement_job_assign',f['atok'],'procurement-approval-assign-'+uuid.uuid4().hex,approval_order['id'],p+'a',1,'Disposable approval assignment'))
approval_line=val('SELECT to_jsonb(requested_lines->0->>\'line_id\') FROM procurement_jobs WHERE id='+literal(approval_job['id'])+';')
approval_purchase=val(purchase_for(approval_order['id'],approval_line,'procurement-approval-purchase-'+uuid.uuid4().hex,2,1,500,'FIXTURE-APPROVAL-RECEIPT'))
assert approval_purchase['state']=='collecting' and approval_purchase['revision']==3
approval_request=val(rpc('jana_procurement_shortage_propose',f['atok'],'procurement-approval-shortage-'+uuid.uuid4().hex,approval_order['id'],3,'Fixture final unit unavailable'))
approval=val(rpc('jana_procurement_shortage_decide',f['t'],'procurement-approval-decision-'+uuid.uuid4().hex,approval_request['id'],4,'approve_removal','I approve removing the unavailable quantity'))
assert approval['request_state']=='approved' and approval['job_state']=='shortage_approved' and approval['revision']==5
assert approval['requires_financial_adjustment'] and not approval['approved_adjustment_applied'] and not approval['customer_total_changed']
assert val('SELECT total_halalas FROM orders WHERE id='+literal(approval_order['id'])+';')==approval_order['total_halalas']
fails(purchase_for(approval_order['id'],approval_line,'procurement-after-approval-'+uuid.uuid4().hex,5,1,500,'FIXTURE-AFTER-APPROVAL'),'procurement_custody_required')
fails('UPDATE procurement_shortage_requests SET reason=\'tampered\' WHERE id='+literal(approval_request['id'])+';','shortage_request_immutable')
fails('DELETE FROM procurement_shortage_decisions WHERE request_id='+literal(approval_request['id'])+';','append_only')
assert val("SELECT count(*) FROM pg_class WHERE relname IN ('procurement_shortage_requests','procurement_shortage_decisions') AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT') AND NOT has_table_privilege('service_role',oid,'SELECT');")==2
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_procurement_shortage_propose','jana_procurement_shortage_decide') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM audit_log WHERE entity_id IN ("+literal(approval_request['id'])+','+literal(approval['id'])+") AND action IN ('procurement_shortage_proposed','procurement_shortage_decided');")==2
assert val('SELECT jana_deep_health();')['ok']
passed('approved removal is immutable explicit consent and blocks collection pending exact financial adjustment')

approval_before=val('SELECT jsonb_build_object(\'total\',total_halalas,\'snapshot\',snapshot::jsonb,\'original\',original_snapshot::jsonb) FROM orders WHERE id='+literal(approval_order['id'])+';')
adjust_key='procurement-adjust-'+uuid.uuid4().hex
adjust_query=rpc('jana_ops_procurement_shortage_apply_adjustment',f['atok'],adjust_key,approval_job['id'],approval_request['id'],5,'Apply only the customer-approved missing quantity reduction')
fails(rpc('jana_ops_procurement_shortage_apply_adjustment',f['t'],'customer-adjust-'+uuid.uuid4().hex,approval_job['id'],approval_request['id'],5,'Customer cannot execute internal adjustment'),'forbidden')
fails(rpc('jana_ops_procurement_shortage_apply_adjustment',f['atok'],'stale-adjust-'+uuid.uuid4().hex,approval_job['id'],approval_request['id'],4,'Stale adjustment attempt'),'procurement_changed')
# A valid inner adjustment paired with the wrong URL job must roll back every
# write made by the inner primitive, leaving the real job available to apply.
fails(rpc('jana_ops_procurement_shortage_apply_adjustment',f['atok'],'wrong-job-adjust-'+uuid.uuid4().hex,job['id'],approval_request['id'],5,'Wrong route job must roll back'),'procurement_adjustment_not_found')
assert val('SELECT to_jsonb(state) FROM procurement_jobs WHERE id='+literal(approval_job['id'])+';')=='shortage_approved'
assert val('SELECT count(*) FROM procurement_retail_adjustments WHERE request_id='+literal(approval_request['id'])+';')==0
assert val('SELECT total_halalas FROM orders WHERE id='+literal(approval_order['id'])+';')==approval_before['total']
adjusted=val(adjust_query)
assert adjusted['job_state']=='ready' and adjusted['revision']==6 and adjusted['customer_total_changed']
assert adjusted['customer_total_before_halalas']==approval_before['total']
assert adjusted['approved_reduction_halalas']==approval_request['proposed_reduction_halalas']
assert adjusted['customer_total_after_halalas']==approval_before['total']-approval_request['proposed_reduction_halalas']
assert adjusted['original_snapshot_changed'] is False and adjusted['inventory_changed'] is False
assert adjusted['supplier_cost_changed'] is False and adjusted['cash_changed'] is False and adjusted['requires_handover']
assert val(adjust_query)==adjusted
fails(rpc('jana_procurement_shortage_apply_adjustment',f['atok'],adjust_key,approval_request['id'],5,'Conflicting adjustment reason'),'idempotency_conflict')
approval_after=val('SELECT jsonb_build_object(\'total\',total_halalas,\'snapshot\',snapshot::jsonb,\'original\',original_snapshot::jsonb) FROM orders WHERE id='+literal(approval_order['id'])+';')
assert approval_after['total']==adjusted['customer_total_after_halalas']
assert approval_after['snapshot']['total_halalas']==approval_after['total']
assert approval_after['snapshot']['subtotal_halalas']==approval_before['snapshot']['subtotal_halalas']-approval_request['proposed_reduction_halalas']
assert len(approval_after['snapshot']['lines'])==1 and approval_after['snapshot']['lines'][0]['qty']==1
assert approval_after['snapshot']['lines'][0]['line_total_halalas']==approval_after['snapshot']['lines'][0]['unit_price_halalas']
assert approval_after['snapshot']['procurement_state']=='ready_for_handover'
assert approval_after['original']==approval_before['original']
assert business()['balance']==before['balance'] and business()['lot']==before['lot'] and business()['movements']==before['movements']
fails('UPDATE procurement_retail_adjustments SET reason=\'tampered\' WHERE id='+literal(adjusted['id'])+';','append_only')
assert val("SELECT count(*) FROM pg_class WHERE relname='procurement_retail_adjustments' AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT') AND NOT has_table_privilege('service_role',oid,'SELECT');")==1
assert val("SELECT count(*) FROM pg_proc WHERE proname='jana_procurement_shortage_apply_adjustment' AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE proname='jana_ops_procurement_shortage_apply_adjustment' AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==1
assert val("SELECT count(*) FROM audit_log WHERE entity_id="+literal(adjusted['id'])+" AND action='procurement_shortage_adjusted';")==1
assert val("SELECT count(*) FROM order_events WHERE order_id="+literal(approval_order['id'])+" AND event='procurement_shortage_adjusted';")==1
assert val('SELECT jana_deep_health();')['ok']
passed('approved reduction applies exactly once while original terms inventory supplier cost and cash stay unchanged')

# Removing every line requires a second, explicit cancellation confirmation from
# the owning customer. The historical price remains intact and the delivery slot
# is released exactly once; no inventory, purchase or cash record is created.
cancel_quote=val(supplier_quote('procurement-unavailable-quote-'+uuid.uuid4().hex,items))
cancel_order=val(rpc('jana_supplier_pickup_order_confirm',f['t'],cancel_quote['id']))
cancel_job=val(rpc('jana_procurement_job_assign',f['atok'],'procurement-unavailable-assign-'+uuid.uuid4().hex,cancel_order['id'],p+'a',1,'Disposable all unavailable assignment'))
cancel_request=val(rpc('jana_procurement_shortage_propose',f['atok'],'procurement-unavailable-shortage-'+uuid.uuid4().hex,cancel_order['id'],2,'Fixture suppliers could not provide any requested item'))
cancel_decision=val(rpc('jana_procurement_shortage_decide',f['t'],'procurement-unavailable-decision-'+uuid.uuid4().hex,cancel_request['id'],3,'approve_removal','I approve removing every unavailable item'))
assert cancel_decision['job_state']=='shortage_approved' and cancel_decision['revision']==4
assert cancel_request['proposed_reduction_halalas']==cancel_quote['subtotal_halalas']
cancel_before=val('SELECT jsonb_build_object(\'order\',to_jsonb(o),\'job\',to_jsonb(j),\'booked\',s.booked) FROM orders o JOIN procurement_jobs j ON j.order_id=o.id JOIN delivery_slots s ON s.id=o.slot_id WHERE o.id='+literal(cancel_order['id'])+';')
cancel_key='procurement-all-unavailable-cancel-'+uuid.uuid4().hex
cancel_query=rpc('jana_procurement_all_unavailable_cancel',f['t'],cancel_key,cancel_request['id'],4,'I explicitly confirm cancelling this entirely unavailable order')
fails(rpc('jana_procurement_all_unavailable_cancel',other_token,'wrong-customer-cancel-'+uuid.uuid4().hex,cancel_request['id'],4,'Another customer cannot cancel this order'),'procurement_shortage_not_found')
fails(rpc('jana_procurement_all_unavailable_cancel',f['atok'],'admin-unavailable-cancel-'+uuid.uuid4().hex,cancel_request['id'],4,'Admin cannot impersonate customer confirmation'),'forbidden')
fails(rpc('jana_procurement_all_unavailable_cancel',f['t'],'stale-unavailable-cancel-'+uuid.uuid4().hex,cancel_request['id'],3,'Stale customer cancellation'),'procurement_changed')
cancelled=val(cancel_query)
assert cancelled['job_state']=='cancelled' and cancelled['revision']==5
assert cancelled['status']=='cancelled' and cancelled['payment_state']=='cancelled'
assert cancelled['fulfillment_state']=='cancelled' and cancelled['delivery_state']=='cancelled'
assert cancelled['customer_total_halalas']==cancel_before['order']['total_halalas'] and not cancelled['customer_total_changed']
assert cancelled['current_snapshot_changed'] is False and cancelled['original_snapshot_changed'] is False
assert cancelled['delivery_capacity_released'] and cancelled['slot_booked_before']==cancel_before['booked']
assert cancelled['slot_booked_after']==cancel_before['booked']-1
assert cancelled['inventory_changed'] is False and cancelled['supplier_cost_changed'] is False and cancelled['cash_changed'] is False
assert val(cancel_query)==cancelled
fails(rpc('jana_procurement_all_unavailable_cancel',f['t'],cancel_key,cancel_request['id'],4,'Conflicting cancellation confirmation'),'idempotency_conflict')
cancel_after=val('SELECT jsonb_build_object(\'order\',to_jsonb(o),\'job\',to_jsonb(j),\'booked\',s.booked) FROM orders o JOIN procurement_jobs j ON j.order_id=o.id JOIN delivery_slots s ON s.id=o.slot_id WHERE o.id='+literal(cancel_order['id'])+';')
assert cancel_after['order']['snapshot']==cancel_before['order']['snapshot']
assert cancel_after['order']['original_snapshot']==cancel_before['order']['original_snapshot']
assert cancel_after['order']['total_halalas']==cancel_before['order']['total_halalas']
assert cancel_after['booked']==cancel_before['booked']-1 and cancel_after['job']['state']=='cancelled'
assert val('SELECT count(*) FROM procurement_purchase_records r JOIN procurement_jobs j ON j.id=r.job_id WHERE j.order_id='+literal(cancel_order['id'])+';')==0
fails(rpc('jana_cancel_order',f['t'],cancel_order['id']),'order_not_cancellable')
fails('UPDATE procurement_unavailable_cancellations SET note=\'tampered\' WHERE id='+literal(cancelled['id'])+';','append_only')
assert val("SELECT count(*) FROM pg_class WHERE relname='procurement_unavailable_cancellations' AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT') AND NOT has_table_privilege('service_role',oid,'SELECT');")==1
assert val("SELECT count(*) FROM pg_proc WHERE proname='jana_procurement_all_unavailable_cancel' AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM audit_log WHERE entity_id="+literal(cancelled['id'])+" AND action='procurement_all_unavailable_cancelled';")==1
assert val("SELECT count(*) FROM order_events WHERE order_id="+literal(cancel_order['id'])+" AND event='procurement_all_unavailable_cancelled';")==1
assert val('SELECT jana_deep_health();')['ok']
passed('explicit all-unavailable cancellation preserves historical terms and releases capacity exactly once')

# Each immutable supplier purchase must identify its actual funding source before
# physical custody leaves purchasing. Repayments are a separate evidence ledger
# and never change the frozen customer price, inventory, or courier cash ledger.
def funding(record,key,source,reference,token=None):
 return rpc('jana_ops_procurement_funding_record',token or f['atok'],key,record['job_id'],record['id'],source,reference,'Disposable funding evidence only')
def settlement(job_id,funding_id,key,amount,reference,token=None):
 return rpc('jana_ops_procurement_settlement_record',token or f['atok'],key,job_id,funding_id,amount,reference,'Disposable settlement evidence only')
fails(rpc('jana_ops_procurement_handover_prepare',f['atok'],'missing-funding-'+uuid.uuid4().hex,job['id'],p+'c',6,'Funding attribution is intentionally missing'),'procurement_funding_required')
fund_employee_key='procurement-funding-employee-'+uuid.uuid4().hex
fund_employee_query=funding(first,fund_employee_key,'employee_paid','FIXTURE-EMPLOYEE-FUNDED')
fund_employee=val(fund_employee_query)
assert fund_employee['principal_halalas']==500 and fund_employee['liability_type']=='employee_reimbursement'
assert fund_employee['employee_id']==p+'a' and fund_employee['outstanding_halalas']==500
assert val(fund_employee_query)==fund_employee
fails(funding(first,fund_employee_key,'supplier_credit','FIXTURE-CONFLICTING-FUNDING'),'idempotency_conflict')
fails(funding(first,'duplicate-funding-'+uuid.uuid4().hex,'employee_paid','FIXTURE-DUPLICATE-FUNDING'),'procurement_funding_exists')
fund_supplier=val(funding(second,'procurement-funding-supplier-'+uuid.uuid4().hex,'supplier_credit','FIXTURE-SUPPLIER-CREDIT'))
assert fund_supplier['principal_halalas']==550 and fund_supplier['liability_type']=='supplier_payable'
assert fund_supplier['supplier_id']==supplier and fund_supplier['outstanding_halalas']==550
fund_company=val(funding(approval_purchase,'procurement-funding-company-'+uuid.uuid4().hex,'company_paid','FIXTURE-COMPANY-PAID'))
assert fund_company['principal_halalas']==500 and fund_company['liability_type']=='none'
assert fund_company['outstanding_halalas']==0 and fund_company['employee_id'] is None and fund_company['supplier_id'] is None
fails(settlement(fund_company['job_id'],fund_company['id'],'company-settlement-'+uuid.uuid4().hex,1,'FIXTURE-COMPANY-DUPLICATE'),'procurement_settlement_not_payable')
fails(funding(second,'customer-funding-'+uuid.uuid4().hex,'supplier_credit','FIXTURE-CUSTOMER-DENIED',f['t']),'forbidden')
fails(rpc('jana_ops_procurement_funding_record',f['atok'],'wrong-path-'+uuid.uuid4().hex,approval_purchase['job_id'],first['id'],'employee_paid','FIXTURE-WRONG-PATH','Disposable wrong path evidence'),'procurement_funding_not_found')
passed('funding attribution separates company payment employee reimbursement and supplier payable from purchase cost')

cash_before=val('SELECT count(*) FROM cash_entries;')
employee_payment_key='procurement-employee-payment-'+uuid.uuid4().hex
employee_payment_query=settlement(fund_employee['job_id'],fund_employee['id'],employee_payment_key,200,'FIXTURE-EMPLOYEE-PAYMENT-1')
employee_payment=val(employee_payment_query)
assert employee_payment['beneficiary_type']=='employee' and employee_payment['beneficiary_id']==p+'a'
assert employee_payment['settled_halalas']==200 and employee_payment['outstanding_halalas']==300 and not employee_payment['fully_settled']
assert val(employee_payment_query)==employee_payment
fails(settlement(fund_employee['job_id'],fund_employee['id'],employee_payment_key,201,'FIXTURE-EMPLOYEE-PAYMENT-1'),'idempotency_conflict')
fails(settlement(fund_employee['job_id'],fund_employee['id'],'employee-overpay-'+uuid.uuid4().hex,301,'FIXTURE-EMPLOYEE-OVERPAY'),'procurement_settlement_exceeded')
supplier_payment_key='procurement-supplier-payment-'+uuid.uuid4().hex
supplier_payment_query=settlement(fund_supplier['job_id'],fund_supplier['id'],supplier_payment_key,550,'FIXTURE-SUPPLIER-PAYMENT-1')
supplier_payments=successful(race([supplier_payment_query]*8));assert len(supplier_payments)==8 and all(x==supplier_payments[0] for x in supplier_payments)
assert supplier_payments[0]['fully_settled'] and supplier_payments[0]['outstanding_halalas']==0
assert supplier_payments[0]['beneficiary_type']=='supplier' and supplier_payments[0]['beneficiary_id']==supplier
fails(settlement(fund_supplier['job_id'],fund_supplier['id'],'supplier-overpay-'+uuid.uuid4().hex,1,'FIXTURE-SUPPLIER-OVERPAY'),'procurement_settlement_exceeded')
assert val('SELECT count(*) FROM cash_entries;')==cash_before
assert val('SELECT total_halalas FROM orders WHERE id='+literal(order['id'])+';')==customer_total
assert business()['balance']==before['balance'] and business()['lot']==before['lot'] and business()['movements']==before['movements']
fails('UPDATE procurement_purchase_funding SET note=\'tampered\' WHERE id='+literal(fund_employee['id'])+';','append_only')
fails('DELETE FROM procurement_settlement_entries WHERE id='+literal(employee_payment['id'])+';','append_only')
assert val("SELECT count(*) FROM pg_class WHERE relname IN ('procurement_purchase_funding','procurement_settlement_entries') AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT') AND NOT has_table_privilege('service_role',oid,'SELECT');")==2
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_procurement_funding_record','jana_procurement_settlement_record') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_ops_procurement_funding_record','jana_ops_procurement_settlement_record') AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==2
assert val("SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN ('jana_procurement_funding_actor','jana_procurement_settlement_actor','jana_procurement_settlement_purchase');")==3
assert val("SELECT count(*) FROM audit_log WHERE entity_id IN ("+literal(fund_employee['id'])+','+literal(fund_supplier['id'])+','+literal(fund_company['id'])+") AND action='procurement_funding_recorded';")==3
assert val("SELECT count(*) FROM audit_log WHERE entity_id IN ("+literal(employee_payment['id'])+','+literal(supplier_payments[0]['id'])+") AND action='procurement_settlement_recorded';")==2
health=val('SELECT jana_deep_health();');assert health['ok'] and health['procurement_funding_invariant_violations']==0
passed('partial and complete settlements are bounded immutable auditable and independent of customer and courier cash')

# Physical custody is a two-party checkpoint. The assigned purchasing employee
# freezes the exact collected evidence for one courier; only that courier can
# accept it and make the order ready for the existing delivery flow.
other_courier_token=secrets.token_hex(32)
run("INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(other_courier_token)+",'sha256'),'hex'),"+literal(p+'d')+",'unused',extract(epoch from clock_timestamp())::bigint*1000+300000,extract(epoch from clock_timestamp())::bigint*1000);")
handover_before=val('SELECT jsonb_build_object(\'order\',to_jsonb(o),\'job\',to_jsonb(j)) FROM orders o JOIN procurement_jobs j ON j.order_id=o.id WHERE o.id='+literal(order['id'])+';')
prepare_key='procurement-handover-'+uuid.uuid4().hex
prepare_query=rpc('jana_ops_procurement_handover_prepare',f['atok'],prepare_key,job['id'],p+'c',6,'Disposable physical goods handover')
fails(rpc('jana_ops_procurement_handover_prepare',f['t'],'customer-handover-'+uuid.uuid4().hex,job['id'],p+'c',6,'Customer cannot prepare custody'),'forbidden')
fails(rpc('jana_ops_procurement_handover_prepare',f['atok'],'stale-handover-'+uuid.uuid4().hex,job['id'],p+'c',5,'Stale handover attempt'),'procurement_changed')
prepared=val(prepare_query)
assert prepared['state']=='handover_pending' and prepared['revision']==7 and prepared['courier_id']==p+'c'
assert prepared['courier_accepted'] is False and prepared['supplier_cost_total_halalas']==1050
assert len(prepared['collected_lines'])==1 and prepared['collected_lines'][0]['qty']==2
assert prepared['collected_lines'][0]['collected_qty']==2 and len(prepared['purchase_record_ids'])==2
assert prepared['inventory_changed'] is False and prepared['cash_changed'] is False
assert prepared['supplier_settlement_recorded'] is False and prepared['employee_settlement_recorded'] is False
assert prepared['purchase_funding_recorded'] is True
assert prepared['employee_reimbursement_outstanding_halalas']==300
assert prepared['supplier_payable_outstanding_halalas']==0
assert val(prepare_query)==prepared
fails(rpc('jana_ops_procurement_handover_prepare',f['atok'],prepare_key,job['id'],p+'d',6,'Conflicting courier'),'idempotency_conflict')
pending_order=val('SELECT jsonb_build_object(\'fulfillment_state\',fulfillment_state,\'delivery_state\',delivery_state,\'courier_id\',courier_id) FROM orders WHERE id='+literal(order['id'])+';')
assert pending_order==dict(fulfillment_state='queued',delivery_state='unassigned',courier_id=None)
roster=val(rpc('jana_procurement_active_couriers',f['atok']))
assert any(row==dict(id=p+'c',name='Audit fixture') for row in roster)
assert all(set(row)=={'id','name'} for row in roster)
fails(rpc('jana_procurement_active_couriers',f['ct']),'forbidden')
courier_page=val('SELECT public.jana_procurement_jobs_page('+literal(f['ct'])+",50,NULL,NULL,'handover_pending')::text;")
assert len(courier_page['items'])==1 and courier_page['items'][0]['id']==job['id']
assert courier_page['courier_custody_only'] and not courier_page['financial_detail_included']
courier_detail=val(rpc('jana_procurement_job_detail',f['ct'],job['id']))
assert courier_detail['courier_custody_only'] and courier_detail['customer_terms'] is None
assert courier_detail['purchases']==[] and courier_detail['funding']==[] and courier_detail['settlements']==[]
assert courier_detail['handover']['request_id']==prepared['id'] and len(courier_detail['lines'])==1
assert all(secret not in json.dumps(courier_detail) for secret in ['Fixture retailer','FIXTURE-RECEIPT','supplier_cost_total_halalas','customer_total_halalas','line_total_halalas','purchase_record_ids'])
fails(rpc('jana_procurement_job_detail',other_courier_token,job['id']),'forbidden')
fails(rpc('jana_update_staff',f['atok'],p+'c',dict(active=False),'Cannot disable pending custody courier'),'staff_has_active_orders')
assert val('SELECT to_jsonb(active) FROM users WHERE id='+literal(p+'c')) is True
passed('purchasing employee freezes exact collected evidence without prematurely assigning delivery')

accept_key='procurement-handover-accept-'+uuid.uuid4().hex
accept_query=rpc('jana_ops_procurement_handover_accept',f['ct'],accept_key,job['id'],prepared['id'],7,'Courier counted and accepted the physical goods')
fails(rpc('jana_ops_procurement_handover_accept',other_courier_token,'wrong-courier-'+uuid.uuid4().hex,job['id'],prepared['id'],7,'Wrong courier cannot accept'),'procurement_handover_not_found')
fails(rpc('jana_ops_procurement_handover_accept',f['atok'],'admin-accept-'+uuid.uuid4().hex,job['id'],prepared['id'],7,'Admin cannot impersonate courier'),'forbidden')
accepted=val(accept_query)
assert accepted['state']=='handed_over' and accepted['revision']==8 and accepted['courier_accepted']
assert accepted['fulfillment_state']=='ready' and accepted['delivery_state']=='assigned'
assert accepted['supplier_cost_total_halalas']==1050 and accepted['customer_total_halalas']==customer_total
assert accepted['inventory_changed'] is False and accepted['cash_changed'] is False
assert accepted['supplier_settlement_recorded'] is False and accepted['employee_settlement_recorded'] is False
assert val(accept_query)==accepted
fails(rpc('jana_ops_procurement_handover_accept',f['ct'],accept_key,job['id'],prepared['id'],7,'Conflicting acceptance note'),'idempotency_conflict')
handover_after=val('SELECT jsonb_build_object(\'order\',to_jsonb(o),\'job\',to_jsonb(j)) FROM orders o JOIN procurement_jobs j ON j.order_id=o.id WHERE o.id='+literal(order['id'])+';')
assert handover_after['order']['fulfillment_state']=='ready' and handover_after['order']['delivery_state']=='assigned'
assert handover_after['order']['courier_id']==p+'c' and handover_after['job']['state']=='handed_over'
assert handover_after['order']['original_snapshot']==handover_before['order']['original_snapshot']
assert handover_after['order']['snapshot']['procurement_state']=='handed_to_courier'
assert handover_after['order']['total_halalas']==handover_before['order']['total_halalas']
assert business()['balance']==before['balance'] and business()['lot']==before['lot'] and business()['movements']==before['movements']
fails('UPDATE procurement_handover_requests SET note=\'tampered\' WHERE id='+literal(prepared['id'])+';','append_only')
fails('DELETE FROM procurement_handover_acceptances WHERE id='+literal(accepted['id'])+';','append_only')
assert val("SELECT count(*) FROM pg_class WHERE relname IN ('procurement_handover_requests','procurement_handover_acceptances') AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT') AND NOT has_table_privilege('service_role',oid,'SELECT');")==2
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_procurement_handover_prepare','jana_procurement_handover_accept') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_procurement_active_couriers','jana_ops_procurement_handover_prepare','jana_ops_procurement_handover_accept') AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==3
assert val("SELECT count(*) FROM audit_log WHERE entity_id IN ("+literal(prepared['id'])+','+literal(accepted['id'])+") AND action IN ('procurement_handover_prepared','procurement_handover_accepted');")==2
assert val("SELECT count(*) FROM order_events WHERE order_id="+literal(order['id'])+" AND event IN ('procurement_handover_prepared','procurement_handover_accepted');")==2
assert val('SELECT jana_deep_health();')['ok']
passed('only the selected courier accepts immutable custody before the order becomes delivery-ready')

# Read-only staff surfaces are independently safe to expose before writes. They
# are bounded, role-scoped and omit customer contact. Picker views omit payment
# references while admin/finance retain the evidence required for reconciliation.
def procurement_page(token,limit=50,before_at=None,before_id=None,state=None):
 return rpc('jana_procurement_jobs_page',token,limit,before_at,before_id,state).replace("'None'",'NULL')
admin_page=val(procurement_page(f['atok'],1))
assert len(admin_page['items'])==1 and admin_page['items'][0]['customer_contact_included'] is False
assert admin_page['items'][0]['id'] and admin_page['limit']==1
if admin_page['next']:
 next_page=val(procurement_page(f['atok'],1,admin_page['next']['before_at'],admin_page['next']['before_id']))
 assert all(x['id']!=admin_page['items'][0]['id'] for x in next_page['items'])
filtered=val(procurement_page(f['atok'],100,state='handed_over'))
assert any(x['id']==job['id'] for x in filtered['items'])
fails(procurement_page(f['atok'],101),'procurement_query_invalid')
fails(procurement_page(f['atok'],10,1,None),'procurement_query_invalid')
detail=val(rpc('jana_procurement_job_detail',f['atok'],job['id']))
assert detail['job']['state']=='handed_over' and detail['customer_contact_included'] is False
assert detail['customer_terms']['total_halalas']==customer_total and len(detail['purchases'])==2
assert len(detail['funding'])==2 and len(detail['settlements'])==2 and detail['financial_detail_included']
passed('admin procurement pages are bounded and reconcile purchase funding without customer contact')

other_picker=p+'pick';other_picker_token=secrets.token_hex(32)
run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+literal(other_picker)+","+literal(p+'pick@example.invalid')+",'Other picker','unused','picker',false,true,extract(epoch from clock_timestamp())::bigint*1000);INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(other_picker_token)+",'sha256'),'hex'),"+literal(other_picker)+",'unused',extract(epoch from clock_timestamp())::bigint*1000+300000,extract(epoch from clock_timestamp())::bigint*1000);")
run("UPDATE users SET role='picker' WHERE id="+literal(p+'a')+';')
picker_page=val(procurement_page(f['atok'],100))
assert any(x['id']==job['id'] for x in picker_page['items']) and all(x['assigned_to']==p+'a' for x in picker_page['items'])
picker_detail=val(rpc('jana_procurement_job_detail',f['atok'],job['id']))
assert picker_detail['financial_detail_included'] is False and picker_detail['settlements']==[]
assert len(picker_detail['funding'])==2 and picker_detail['customer_contact_included'] is False
assert val(procurement_page(other_picker_token,100))['items']==[]
fails(rpc('jana_procurement_job_detail',other_picker_token,job['id']),'forbidden')
fails(procurement_page(f['t'],10),'forbidden')
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_procurement_jobs_page','jana_procurement_job_detail') AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==2
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_procurement_funding_record','jana_procurement_settlement_record','jana_procurement_handover_prepare','jana_procurement_handover_accept') AND has_function_privilege('service_role',oid,'EXECUTE');")==0
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_ops_procurement_funding_record','jana_ops_procurement_settlement_record') AND has_function_privilege('service_role',oid,'EXECUTE');")==2
assert val("SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='jana_procurement_jobs_created_page';")==1
assert val('SELECT jana_deep_health();')['ok']
passed('picker procurement reads hide settlement references while finance writes remain role scoped')

# Customer order detail exposes only the customer's own collection quantities and
# consent-safe shortage totals. Supplier, employee, document and actual-cost
# evidence remains outside this boundary; legacy orders receive a null progress.
customer_detail=val(rpc('jana_order_detail',f['t'],order['id']))
progress=customer_detail['procurement_progress']
assert progress['version']==1 and progress['state']=='handed_over' and progress['revision']>=1 and progress['inventory_reserved'] is False
assert progress['supplier_detail_included'] is False and progress['staff_identity_included'] is False and progress['actual_cost_included'] is False
assert len(progress['lines'])==1 and progress['lines'][0]['requested_qty']==2 and progress['lines'][0]['collected_qty']==2 and progress['lines'][0]['remaining_qty']==0
assert all(key not in json.dumps(progress) for key in ['Fixture retailer','FIXTURE-RECEIPT','total_actual_cost_halalas','assigned_to','employee_id'])
approval_progress=val(rpc('jana_order_detail',f['t'],approval_order['id']))['procurement_progress']
assert approval_progress['shortage']['state']=='approved'
assert approval_progress['shortage']['proposed_reduction_halalas']==approval_request['proposed_reduction_halalas']
assert approval_progress['shortage']['customer_total_if_approved_halalas']==approval_request['customer_total_before_halalas']-approval_request['proposed_reduction_halalas']
fails(rpc('jana_order_detail',other_token,order['id']),'order_not_found')
assert val("SELECT count(*) FROM pg_proc WHERE proname='jana_order_detail' AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==1
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_order_detail_pre_procurement_progress','jana_order_detail_pre_customer_shortage_decision') AND has_function_privilege('service_role',oid,'EXECUTE');")==0
assert val("SELECT count(*) FROM pg_proc WHERE proname='jana_customer_procurement_shortage_decide' AND has_function_privilege('service_role',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('authenticated',oid,'EXECUTE');")==1
assert val("SELECT count(*) FROM pg_proc WHERE proname='jana_procurement_shortage_decide' AND has_function_privilege('service_role',oid,'EXECUTE');")==0
passed('customer order detail shows owned collection progress without supplier staff or actual-cost leakage')
print(json.dumps(dict(passed=len(checks),checks=checks)))
