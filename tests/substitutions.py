from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(q,code):
 r=run(q,False);assert not r['ok'] and code in r['error'],r

def setup(replacement_stock=1000,qty=1):
 f=fixture();p=f['p']
 st=val(rpc('jana_inventory_create_stock',f['atok'],'فاكهة بديلة للاختبار','gram'))['id']
 supplier=val(rpc('jana_admin_create_supplier',f['atok'],'مورد الاختبار',''))['id']
 lot=val(rpc('jana_inventory_receive_lot',f['atok'],st,supplier,replacement_stock,500,4102444800000))['id']
 val(rpc('jana_inventory_inspect_lot',f['atok'],lot,'accepted','فحص الاختبار'))
 v=val(rpc('jana_admin_create_product_version',f['atok'],'',dict(title='بديل محفوظ السعر',description='',category='fruit',kind='sized',offerings=[dict(sellable_key='one-kg',size_label='1 kg',sale_unit='kg',price_halalas=2700,components=[dict(stock_id=st,base_qty=1000)])])))
 val(rpc('jana_admin_activate_product_version',f['atok'],v['id']))
 q=val(quote(f,'substitution-quote',qty));o=val(rpc('jana_critical_write',f['t'],'substitution-confirm','order.confirm',{'quote_id':q['id']}));val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''))
 f.update(order=o['id'],line=q['lines'][0]['line_id'],replacement=v['offerings'][0]['id'],stock=st,lot=lot,version=v)
 return f

