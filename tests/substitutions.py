from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(q,code):
 r=run(q,False);assert not r['ok'] and code in r['error'],r

def setup(replacement_stock=1000,qty=1,coupon=False):
 f=fixture();p=f['p']
 st=val(rpc('jana_inventory_create_stock',f['atok'],'فاكهة بديلة للاختبار','gram'))['id']
 supplier=val(rpc('jana_admin_create_supplier',f['atok'],'مورد الاختبار',''))['id']
 lot=val(rpc('jana_inventory_receive_lot',f['atok'],st,supplier,replacement_stock,500,4102444800000))['id']
 val(rpc('jana_inventory_inspect_lot',f['atok'],lot,'accepted','فحص الاختبار'))
 v=val(rpc('jana_admin_create_product_version',f['atok'],'',dict(title='بديل محفوظ السعر',description='',category='fruit',kind='sized',offerings=[dict(sellable_key='one-kg',size_label='1 kg',sale_unit='kg',price_halalas=2700,components=[dict(stock_id=st,base_qty=1000)])])))
 val(rpc('jana_admin_activate_product_version',f['atok'],v['id']))
 if coupon:
  cp=val(rpc('jana_admin_create_coupon_v2',f['atok'],'S'+p.upper(),1,0,20,4102444800000,'percentage',1000))
  q=val('SELECT jana_create_quote_with_coupon('+','.join(map(literal,[f['t'],'substitution-coupon',p+'s',p+'addr']))+','+literal(json.dumps([{'offering_id':p+'off','qty':qty}]))+'::jsonb,'+literal('S'+p.upper())+');')
 else:q=val(quote(f,'substitution-quote',qty))
 o=val(rpc('jana_critical_write',f['t'],'substitution-confirm','order.confirm',{'quote_id':q['id']}));val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''))
 f.update(order=o['id'],line=q['lines'][0]['line_id'],replacement=v['offerings'][0]['id'],stock=st,lot=lot,version=v)
 return f

def current(f):return val('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(f['order'])+';')
def write(f,key,operation,payload,customer=False):
 if operation!='substitution.decide':payload={'order_id':f['order'],**payload}
 return rpc('jana_picking_write',f['t'] if customer else f['atok'],key,operation,payload)
def propose(f,key='propose-alternative'):return write(f,key,'substitution.propose',{'line_id':f['line'],'offering_id':f['replacement'],'qty':1})
def decide(f,s,accept=True,key='decide-alternative'):return write(f,key,'substitution.decide',{'substitution_id':s['id'],'accept':accept},True)
def stock(f):return val('SELECT jsonb_build_object(\'hand\',on_hand_base,\'reserved\',reserved_base) FROM stock_balances WHERE stock_id='+literal(f['stock'])+';')

def setup_removal():
 f=fixture();p=f['p'];now=val('SELECT (extract(epoch from clock_timestamp())*1000)::bigint;')
 components=json.dumps([{'stock_id':p+'2st','base_unit':'gram','name':'الصنف الثاني','base_qty':1000}])
 run("INSERT INTO stock_items(id,name,base_unit,active) VALUES("+literal(p+'2st')+",'صنف ثان للاختبار','gram',true);"
  "INSERT INTO stock_balances(stock_id,on_hand_base,reserved_base) VALUES("+literal(p+'2st')+",5000,0);"
  "INSERT INTO inventory_lots(id,stock_id,received_base,on_hand_base,reserved_base,total_cost_halalas,remaining_cost_halalas,expires_at,inspection_state,received_by,inspection_note,created_at) VALUES("+','.join([literal(p+'2lot'),literal(p+'2st'),'5000','5000','0','500','500','4102444800000',literal('accepted'),literal(p+'a'),literal('فحص اختبار الحذف'),str(now)])+");"
  "INSERT INTO offerings(id,family_id,version,kind,name,description,category,size_label,emoji,image_url,sale_unit,price_halalas,components,active,created_at) VALUES("+','.join([literal(p+'2off'),literal(p+'2fam'),'1',literal('individual'),literal('الصنف الباقي'),literal(''),literal('fruit'),literal('1 kg'),literal(''),literal(''),literal('kg'),'1000',literal(components)+'::json','true',str(now)])+");")
 items=[{'offering_id':p+'off','qty':1},{'offering_id':p+'2off','qty':1}]
 q=val('SELECT jana_create_quote_idempotent('+','.join(map(literal,[f['t'],'line-removal-quote',p+'s',p+'addr']))+','+literal(json.dumps(items))+'::jsonb);')
 o=val(rpc('jana_critical_write',f['t'],'line-removal-confirm','order.confirm',{'quote_id':q['id']}));val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''))
 f.update(order=o['id'],line=q['lines'][0]['line_id'],kept_line=q['lines'][1]['line_id'],second_stock=p+'2st',quote=q)
 return f

