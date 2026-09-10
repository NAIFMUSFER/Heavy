from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 result=run(query,False);assert not result['ok'] and code in result['error'],result

def history(f,**filters):return val(rpc('jana_stock_movement_history',f['atok'],{'stock_id':f['p']+'st',**filters}))
f=fixture();q=val(quote(f,'movement-quote-fixture'));reserved=history(f)['items'];assert any(x['on_hand_delta']==0 and x['reserved_delta']==1000 and not x['has_cost_entry'] for x in reserved);val(rpc('jana_cancel_quote',f['t'],q['id']));rows=history(f)['items'];assert sum(x['reserved_delta'] for x in rows)==0;passed('reservation and release show actual deltas without inventing purchase cost')
body={'lot_id':f['p']+'l','kind':'waste','quantity_base':100,'revision':0,'reason':'Ledger fixture disposal','reference':'LEDGER-DOC-%_'}
event=val(rpc('jana_inventory_dispose',f['atok'],'movement-waste-fixture',body));rows=history(f,reason='waste',reference=body['reference'])['items'];assert len(rows)==1;row=rows[0];assert row['id']==event['movement_id'] and row['on_hand_delta']==-100 and row['reserved_delta']==0 and row['value_delta_halalas']==-10 and row['cost_basis']=='recorded';assert row['document_reference']==body['reference'] and row['disposal_reason']==body['reason'];assert history(f,reference='%')['items']==[];passed('disposal history joins real document and signed cost using literal exact references')
run("UPDATE inventory_lots SET total_cost_halalas=NULL,remaining_cost_halalas=NULL,cost_basis='unknown' WHERE id="+literal(f['p']+'l')+';');body.update(kind='damage',revision=1,reference='UNKNOWN-COST');val(rpc('jana_inventory_dispose',f['atok'],'movement-unknown-fixture',body));row=history(f,reason='damage')['items'][0];assert row['has_cost_entry'] and row['value_delta_halalas'] is None and row['cost_basis']=='unknown';passed('unknown cost entries differ from reservation events that have no cost entry')
f=fixture();stamp=1900000000000
run("INSERT INTO stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at) SELECT "+literal(f['p'])+"||lpad(i::text,3,'0'),"+literal(f['p']+'st')+","+literal(f['p']+'l')+",0,0,'fixture_history','PAGE',NULL,"+str(stamp)+" FROM generate_series(1,53) i;")
first=history(f);assert len(first['items'])==50 and first['next'];assert all(x['created_at']==stamp for x in first['items']);assert all(x['actor_name'] is None and x['actor_id'] is None for x in first['items']);c=first['next'];run("INSERT INTO stock_movements(id,stock_id,on_hand_delta,reserved_delta,reason,reference,created_at) VALUES("+literal(f['p']+'new')+','+literal(f['p']+'st')+",0,0,'fixture_history','NEW',"+str(stamp+1)+");")
second=val(rpc('jana_stock_movement_history',f['atok'],{'stock_id':f['p']+'st'},c['before_at'],c['before_id']));ids=[x['id'] for x in first['items']+second['items']];assert len(ids)==53 and len(set(ids))==53 and second['next'] is None;passed('same-timestamp keyset pages remain complete and distinct after a new concurrent insert')
rows=history(f,from_at=str(stamp),to_at=str(stamp+1),lot_id=f['p']+'l')['items'];assert len(rows)==50;assert history(f,from_at=str(stamp+1),to_at=str(stamp+2))['items'][0]['reference']=='NEW';assert history(f,lot_id='nonexistent')['items']==[];passed('canonical lot and stock filters plus half-open time ranges preserve boundaries')
for filters in [None,[],{'unknown':'x'},{'from_at':'tomorrow'},{'from_at':'2','to_at':'1'},{'stock_id':123},{'reference':''},{'lot_id':'x'*37}]:
 query='SELECT jana_stock_movement_history('+literal(f['atok'])+','+literal(json.dumps(filters))+'::jsonb);';fails(query,'movement_filters_invalid')
fails('SELECT jana_stock_movement_history('+literal(f['atok'])+",'{}',1,NULL);",'movement_filters_invalid');passed('invalid filters and incomplete cursors are rejected by the database')
for token in [f['t'],f['ct']]:fails(rpc('jana_stock_movement_history',token),'forbidden')
for role in ['inventory','finance']:
 run('UPDATE users SET role='+literal(role)+' WHERE id='+literal(f['p']+'a')+';');rows=history(f)['items'];assert rows;assert all(not ({'email','phone','token','password_hash','address'}&set(x)) for x in rows)
passed('inventory and finance can read bounded evidence while customer and courier cannot')
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='jana_stock_movement_history' AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0;assert val('SELECT jana_deep_health();')['ok'];passed('service-only function grants and existing commerce invariants remain intact')
print(json.dumps({'passed':len(checks),'scope':'stock movement history'}))
