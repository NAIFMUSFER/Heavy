"""Explicit published store ONLY for disposable PostgreSQL; no production seed."""
from database_support import *
POLICY='Disposable automated test policy. This is fixture text for local CI only and is not a commercial policy.'
PROFILE=dict(display_name='Fixture store',legal_name='Fixture legal entity',registration_type='other_license',registration_number='FIXTURE-ONLY',business_address='Disposable local database',phone='+966500000001',email='store@example.invalid',support_hours='Fixture support hours',tax_status='not_registered',tax_number='',terms=POLICY,privacy=POLICY,delivery=POLICY,returns=POLICY)
REVIEWED=dict(catalog=True,supplier_sites=True,procurement=True,delivery=True,tax=True,operations=True)
def get_store(f):return val(rpc('jana_admin_storefront',f['atok']))
def write_store(f,operation,payload,key=None):
 return val(rpc('jana_storefront_write',f['atok'],key or 'fixture-'+uuid.uuid4().hex,operation,payload))
def intake(f,opening):
 s=get_store(f);return write_store(f,'intake.set',dict(revision=s['revision'],accepting_orders=opening,message='Fixture ordering is open' if opening else 'Fixture ordering is paused',reason='Disposable verification',reference='CI-FIXTURE-ONLY',reviewed=REVIEWED))
def bootstrap_store():
 f=fixture();s=get_store(f)
 assert s['accepting_orders'] is False and s['published'] is None,'Production migration must default closed and unpublished'
 run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+','.join(map(literal,[f['p']+'picker',f['p']+'picker@example.invalid','Fixture purchasing employee','unused','picker']))+",false,true,extract(epoch from clock_timestamp())::bigint*1000);INSERT INTO suppliers(id,name,phone,active) VALUES("+literal(f['p']+'supplier')+",'Fixture retailer','+966500000001',true);")
 val(rpc('jana_supplier_pickup_site_write',f['atok'],'fixture-launch-pickup',dict(id=None,revision=None,reason='Disposable supplier pickup setup',changes=dict(supplier_id=f['p']+'supplier',name='Fixture pickup shop',city='Fixture city',address_line='Disposable database only',latitude=16.5,longitude=42.5,instructions='Fixture only',active=True))))
 warehouse=val(rpc('jana_delivery_admin_write',f['atok'],'fixture-launch-warehouse','warehouse.save',dict(id=None,revision=None,reason='Disposable warehouse setup',changes=dict(name='Fixture launch warehouse',city='Fixture city',address_line='Disposable database only',latitude=16.5,longitude=42.5,active=True))))
 val(rpc('jana_delivery_admin_write',f['atok'],'fixture-launch-route','zone.save',dict(id=f['p']+'z',revision=1,reason='Disposable warehouse route',changes=dict(warehouse_id=warehouse['id']))))
 s=write_store(f,'draft.save',dict(revision=s['revision'],profile=PROFILE))
 assert s['draft']==PROFILE and s['revision']==1
 s=write_store(f,'profile.publish',dict(revision=s['revision'],confirmed=True))
 assert s['published']['version']==1
 intake(f,True)
 # Keep catalog fixtures owned by individual suites; bootstrap does not add a visible item.
 run('UPDATE offerings SET active=false WHERE id='+literal(f['p']+'off')+';')
 print('Disposable store explicitly configured through canonical admin RPCs')
if __name__=='__main__':bootstrap_store()
