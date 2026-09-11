from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
f=fixture();q=val(quote(f,'checkout-recovery'));qid=q['id']
before=balance(f);detail=val(rpc('jana_quote_detail',f['t'],qid))
assert detail['id']==qid and detail['state']=='active' and detail['order'] is None
assert detail['created_at']<=detail['server_now']<detail['expires_at']
assert detail['lines']==q['lines'] and balance(f)==before
passed('read-only review returns frozen terms and server time without changing stock or capacity')
for token in [f['ct'],f['atok'],'invalid-session']:
 result=run(rpc('jana_quote_detail',token,qid),False);assert not result['ok'],result
assert not val("SELECT has_function_privilege('anon','jana_quote_detail(text,text)','EXECUTE');")
assert not val("SELECT has_function_privilege('authenticated','jana_quote_detail(text,text)','EXECUTE');")
passed('custom session ownership and service-only privileges remain enforced')
o=val(rpc('jana_critical_write',f['t'],'checkout-confirm','order.confirm',{'quote_id':qid}))
detail=val(rpc('jana_quote_detail',f['t'],qid));assert detail['order']['id']==o['id']
assert set(detail['order'])=={'id','number','status','total_halalas','payment_state','fulfillment_state','delivery_state'}
assert 'delivery_code' not in json.dumps(detail) and 'code_hash' not in json.dumps(detail)
assert detail['state']=='converted' and balance(f)==before
assert val(rpc('jana_critical_write',f['t'],'checkout-confirm','order.confirm',{'quote_id':qid}))['id']==o['id']
assert val('SELECT count(*) FROM orders WHERE quote_id='+literal(qid)+';')==1
passed('lost confirmation response resolves to one existing order without returning its secret code')
cancel=val(rpc('jana_cancel_quote',f['t'],qid));assert cancel['state']=='converted'
assert val(rpc('jana_quote_detail',f['t'],qid))['order']['status']=='active' and balance(f)==before
passed('cancelling a converted quote does not cancel an order or release its resources')
val(rpc('jana_cancel_order',f['t'],o['id']))
assert val(rpc('jana_quote_detail',f['t'],qid))['order']['status']=='cancelled'
passed('a subsequently cancelled order remains discoverable with its actual status')
f=fixture();q=val(quote(f,'checkout-expired'));qid=q['id']
run('UPDATE quotes SET expires_at=1 WHERE id='+literal(qid)+';')
detail=val(rpc('jana_quote_detail',f['t'],qid));assert detail['expires_at']<detail['server_now'] and detail['order'] is None
val(rpc('jana_cancel_quote',f['t'],qid));assert val(rpc('jana_quote_detail',f['t'],qid))['state']=='cancelled'
assert balance(f)['reserved']==0 and balance(f)['booked']==0
passed('expired review can be released exactly once without creating an order')
# Untrusted snapshot metadata must never replace authoritative state or order.
run("UPDATE quotes SET snapshot=(snapshot::jsonb||'{\"id\":\"wrong\",\"state\":\"converted\",\"server_now\":0,\"order\":{\"id\":\"wrong\"}}'::jsonb)::json WHERE id="+literal(qid)+';')
detail=val(rpc('jana_quote_detail',f['t'],qid));assert detail['id']==qid and detail['state']=='cancelled' and detail['order'] is None and detail['server_now']>0
passed('quote metadata cannot override authoritative lifecycle and order association')
print(json.dumps({'ok':True,'checks':len(checks)}))
