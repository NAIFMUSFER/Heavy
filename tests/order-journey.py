from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def denied(query,message):
 r=run(query,False);assert not r['ok'] and message in r['error'],r

f=fixture(capacity=30);p=f['p'];q=val(quote(f,'journey-quote'));o=val(rpc('jana_critical_write',f['t'],'journey-confirm','order.confirm',{'quote_id':q['id']}));oid=o['id'];stamp=val('SELECT created_at FROM orders WHERE id='+literal(oid)+';')
# Cancelled historical fixture rows do not consume stock or slot reservations.
run("INSERT INTO quotes SELECT clone.* FROM quotes q CROSS JOIN generate_series(1,120)n CROSS JOIN LATERAL jsonb_populate_record(NULL::quotes,to_jsonb(q)||jsonb_build_object('id',"+literal(p)+"||'q'||lpad(n::text,3,'0'),'snapshot','{}'::json,'created_at',"+str(stamp-1000)+"))clone WHERE q.id="+literal(q['id'])+';')
run("INSERT INTO orders SELECT clone.* FROM orders o CROSS JOIN generate_series(1,120)n CROSS JOIN LATERAL jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id',"+literal(p)+"||'o'||lpad(n::text,3,'0'),'number',"+literal(p)+"||lpad(n::text,3,'0'),'quote_id',"+literal(p)+"||'q'||lpad(n::text,3,'0'),'snapshot','{}'::json,'original_snapshot','{}'::json,'created_at',"+str(stamp-1000)+",'status','cancelled','fulfillment_state','cancelled','delivery_state','cancelled','payment_state','cancelled','total_halalas',0,'code_hash',NULL))clone WHERE o.id="+literal(oid)+';')
def page(before=None,token=f['t'],offset=0):return val('SELECT jana_orders_page('+literal(token)+',25,'+(str(before['before_at']) if before else 'NULL')+','+(literal(before['before_id']) if before else 'NULL')+','+str(offset)+')::text;')
first=page();assert len(first['items'])==25 and first['next_offset']==25
newq=val(quote(f,'journey-newer-quote'));neworder=val(rpc('jana_critical_write',f['t'],'journey-newer-confirm','order.confirm',{'quote_id':newq['id']}))
rows=first['items'];cursor=first['next']
while cursor:
 result=page(cursor);rows+=result['items'];cursor=result['next']
ids=[r['id'] for r in rows];assert len(ids)==121 and len(set(ids))==121 and neworder['id'] not in ids
assert page()['items'][0]['id']==neworder['id'];assert len(page(offset=25)['items'])==25
passed('keyset pages beyond 100 orders preserve tied timestamps while new orders arrive; legacy offset remains supported')
assert page(token=f['ct'])['items']==[]
for fn in ['jana_order_detail','jana_customer_tracking']:denied(rpc(fn,f['ct'],oid),'order_not_found')
for args in ['0,NULL,NULL,0','101,NULL,NULL,0','25,1,NULL,0',"25,1,'x',1",'25,NULL,NULL,-1']:
 denied('SELECT jana_orders_page('+literal(f['t'])+','+args+');','invalid_orders_page')
passed('order reads are account-scoped and malformed page cursors are rejected')
run("INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES("+literal(p+'internal')+','+literal(oid)+','+literal(p+'a')+",'cash_settled','private operator note','{\"secret\":\"private\"}',"+str(stamp+1)+');')
detail=val(rpc('jana_order_detail',f['t'],oid));assert detail['original_snapshot']['address']['id']==p+'addr';assert detail['original_snapshot']['slot']['id']==p+'s';assert detail['timeline'][0]['event']=='order_created';assert all(set(e)=={'id','event','created_at'} for e in detail['timeline']);assert 'private' not in json.dumps(detail['timeline']);assert detail['timeline_has_earlier'] is False
passed('order detail returns frozen delivery terms and a customer-safe timeline without actors or internal notes')
run("UPDATE orders SET fulfillment_state='ready',delivery_state='out_for_delivery',courier_id="+literal(p+'c')+' WHERE id='+literal(oid)+';')
def position(suffix,courier,at):
 run("INSERT INTO courier_positions(id,order_id,courier_id,latitude,longitude,accuracy_m,created_at) VALUES("+','.join(map(literal,[p+suffix,oid,p+courier]))+",16.5,42.5,20,"+str(at)+');')
position('old','c',stamp-600000);position('wrong','d',stamp)
# Existing journey started at order creation: an old attempt must not be exposed.
assert val(rpc('jana_customer_tracking',f['t'],oid))['latitude'] is None
position('current','c',stamp)
tracking=val(rpc('jana_customer_tracking',f['t'],oid));assert tracking['updated_at']==stamp and tracking['location_state']=='recent'
for state in ['failed','delivered','cancelled']:
 run('UPDATE orders SET delivery_state='+literal(state)+' WHERE id='+literal(oid)+';');assert val(rpc('jana_customer_tracking',f['t'],oid))['latitude'] is None
