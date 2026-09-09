from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def lot(f):return val('SELECT to_jsonb(l) FROM inventory_lots l WHERE id='+literal(f['p']+'l')+';')
def prepare(f,key,actual=None):
 q=val(quote(f,key));o=val(rpc('jana_critical_write',f['t'],key+'confirm','order.confirm',{'quote_id':q['id']}));val(rpc('jana_ops_transition',f['atok'],o['id'],'start',''))
 if actual:val(rpc('jana_picker_record_actual',f['atok'],o['id'],q['lines'][0]['line_id'],actual))
 val(rpc('jana_finalize_picking',f['atok'],o['id']));return o
def deliver(f,o):
 val(rpc('jana_ops_transition',f['ct'],o['id'],'dispatch',''));val(rpc('jana_critical_write',f['ct'],'deliver-'+o['id'],'order.deliver',{'order_id':o['id'],'code':o['delivery_code']}))
def report(f):return val(rpc('jana_admin_reports',f['atok']))
f=fixture();o=prepare(f,'cost-picking',800);l=lot(f);assert l['on_hand_base']==9200 and l['remaining_cost_halalas']==920
entry=val('SELECT to_jsonb(c) FROM inventory_cost_entries c WHERE order_id='+literal(o['id'])+';');assert entry['value_delta_halalas']==-80 and entry['cost_basis']=='recorded';passed('actual picked quantity consumes proportional recorded lot cost')
r=run(rpc('jana_finalize_picking',f['atok'],o['id']),False);assert not r['ok'];assert val('SELECT count(*) FROM inventory_cost_entries WHERE order_id='+literal(o['id'])+';')==1;passed('duplicate picking cannot double consume cost')
before=report(f);deliver(f,o);after=report(f);assert after['known_cogs_7d_halalas']-before['known_cogs_7d_halalas']==80;assert after['sales_7d_halalas']-before['sales_7d_halalas']==1600;assert len(after['daily'])==7 and after['daily'][-1]['sales_halalas']==after['today_sales_halalas'];assert sum(x['sales_halalas'] for x in after['daily'])==after['sales_7d_halalas'];passed('sales report includes consumed COGS and seven Saudi calendar days')
f2=fixture(stock=3);run('UPDATE inventory_lots SET total_cost_halalas=100,remaining_cost_halalas=100 WHERE id='+literal(f2['p']+'l')+';')
for qty in [2,1,0]:val(rpc('jana_inventory_adjust_lot',f2['atok'],f2['p']+'l',qty,'Disposable counted loss'))
assert lot(f2)['remaining_cost_halalas']==0;assert val('SELECT sum(-value_delta_halalas) FROM inventory_cost_entries WHERE lot_id='+literal(f2['p']+'l')+';')==100;passed('partial quantity rounding conserves all purchase cost')
f3=fixture();run('UPDATE inventory_lots SET total_cost_halalas=NULL,remaining_cost_halalas=NULL,cost_basis=\'unknown\' WHERE id='+literal(f3['p']+'l')+';');unknown=prepare(f3,'unknown-cost');deliver(f3,unknown);r=report(f3);assert r['cost_status']=='unknown' and r['orders_with_unknown_cost']>=1 and r['gross_profit_7d_halalas'] is None and r['gross_margin_bps'] is None
assert val('SELECT jsonb_agg(value_delta_halalas) FROM inventory_cost_entries WHERE order_id='+literal(unknown['id'])+';')==[None];passed('unknown purchase cost stays unknown and prevents invented profit')
f4=fixture();val(rpc('jana_inventory_adjust_lot',f4['atok'],f4['p']+'l',12000,'Disposable found stock'));assert lot(f4)['remaining_cost_halalas']==1200 and lot(f4)['cost_basis']=='estimated';est=prepare(f4,'estimated-cost');deliver(f4,est);assert report(f4)['orders_with_estimated_cost']>=1;passed('found-stock valuation and later consumption are explicitly estimated')
before=report(f)['inventory_value_halalas'];received=val('SELECT jana_inventory_receive_lot('+','.join(literal(v) if v is not None else 'NULL' for v in [f['atok'],f['p']+'st',None,1000,500,4102444800000])+')::text;');assert report(f)['inventory_value_halalas']==before;val(rpc('jana_inventory_inspect_lot',f['atok'],received['id'],'rejected','Disposable rejected shipment'));assert report(f)['inventory_value_halalas']==before;passed('pending and rejected lots do not inflate usable inventory valuation')
received=val('SELECT jana_inventory_receive_lot('+','.join(literal(v) if v is not None else 'NULL' for v in [f['atok'],f['p']+'st',None,1000,500,4102444800000])+')::text;');val(rpc('jana_inventory_inspect_lot',f['atok'],received['id'],'accepted','Disposable accepted shipment'));assert report(f)['inventory_value_halalas']==before+500
r=run(rpc('jana_inventory_inspect_lot',f['atok'],received['id'],'accepted','Duplicate inspection'),False);assert not r['ok'];assert val('SELECT count(*) FROM inventory_cost_entries WHERE lot_id='+literal(received['id'])+';')==1;passed('accepted receipt recognizes inventory cost exactly once')
r=run('UPDATE inventory_cost_entries SET value_delta_halalas=0 WHERE id='+literal(entry['id'])+';',False);assert not r['ok'] and 'append_only_ledger' in r['error'];passed('inventory cost ledger rejects destructive edits')
r=run(rpc('jana_admin_reports',f['t']),False);assert not r['ok'] and 'forbidden' in r['error'];assert val("SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='inventory_cost_entries' AND grantee IN ('anon','authenticated','PUBLIC');")==0;passed('customer role cannot access financial report or cost ledger')
print(json.dumps({'passed':len(checks),'checks':checks}))
