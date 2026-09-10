from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(q,code):
 r=run(q,False);assert not r['ok'] and code in r['error'],r

def definition(f,under=2000,over=2000,**extra):
 return dict(title='وزن مضبوط للاختبار',description='',category='fruit',kind='sized',offerings=[dict(sellable_key='one-kg',size_label='1 kg',sale_unit='kg',price_halalas=2000,weight_under_bps=under,weight_over_bps=over,components=[dict(stock_id=f['p']+'st',base_qty=1000)],**extra)])
def version(f,under=2000,over=2000):
 v=val(rpc('jana_admin_create_product_version',f['atok'],'',definition(f,under,over)));val(rpc('jana_admin_activate_product_version',f['atok'],v['id']));return v

def setup(stock=10000,qty=1,under=2000,over=2000,coupon=False):
 f=fixture(stock=stock);v=version(f,under,over);f.update(version=v,offering=v['offerings'][0]['id']);return order(f,qty,coupon)
def order(f,qty=1,coupon=False):
 f=dict(f);key='weight-'+uuid.uuid4().hex
 items=[dict(offering_id=f['offering'],qty=qty)]
 if coupon:
  code='W'+uuid.uuid4().hex[:12].upper();val(rpc('jana_admin_create_coupon_v2',f['atok'],code,1,0,10,4102444800000,'percentage',1000))
  q=val('SELECT jana_create_quote_with_coupon('+','.join(map(literal,[f['t'],key,f['p']+'s',f['p']+'addr']))+','+literal(json.dumps(items))+'::jsonb,'+literal(code)+');')
 else:q=val('SELECT jana_create_quote_idempotent('+','.join(map(literal,[f['t'],key,f['p']+'s',f['p']+'addr']))+','+literal(json.dumps(items))+'::jsonb);')
 o=val(rpc('jana_critical_write',f['t'],'confirm-'+uuid.uuid4().hex,'order.confirm',dict(quote_id=q['id'])));val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''))
 f.update(order=o['id'],line=q['lines'][0]['line_id'],quote=q);return f

