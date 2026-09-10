"""Actual component evidence against the disposable PostgreSQL commerce workflow."""
from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(q,code):
 r=run(q,False);assert not r['ok'] and code in r['error'],r
def current(f):return val('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(f['order'])+';')
def version(f,price=2000):
 v=val(rpc('jana_admin_create_product_version',f['atok'],'',dict(title='سلة مكونات اختبار',description='',category='fruit',kind='basket',offerings=[dict(sellable_key='basket',size_label='سلة',sale_unit='basket',price_halalas=price,components=[dict(stock_id=f['p']+'st',base_qty=1000),dict(stock_id=f['piece'],base_qty=3)])])))
 val(rpc('jana_admin_activate_product_version',f['atok'],v['id']));return v['offerings'][0]['id']
def setup(qty=2):
 f=fixture();f['piece']=val(rpc('jana_inventory_create_stock',f['atok'],'قطع السلة','piece'))['id']
 lot=val(rpc('jana_inventory_receive_lot',f['atok'],f['piece'],'',100,1000,4102444800000).replace("'','100'","NULL,'100'"))['id']
 val(rpc('jana_inventory_inspect_lot',f['atok'],lot,'accepted','فحص اختبار السلة'))
 offering=version(f);items=[dict(offering_id=offering,qty=qty)]
 q=val('SELECT jana_create_quote_idempotent('+','.join(map(literal,[f['t'],'basket-quote',f['p']+'s',f['p']+'addr']))+','+literal(json.dumps(items))+'::jsonb);')
 o=val(rpc('jana_critical_write',f['t'],'basket-confirm','order.confirm',dict(quote_id=q['id'])))
 val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''))
 f.update(order=o['id'],line=q['lines'][0]['line_id'],quote=q,qty=qty,offering=offering);return f
def payload(f,gram=None,pieces=None):
 return dict(order_id=f['order'],line_id=f['line'],revision=current(f)['picking_revision'],items=[dict(stock_id=f['p']+'st',actual_base=f['qty']*1000 if gram is None else gram),dict(stock_id=f['piece'],actual_base=f['qty']*3 if pieces is None else pieces)])
def record(f,p=None,key=None,token=None):return rpc('jana_picker_record_components',token or f['atok'],key or 'component-'+uuid.uuid4().hex,p or payload(f))
def finish(f,key=None):return rpc('jana_picking_write',f['atok'],key or 'basket-finish-'+uuid.uuid4().hex,'picking.finish',dict(order_id=f['order']))
def stock_state(f):
 return val("SELECT jsonb_agg(to_jsonb(b) ORDER BY stock_id) FROM stock_balances b WHERE stock_id IN ("+literal(f['p']+'st')+','+literal(f['piece'])+');')
def movements(f):return val('SELECT count(*) FROM stock_movements WHERE reference='+literal(f['order'])+';')

f=setup();before=current(f);b=stock_state(f);n=movements(f)
for q in [finish(f),rpc('jana_finalize_picking',f['atok'],f['order']),rpc('jana_ops_transition',f['atok'],f['order'],'ready','')]:fails(q,'basket_components_unresolved')
assert current(f)==before and stock_state(f)==b and movements(f)==n
passed('all finishing entry points require component measurements and leave missing evidence unshipped')

bad=[]
for amount in [None,True,'2000',-1,1.5,20000000001]:
 p=payload(f);p['items'][0]['actual_base']=amount;bad.append(p)
for field in ['revision','line_id','items']:
 p=payload(f);del p[field];bad.append(p)
for value in [None,False,'1',-1,1.5]:
 p=payload(f);p['revision']=value;bad.append(p)
p=payload(f);p['items'][1]=p['items'][0];bad.append(p)
p=payload(f);p['items'][0]['stock_id']='unrelated';bad.append(p)
p=payload(f);p['items'][0]['price']=1;bad.append(p)
p=payload(f);p['items']=[[],{}];bad.append(p)
p=payload(f);p['price']=1;bad.append(p)
for p in bad:fails(record(f,p),'invalid_component_check')
assert current(f)==before and stock_state(f)==b and movements(f)==n
passed('strict typed complete component sets reject duplicates unknown stock fractions omitted fields and price injection atomically')

for grams,pieces in [(0,6),(1999,6),(2001,6),(2000,5),(2000,7)]:
 r=val(record(f,payload(f,grams,pieces)));assert not r['matches'];fails(finish(f),'basket_components_unresolved')
 o=current(f);assert o['total_halalas']==before['total_halalas'] and o['original_snapshot']==before['original_snapshot']
 assert o['snapshot']['allocations']==before['snapshot']['allocations'] and stock_state(f)==b and movements(f)==n
passed('zero shortages and excess are retained as evidence while price reservations stock and original terms remain unchanged')

