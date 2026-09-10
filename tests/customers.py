from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
f=fixture();p=f['p'];prefix=p+'customer';stamp=val('SELECT created_at FROM users WHERE id='+literal(p+'u')+';')
run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) SELECT "+literal(p)+"||'-c-'||lpad(n::text,3,'0'),"+literal(prefix)+"||n||'@example.invalid',"+literal(prefix)+"||n,'not-a-login-fixture','customer',false,n<>1,"+str(stamp)+" FROM generate_series(1,55)n;")
def page(before=None,token=f['atok'],query=prefix):return val('SELECT jana_admin_customers('+literal(token)+','+literal(query)+','+(str(before['before_at']) if before else 'NULL')+','+(literal(before['before_id']) if before else 'NULL')+')::text;')
a=page();b=page(a['next']);assert len(a['items'])==50 and len(b['items'])==5 and b['next'] is None;ids=[x['id'] for x in a['items']+b['items']];assert len(set(ids))==55 and ids==sorted(ids,reverse=True);passed('customer directory pages equal timestamps without duplicated or missing accounts')
keys={'id','name','email','phone','active','verified_phone','created_at','orders_count'};assert all(set(x)==keys for x in a['items']+b['items']);assert any(not x['active'] for x in b['items']);assert page(query='not-existing-fixture')['items']==[];passed('search responses expose selected customer fields including inactive status without credentials or sessions')
for token in [f['t'],f['ct']]:
 for query in [rpc('jana_admin_customer_detail',token,p+'u'),rpc('jana_admin_customers',token,'')]:
  r=run(query,False);assert not r['ok'] and 'forbidden' in r['error']
passed('customer and courier roles cannot enumerate the customer directory')
r=run(rpc('jana_admin_customer_detail',f['atok'],p+'a'),False);assert not r['ok'] and 'customer_not_found' in r['error'];passed('customer detail does not expose operational account records')
q=val(quote(f,'customer-admin-quote'));o=val(rpc('jana_critical_write',f['t'],'customer-admin-confirm','order.confirm',{'quote_id':q['id']}));original=val('SELECT original_snapshot::jsonb FROM orders WHERE id='+literal(o['id'])+';');balance_before=balance(f)
detail=val(rpc('jana_admin_customer_detail',f['atok'],p+'u'));assert detail['orders_count']==1 and detail['orders'][0]['id']==o['id'] and detail['orders'][0]['total_halalas']==2000;assert set(detail['customer'])==keys-{'orders_count'};assert 'snapshot' not in detail['orders'][0];assert val('SELECT original_snapshot::jsonb FROM orders WHERE id='+literal(o['id'])+';')==original and balance(f)==balance_before;passed('customer activity reads real order totals without changing order snapshots or reservations')
audit=val("SELECT detail::jsonb FROM audit_log WHERE action='customer_record_viewed' AND entity_id="+literal(p+'u')+';');assert audit=={'actor_role':'admin','purpose':'customer_operations_review'};passed('opening a customer record leaves an administrator access audit without copying contact data')
for query in ['x'*121]:
 r=run(rpc('jana_admin_customers',f['atok'],query),False);assert not r['ok'] and 'customer_query_invalid' in r['error']
r=run('SELECT jana_admin_customers('+literal(f['atok'])+",'',1,NULL);",False);assert not r['ok'] and 'customer_query_invalid' in r['error'];passed('query length and paired pagination cursors are validated by PostgreSQL')
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_admin_customers','jana_admin_customer_detail') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0;passed('customer administration RPCs remain service-only')
print(json.dumps({'passed':len(checks),'checks':checks}))
