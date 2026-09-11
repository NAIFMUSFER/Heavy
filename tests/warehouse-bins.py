"""Reference warehouse-bin placement in disposable PostgreSQL only."""
from storefront_fixture import *

checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 r=run(query,False);assert not r['ok'] and code in r['error'],r
def write(token,key,operation,payload):return rpc('jana_inventory_bin_write',token,key,operation,payload)

f=fixture();warehouse=val("SELECT to_jsonb(w) FROM warehouses w WHERE active;")
create_key='bin-create-'+uuid.uuid4().hex
draft_payload=dict(id=None,revision=None,reason='Disposable shelf setup',changes=dict(warehouse_id=warehouse['id'],code='a-01-01',label='Fixture cold shelf',active=False))
draft=val(write(f['atok'],create_key,'bin.save',draft_payload))
assert draft['code']=='A-01-01' and draft['active'] is False and draft['revision']==1
assert val(write(f['atok'],create_key,'bin.save',draft_payload))==draft
fails(write(f['atok'],create_key,'bin.save',{**draft_payload,'reason':'Different request'}),'idempotency_conflict')
passed('bin creation is inactive by default, canonicalized, and idempotent')

active=val(write(f['atok'],'bin-activate-'+uuid.uuid4().hex,'bin.save',dict(id=draft['id'],revision=draft['revision'],reason='Disposable shelf activation',changes=dict(active=True))))
assert active['active'] and active['revision']==2
fails(write(f['atok'],'bin-stale-'+uuid.uuid4().hex,'bin.save',dict(id=draft['id'],revision=1,reason='Disposable stale update',changes=dict(label='Stale'))),'bin_changed')
fails(write(f['atok'],'bin-code-'+uuid.uuid4().hex,'bin.save',dict(id=None,revision=None,reason='Disposable invalid code',changes=dict(warehouse_id=warehouse['id'],code='رف ١',active=False))),'bin_validation')
passed('activation requires current revision and operational ASCII shelf codes')

before=val("SELECT jsonb_build_object('balance',to_jsonb(b),'lots',coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM inventory_lots l WHERE l.stock_id=b.stock_id),'[]'::jsonb)) FROM stock_balances b WHERE b.stock_id="+literal(f['p']+'st')+';')
assigned=val(write(f['atok'],'bin-assign-'+uuid.uuid4().hex,'stock.assign_bin',dict(stock_id=f['p']+'st',bin_id=active['id'],reason='Disposable shelf assignment')))
assert assigned['bin_code']=='A-01-01'
after=val("SELECT jsonb_build_object('balance',to_jsonb(b),'lots',coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM inventory_lots l WHERE l.stock_id=b.stock_id),'[]'::jsonb)) FROM stock_balances b WHERE b.stock_id="+literal(f['p']+'st')+';')
assert before==after
catalog=val(rpc('jana_admin_catalog',f['atok']))
stock=next(x for x in catalog['stock'] if x['id']==f['p']+'st');bin_view=next(x for x in catalog['warehouse_bins'] if x['id']==active['id'])
assert stock['bin_id']==active['id'] and stock['bin_code']=='A-01-01' and bin_view['assigned_count']==1
passed('assignment is visible to operations without changing balances or lots')

fails(write(f['atok'],'bin-stop-assigned-'+uuid.uuid4().hex,'bin.save',dict(id=active['id'],revision=active['revision'],reason='Disposable assigned stop',changes=dict(active=False))),'bin_assigned')
unassigned=val(write(f['atok'],'bin-unassign-'+uuid.uuid4().hex,'stock.assign_bin',dict(stock_id=f['p']+'st',bin_id=None,reason='Disposable shelf removal')))
assert unassigned['bin_id'] is None
stopped=val(write(f['atok'],'bin-stop-'+uuid.uuid4().hex,'bin.save',dict(id=active['id'],revision=active['revision'],reason='Disposable shelf stop',changes=dict(active=False))))
assert stopped['active'] is False and stopped['revision']==3
passed('assigned bins cannot stop until every stock reference is removed')

inventory_token=secrets.token_hex(32);inventory_id=f['p']+'i'
run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+','.join(map(literal,[inventory_id,inventory_id+'@example.invalid','Fixture inventory','unused','inventory']))+",false,true,extract(epoch from clock_timestamp())::bigint*1000);INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(inventory_token)+",'sha256'),'hex'),"+literal(inventory_id)+",'unused',extract(epoch from clock_timestamp())::bigint*1000+60000,extract(epoch from clock_timestamp())::bigint*1000);")
inventory_draft=val(write(inventory_token,'bin-inventory-'+uuid.uuid4().hex,'bin.save',dict(id=None,revision=None,reason='Disposable inventory role',changes=dict(warehouse_id=warehouse['id'],code='B-02',active=False))))
assert inventory_draft['code']=='B-02'
fails(write(f['t'],'bin-customer-'+uuid.uuid4().hex,'bin.save',draft_payload),'forbidden')
fails(write(f['ct'],'bin-courier-'+uuid.uuid4().hex,'bin.save',draft_payload),'forbidden')
passed('admin and inventory roles can maintain bins while customers and couriers cannot')

assert val("SELECT count(*) FROM pg_class c WHERE c.relname IN ('warehouse_bins','stock_item_bins') AND (has_table_privilege('anon',c.oid,'SELECT') OR has_table_privilege('authenticated',c.oid,'SELECT'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_admin_catalog_pre_bins' AND has_function_privilege('service_role',oid,'EXECUTE');")==0
assert val("SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='stock_item_bins' AND indexdef LIKE '%(assigned_by)%';")>=1
assert val("SELECT count(*) FROM audit_log WHERE entity_id="+literal(active['id'])+" AND action IN ('warehouse_bin_created','warehouse_bin_updated');")>=2
assert val('SELECT jana_deep_health();')['ok']
passed('RLS grants, private wrapper, audit trail, and deep health remain intact')
print(json.dumps(dict(passed=len(checks),checks=checks)))
