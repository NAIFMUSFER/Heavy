"""Staff order pagination against guarded disposable PostgreSQL; no production access."""
from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def denied(query,message):
 r=run(query,False);assert not r['ok'] and message in r['error'],r

def page(token,before=None,offset=0,limit=25):
 return val('SELECT jana_ops_orders_page('+literal(token)+','+str(limit)+','+(str(before['before_at']) if before else 'NULL')+','+(literal(before['before_id']) if before else 'NULL')+','+str(offset)+')::text;')
def all_pages(token,first=None):
 r=first or page(token);rows=r['items'];seen=set()
 while r['next']:
  cursor=json.dumps(r['next'],sort_keys=True);assert cursor not in seen;seen.add(cursor)
  r=page(token,r['next']);rows+=r['items']
 return rows

def staff(f,suffix,role):
 token=secrets.token_hex(32);uid=f['p']+suffix
 run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+','.join(map(literal,[uid,uid+'@example.invalid','Paging fixture','unused',role]))+",false,true,(extract(epoch FROM clock_timestamp())*1000)::bigint); INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(token)+",'sha256'),'hex'),"+literal(uid)+",'unused',(extract(epoch FROM clock_timestamp())*1000)::bigint+600000,(extract(epoch FROM clock_timestamp())*1000)::bigint);")
 return token,uid

f=fixture(stock=30000,capacity=30);p=f['p']
q=val(quote(f,'ops-page-quote'));o=val(rpc('jana_critical_write',f['t'],'ops-page-confirm','order.confirm',{'quote_id':q['id']}));stamp=val('SELECT created_at FROM orders WHERE id='+literal(o['id'])+';')
# Cancelled fixture history consumes neither inventory nor delivery capacity.
run("INSERT INTO quotes SELECT clone.* FROM quotes q CROSS JOIN generate_series(1,120)n CROSS JOIN LATERAL jsonb_populate_record(NULL::quotes,to_jsonb(q)||jsonb_build_object('id',"+literal(p)+"||'q'||lpad(n::text,3,'0'),'snapshot','{}'::json,'created_at',"+str(stamp-1000)+"))clone WHERE q.id="+literal(q['id'])+';')
run("INSERT INTO orders SELECT clone.* FROM orders o CROSS JOIN generate_series(1,120)n CROSS JOIN LATERAL jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id',"+literal(p)+"||'o'||lpad(n::text,3,'0'),'number',"+literal(p)+"||lpad(n::text,3,'0'),'quote_id',"+literal(p)+"||'q'||lpad(n::text,3,'0'),'snapshot','{}'::json,'original_snapshot','{}'::json,'created_at',"+str(stamp-1000)+",'status','cancelled','fulfillment_state','cancelled','delivery_state','cancelled','payment_state','cancelled','total_halalas',0,'code_hash',NULL))clone WHERE o.id="+literal(o['id'])+';')
expected=val("SELECT coalesce(jsonb_agg(id ORDER BY created_at DESC,id DESC),'[]'::jsonb) FROM orders;")
first=page(f['atok']);assert len(first['items'])==25 and first['next_offset']==25
q2=val(quote(f,'ops-page-newer-quote'));new=val(rpc('jana_critical_write',f['t'],'ops-page-newer-confirm','order.confirm',{'quote_id':q2['id']}))
rows=all_pages(f['atok'],first);ids=[x['id'] for x in rows]
assert ids==expected and len(ids)==len(set(ids)) and len(ids)>100 and new['id'] not in ids
assert page(f['atok'])['items'][0]['id']==new['id']
assert [x['id'] for x in page(f['atok'],offset=25)['items']]==[x['id'] for x in all_pages(f['atok'])][25:50]
passed('staff keyset pages reach tied-time history beyond 100 without shifts from new orders and retain offset compatibility')
for role in ['admin','finance','support']:
 token=f['atok'] if role=='admin' else staff(f,role,role)[0]
 actual=all_pages(token);legacy=val(rpc('jana_admin_orders',token))
 assert {x['id']:x for x in actual}=={x['id']:x for x in legacy}
 assert all('code_hash' not in x and 'user_id' not in x for x in actual)