passed('tracking only exposes the assigned courier on an active delivery and hides previous attempts and ended journeys')
run("UPDATE orders SET delivery_state='out_for_delivery' WHERE id="+literal(oid)+';');run('UPDATE courier_positions SET created_at='+str(stamp-400000)+' WHERE id='+literal(p+'current')+';')
run('UPDATE orders SET created_at='+str(stamp-500000)+' WHERE id='+literal(oid)+';')
assert val(rpc('jana_customer_tracking',f['t'],oid))['location_state']=='stale'
run("INSERT INTO order_events(id,order_id,actor_id,event,reason,states,created_at) VALUES("+literal(p+'dispatch')+','+literal(oid)+','+literal(p+'c')+",'out_for_delivery','','{}',"+str(stamp)+');')
assert val(rpc('jana_customer_tracking',f['t'],oid))['latitude'] is None
passed('stale locations are explicit and redispatch cannot reuse an earlier location from the same courier')

f=fixture();p=f['p'];q=val(quote(f,'location-write-quote'));o=val(rpc('jana_critical_write',f['t'],'location-write-confirm','order.confirm',{'quote_id':q['id']}));oid=o['id']
denied(rpc('jana_courier_update_location',f['ct'],oid,16.5,42.5,15),'order_not_assigned')
run("UPDATE orders SET courier_id="+literal(p+'c')+' WHERE id='+literal(oid)+';')
denied(rpc('jana_courier_update_location',f['ct'],oid,16.5,42.5,15),'invalid_transition')
run("UPDATE orders SET fulfillment_state='ready',delivery_state='out_for_delivery' WHERE id="+literal(oid)+';')
for token in [f['t'],f['atok']]:denied(rpc('jana_courier_update_location',token,oid,16.5,42.5,15),'forbidden')
denied(rpc('jana_courier_update_location',f['ct'],oid,91,42,15),'invalid_coordinates')
denied(rpc('jana_courier_update_location',f['ct'],oid,16,42,-1),'invalid_coordinates')
point=val(rpc('jana_courier_update_location',f['ct'],oid,16.5,42.5,15));assert val(rpc('jana_customer_tracking',f['t'],oid))['updated_at']==point['created_at']
denied(rpc('jana_courier_update_location',f['ct'],oid,16.6,42.6,15),'location_rate_limit')
passed('explicit foreground location sharing requires the assigned outbound courier, validates accuracy and limits repeated writes')

f=fixture();p=f['p'];old='fixture-only-password!';new='ع'*36
before=val('SELECT to_jsonb(u) FROM users u WHERE id='+literal(p+'u')+';')
denied(rpc('jana_change_password',f['t'],'incorrect-current',new),'invalid_credentials')
for invalid in ['short','ع'*37,'😀'*19]:denied(rpc('jana_change_password',f['t'],old,invalid),'weak_password')
assert val('SELECT to_jsonb(u) FROM users u WHERE id='+literal(p+'u')+';')==before
passed('incorrect current passwords and oversized UTF-8 replacements cannot modify the account')
login=val(rpc('jana_login',p+'u@example.invalid',old));second=login['token']
result=val(rpc('jana_change_password',f['t'],old,new));assert result['all_sessions_revoked'] and result['sign_in_again']
assert val('SELECT count(*) FROM sessions WHERE user_id='+literal(p+'u')+';')==0
for token in [f['t'],second]:denied(rpc('jana_me',token),'unauthorized')
audit=val("SELECT detail::jsonb FROM audit_log WHERE action='password_changed' AND actor_id="+literal(p+'u')+';');assert audit=={'all_sessions_revoked':True}
assert val(rpc('jana_login',p+'u@example.invalid',old))['_error']=='invalid_credentials';assert 'token' in val(rpc('jana_login',p+'u@example.invalid',new));assert val('SELECT count(*) FROM sessions WHERE user_id='+literal(p+'a')+';')==1
passed('a valid 72-byte password change revokes current and other sessions, preserves other accounts, and logs no credentials')
f=fixture();p=f['p'];other=val(rpc('jana_login',p+'u@example.invalid',old))['token']
results=race([rpc('jana_change_password',f['t'],old,'first-new-password!'),rpc('jana_change_password',other,old,'second-new-password!')]);assert sum(r['ok'] for r in results)==1
assert val('SELECT count(*) FROM sessions WHERE user_id='+literal(p+'u')+';')==0
assert val("SELECT count(*) FROM audit_log WHERE action='password_changed' AND actor_id="+literal(p+'u')+';')==1
passed('concurrent password changes serialize and the revoked session cannot rotate the password again')
f=fixture();p=f['p']
results=race([rpc('jana_login',p+'u@example.invalid',old),rpc('jana_change_password',f['t'],old,'new-after-login-race!')]);assert results[1]['ok']
assert val('SELECT count(*) FROM sessions WHERE user_id='+literal(p+'u')+';')==0
passed('concurrent old-password login cannot leave a session alive after rotation')
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_orders_page','jana_order_detail','jana_customer_tracking','jana_courier_update_location','jana_change_password') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
passed('all customer journey and password functions remain service-only')
print(json.dumps({'passed':len(checks),'checks':checks}))
