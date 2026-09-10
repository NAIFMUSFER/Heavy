from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 r=run(query,False);assert not r['ok'] and code in r['error'],r

def prepared(*,stock=10000,cost=None,unknown=False,delivered=True):
 f=fixture(stock=stock);p=f['p']
 if unknown:run("UPDATE inventory_lots SET total_cost_halalas=NULL,remaining_cost_halalas=NULL,cost_basis='unknown' WHERE id="+literal(p+'l')+';')
 elif cost is not None:run('UPDATE inventory_lots SET total_cost_halalas='+str(cost)+',remaining_cost_halalas='+str(cost)+' WHERE id='+literal(p+'l')+';')
 q=val(quote(f,'return-fixture-quote'));o=val(rpc('jana_critical_write',f['t'],'return-fixture-confirm','order.confirm',{'quote_id':q['id']}));val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''));val(rpc('jana_finalize_picking',f['atok'],o['id']))
 if delivered:
  val(rpc('jana_ops_transition',f['ct'],o['id'],'dispatch',''));val(rpc('jana_critical_write',f['ct'],'return-fixture-deliver','order.deliver',{'order_id':o['id'],'code':o['delivery_code']}))
 f['order']=o;f['source']=val("SELECT to_jsonb(m) FROM stock_movements m WHERE reference="+literal(o['id'])+" AND reason='order_picked';");return f

