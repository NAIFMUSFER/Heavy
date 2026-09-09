from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
f=fixture();data={'label':'Home','details':'Building fixture','city':'Jazan','district':'Fixture district','street':'Fixture street','building':'12','floor':'2','apartment':'3','notes':'Disposable fixture','recipient_name':'Fixture customer','recipient_phone':'0500000000','latitude':16.5,'longitude':42.5,'is_default':True}
def save(f,data,id=None):return 'SELECT public.jana_save_address('+literal(f['t'])+','+(literal(id) if id else 'NULL')+','+literal(json.dumps(data))+'::jsonb)::text;'
a=val(save(f,data));assert all(str(a[k])==str(v) for k,v in data.items());passed('structured address fields round-trip with explicit coordinates')
for changes in [{'latitude':None},{'longitude':''},{'latitude':'NaN'},{'longitude':181},{'latitude':-91},{'recipient_phone':'wrong'},{'label':None},{'is_default':'false'}]:
 r=run(save(f,{**data,**changes}),False);assert not r['ok'];assert 'invalid_coordinates' in r['error'] or 'address_validation' in r['error'],r
passed('missing nonfinite out-of-range coordinates and malformed address fields rejected')
other=fixture();r=run(save(other,{'notes':'not allowed'},a['id']),False);assert not r['ok'] and 'invalid_address' in r['error'];passed('customer cannot edit another customer address')
a=val(save(f,{'notes':'updated only'},a['id']));assert a['city']=='Jazan' and a['notes']=='updated only';passed('partial update preserves structured fields')
inside=val(rpc('jana_customer_coverage',f['t'],a['id']));assert inside['covered'];outside=val(save(f,{'latitude':24.7,'longitude':46.7},a['id']));assert not val(rpc('jana_customer_coverage',f['t'],a['id']))['covered'];passed('coverage uses geometry rather than city text')
rows=successful(race([save(f,{**data,'label':'Address '+str(i)}) for i in range(16)]));assert len(rows)==16;count=val('SELECT count(*) FROM addresses WHERE user_id='+literal(f['p']+'u')+' AND is_default;');assert count==1;passed('sixteen address mutations preserve one default')
default=val('SELECT to_jsonb(a) FROM addresses a WHERE user_id='+literal(f['p']+'u')+' AND is_default;');val(rpc('jana_delete_address',f['t'],default['id']));assert val('SELECT count(*) FROM addresses WHERE user_id='+literal(f['p']+'u')+' AND is_default;')==1;passed('deleting default promotes one remaining address')
q=val(quote(other,'address-snapshot-key'));o=val(rpc('jana_critical_write',other['t'],'address-confirm-key','order.confirm',{'quote_id':q['id']}));before=val('SELECT original_snapshot::jsonb->\'address\' FROM orders WHERE id='+literal(o['id'])+';');val(rpc('jana_delete_address',other['t'],other['p']+'addr'));after=val('SELECT original_snapshot::jsonb->\'address\' FROM orders WHERE id='+literal(o['id'])+';');assert before==after;passed('deleting saved address cannot alter sold order snapshot')
print(json.dumps({'passed':len(checks),'checks':checks}))
