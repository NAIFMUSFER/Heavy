from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 result=run(query,False);assert not result['ok'] and code in result['error'],result
def prepare(stock=10000):
 f=fixture(stock=stock);supplier=val(rpc('jana_admin_create_supplier',f['atok'],'Supplier credit fixture',''))
 run('UPDATE inventory_lots SET supplier_id='+literal(supplier['id'])+' WHERE id='+literal(f['p']+'l')+';')
 return f,supplier
def disposal(f,key='supplier-return-fixture',reference='RETURN-FIXTURE'):
 revision=val(rpc('jana_inventory_disposal_context',f['atok'],f['p']+'l'))['quantity_revision']
 return val(rpc('jana_inventory_dispose',f['atok'],key,{'lot_id':f['p']+'l','kind':'supplier_return','quantity_base':100,'revision':revision,'reason':'Physical supplier return fixture','reference':reference}))
def credit(f,token,key,event,amount=75,reference='CREDIT-FIXTURE',note='Actual supplier credit note fixture'):
 return rpc('jana_supplier_credit_record',token,key,{'disposal_id':event['id'],'amount_halalas':amount,'reference':reference,'note':note})
def history(f,token=None,*cursor):return val(rpc('jana_supplier_credit_reconciliation',token or f['atok'],*cursor))

f,supplier=prepare();event=disposal(f);body=credit(f,f['atok'],'same-credit-retry',event)
rows=successful(race([body]*16));assert len(rows)==16 and all(x==rows[0] for x in rows);record=rows[0]
assert event['value_halalas']==10 and event['cost_basis']=='recorded'
assert record['amount_halalas']==75 and record['credited_halalas']==75 and record['inventory_value_halalas']==event['value_halalas'] and record['inventory_cost_basis']==event['cost_basis']
assert val('SELECT count(*) FROM supplier_credit_notes WHERE disposal_id='+literal(event['id'])+'::uuid;')==1
assert val("SELECT count(*) FROM audit_log WHERE action='supplier_credit_recorded' AND entity_id="+literal(record['id'])+';')==1
assert balance(f)['on_hand']==9900
passed('sixteen retries record one immutable supplier credit without changing returned stock')
fails(credit(f,f['atok'],'same-credit-retry',event,76),'idempotency_conflict')
fails(credit(f,f['atok'],'different-key',event,1),'supplier_credit_reference_exists')
assert val('SELECT count(*) FROM supplier_credit_notes;')==1
passed('changed retry and duplicate supplier document cannot double-record credit')

row=history(f)['items'][0];assert row['credit_count']==1 and row['credited_halalas']==75 and row['inventory_value_halalas']==event['value_halalas'] and row['variance_to_inventory_cost_halalas']==75-event['value_halalas']
assert row['credit_notes'][0]['reference']=='CREDIT-FIXTURE' and row['credit_notes'][0]['actor_name']
passed('reconciliation keeps supplier evidence separate from reference inventory cost')
fails('UPDATE supplier_credit_notes SET amount_halalas=76 WHERE id='+literal(record['id'])+'::uuid;','append_only')
fails('DELETE FROM supplier_credit_notes WHERE id='+literal(record['id'])+'::uuid;','append_only')
other=val(rpc('jana_admin_create_supplier',f['atok'],'Other supplier fixture',''))
fails("INSERT INTO supplier_credit_notes(disposal_id,supplier_id,amount_halalas,reference,note,actor_id,actor_role,created_at) VALUES("+literal(event['id'])+'::uuid,'+literal(other['id'])+",1,'MISMATCH','Mismatch supplier fixture',"+literal(f['p']+'a')+",'admin',1);",'supplier_credit_supplier_mismatch')
passed('credit records are append-only and database guard rejects supplier mismatch')

f2,supplier2=prepare();damage=val(rpc('jana_inventory_dispose',f2['atok'],'damage-not-return',{'lot_id':f2['p']+'l','kind':'damage','quantity_base':1,'revision':0,'reason':'Damage fixture only','reference':'DAMAGE'}));fails(credit(f2,f2['atok'],'credit-damage-denied',damage),'supplier_credit_requires_return')
base={'disposal_id':event['id'],'amount_halalas':1,'reference':'VALID-REF','note':'Valid note'}
for field,value in [('disposal_id','not-a-uuid'),('amount_halalas',0),('amount_halalas',-1),('amount_halalas',1.5),('amount_halalas','1'),('reference',''),('note','x')]:
 fails(rpc('jana_supplier_credit_record',f['atok'],'invalid-credit-fixture',{**base,field:value}),'supplier_credit_validation')
passed('only strictly typed positive credit notes can target a supplier return')

f3,supplier3=prepare();run("UPDATE inventory_lots SET total_cost_halalas=NULL,remaining_cost_halalas=NULL,cost_basis='unknown' WHERE id="+literal(f3['p']+'l')+';');unknown=disposal(f3,reference='UNKNOWN-RETURN');val(credit(f3,f3['atok'],'unknown-credit',unknown,40,'UNKNOWN-CREDIT'));unknown_row=history(f3)['items'][0]
assert unknown_row['inventory_value_halalas'] is None and unknown_row['variance_to_inventory_cost_halalas'] is None and unknown_row['credited_halalas']==40
passed('unknown inventory cost remains unknown instead of becoming zero or a false variance')

f4,supplier4=prepare();first=disposal(f4,'finance-credit-return','FINANCE-RETURN');run("UPDATE users SET role='finance' WHERE id="+literal(f4['p']+'a')+';');finance_record=val(credit(f4,f4['atok'],'finance-credit-record',first,100,'FINANCE-CREDIT'));assert finance_record['actor_role']=='finance'
run("UPDATE users SET role='inventory' WHERE id="+literal(f4['p']+'a')+';');fails(credit(f4,f4['atok'],'inventory-credit-denied',first,1,'INVENTORY-CREDIT'),'forbidden');assert history(f4)['items']
fails(rpc('jana_supplier_credit_reconciliation',f4['t']),'forbidden')
fails(credit(f4,f4['t'],'customer-credit-denied',first,1,'CUSTOMER-CREDIT'),'forbidden')
passed('finance records credits, inventory reviews only, and customer is denied')

f5,supplier5=prepare(stock=10000);revision=0
for i in range(52):
 event_i=val(rpc('jana_inventory_dispose',f5['atok'],'credit-page-return-'+str(i),{'lot_id':f5['p']+'l','kind':'supplier_return','quantity_base':1,'revision':revision,'reason':'Pagination supplier return fixture','reference':'PAGE-RETURN-'+str(i)}));revision+=1
page=history(f5);assert len(page['items'])==50 and page['next'];seen=set();references=[]
while True:
 assert len(page['items'])<=50 and not (seen&{x['id'] for x in page['items']})
 seen.update(x['id'] for x in page['items']);references.extend(x['return_reference'] for x in page['items'])
 if not page['next']:break
 cursor=page['next'];page=history(f5,None,cursor['before_at'],cursor['before_id'])
assert sorted(x for x in references if x.startswith('PAGE-RETURN-'))==sorted('PAGE-RETURN-'+str(i) for i in range(52))
passed('supplier return reconciliation uses bounded stable pages without duplicates')

assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_supplier_credit_record','jana_supplier_credit_reconciliation','jana_supplier_credit_guard') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
assert val("SELECT to_jsonb(relrowsecurity) FROM pg_class WHERE oid='public.supplier_credit_notes'::regclass;")
assert val('SELECT jana_deep_health();')['ok']
passed('supplier credit RLS privileges and existing operational invariants remain enforced')
print(json.dumps({'passed':len(checks),'checks':checks}))
