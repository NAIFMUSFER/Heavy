"""Dormant warehouse-free quote/order/assignment in disposable PostgreSQL only."""
from database_support import *
from storefront_fixture import PROFILE,REVIEWED,get_store,write_store
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 r=run(query,False);assert not r['ok'] and code in r['error'],r
f=fixture();p=f['p'];other_token=secrets.token_hex(32)
run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+literal(p+'other')+","+literal(p+'other@example.invalid')+",'Other customer','unused','customer',false,true,extract(epoch from clock_timestamp())::bigint*1000);INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(other_token)+",'sha256'),'hex'),"+literal(p+'other')+",'unused',extract(epoch from clock_timestamp())::bigint*1000+300000,extract(epoch from clock_timestamp())::bigint*1000);")
# Use the existing launch gate only to create an isolated open-store fixture, then
# remove all physical stock before exercising the new dormant path.
s=get_store(f)
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
print(json.dumps(dict(passed=len(checks),checks=checks)))