r=val(record(f));assert r['matches'];assert r['component_check']['items'][0]['planned_base']==2000 and r['component_check']['items'][1]['planned_base']==6
val(finish(f));assert balance(f)['on_hand']==8000 and balance(f)['reserved']==0
assert val('SELECT on_hand_base FROM stock_balances WHERE stock_id='+literal(f['piece'])+';')==94
assert current(f)['total_halalas']==4000 and current(f)['original_snapshot']==before['original_snapshot']
assert val('SELECT sum(-on_hand_delta) FROM stock_movements WHERE reference='+literal(f['order'])+" AND reason='order_picked' AND stock_id="+literal(f['p']+'st')+';')==2000
assert val('SELECT count(*) FROM inventory_cost_entries WHERE order_id='+literal(f['order'])+';')==2
passed('complete quantity-scaled gram and piece checks consume and cost exactly the sold quantities once')

f=setup();p=payload(f);query=record(f,p,'concurrent-component-retry');rows=successful(race([query]*12));assert len(rows)==12 and all(x==rows[0] for x in rows)
assert val("SELECT count(*) FROM audit_log WHERE action='basket_components_recorded' AND entity_id="+literal(f['order'])+';')==1
assert val("SELECT count(*) FROM order_events WHERE event='basket_components_recorded' AND order_id="+literal(f['order'])+';')==1
p2={**p,'items':[{**p['items'][0],'actual_base':1999},p['items'][1]]};fails(record(f,p2,'concurrent-component-retry'),'idempotency_conflict')
passed('concurrent same-key retries produce one measurement event audit and immutable original response')
val(finish(f));assert val(query)==rows[0];fails(record(f),'invalid_transition')
passed('original retry remains available after finishing but new measurements cannot change a prepared order')

f=setup();p=payload(f);p2={**p,'items':[{**p['items'][0],'actual_base':1999},p['items'][1]]};rows=race([record(f,p),record(f,p2)])
assert len(successful(rows))==1 and all(x['ok'] or 'component_check_changed' in x['error'] for x in rows)
assert current(f)['picking_revision']==p['revision']+1
passed('competing measurements from the same revision cannot overwrite one another')

f=setup();val(record(f));b=stock_state(f);p=payload(f,1999);rows=race([record(f,p),finish(f)])
o=current(f)
if o['fulfillment_state']=='ready':
 assert not rows[0]['ok'] and rows[1]['ok'];assert balance(f)['on_hand']==8000
else:
 assert rows[0]['ok'] and not rows[1]['ok'] and 'basket_components_unresolved' in rows[1]['error'];assert stock_state(f)==b
passed('measurement versus finishing serializes so a saved shortage can never be shipped')

f=setup();p=payload(f)
for t in [f['t'],f['ct']]:fails(record(f,p,token=t),'forbidden')
staff=val(rpc('jana_staff_write',f['atok'],'basket-test-picker','staff.create',dict(email=f['p']+'@example.invalid',name='Basket picker',password='Fixture-only-password-12!',role='picker')))
t=secrets.token_hex(32);run("INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(t)+",'sha256'),'hex'),"+literal(staff['id'])+",'unused',4102444800000,0);")
fails(record(f,p,token=t),'order_not_assigned')
val(rpc('jana_staff_write',f['atok'],'basket-assign-picker','order.assign',dict(order_id=f['order'],assignments=dict(picker_id=staff['id']),reason='Assign actual basket picker')))
fails(record(f,p,token=t),'component_check_changed');assert val(record(f,token=t))['matches']
passed('customer courier and unassigned picker cannot record while assigned picker uses a fresh revision')

f=setup();val(record(f));stale=payload(f);original=current(f)['original_snapshot'];replacement=version(f,2200)
sub=val(rpc('jana_picking_write',f['atok'],'basket-sub-propose','substitution.propose',dict(order_id=f['order'],line_id=f['line'],offering_id=replacement,qty=2)))
fails(record(f,stale),'invalid_transition')
val(rpc('jana_picking_write',f['t'],'basket-sub-accept','substitution.decide',dict(substitution_id=sub['id'],accept=True)))
fails(record(f,stale),'component_check_changed');fails(finish(f),'basket_components_unresolved')
assert 'component_check' not in current(f)['snapshot']['lines'][0]
assert val(record(f))['matches'];val(finish(f));assert current(f)['total_halalas']==4400 and current(f)['original_snapshot']==original
passed('customer-approved replacement requires its own component evidence and invalidates the old form without changing original terms')

f=setup();p=payload(f);val(rpc('jana_picking_issue',f['atok'],f['order'],f['line'],'Unavailable during physical check',False))
fails(record(f),'unresolved_picking_items')
val(rpc('jana_picking_issue',f['atok'],f['order'],f['line'],'Physically restored original goods',True))
fails(record(f,p),'component_check_changed');assert val(record(f))['matches']
passed('unavailable and restored item transitions invalidate previously loaded measurement forms')

assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_picker_record_components','jana_basket_components_match','jana_order_picking_revision','jana_issue_picking_revision') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_basket_components_match','jana_order_picking_revision','jana_issue_picking_revision') AND has_function_privilege('service_role',oid,'EXECUTE');")==0
assert val('SELECT jana_deep_health();')['ok']
passed('internal helpers remain private and the real database invariants hold')
print(json.dumps(dict(passed=len(checks),checks=checks)))
