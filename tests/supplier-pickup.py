"""Supplier locations: disposable PostgreSQL only; never production fixtures."""
from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 r=run(query,False);assert not r['ok'] and code in r['error'],r
p='ps'+uuid.uuid4().hex[:16];tokens={}
for role in ['admin','inventory','picker','customer','courier']:
 token=secrets.token_hex(32);uid=p+role;tokens[role]=token
 run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+','.join(map(literal,[uid,uid+'@example.invalid','Fixture '+role,'unused',role]))+",false,true,extract(epoch from clock_timestamp())::bigint*1000);INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(token)+",'sha256'),'hex'),"+literal(uid)+",'unused',extract(epoch from clock_timestamp())::bigint*1000+300000,extract(epoch from clock_timestamp())::bigint*1000);")
supplier=p+'supplier';run("INSERT INTO suppliers(id,name,phone,active) VALUES("+literal(supplier)+",'Fixture retailer','+966500000001',true);")
def write(role,payload,key=None):return rpc('jana_supplier_pickup_site_write',tokens[role],key or 'pickup-'+uuid.uuid4().hex,payload)
def listing(role,limit=50,after=None):return 'SELECT jana_supplier_pickup_sites('+literal(tokens[role])+','+str(limit)+','+('NULL' if after is None else literal(after))+')::text;'
def fingerprints():
 return val("SELECT jsonb_object_agg(name,hash) FROM ("+' UNION ALL '.join("SELECT "+literal(t)+" AS name,md5(coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text)::text,'')) AS hash FROM "+t+" x" for t in ['warehouses','stock_balances','inventory_lots','stock_movements','orders','cash_entries','delivery_slots'])+") x;")
before=fingerprints()
payload=dict(id=None,revision=None,reason='Fixture retailer address',changes=dict(supplier_id=supplier,name='Local shop'))
key='pickup-create-'+uuid.uuid4().hex;site=val(write('inventory',payload,key))
assert site['active'] is False and site['latitude'] is None and site['revision']==1
assert val(write('inventory',payload,key))==site
fails(write('inventory',{**payload,'reason':'Different'},key),'idempotency_conflict')
assert all(x['id']!=site['id'] for x in val(listing('picker'))['items'])
passed('draft site reuses supplier identity with durable retry and no warehouse requirement')
fails(write('admin',dict(id=site['id'],revision=1,reason='Fixture activate',changes=dict(active=True))),'pickup_incomplete')
active=val(write('admin',dict(id=site['id'],revision=1,reason='Fixture checked address',changes=dict(city='Fixture city',address_line='Disposable shop address',latitude=16.5,longitude=42.5,active=True))))
assert active['active'] and active['revision']==2
view=val(listing('picker'));item=next(x for x in view['items'] if x['id']==site['id'])
assert item['supplier_phone']=='+966500000001' and view['suppliers']==[] and not view['can_manage'] and not view['order_flow_ready']
assert 'email' not in item and 'notes' not in item
passed('picker sees active reviewed locations and contact only, not financial supplier metadata')
fails(write('admin',dict(id=site['id'],revision=1,reason='Stale revision',changes=dict(name='Stale'))),'pickup_changed')
queries=[write('admin',dict(id=site['id'],revision=2,reason='Concurrent edit '+str(i),changes=dict(instructions='Fixture '+str(i)))) for i in range(8)]
results=race(queries);assert len(successful(results))==1
assert all(r['ok'] or 'pickup_changed' in r['error'] for r in results)
passed('optimistic revision permits only one concurrent edit without lost updates')
for changes in [dict(name='x'*121),dict(latitude=91,longitude=42),dict(latitude=16),dict(latitude=None,longitude=42),dict(latitude='16',longitude=42),dict(active='true'),dict(warehouse_id='invented')]:
 fails(write('admin',{**payload,'changes':{**payload['changes'],**changes}}),'pickup_validation')
for role in ['picker','customer','courier']:fails(write(role,payload),'forbidden')
for role in ['customer','courier']:fails(listing(role),'forbidden')
passed('validation and existing role boundaries reject malformed or unauthorized writes')
run('UPDATE suppliers SET active=false WHERE id='+literal(supplier)+';')
assert all(x['id']!=site['id'] for x in val(listing('picker'))['items'])
assert any(x['id']==site['id'] for x in val(listing('admin'))['items'])
fails(write('admin',dict(id=site['id'],revision=3,reason='Cannot retarget',changes=dict(supplier_id='other'))),'pickup_supplier_immutable')
passed('supplier deactivation hides sites immediately while preserving recorded history')
page=val(listing('admin',1));assert len(page['items'])==1
if page['next']:assert all(x['id']>page['next'] for x in val(listing('admin',100,page['next']))['items'])
assert val("SELECT count(*) FROM pg_class WHERE oid='public.supplier_pickup_sites'::regclass AND relrowsecurity AND NOT has_table_privilege('anon',oid,'SELECT') AND NOT has_table_privilege('authenticated',oid,'SELECT');")==1
assert val("SELECT count(*) FROM pg_proc WHERE proname IN ('jana_supplier_pickup_sites','jana_supplier_pickup_site_write') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
assert val('SELECT count(*) FROM audit_log WHERE entity_id='+literal(site['id'])+" AND action LIKE 'supplier_pickup_site_%';")==3
assert fingerprints()==before
passed('private grants, pagination, audit and unchanged stock orders slots cash and warehouses')
print(json.dumps(dict(passed=len(checks),checks=checks)))
