from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
f=fixture();p=f['p'];family=val('SELECT to_jsonb(family_id) FROM offerings WHERE id='+literal(p+'off')+';');items=[{'offering_family_id':family,'quantity':2}]
def read(token=f['t']):return val(rpc('jana_customer_cart',token))
def write(key,revision,rows=items,token=f['t']):return 'SELECT jana_save_customer_cart('+','.join(map(literal,[token,key,revision]))+','+literal(json.dumps(rows))+'::jsonb)::text;'
baseline=balance(f);assert read()=={'revision':0,'updated_at':None,'items':[]};passed('missing saved cart reads empty without creating rows or reservations')
a=val(write('save-fixture-cart',0,[dict(items[0],price_halalas=1,name='Untrusted',base_unit='piece')]));assert a['revision']==1 and a['saved'];r=read();assert r['items'][0]['price_halalas']==2000 and r['items'][0]['name']!='Untrusted';assert val('SELECT items FROM customer_carts WHERE user_id='+literal(p+'u')+';')==items;passed('only canonical stable product identities and quantities are persisted')
replay=val(write('save-fixture-cart',0,[dict(items[0],price_halalas=1,name='Untrusted',base_unit='piece')]));assert replay==a and read()['revision']==1
bad=run(write('save-fixture-cart',0,[]),False);assert not bad['ok'] and 'idempotency_conflict' in bad['error'];passed('same key request replays original result while changed body is rejected')
results=race([write('concurrent-cart-'+str(i),1,[dict(items[0],quantity=i+1)]) for i in range(8)]);assert len(successful(results))==1 and sum('cart_changed' in x['error'] for x in results)==7;assert read()['revision']==2;passed('concurrent devices cannot silently overwrite the same cart revision')
rows=[{'offering_family_id':family,'quantity':1}];queries=[write('same-cart-key',2,rows) for _ in range(8)];results=successful(race(queries));assert len(results)==8 and all(x==results[0] for x in results) and read()['revision']==3;passed('eight retried cart writes increment the revision only once')
g=fixture();assert read(g['t'])['items']==[];val(write('other-customer-cart',0,[],g['t']));assert read()['revision']==3
for t in [f['atok'],f['ct']]:
 bad=run(rpc('jana_customer_cart',t),False);assert not bad['ok'] and 'forbidden' in bad['error'];bad=run(write('staff-cart-write',0,[],t),False);assert not bad['ok'] and 'forbidden' in bad['error']
passed('customers read only their own cart and operational roles cannot use customer writes')
for n,rows in enumerate([[{'offering_family_id':'missing','quantity':1}],[dict(items[0],quantity='2')],[dict(items[0],quantity=0)],[dict(items[0],quantity=21)],[dict(items[0],quantity=11)]*2]):
 bad=run(write('invalid-cart-'+str(n),3,rows),False);assert not bad['ok'] and 'invalid_list_items' in bad['error'];assert read()['revision']==3
passed('invalid quantities identities and aggregate duplicates never change saved state')
val(rpc('jana_admin_new_offering_version',f['atok'],family,{'name':'New saved-cart version','price_halalas':2400}));r=read();assert r['items'][0]['price_halalas']==2400 and r['items'][0]['offering_id']!=p+'off';passed('restoration resolves the current offering version and price without trusting old client amounts')
run('UPDATE stock_items SET active=false WHERE id='+literal(p+'st')+';');r=read();assert len(r['items'])==1 and not r['items'][0]['available'];passed('unavailable saved selections are retained and explicitly marked')
val(write('clear-cart-fixture',3,[]));assert read()['items']==[] and read()['revision']==4;assert balance(f)==baseline;passed('explicit cart clearing and all saved-cart operations leave stock and delivery capacity unchanged')
assert val("SELECT jsonb_build_object('rls',(SELECT relrowsecurity FROM pg_class WHERE oid='public.customer_carts'::regclass),'client_grants',(SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_customer_cart','jana_save_customer_cart') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'))));")=={'rls':True,'client_grants':0};passed('cart table is protected by RLS and RPCs remain service-only')
print(json.dumps({'passed':len(checks),'checks':checks}))
