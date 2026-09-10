from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
f=fixture(stock=12500);p=f['p'];category=p+'catalog'
run("INSERT INTO offerings(id,family_id,version,kind,name,description,category,size_label,emoji,image_url,sale_unit,price_halalas,components,active,created_at) SELECT "+literal(p)+"||'-cat-'||lpad(n::text,3,'0'),"+literal(p)+"||'-fam-'||lpad(n::text,3,'0'),1,o.kind,'Catalog %_ literal '||n,o.description,"+literal(category)+",o.size_label,o.emoji,o.image_url,o.sale_unit,o.price_halalas,o.components,true,o.created_at FROM offerings o CROSS JOIN generate_series(1,123) n WHERE o.id="+literal(p+'off')+';')
def page(offset=0,limit=100,query='',cat=category):return val(rpc('jana_catalog_page',offset,limit,query,cat))
a=page();b=page(a['next_offset']);assert len(a['items'])==100 and a['next_offset']==100 and len(b['items'])==23 and b['next_offset'] is None
ids=[x['id'] for x in a['items']+b['items']];assert len(set(ids))==123 and ids==sorted(ids);assert page(123)=={'items':[],'next_offset':None};passed('bounded pages use deterministic timestamp and id ordering without duplicates or phantom next pages')
legacy={x['id']:x for x in val('SELECT jana_public_catalog();')};assert all(x==legacy[x['id']] for x in a['items']+b['items']);assert all(x['available_units']==12 for x in a['items']);passed('paged items preserve exact legacy prices components identities and usable availability')
assert len(page(query='%_')['items'])==100;assert page(query='not present')['items']==[];assert page(cat='unknown-category')['items']==[];assert len(page(limit=1)['items'])==1;passed('literal substring and category filters are applied before pagination')
run('UPDATE offerings SET active=false WHERE id='+literal(ids[0])+';');assert page(limit=1)['items'][0]['id']==ids[1];passed('inactive offerings are excluded before offset and page calculation')
baseline=balance(f);nowms=val("SELECT (extract(epoch from clock_timestamp())*1000)::bigint;")
val(rpc('jana_inventory_write',f['atok'],'catalog-receipt-key','lot.receive',{'stock_id':p+'st','received_base':100000,'total_cost_halalas':None,'expires_at':nowms+86400000}));assert page(limit=1)['items'][0]['available_units']==12
run('UPDATE inventory_lots SET expires_at='+str(nowms-60000)+' WHERE id='+literal(p+'l')+';');assert page(limit=1)['items'][0]['available_units']==0;passed('pending inspection and expired lots never inflate advertised availability')
run('UPDATE inventory_lots SET expires_at='+str(nowms+86400000)+' WHERE id='+literal(p+'l')+';');run('UPDATE stock_items SET active=false WHERE id='+literal(p+'st')+';');assert page(limit=1)['items'][0]['available_units']==0;run('UPDATE stock_items SET active=true WHERE id='+literal(p+'st')+';');assert balance(f)==baseline;passed('inactive stock is unavailable and catalog reads never reserve stock or slot capacity')
for args in [(-1,50,'',''),(0,0,'',''),(0,101,'',''),(100001,1,'',''),(0,1,'q'*201,''),(0,1,'','c'*101)]:
 r=run(rpc('jana_catalog_page',*args),False);assert not r['ok'] and 'invalid_catalog_page' in r['error'],r
r=run('SELECT jana_catalog_page(NULL,50,\'\',\'\');',False);assert not r['ok'] and 'invalid_catalog_page' in r['error'];passed('database validates limits offsets and filter lengths independently of the API')
assert val("SELECT jsonb_build_object('anon',has_function_privilege('anon','jana_catalog_page(integer,integer,text,text)','EXECUTE'),'authenticated',has_function_privilege('authenticated','jana_catalog_page(integer,integer,text,text)','EXECUTE'),'service',has_function_privilege('service_role','jana_catalog_page(integer,integer,text,text)','EXECUTE'));")=={'anon':False,'authenticated':False,'service':True};passed('public catalog still uses the trusted service layer without direct client RPC grants')
print(json.dumps({'passed':len(checks),'checks':checks}))