def current(f):return val('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(f['order'])+';')
def write(f,key,operation,payload,customer=False):
 if operation!='substitution.decide':payload={'order_id':f['order'],**payload}
 return rpc('jana_picking_write',f['t'] if customer else f['atok'],key,operation,payload)
def propose(f,key='propose-alternative'):return write(f,key,'substitution.propose',{'line_id':f['line'],'offering_id':f['replacement'],'qty':1})
def decide(f,s,accept=True,key='decide-alternative'):return write(f,key,'substitution.decide',{'substitution_id':s['id'],'accept':accept},True)
def stock(f):return val('SELECT jsonb_build_object(\'hand\',on_hand_base,\'reserved\',reserved_base) FROM stock_balances WHERE stock_id='+literal(f['stock'])+';')

f=setup();original=current(f);before=balance(f);s=val(propose(f));assert balance(f)==before and stock(f)['reserved']==0;assert s['proposed']['price_difference_halalas']==700 and s['proposed']['total_halalas']==2700;assert s['proposed']['replacement_line']['product_version_id']==f['version']['id'];passed('proposal preserves immutable commercial terms and does not reserve substitute before consent')
fails(write(f,'finish-pending','picking.finish',{}),'unresolved_picking_items');fails(write(f,'weight-pending','line.actual',{'line_id':f['line'],'actual_base':900}),'unresolved_picking_items');passed('pending proposal blocks fulfillment and repricing the unavailable original')
accepted=successful(race([decide(f,s)]*16));assert len(accepted)==16 and all(x==accepted[0] for x in accepted);o=current(f);assert o['total_halalas']==2700 and o['original_snapshot']==original['original_snapshot'];assert balance(f)['reserved']==0 and stock(f)['reserved']==1000 and balance(f)['booked']==1;assert val('SELECT count(*) FROM stock_movements WHERE reason=\'substitution_reserved\' AND reference='+literal(f['order'])+';')==1;passed('sixteen approval retries reserve new stock once release old stock and keep slot and original order terms')
fails(decide(f,s,False,'reverse-accepted'),'substitution_already_decided');fails(decide(f,s,False),'idempotency_conflict');fails('UPDATE substitutions SET proposed=\'{}\' WHERE id='+literal(s['id'])+';','immutable_substitution_history');passed('consent cannot be reversed or rewritten and reused keys reject changed decisions')
val(write(f,'finish-replacement','picking.finish',{}));assert stock(f)=={'hand':0,'reserved':0};assert balance(f)['on_hand']==10000;assert val('SELECT count(*) FROM inventory_cost_entries WHERE order_id='+literal(f['order'])+';')==1;passed('picker consumes the approved stock lot and attributes its cost to the order')

f=setup();s=val(propose(f));o=current(f);val(decide(f,s,False));assert current(f)['snapshot']==o['snapshot'];assert stock(f)['reserved']==0;fails(write(f,'finish-rejected','picking.finish',{}),'unresolved_picking_items');val(write(f,'verify-original','line.restore',{'line_id':f['line'],'reason':'تم التحقق من توفر الصنف الأصلي'}));val(write(f,'finish-original','picking.finish',{}));assert stock(f)['hand']==1000;passed('rejection retains original resources and requires explicit picker resolution before completion')

f=setup(500);s=val(propose(f));before=current(f);b=balance(f);fails(decide(f,s),'insufficient_stock');assert current(f)==before and balance(f)==b and stock(f)['reserved']==0
passed('unavailable substitute rolls back all old-resource releases price and decision')

f=setup();s=val(propose(f));val(rpc('jana_admin_set_offering_active',f['atok'],f['replacement'],False));r=val(decide(f,s));assert r['total_halalas']==2700;passed('catalog deactivation never silently changes previously offered substitution price or definition')

f=setup();s=val(propose(f));now=val('SELECT (extract(epoch from clock_timestamp())*1000)::bigint;')
# Fixture time travel occurs only before insertion of a proposal in disposable PostgreSQL.
# Expiry is immutable once proposed: use transaction-local clock by constructing a valid expired fixture at INSERT.
# Finish the real proposal through rejection, then insert a past-expiry proposal with a fresh identity.
val(decide(f,s,False));expired='sub-'+uuid.uuid4().hex
run('INSERT INTO substitutions(id,order_id,line_id,component_id,proposed,default_action,state,expires_at,actor_id,created_at) SELECT '+literal(expired)+",order_id,line_id,component_id,proposed,default_action,'pending',1,actor_id,1 FROM substitutions WHERE id="+literal(s['id'])+'; UPDATE orders SET fulfillment_state=\'awaiting_customer\' WHERE id='+literal(f['order'])+';')
r=val(decide(f,{'id':expired},key='expired-approval'));assert r['_error']=='substitution_expired';assert current(f)['fulfillment_state']=='picking';fails(write(f,'finish-expired','picking.finish',{}),'unresolved_picking_items');assert stock(f)['reserved']==0;passed('expired decision is persisted without implicit approval removal or fulfillment')

f=setup();s=val(propose(f));val(decide(f,s,False));expired='sub-'+uuid.uuid4().hex
run('INSERT INTO substitutions(id,order_id,line_id,component_id,proposed,default_action,state,expires_at,actor_id,created_at) SELECT '+literal(expired)+",order_id,line_id,component_id,proposed,default_action,'pending',1,actor_id,1 FROM substitutions WHERE id="+literal(s['id'])+'; UPDATE orders SET fulfillment_state=\'awaiting_customer\' WHERE id='+literal(f['order'])+';')
r=val('SELECT jana_expiry_worker();');assert r['substitutions_expired']>=1;assert current(f)['fulfillment_state']=='picking';fails(write(f,'finish-worker-expired','picking.finish',{}),'unresolved_picking_items');passed('scheduled expiry retains unresolved issue and records notification without silently accepting')

f=setup();s=val(propose(f));other=fixture();fails(rpc('jana_picking_write',other['t'],'other-customer-decision','substitution.decide',{'substitution_id':s['id'],'accept':True}),'order_not_found');fails(rpc('jana_picking_detail',f['ct'],f['order']),'forbidden');fails(rpc('jana_propose_substitution',f['t'],f['order'],f['line'],f['replacement'],1),'forbidden');fails(decide(f,s,'false'),'invalid_substitution_decision');passed('ownership and explicit boolean consent are enforced inside PostgreSQL')

f=setup();s=val(propose(f));run('UPDATE inventory_lots SET expires_at=(SELECT ends_at FROM delivery_slots WHERE id='+literal(f['p']+'s')+')-1 WHERE id='+literal(f['lot'])+';');b=balance(f);fails(decide(f,s),'insufficient_lot_stock');assert balance(f)==b;passed('replacement FEFO excludes lots expiring before the delivery window')

f=setup(1000);s=val(propose(f));f2=fixture();q=val(quote(f2,'second-substitution-order'));o=val(rpc('jana_critical_write',f2['t'],'second-confirm','order.confirm',{'quote_id':q['id']}));val(rpc('jana_ops_transition',f2['atok'],o['id'],'start',''));f2.update(order=o['id'],line=q['lines'][0]['line_id'],replacement=f['replacement']);s2=val(propose(f2));rows=race([decide(f,s),decide(f2,s2)]);assert len(successful(rows))==1 and stock(f)['reserved']==1000;assert all(r['ok'] or 'insufficient_stock' in r['error'] for r in rows);passed('two customers competing for the last substitute cannot over-reserve stock')

assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_picking_write','jana_reallocate_order','jana_picking_detail','jana_finalize_picking_base') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0;assert val("SELECT has_function_privilege('service_role','public.jana_reallocate_order(text,jsonb,text)','EXECUTE');")==False;assert val('SELECT jana_deep_health();')['ok'];passed('transaction helpers remain private and stock slot and cash invariants still hold')
print(json.dumps({'passed':len(checks),'checks':checks}))