passed('admin finance and support see the same permitted fields and complete history as the established contract')
pt,pid=staff(f,'picker','picker');otherpt,otherpid=staff(f,'otherpicker','picker');inventory,_=staff(f,'inventory','inventory')
assert o['id'] in [x['id'] for x in all_pages(pt)]
val(rpc('jana_ops_transition',pt,o['id'],'start',''))
assert o['id'] in [x['id'] for x in all_pages(pt)] and o['id'] not in [x['id'] for x in all_pages(otherpt)]
for token in [pt,otherpt]:
 assert {x['id']:x for x in all_pages(token)}=={x['id']:x for x in val(rpc('jana_ops_orders',token,'picker'))}
val(rpc('jana_finalize_picking',pt,o['id']))
assert o['id'] not in [x['id'] for x in all_pages(pt)]
passed('picker paging retains claimable queued work and assigned work but hides another picker and completed preparation')
other=fixture()
assert o['id'] in [x['id'] for x in all_pages(f['ct'])] and o['id'] in [x['id'] for x in all_pages(other['ct'])]
val(rpc('jana_ops_transition',f['ct'],o['id'],'dispatch',''))
assert o['id'] not in [x['id'] for x in all_pages(other['ct'])]
val(rpc('jana_critical_write',f['ct'],'ops-page-deliver','order.deliver',{'order_id':o['id'],'code':o['delivery_code']}))
assert next(x for x in all_pages(f['ct']) if x['id']==o['id'])['payment_state']=='awaiting_collection'
val(rpc('jana_critical_write',f['ct'],'ops-page-collect','cod.collect',{'order_id':o['id'],'amount_halalas':o['total_halalas']}))
assert next(x for x in all_pages(f['ct']) if x['id']==o['id'])['cash_liability_halalas']==2000
val(rpc('jana_critical_write',f['atok'],'ops-page-partial-settle','cod.settle',{'order_id':o['id'],'amount_halalas':700,'reference':'Disposable paging partial deposit'}))
assert next(x for x in all_pages(f['ct']) if x['id']==o['id'])['cash_liability_halalas']==1300
for token in [f['ct'],other['ct']]:assert {x['id']:x for x in all_pages(token)}=={x['id']:x for x in val(rpc('jana_ops_orders',token,'courier'))}
val(rpc('jana_critical_write',f['atok'],'ops-page-final-settle','cod.settle',{'order_id':o['id'],'reference':'Disposable paging final deposit'}))
assert o['id'] not in [x['id'] for x in all_pages(f['ct'])]
passed('courier pages preserve delivery collection and partial cash liability until fully settled with assignment isolation')
for token in [f['t'],inventory]:denied('SELECT jana_ops_orders_page('+literal(token)+');','forbidden')
for args in ['0,NULL,NULL,0','101,NULL,NULL,0','25,1,NULL,0',"25,1,'x',1",'25,NULL,NULL,-1','25,NULL,NULL,1000001',"25,-1,'x',0","25,9007199254740992,'x',0","25,1,'',0"]:
 denied('SELECT jana_ops_orders_page('+literal(f['atok'])+','+args+');','invalid_orders_page')
assert page(f['atok'],{'before_at':0,'before_id':'missing'})=={'items':[],'next':None,'next_offset':None}
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_ops_orders_page' AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
assert val("SELECT to_jsonb(has_function_privilege('service_role','public.jana_ops_orders_page(text,integer,bigint,text,integer)','EXECUTE'));")
passed('page validation role boundaries and service-only execution match the custom session access model')
before=balance(f);all_pages(f['atok']);assert balance(f)==before
assert val('SELECT jana_deep_health();')['ok']
passed('paged reads leave stock delivery capacity and financial invariants intact')
print(json.dumps({'passed':len(checks),'checks':checks}))