def current(f):return val('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(f['order'])+';')
def actual(f,n,key=None):return rpc('jana_picking_write',f['atok'],key or 'actual-'+uuid.uuid4().hex,'line.actual',dict(order_id=f['order'],line_id=f['line'],actual_base=n))
def finish(f):return val(rpc('jana_picking_write',f['atok'],'finish-'+uuid.uuid4().hex,'picking.finish',dict(order_id=f['order'])))

f=setup(qty=2);policy=f['quote']['lines'][0]['weight_policy'];assert policy==dict(under_bps=2000,over_bps=2000,target_base=2000,min_base=1600,max_base=2400,base_unit='gram',overage_pricing='included');assert f['quote']['total_halalas']==4000;assert balance(f)['reserved']==2000;passed('quote freezes quantity-scaled integer bounds and capped price in immutable commercial terms')
original=current(f);before=balance(f)
for amount in [0,1599,2401]:fails(actual(f,amount),'invalid_actual_weight')
fails(rpc('jana_picker_record_actual',f['atok'],f['order'],f['line'],None).replace("'None'",'NULL'),'invalid_actual_weight');assert current(f)==original and balance(f)==before;passed('out-of-range and null weights leave the full order and reservations unchanged')

f=fixture()
for under,over in [(10001,0),(0,2001),(-1,0),(0,-1),(1.5,100),(True,100),(None,100),('2000',100)]:fails(rpc('jana_admin_create_product_version',f['atok'],'',definition(f,under,over)),'invalid_weight_policy')
st=val(rpc('jana_inventory_create_stock',f['atok'],'قطعة اختبار الوزن','piece'))['id'];d=definition(f);d['offerings'][0]['components'][0]['stock_id']=st;fails(rpc('jana_admin_create_product_version',f['atok'],'',d),'invalid_weight_policy');passed('policy validation rejects untyped fractional excessive and non-weighted configurations')
v=version(f,1500,500);copy=val(rpc('jana_admin_create_product_version',f['atok'],v['family_id'],dict(copy_version_id=v['id'])));assert copy['offerings'][0]['weight_under_bps']==1500 and copy['offerings'][0]['weight_over_bps']==500;fails('UPDATE offerings SET weight_over_bps=0 WHERE id='+literal(v['offerings'][0]['id'])+';','create_a_new_offering_version');passed('version copy preserves policy and existing sellable definitions cannot be rewritten')

f=setup(stock=1500);original=current(f)['original_snapshot'];rows=successful(race([actual(f,1200,'same-extra-weight')]*12));assert len(rows)==12 and all(x==rows[0] for x in rows);o=current(f);assert o['total_halalas']==2000 and o['snapshot']['total_halalas']==2000 and o['original_snapshot']==original;assert balance(f)['reserved']==1200;assert val('SELECT count(*) FROM stock_movements WHERE reference='+literal(f['order'])+" AND reason='weight_reserved';")==1;fails(actual(f,1100,'same-extra-weight'),'idempotency_conflict');passed('concurrent same-key overfill retries reserve real stock once without increasing customer price')
finish(f);assert balance(f)['on_hand']==300 and balance(f)['reserved']==0;assert val('SELECT sum(-on_hand_delta) FROM stock_movements WHERE reference='+literal(f['order'])+" AND on_hand_delta<0;")==1200;assert val('SELECT count(*) FROM inventory_cost_entries WHERE order_id='+literal(f['order'])+';')>=1;passed('picking consumes and costs the actual additional weight from accepted FEFO lots')

f=setup(stock=1000);original=current(f);b=balance(f);fails(actual(f,1100),'insufficient_stock');assert current(f)==original and balance(f)==b;passed('insufficient extra stock rolls back release reallocation price and audit together')

f=setup();val(actual(f,900));assert current(f)['total_halalas']==1800 and current(f)['snapshot']['total_halalas']==1800;val(actual(f,1100));assert current(f)['total_halalas']==2000 and balance(f)['reserved']==1100;val(actual(f,800));assert current(f)['total_halalas']==1600 and balance(f)['reserved']==800;finish(f);assert balance(f)['on_hand']==9200;passed('lower weight reprices proportionally and revising an overfill releases surplus without exceeding quote price')

f=setup(coupon=True);val(actual(f,1200));assert current(f)['total_halalas']==1800 and current(f)['snapshot']['discount_halalas']==200;val(actual(f,900));assert current(f)['total_halalas']==1620 and current(f)['snapshot']['total_halalas']==1620;passed('overfill cap and lower-weight pricing retain the original percentage discount')

f=setup();original=current(f)['original_snapshot'];v=f['version'];d=definition(f,0,0);d['copy_version_id']=v['id'];new=val(rpc('jana_admin_create_product_version',f['atok'],v['family_id'],d));val(rpc('jana_admin_activate_product_version',f['atok'],new['id']));val(actual(f,1100));assert current(f)['original_snapshot']==original;f2=order({**f,'offering':new['offerings'][0]['id']});fails(actual(f2,1100),'invalid_actual_weight');fails(actual(f2,999),'invalid_actual_weight');passed('later catalog policy changes govern new orders only and preserve sold-version weight rights')

f=setup();replacement=version(f,1000,1000);sub=val(rpc('jana_picking_write',f['atok'],'weight-substitution','substitution.propose',dict(order_id=f['order'],line_id=f['line'],offering_id=replacement['offerings'][0]['id'],qty=1)));assert sub['proposed']['replacement_line']['weight_policy']['max_base']==1100;val(rpc('jana_picking_write',f['t'],'weight-sub-accept','substitution.decide',dict(substitution_id=sub['id'],accept=True)));fails(actual(f,899),'invalid_actual_weight');val(actual(f,1100));assert balance(f)['reserved']==1100;passed('customer-approved replacement carries its own frozen weight policy before any picking change')

f=setup(stock=2200);f2=order(f);rows=race([actual(f,1200),actual(f2,1200)]);assert len(successful(rows))==1 and all(r['ok'] or 'insufficient_stock' in r['error'] for r in rows);assert balance(f)['reserved']==2200;finish(f);finish(f2);assert balance(f)['on_hand']==0 and balance(f)['reserved']==0;passed('competing orders cannot both consume the last extra weight or over-reserve stock')

f=setup(stock=1000);lot=val(rpc('jana_inventory_receive_lot',f['atok'],f['p']+'st','',200,100,4102444800000).replace("'','200'","NULL,'200'"))['id'];val(rpc('jana_inventory_inspect_lot',f['atok'],lot,'accepted','فحص الاختبار'));run('UPDATE inventory_lots SET expires_at=(SELECT ends_at FROM delivery_slots WHERE id='+literal(f['p']+'s')+')-1 WHERE id='+literal(lot)+';');o=current(f);b=balance(f);fails(actual(f,1100),'insufficient_lot_stock');assert current(f)==o and balance(f)==b;passed('overfill excludes lots expiring before delivery and preserves all original allocations on failure')

assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_weight_terms','jana_reallocate_order','jana_picker_record_actual') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
assert val("SELECT to_jsonb(has_function_privilege('service_role','jana_reallocate_order(text,jsonb,text,text)','EXECUTE'));")==False
assert val("SELECT to_jsonb(has_function_privilege('service_role','jana_weight_terms(text,integer)','EXECUTE'));")==False
assert val('SELECT jana_deep_health();')['ok'];passed('weight and allocation helpers remain private and all production invariants hold')
print(json.dumps(dict(passed=len(checks),checks=checks)))
