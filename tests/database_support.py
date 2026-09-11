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
 run('DO $fixture$ '+declare+' BEGIN '+setup+f" UPDATE public.stock_balances SET on_hand_base={stock} WHERE stock_id=p||'st'; UPDATE public.inventory_lots SET received_base={stock},on_hand_base={stock},expires_at=nowms+86400000 WHERE id=p||'l'; UPDATE public.delivery_slots SET capacity={capacity} WHERE id=p||'s'; INSERT INTO public.delivery_zone_warehouses(zone_id,warehouse_id,assigned_by,assigned_at) SELECT p||'z',id,p||'a',nowms FROM public.warehouses WHERE active ON CONFLICT(zone_id) DO NOTHING; END $fixture$;")
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
