"""Real multi-connection PostgreSQL tests. Disposable localhost database only."""
import concurrent.futures,json,os,pathlib,secrets,subprocess,threading,uuid
if os.environ.get('JANA_TEST_DATABASE')!='disposable' or os.environ.get('PGHOST') not in ('127.0.0.1','localhost') or os.environ.get('PGDATABASE')!='jana_test':
 raise SystemExit('Refusing concurrency fixtures outside disposable loopback jana_test database')
def literal(v):return "'"+str(v).replace("'","''")+"'"
def run(query,required=True):
 p=subprocess.run(['psql','-X','-qAt','-v','ON_ERROR_STOP=1'],input='SET statement_timeout=15000;\n'+query,text=True,capture_output=True,timeout=25)
 if required and p.returncode:raise AssertionError(p.stderr)
 return {'ok':not p.returncode,'data':p.stdout.strip(),'error':p.stderr}
def val(query):return json.loads(run(query)['data'])
def rpc(name,*args):
 return 'SELECT public.'+name+'('+','.join(literal(a) if not isinstance(a,dict) else literal(json.dumps(a))+'::jsonb' for a in args)+')::text;'
def fixture(stock=10000,capacity=20):
 p='jc'+uuid.uuid4().hex[:16]; t,ct,atok=[secrets.token_hex(32) for _ in range(3)]
 source=pathlib.Path('tests/database-critical-writes.sql').read_text()
 setup=source.split(' BEGIN\n',1)[1].split('  BEGIN r=public.jana_login',1)[0]
 declare=f'DECLARE p text:={literal(p)};t text:={literal(t)};ct text:={literal(ct)};atok text:={literal(atok)};nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;'
 run('DO $fixture$ '+declare+' BEGIN '+setup+f" UPDATE public.stock_balances SET on_hand_base={stock} WHERE stock_id=p||'st'; UPDATE public.inventory_lots SET received_base={stock},on_hand_base={stock},expires_at=nowms+86400000 WHERE id=p||'l'; UPDATE public.delivery_slots SET capacity={capacity} WHERE id=p||'s'; END $fixture$;")
 return {'p':p,'t':t,'ct':ct,'atok':atok}
def quote(f,key,qty=1):
 p=f['p'];return 'SELECT public.jana_create_quote_idempotent('+','.join(map(literal,[f['t'],key,p+'s',p+'addr']))+','+literal(json.dumps([{'offering_id':p+'off','qty':qty}]))+'::jsonb)::text;'
def race(queries):
 gate=threading.Barrier(len(queries))
 def worker(query):gate.wait(timeout=10);return run(query,False)
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries)) as pool:return list(pool.map(worker,queries))
def successful(rows):return [json.loads(r['data']) for r in rows if r['ok']]
def balance(f):
 p=f['p'];return val("SELECT jsonb_build_object('on_hand',b.on_hand_base,'reserved',b.reserved_base,'booked',s.booked,'capacity',s.capacity) FROM public.stock_balances b CROSS JOIN public.delivery_slots s WHERE b.stock_id="+literal(p+'st')+' AND s.id='+literal(p+'s')+';')
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
f=fixture(stock=1000);rows=race([quote(f,'last-stock-'+str(i)) for i in range(16)]);assert len(successful(rows))==1;assert all(r['ok'] or 'insufficient_stock' in r['error'] for r in rows);assert balance(f)['reserved']==1000;passed('16 buyers cannot oversell last stock')
f=fixture(stock=30000,capacity=1);rows=race([quote(f,'last-slot-'+str(i)) for i in range(16)]);assert len(successful(rows))==1;assert all(r['ok'] or 'slot_unavailable' in r['error'] for r in rows);assert balance(f)['booked']==1;passed('16 buyers cannot overbook last slot')
f=fixture();rows=race([quote(f,'same-quote-key')]*16);quotes=successful(rows);assert len(quotes)==16 and len({q['id'] for q in quotes})==1;assert balance(f)['reserved']==1000 and balance(f)['booked']==1;passed('16 identical quote retries reserve once')
rows=race([quote(f,'mixed-quote-key',1+i%2) for i in range(16)]);accepted=successful(rows);assert 0<len(accepted)<16;assert len({q['id'] for q in accepted})==1;assert all(r['ok'] or 'idempotency_conflict' in r['error'] for r in rows);passed('concurrent changed-body key reuse is rejected')
# Use a separate fixture for the complete delivery/COD retry journey.
f=fixture();q=val(quote(f,'fulfillment-quote'));confirm=rpc('jana_critical_write',f['t'],'same-confirm-key','order.confirm',{'quote_id':q['id']});orders=successful(race([confirm]*16));assert len(orders)==16 and all(o==orders[0] for o in orders);o=orders[0];oid=o['id'];assert val('SELECT count(*) FROM orders WHERE quote_id='+literal(q['id'])+';')==1;passed('16 confirmations create one order and replay delivery code')
val(rpc('jana_ops_transition',f['atok'],oid,'start',''))
val(rpc('jana_finalize_picking',f['atok'],oid))
val(rpc('jana_ops_transition',f['ct'],oid,'dispatch',''))
deliver=rpc('jana_critical_write',f['ct'],'same-delivery-key','order.deliver',{'order_id':oid,'code':o['delivery_code']});rows=successful(race([deliver]*16));assert len(rows)==16 and all(r==rows[0] for r in rows);assert val('SELECT collected_halalas FROM orders WHERE id='+literal(oid)+';')==0;passed('delivery retries prove delivery without collecting cash')
collect=rpc('jana_critical_write',f['ct'],'same-collect-key','cod.collect',{'order_id':oid,'amount_halalas':2000});rows=successful(race([collect]*16));assert len(rows)==16 and all(r==rows[0] for r in rows);assert val("SELECT count(*) FROM order_events WHERE event='collect' AND order_id="+literal(oid)+';')==1;passed('16 collection retries record one cash liability')
refund=rpc('jana_critical_write',f['atok'],'same-refund-key','refund.create',{'order_id':oid,'amount_halalas':100,'reason':'Disposable concurrency fixture refund'});rows=successful(race([refund]*16));assert len(rows)==16 and all(r==rows[0] for r in rows);assert val('SELECT refunded_halalas FROM orders WHERE id='+literal(oid)+';')==100;passed('16 refund retries create one refund')
settle=rpc('jana_critical_write',f['atok'],'same-settle-key','cod.settle',{'order_id':oid,'reference':'Disposable concurrency deposit'});rows=successful(race([settle]*16));assert len(rows)==16 and all(r==rows[0] for r in rows);assert rows[0]['settled_halalas']==1900;assert val("SELECT count(*) FROM audit_log WHERE action='cash_settled' AND entity_id="+literal(oid)+';')==1;passed('16 settlement retries settle liability once')
health=val('SELECT public.jana_deep_health()::text;');assert health['ok'];passed('database invariants survive concurrent journeys')
print(json.dumps({'passed':len(checks),'clients_per_race':16,'database':'disposable PostgreSQL/PostGIS','checks':checks}))
