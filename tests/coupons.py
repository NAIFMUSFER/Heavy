from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def create_coupon(f,**kw):
 args=dict(code='CP'+uuid.uuid4().hex[:16].upper(),amount_halalas=500,minimum_halalas=0,max_uses=20,expires_at=4102444800000,discount_type='fixed',percentage_bps=None);args.update(kw)
 sql='SELECT public.jana_admin_create_coupon_v2('+','.join(literal(v) if v is not None else 'NULL' for v in [f['atok'],*args.values()])+')::text;'
 return val(sql)
def cq(f,c,key='coupon-test-key',qty=1):
 return quote(f,key,qty).replace('jana_create_quote_idempotent','jana_create_quote_with_coupon').replace('::jsonb)::text;','::jsonb,'+literal(c['code'])+')::text;')
def state(c):return val('SELECT to_jsonb(c) FROM coupons c WHERE id='+literal(c['id'])+';')
def fails(sql,code):
 r=run(sql,False);assert not r['ok'] and code in r['error'],r
f=fixture();c=create_coupon(f);q=val(cq(f,c));assert q['discount_halalas']==500 and q['total_halalas']==1500;assert state(c)['reserved']==1;assert balance(f)['booked']==1;passed('fixed coupon reserves usage with stock and slot')
assert val(cq(f,c))==q and state(c)['reserved']==1
fails(cq(f,c,qty=2),'idempotency_conflict');fails(quote(f,'coupon-test-key'),'idempotency_conflict');passed('coupon retry replays once and altered request conflicts')
val(rpc('jana_cancel_quote',f['t'],q['id']));assert state(c)['reserved']==0 and balance(f)['reserved']==0 and balance(f)['booked']==0;passed('quote cancellation releases all three resources')
for change,code in [('active=false','coupon_unavailable'),('expires_at=1','coupon_expired'),('minimum_halalas=9999','coupon_minimum'),('max_uses=0','coupon_exhausted')]:
 c=create_coupon(f);run('UPDATE coupons SET '+change+' WHERE id='+literal(c['id'])+';');before=balance(f);fails(cq(f,c,'invalid-'+c['id']),code);assert balance(f)==before and state(c)['reserved']==0
passed('inactive expired minimum and exhausted coupon failures roll back reservations')
c=create_coupon(f);q=val(cq(f,c,'expires-coupon-key'));run('UPDATE quotes SET expires_at=1 WHERE id='+literal(q['id'])+';');run('SELECT jana_expire_quotes();');assert state(c)['reserved']==0 and balance(f)['booked']==0;passed('expiry releases coupon stock and delivery capacity')
c=create_coupon(f,amount_halalas=5000);q=val(cq(f,c,'capped-coupon-key'));assert q['discount_halalas']==2000 and q['total_halalas']==0;val(rpc('jana_cancel_quote',f['t'],q['id']));passed('discount cannot exceed merchandise subtotal')
c=create_coupon(f,discount_type='percentage',percentage_bps=1250);q=val(cq(f,c,'percent-coupon-key'));assert q['discount_halalas']==250 and q['total_halalas']==1750
orders=successful(race([rpc('jana_critical_write',f['t'],'coupon-confirm-key','order.confirm',{'quote_id':q['id']})]*16));assert len(orders)==16 and all(o==orders[0] for o in orders);o=orders[0];assert state(c)['reserved']==0 and state(c)['redeemed']==1;passed('concurrent confirmation redeems percentage coupon once')
val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''))
r=val(rpc('jana_picker_record_actual',f['atok'],o['id'],q['lines'][0]['line_id'],800));assert r['total_halalas']==1400 and r['snapshot']['discount_halalas']==200
run('UPDATE coupons SET percentage_bps=9900 WHERE id='+literal(c['id'])+';')
r=val(rpc('jana_picker_record_actual',f['atok'],o['id'],q['lines'][0]['line_id'],800));assert r['total_halalas']==1400;passed('actual weight preserves original sold discount despite later coupon changes')
fixtures=[fixture() for _ in range(16)];c=create_coupon(fixtures[0],max_uses=1);rows=race([cq(ff,c,'last-coupon-key') for ff in fixtures]);assert len(successful(rows))==1;assert all(r['ok'] or 'coupon_exhausted' in r['error'] for r in rows);assert sum(balance(ff)['booked'] for ff in fixtures)==1;assert sum(balance(ff)['reserved'] for ff in fixtures)==1000;assert state(c)['reserved']==1;passed('sixteen distinct slots compete for last coupon usage without partial reservations')
assert val("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('jana_create_quote_with_coupon','jana_admin_create_coupon_v2','jana_coupon_quote_transition','jana_preserve_order_discount') AND (has_function_privilege('anon',p.oid,'EXECUTE') OR has_function_privilege('authenticated',p.oid,'EXECUTE')); ")==0;passed('coupon writes remain unavailable to direct client roles')
print(json.dumps({'passed':len(checks),'checks':checks}))
