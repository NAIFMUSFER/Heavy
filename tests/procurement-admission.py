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
order=val(rpc('jana_supplier_pickup_order_confirm',f['t'],q['id']))
again=val(rpc('jana_supplier_pickup_order_confirm',f['t'],q['id']))
assert again['id']==order['id'] and again['idempotent_replay'] is True and order['inventory_reserved'] is False
job=val('SELECT to_jsonb(j) FROM procurement_jobs j WHERE order_id='+literal(order['id'])+';')
assert job['state']=='unassigned' and job['assigned_to'] is None and len(job['requested_lines'])==1
assert val('SELECT snapshot::jsonb FROM orders WHERE id='+literal(order['id'])+';')['total_halalas']==q['total_halalas']
fails('UPDATE procurement_jobs SET requested_lines='+literal(json.dumps([dict(offering_id='tampered',qty=9)]))+'::jsonb WHERE id='+literal(job['id'])+';','procurement_identity_immutable')
assert business()['balance']==before['balance'] and business()['lot']==before['lot'] and business()['movements']==before['movements']
passed('confirmation creates one immutable-request order and procurement job without inventory')
assign_key='procurement-assign-'+uuid.uuid4().hex
assigned=val(rpc('jana_procurement_job_assign',f['atok'],assign_key,order['id'],p+'a',1,'Fixture purchasing assignment'))
assert assigned['state']=='assigned' and assigned['assigned_to']==p+'a' and assigned['revision']==2
assert val('SELECT to_jsonb(picker_id) FROM orders WHERE id='+literal(order['id'])+';')==p+'a'
assert val(rpc('jana_procurement_job_assign',f['atok'],assign_key,order['id'],p+'a',1,'Fixture purchasing assignment'))==assigned
fails(rpc('jana_procurement_job_assign',f['atok'],'stale-'+uuid.uuid4().hex,order['id'],p+'a',1,'Stale assignment'),'procurement_changed')
passed('admin assignment is idempotent revisioned and mirrored to legacy picker ownership')
for token in [f['t'],f['ct']]:
 fails(rpc('jana_procurement_job_assign',token,'forbidden-'+uuid.uuid4().hex,order['id'],p+'a',2,'Unauthorized assignment'),'forbidden')
fails(rpc('jana_supplier_pickup_order_confirm',other_token,q['id']),'quote_not_found')
assert val("SELECT count(*) FROM pg_class WHERE oid='public.procurement_jobs'::regclass AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT');")==1
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_supplier_pickup_quote_create','jana_supplier_pickup_quote_idempotent','jana_supplier_pickup_order_confirm','jana_procurement_job_assign') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('service_role',oid,'EXECUTE'));")==0
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
purchase_key='procurement-purchase-'+uuid.uuid4().hex
first=val(purchase(purchase_key,2,1,500));assert first['state']=='collecting' and first['revision']==3 and not first['collection_complete']
assert val(purchase(purchase_key,2,1,500))==first
fails(purchase(purchase_key,2,1,501),'idempotency_conflict')
assert val('SELECT total_halalas FROM orders WHERE id='+literal(order['id'])+';')==customer_total
assert business()['balance']==before['balance'] and business()['lot']==before['lot'] and business()['movements']==before['movements']
passed('partial supplier purchase is durable and leaves customer price and inventory unchanged')

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
decision_query=rpc('jana_procurement_shortage_decide',f['t'],decision_key,shortage['id'],4,'reject_removal','Please continue purchasing the requested item')
fails(rpc('jana_procurement_shortage_decide',other_token,'wrong-owner-'+uuid.uuid4().hex,shortage['id'],4,'reject_removal','Not the order owner'),'procurement_shortage_not_found')
decision=val(decision_query)
assert decision['decision']=='reject_removal' and decision['request_state']=='rejected'
assert decision['job_state']=='collecting' and decision['revision']==5 and decision['customer_total_changed'] is False
assert decision['approved_adjustment_applied'] is False and decision['requires_financial_adjustment'] is False
assert val(decision_query)==decision
fails(rpc('jana_procurement_shortage_decide',f['t'],decision_key,shortage['id'],4,'approve_removal','Conflicting decision'),'idempotency_conflict')
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

# Approval has a deliberately different terminal gate: it blocks further
# collection and does not make the order courier-ready until the exact approved
# retail adjustment exists.
approval_quote=val(supplier_quote('procurement-approval-quote-'+uuid.uuid4().hex,items))
approval_order=val(rpc('jana_supplier_pickup_order_confirm',f['t'],approval_quote['id']))
approval_job=val('SELECT to_jsonb(j) FROM procurement_jobs j WHERE order_id='+literal(approval_order['id'])+';')
approval_job=val(rpc('jana_procurement_job_assign',f['atok'],'procurement-approval-assign-'+uuid.uuid4().hex,approval_order['id'],p+'a',1,'Disposable approval assignment'))
approval_line=val('SELECT requested_lines->0->>\'line_id\' FROM procurement_jobs WHERE id='+literal(approval_job['id'])+';')
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
print(json.dumps(dict(passed=len(checks),checks=checks)))