def propose_removal(f,key='propose-line-removal'):return write(f,key,'line.removal.propose',{'line_id':f['line']})

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


f=setup(coupon=True);s=val(propose(f));assert s['proposed']['original_total_halalas']==1800 and s['proposed']['total_halalas']==2430 and s['proposed']['price_difference_halalas']==630;val(decide(f,s));assert current(f)['total_halalas']==2430;val(write(f,'actual-replacement-weight','line.actual',{'line_id':f['line'],'actual_base':900}));assert current(f)['total_halalas']==2187;val(write(f,'finish-weighted-replacement','picking.finish',{}));assert stock(f)=={'hand':100,'reserved':0};passed('approved substitute and actual lower weight preserve immutable percentage discount terms')

f=setup();s=val(propose(f));rows=race([decide(f,s),rpc('jana_inventory_adjust_lot',f['atok'],f['lot'],500,'Physical count during reservation')]);assert len(successful(rows))==1;assert all(r['ok'] or any(code in r['error'] for code in ['insufficient_stock','validation']) for r in rows);assert stock(f)['reserved']<=stock(f)['hand'];passed('inventory adjustment and approval share balance-first locks and preserve reserved bounds')

f=setup_removal();original=current(f);before=balance(f);s=val(propose_removal(f));assert s['proposed']['action']=='remove_line' and s['proposed']['original_total_halalas']==3000 and s['proposed']['total_halalas']==1000 and s['proposed']['price_difference_halalas']==-2000;assert current(f)['snapshot']==original['snapshot'] and balance(f)==before;passed('line removal proposal freezes the exact lower total without changing price or inventory before consent')
accepted=successful(race([decide(f,s)]*16));assert len(accepted)==16 and all(x==accepted[0] for x in accepted) and accepted[0]['action']=='remove_line';o=current(f);assert len(o['snapshot']['lines'])==1 and o['snapshot']['lines'][0]['line_id']==f['kept_line'] and o['total_halalas']==1000 and o['original_snapshot']==original['original_snapshot'];assert balance(f)['reserved']==0;assert val('SELECT reserved_base FROM stock_balances WHERE stock_id='+literal(f['second_stock'])+';')==1000;assert val("SELECT count(*) FROM stock_movements WHERE reason='line_removal_reserved' AND reference="+literal(f['order'])+';')==1;assert val("SELECT to_jsonb(state='removed') FROM picking_line_issues WHERE order_id="+literal(f['order'])+' AND line_id='+literal(f['line'])+';');passed('concurrent approval retries remove one line once release its reservation and retain the remaining line')
detail=val(rpc('jana_order_detail',f['t'],f['order']));assert [x['event'] for x in detail['timeline'] if x['event'].startswith('line_removal_')]==['line_removal_proposed','line_removal_accepted'];val(write(f,'finish-after-line-removal','picking.finish',{}));assert val('SELECT on_hand_base FROM stock_balances WHERE stock_id='+literal(f['p']+'st')+';')==10000;assert val('SELECT on_hand_base FROM stock_balances WHERE stock_id='+literal(f['second_stock'])+';')==4000;passed('accepted removal is visible in customer history and consumes only the retained item')

f=setup_removal();s=val(propose_removal(f));before=current(f);val(decide(f,s,False));assert current(f)['snapshot']==before['snapshot'];fails(write(f,'finish-rejected-removal','picking.finish',{}),'unresolved_picking_items');passed('rejected removal leaves the sold line and its reservation unresolved for explicit picker action')

f=setup();fails(write(f,'remove-only-line','line.removal.propose',{'line_id':f['line']}),'cannot_remove_last_line');passed('the last order line cannot be removed into an empty delivery')

assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_picking_write','jana_reallocate_order','jana_picking_detail','jana_finalize_picking_base','jana_propose_line_removal') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0;assert val("SELECT to_jsonb(has_function_privilege('service_role','public.jana_reallocate_order(text,jsonb,text)','EXECUTE'));")==False;assert val('SELECT jana_deep_health();')['ok'];passed('transaction helpers remain private and stock slot and cash invariants still hold')
print(json.dumps({'passed':len(checks),'checks':checks}))
