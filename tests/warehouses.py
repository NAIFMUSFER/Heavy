"""Single-hub ownership and commercial admission in disposable PostgreSQL."""
from storefront_fixture import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 r=run(query,False);assert not r['ok'] and code in r['error'],r
def save(f,key,changes,id=None,revision=None):
 return rpc('jana_delivery_admin_write',f['atok'],key,'warehouse.save',dict(id=id,revision=revision,reason='Disposable warehouse verification',changes=changes))

f=fixture();active=val("SELECT to_jsonb(w) FROM warehouses w WHERE active;")
assert active['city'] and active['address_line'] and active['latitude'] is not None
catalog=val(rpc('jana_admin_catalog',f['atok']));assert len([w for w in catalog['warehouses'] if w['active']])==1
assert next(z for z in catalog['zones'] if z['id']==f['p']+'z')['warehouse_id']==active['id']
passed('admin catalog exposes one explicit launch warehouse and each fixture zone owner')

draft=val(save(f,'warehouse-draft-'+uuid.uuid4().hex,dict(name='مستودع ثانٍ غير مفعل')))
assert not draft['active'] and draft['revision']==1
fails(save(f,'warehouse-incomplete-'+uuid.uuid4().hex,dict(active=True),draft['id'],draft['revision']),'delivery_validation')
complete=dict(city='جازان',address_line='عنوان اختباري معزول',latitude=16.9,longitude=42.6,active=True)
fails(save(f,'warehouse-second-'+uuid.uuid4().hex,complete,draft['id'],draft['revision']),'delivery_validation')
passed('draft warehouses require real location fields and a second active hub is rejected')

polygon={'type':'Polygon','coordinates':[[[44,16],[45,16],[45,17],[44,17],[44,16]]]}
fails(rpc('jana_delivery_admin_write',f['atok'],'zone-no-hub-'+uuid.uuid4().hex,'zone.save',dict(id=None,revision=None,reason='Disposable route omission',changes=dict(name='منطقة بلا مستودع',polygon=polygon,fee_halalas=0,minimum_halalas=0,active=True))),'delivery_validation')
zone=val(rpc('jana_delivery_admin_write',f['atok'],'zone-with-hub-'+uuid.uuid4().hex,'zone.save',dict(id=None,revision=None,reason='Disposable routed zone',changes=dict(name='منطقة مرتبطة',polygon=polygon,fee_halalas=0,minimum_halalas=0,active=False,warehouse_id=active['id']))))
assert zone['warehouse_id']==active['id'] and val('SELECT count(*) FROM delivery_zone_warehouses WHERE zone_id='+literal(zone['id'])+';')==1
passed('zone creation is atomic with an explicit active warehouse route')

before=val('SELECT jana_storefront_readiness();');assert before['warehouse_ready'] and before['active_warehouses']==1 and before['unrouted_available_slots']==0
run('DELETE FROM delivery_zone_warehouses WHERE zone_id='+literal(f['p']+'z')+';')
after=val('SELECT jana_storefront_readiness();');assert not after['warehouse_ready'] and after['unrouted_available_slots']>=1
s=get_store(f);fails(rpc('jana_storefront_write',f['atok'],'warehouse-gate-'+uuid.uuid4().hex,'intake.set',dict(revision=s['revision'],accepting_orders=True,message='Fixture ordering remains open',reason='Disposable opening verification',reference='FIXTURE-WAREHOUSE-GATE',reviewed=REVIEWED)),'storefront_not_ready')
run('INSERT INTO delivery_zone_warehouses(zone_id,warehouse_id,assigned_by,assigned_at) VALUES('+literal(f['p']+'z')+','+literal(active['id'])+','+literal(f['p']+'a')+',extract(epoch from clock_timestamp())::bigint*1000);')
passed('unrouted available slots block commercial opening without changing inventory')

fails(save(f,'warehouse-disable-open-'+uuid.uuid4().hex,dict(active=False),active['id'],active['revision']),'delivery_changed')
assert val("SELECT to_jsonb(active) FROM warehouses WHERE id="+literal(active['id'])+';') is True
assert val("SELECT count(*) FROM pg_class c WHERE c.relname IN ('warehouses','delivery_zone_warehouses') AND (has_table_privilege('anon',c.oid,'SELECT') OR has_table_privilege('authenticated',c.oid,'SELECT'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_save_warehouse','jana_delivery_admin_write_pre_warehouse','jana_admin_catalog_pre_warehouse','jana_storefront_readiness_pre_warehouse','jana_storefront_write_pre_warehouse') AND has_function_privilege('service_role',oid,'EXECUTE');")==0
passed('an open storefront pins the active hub and private helpers remain inaccessible')

assert val('SELECT jana_deep_health();')['ok']
print(json.dumps(dict(passed=len(checks),checks=checks)))