def body(f,qty=500,ref='RETURN-FIXTURE',**more):return {'source_movement_id':f['source']['id'],'quantity_base':qty,'reference':ref,'reason':'Actual returned goods fixture',**more}
def receive(f,key='receive-return-fixture',payload=None):return rpc('jana_customer_return_receive',f['atok'],key,payload or body(f))
def inspect(f,r,accepted,key='inspect-return-fixture'):return rpc('jana_customer_return_inspect',f['atok'],key,{'return_id':r['id'],'accepted_base':accepted,'note':'Recorded physical quality inspection fixture'})
def lot(f):return val('SELECT to_jsonb(l) FROM inventory_lots l WHERE id='+literal(f['p']+'l')+';')
def order_row(f):return val('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(f['order']['id'])+';')
def history(f):return val(rpc('jana_customer_returns',f['atok']))

f=prepared();before=balance(f);original_order=order_row(f);rows=successful(race([receive(f)]*16));assert len(rows)==16 and all(x==rows[0] for x in rows);r=rows[0];assert balance(f)==before and order_row(f)==original_order;assert val('SELECT count(*) FROM customer_return_receipts WHERE id='+literal(r['id'])+';')==1;assert val('SELECT count(*) FROM stock_movements WHERE reference='+literal(r['id'])+" AND reason='customer_return_received' AND on_hand_delta=0 AND reserved_delta=0;")==1;passed('sixteen receive retries create one quarantined receipt without changing stock order or cash')
fails(receive(f,payload=body(f,501)),'idempotency_conflict');fails(receive(f,'same-reference-new-key'),'return_reference_exists');passed('changed request reuse and repeated physical document cannot receive goods twice')
rows=successful(race([inspect(f,r,400)]*16));assert len(rows)==16 and all(x==rows[0] for x in rows);i=rows[0];assert i['accepted_base']==400 and i['rejected_base']==100 and i['restored_cost_halalas']==40 and i['cost_basis']=='recorded';assert balance(f)['on_hand']==before['on_hand']+400 and balance(f)['reserved']==before['reserved'];assert lot(f)['remaining_cost_halalas']==940;assert order_row(f)==original_order;assert val('SELECT count(*) FROM inventory_cost_entries WHERE movement_id='+literal(i['movement_id'])+';')==1;assert val('SELECT to_jsonb(order_id::text= '+literal(f['order']['id'])+') FROM inventory_cost_entries WHERE movement_id='+literal(i['movement_id'])+';');passed('sixteen inspection retries restock accepted quantity and original cost once while rejecting the remainder')
fails(inspect(f,r,400,'different-inspection-key'),'return_already_inspected');fails(inspect(f,r,401),'idempotency_conflict');assert val(receive(f))==r;passed('completed receipt and inspection return their original idempotent results after stock changes')
for table,key in [('customer_return_receipts','id'),('customer_return_inspections','return_id')]:fails('DELETE FROM '+table+' WHERE '+key+'='+literal(r['id'])+';','append_only')
fails('UPDATE customer_return_receipts SET quantity_base=1 WHERE id='+literal(r['id'])+';','append_only');passed('receipt source terms and quality decision remain append-only')

ledger=val(rpc('jana_stock_movement_history',f['atok'],{'reference':'RETURN-FIXTURE'}));assert len(ledger['items'])==2 and all(x['document_reference']=='RETURN-FIXTURE' for x in ledger['items']);assert sum(x['on_hand_delta'] for x in ledger['items'])==400;passed('general stock history resolves the actual return document for receipt and accepted inspection movements')

f=prepared();rows=race([receive(f,'receipt-race-one',body(f,600,'FIRST')),receive(f,'receipt-race-two',body(f,600,'SECOND'))]);assert len(successful(rows))==1 and all(x['ok'] or 'return_exceeds_shipped' in x['error'] for x in rows);assert val('SELECT sum(quantity_base) FROM customer_return_receipts WHERE source_movement_id='+literal(f['source']['id'])+';')==600;passed('concurrent physical receipts cannot exceed the exact original shipped quantity')
f=prepared();r=val(receive(f));before=balance(f);rows=race([inspect(f,r,500,'quality-decision-one'),inspect(f,r,200,'quality-decision-two')]);assert len(successful(rows))==1;assert balance(f)['on_hand']==before['on_hand']+successful(rows)[0]['accepted_base'];assert all(x['ok'] or 'return_already_inspected' in x['error'] for x in rows);passed('competing inspectors cannot publish two quality decisions or duplicate stock')
f=prepared();r=val(receive(f));before=lot(f);i=val(inspect(f,r,0));assert i['accepted_base']==0 and i['rejected_base']==500 and i['restored_cost_halalas'] is None and i['cost_basis'] is None;assert lot(f)==before;assert val('SELECT count(*) FROM inventory_cost_entries WHERE movement_id='+literal(i['movement_id'])+';')==0;passed('rejected returned goods remain quarantined without usable stock or a second consumption charge')

f=prepared();bad=body(f)
for key,v in [('quantity_base',0),('quantity_base',-1),('quantity_base',1.5),('quantity_base','1'),('reference',''),('reason','x'),('actor_id','untrusted')]:fails(receive(f,'invalid-return-input',{**bad,key:v}),'return_validation')
bad_source=val('SELECT to_jsonb(m) FROM stock_movements m WHERE stock_id='+literal(f['p']+'st')+" AND on_hand_delta=0 LIMIT 1;");fails(receive(f,'non-shipped-source',{**bad,'source_movement_id':bad_source['id']}),'return_source_invalid');r=val(receive(f));fails(inspect(f,r,501),'return_validation');fails(rpc('jana_customer_return_inspect',f['atok'],'invalid-return-inspection',{'return_id':r['id'],'accepted_base':'10','note':'Invalid typed number'}),'return_validation');passed('strict canonical source quantity document and inspection input validation rejects fabricated terms')

f=prepared();r=val(receive(f));run('UPDATE inventory_lots SET expires_at=1 WHERE id='+literal(f['p']+'l')+';');before=balance(f);fails(inspect(f,r,500),'return_lot_not_restockable');assert balance(f)==before;assert val(inspect(f,r,0))['accepted_base']==0;passed('expired original lot can be rejected but never made sellable by a return')
f=prepared(unknown=True);r=val(receive(f));i=val(inspect(f,r,300));assert i['restored_cost_halalas'] is None and i['cost_basis']=='unknown';assert lot(f)['remaining_cost_halalas'] is None;passed('missing original purchase cost remains explicitly unknown on the return and pooled inventory')
f=prepared(cost=0);r=val(receive(f));i=val(inspect(f,r,300));assert i['restored_cost_halalas']==0 and i['cost_basis']=='recorded';passed('recorded zero return cost is distinct from unknown cost')
f=prepared(stock=1000,cost=1);assert lot(f)['on_hand_base']==0 and lot(f)['remaining_cost_halalas']==0;returned=0
for n,qty in enumerate([333,333,334]):
 r=val(receive(f,'rounding-receipt-'+str(n),body(f,qty,'ROUND-'+str(n))));i=val(inspect(f,r,qty,'rounding-inspection-'+str(n)));returned+=i['restored_cost_halalas'];assert returned<=1
assert returned==1 and lot(f)['on_hand_base']==1000 and lot(f)['remaining_cost_halalas']==1;assert val('SELECT sum(value_delta_halalas) FROM inventory_cost_entries WHERE order_id='+literal(f['order']['id'])+';')==0;passed('split return rounding conserves the full original shipment cost without inventing extra value')

f=prepared();r=val(receive(f));before=lot(f);run('BEGIN;'+inspect(f,r,500)+'ROLLBACK;');assert lot(f)==before and val('SELECT count(*) FROM customer_return_inspections WHERE return_id='+literal(r['id'])+';')==0;assert val(inspect(f,r,500))['accepted_base']==500;passed('inspection rollback releases every stock cost audit and idempotency change for a safe retry')
f=prepared(stock=1000);r=val(receive(f,payload=body(f,1000)));rows=race([inspect(f,r,1000),quote(f,'quote-versus-return')]);assert rows[0]['ok'] and (rows[1]['ok'] or 'insufficient' in rows[1]['error']);b=balance(f);assert b['on_hand']==1000 and b['reserved'] in (0,1000);passed('inspection and checkout share balance locks and never reserve quarantined units early')

f=prepared(delivered=False);fails(receive(f),'return_order_ineligible');fails(rpc('jana_customer_return_context',f['atok'],f['order']['number']),'return_order_ineligible');val(rpc('jana_ops_transition',f['ct'],f['order']['id'],'dispatch',''));val(rpc('jana_ops_transition',f['ct'],f['order']['id'],'fail','Customer unavailable fixture'));r=val(receive(f));fails(rpc('jana_ops_transition',f['ct'],f['order']['id'],'dispatch',''),'return_requires_resolution');assert order_row(f)['delivery_state']=='failed';passed('only delivered or failed shipments accept returns and a physically returned failed shipment cannot be redispatched')
f=prepared(delivered=False);val(rpc('jana_ops_transition',f['ct'],f['order']['id'],'dispatch',''));val(rpc('jana_ops_transition',f['ct'],f['order']['id'],'fail','Customer unavailable fixture'));rows=race([receive(f),rpc('jana_ops_transition',f['ct'],f['order']['id'],'dispatch','')]);assert len(successful(rows))==1 and all(x['ok'] or any(e in x['error'] for e in ['return_requires_resolution','return_order_ineligible']) for x in rows);passed('warehouse return receipt and courier redispatch serialize on the original order')

f=prepared();r=val(receive(f));count=val('SELECT jana_count_start('+literal(f['atok'])+','+literal('Returns physical count')+','+literal(json.dumps([f['p']+'l']))+'::jsonb)::text;');val(inspect(f,r,500));sessions=val(rpc('jana_inventory_counts',f['atok']));assert next(x for x in sessions if x['id']==count['id'])['counts'][0]['stale'];passed('restocked returned quantity invalidates an earlier physical-count baseline')
f=prepared();run('DO $batch$ BEGIN FOR i IN 1..52 LOOP PERFORM jana_customer_return_receive('+literal(f['atok'])+",'return-page-'||i,jsonb_build_object('source_movement_id',"+literal(f['source']['id'])+",'quantity_base',1,'reference','RETURN-PAGE-'||i,'reason','Return pagination fixture'));END LOOP;END $batch$;");first=history(f);assert len(first['items'])==50 and first['next'];cursor=first['next'];second=val(rpc('jana_customer_returns',f['atok'],cursor['before_at'],cursor['before_id']));assert not ({x['id'] for x in first['items']}&{x['id'] for x in second['items']});passed('return history is bounded and uses stable keyset pagination')
f=prepared();r=val(receive(f));val(inspect(f,r,100));fails(rpc('jana_customer_returns',f['t']),'forbidden');fails(rpc('jana_customer_return_receive',f['ct'],'courier-forged-return',body(f)),'forbidden');run("UPDATE users SET role='support' WHERE id="+literal(f['p']+'a')+';');item=next(x for x in history(f)['items'] if x['id']==r['id']);assert 'restored_cost_halalas' not in item['inspection'] and 'cost_basis' not in item['inspection'];assert 'recipient_phone' not in json.dumps(item);fails(receive(f),'forbidden');run("UPDATE users SET role='finance' WHERE id="+literal(f['p']+'a')+';');assert next(x for x in history(f)['items'] if x['id']==r['id'])['inspection']['restored_cost_halalas']==10;fails(inspect(f,r,100),'forbidden');passed('inventory and admin alone receive or inspect while support sees redacted status and finance sees cost evidence')
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'jana_customer_return%' AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0;assert val("SELECT count(*) FROM pg_class WHERE relname IN ('customer_return_receipts','customer_return_inspections') AND relrowsecurity;")==2;assert val('SELECT jana_deep_health();')['ok'];passed('RLS service-only grants and existing stock slot order and cash invariants remain enforced')

# Rejected-return custody is a separate append-only ledger, tested on the same disposable database.
def dispose(f,r,qty=40,key='return-dispose-fixture',ref='DISPOSITION-FIXTURE',kind='destroyed',recipient=None,**extra):
 return rpc('jana_customer_return_dispose',f['atok'],key,{'return_id':r['id'],'kind':kind,'quantity_base':qty,'reference':ref,'recipient':recipient,'note':'Completed physical disposition fixture',**extra})
def custody(f,r,*cursor):return val(rpc('jana_customer_return_dispositions',f['atok'],r['id'],*cursor))
def business(f):
 sid=literal(f['p']+'st');oid=literal(f['order']['id'])
 entries=val(f"SELECT jsonb_build_object('movements',(SELECT count(*) FROM stock_movements WHERE stock_id={sid}),'costs',(SELECT count(*) FROM inventory_cost_entries WHERE stock_id={sid}),'cash',(SELECT count(*) FROM cash_entries WHERE order_id={oid}),'refunds',(SELECT count(*) FROM refunds WHERE order_id={oid}),'receipts',(SELECT count(*) FROM customer_return_receipts WHERE order_id={oid}),'inspections',(SELECT count(*) FROM customer_return_inspections WHERE return_id IN (SELECT id FROM customer_return_receipts WHERE order_id={oid})));")
 return {'balance':balance(f),'lot':lot(f),'order':order_row(f),'entries':entries}

f=prepared();r=val(receive(f));val(inspect(f,r,400));before=business(f)
rows=successful(race([dispose(f,r)]*16));assert len(rows)==16 and all(x==rows[0] for x in rows);d=rows[0]
assert d['remaining_base']==60 and d['state']=='partial';assert custody(f,r)['receipt']['remaining_base']==60
assert val('SELECT count(*) FROM customer_return_dispositions WHERE return_id='+literal(r['id'])+';')==1
assert val("SELECT count(*) FROM audit_log WHERE action='customer_return_disposed' AND entity_id="+literal(d['id'])+';')==1
assert business(f)==before;passed('sixteen custody retries create one partial disposal document and audit without changing stock cost order or cash')
fails(dispose(f,r,41),'idempotency_conflict');fails(dispose(f,r,key='repeat-disposition-document'),'return_disposition_reference_exists')
assert business(f)==before;passed('changed idempotency payload and duplicate disposition document do not close custody twice')
closed=val(dispose(f,r,60,key='return-handover-fixture',ref='SUPPLIER-HANDOVER',kind='supplier_handover',recipient='Fixture supplier and recipient'))
assert closed['state']=='closed' and closed['remaining_base']==0;h=custody(f,r)
assert len(h['items'])==2 and h['receipt']['disposed_base']==100 and h['receipt']['remaining_base']==0
assert any(x['recipient']=='Fixture supplier and recipient' for x in h['items'])
item=next(x for x in history(f)['items'] if x['id']==r['id']);assert item['disposition_summary']=={'disposed_base':100,'remaining_base':0}
assert business(f)==before;passed('partial destruction followed by supplier handover closes exactly the rejected quantity and preserves all business ledgers')
fails(dispose(f,r,1,key='extra-disposition-fixture',ref='EXTRA'),'return_disposition_exceeds_remaining')
assert val(dispose(f,r))==d;passed('closed custody rejects additional quantities while original retry returns its unchanged result')
fails('DELETE FROM customer_return_dispositions WHERE id='+literal(d['id'])+';','append_only')
fails("UPDATE customer_return_dispositions SET recipient='Changed' WHERE id="+literal(d['id'])+';','append_only')
passed('recorded disposition quantity document recipient and actor cannot be overwritten or deleted')

f=prepared();r=val(receive(f));val(inspect(f,r,0));before=business(f)
rows=race([dispose(f,r,300,key='concurrent-dispose-one',ref='FIRST'),dispose(f,r,300,key='concurrent-dispose-two',ref='SECOND')])
assert len(successful(rows))==1 and all(x['ok'] or 'return_disposition_exceeds_remaining' in x['error'] for x in rows)
assert custody(f,r)['receipt']['remaining_base']==200 and business(f)==before
passed('competing warehouse dispositions serialize and cannot exceed the same rejected quantity')

f=prepared();r=val(receive(f));assert custody(f,r)['receipt']['remaining_base'] is None
fails(dispose(f,r),'return_disposition_requires_rejection');val(inspect(f,r,500));fails(dispose(f,r),'return_disposition_requires_rejection')
assert custody(f,r)['receipt']['remaining_base']==0 and custody(f,r)['items']==[]
passed('pending inspection and fully accepted returns cannot be disposed as rejected goods')

f=prepared();r=val(receive(f));val(inspect(f,r,0))
for key,v in [('quantity_base',0),('quantity_base',-1),('quantity_base',1.5),('quantity_base','1'),('quantity_base',None),('kind','restock'),('reference',''),('note','x'),('recipient',{}),('actor_id','fabricated')]:
 payload={'return_id':r['id'],'kind':'destroyed','quantity_base':1,'reference':'INVALID-FIXTURE','recipient':None,'note':'Fixture observed disposition',key:v}
 fails(rpc('jana_customer_return_dispose',f['atok'],'invalid-disposition-fixture',payload),'return_disposition_validation')
fails(dispose(f,r,kind='supplier_handover'),'return_disposition_validation')
fails(dispose(f,r,kind='destroyed',recipient='Unexpected recipient'),'return_disposition_validation')
assert custody(f,r)['items']==[];passed('custody validates actual integer quantity kind reference note and required handover recipient')
before=business(f);run('BEGIN;'+dispose(f,r)+'ROLLBACK;');assert custody(f,r)['items']==[]
assert val("SELECT count(*) FROM idempotency_records WHERE scope="+literal('customer-return-dispose:'+f['p']+'a:return-dispose-fixture')+';')==0
assert val(dispose(f,r))['quantity_base']==40 and business(f)==before
passed('rolled-back disposition leaves no document or idempotency claim and permits a complete retry')

f=prepared();r=val(receive(f));val(inspect(f,r,0));run("UPDATE users SET role='inventory' WHERE id="+literal(f['p']+'a')+';');val(dispose(f,r))
for role in ['finance','support']:
 run('UPDATE users SET role='+literal(role)+' WHERE id='+literal(f['p']+'a')+';')
 assert custody(f,r)['receipt']['remaining_base']==460;assert 'restored_cost_halalas' not in json.dumps(custody(f,r))
 fails(dispose(f,r),'forbidden')
for role in ['picker','courier','customer']:
 run('UPDATE users SET role='+literal(role)+' WHERE id='+literal(f['p']+'a')+';')
 fails(rpc('jana_customer_return_dispositions',f['atok'],r['id']),'forbidden');fails(dispose(f,r),'forbidden')
passed('warehouse alone writes custody while finance and support read it and other roles cannot access it')

f=prepared();r=val(receive(f));val(inspect(f,r,0))
for n in range(52):val(dispose(f,r,1,key='custody-page-'+str(n),ref='PAGE-'+str(n)))
first=custody(f,r);assert len(first['items'])==50 and first['next'];cursor=first['next'];ids={x['id'] for x in first['items']}
val(dispose(f,r,1,key='custody-newest-after-page',ref='NEWEST'))
second=custody(f,r,cursor['before_at'],cursor['before_id'])
assert len(second['items'])==2 and second['next'] is None and not(ids&{x['id'] for x in second['items']})
assert all(x['return_id']==r['id'] for x in first['items']+second['items'])
assert second['receipt']['remaining_base']==447
passed('custody history is bounded to fifty rows with stable pages despite a new intervening document')
summary=history(f)['summary'];assert summary['open_rejected_receipts']>0 and summary['closed_rejected_receipts']>0
assert summary['open_rejected_receipts']+summary['closed_rejected_receipts']==summary['rejected_receipts']
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_customer_return_dispose','jana_customer_return_dispositions') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
assert val("SELECT relrowsecurity FROM pg_class WHERE oid='public.customer_return_dispositions'::regclass;")
assert val('SELECT jana_deep_health();')['ok'];passed('custody counts reconcile without mixing units and new storage retains RLS service-only access and business invariants')

print(json.dumps({'passed':len(checks),'checks':checks}))
