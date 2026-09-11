"""Commercial admission and version integrity in explicitly disposable PostgreSQL."""
from storefront_fixture import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def fails(query,code):
 r=run(query,False);assert not r['ok'] and code in r['error'],r
f=fixture();s=get_store(f)
for t in [f['t'],f['ct']]:
 fails(rpc('jana_admin_storefront',t),'forbidden')
 fails(rpc('jana_storefront_write',t,'store-role-fixture','draft.save',dict(revision=s['revision'],profile=PROFILE)),'forbidden')
assert 'draft' not in val('SELECT jana_public_storefront();')
passed('admin-only settings and public output containing only a published profile')
for profile in [None,[],dict(PROFILE,tax_status='unspecified'),dict(PROFILE,terms=True),dict(PROFILE,terms='x'*6001),dict(PROFILE,unknown='not allowed')]:
 fails(rpc('jana_storefront_write',f['atok'],'invalid-'+uuid.uuid4().hex,'draft.save',dict(revision=s['revision'],profile=profile)),'storefront_validation')
assert get_store(f)['revision']==s['revision']
passed('invalid typed or oversized profiles leave the saved revision unchanged')
public=val('SELECT jana_public_storefront();')
s=write_store(f,'draft.save',dict(revision=s['revision'],profile=dict(PROFILE,legal_name='A new fixture seller')))
assert val('SELECT jana_public_storefront();')==public
q=val(quote(f,'before-policy-change'));old=q['store_profile']
s=write_store(f,'profile.publish',dict(revision=s['revision'],confirmed=True))
assert s['published']['id']!=old['id']
assert val('SELECT jana_public_storefront('+literal(old['id'])+');')['published']==public['published']
assert val('SELECT snapshot::jsonb FROM quotes WHERE id='+literal(q['id'])+';')['store_profile']==old
passed('drafts remain private and new policy publication preserves old public versions and reserved quote terms')
intake(f,False);before=balance(f)
fails(quote(f,'new-quote-after-closure'),'storefront_closed');assert balance(f)==before
assert val(quote(f,'before-policy-change'))==q
order=val(rpc('jana_critical_write',f['t'],'confirm-after-closure','order.confirm',dict(quote_id=q['id'])))
o=val('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(order['id'])+';')
assert o['original_snapshot']['store_profile']==old and o['snapshot']['store_profile']==old and o['total_halalas']==q['total_halalas']
passed('closure blocks new reservations but cached quote retries and existing confirmations preserve seller version price and stock')
s=get_store(f)
profile=dict(PROFILE,tax_status='registered',tax_number='123456789012345')
s=write_store(f,'draft.save',dict(revision=s['revision'],profile=profile))
s=write_store(f,'profile.publish',dict(revision=s['revision'],confirmed=True))
payload=dict(revision=s['revision'],accepting_orders=True,message='Fixture customer message',reason='Fixture opening reason',reviewed=REVIEWED,reference='Fixture approval')
fails(rpc('jana_storefront_write',f['atok'],'tax-opening-fixture','intake.set',payload),'storefront_tax_setup_required')
assert not get_store(f)['accepting_orders']
passed('VAT-registered profile can be saved and published but cannot open unsupported tax and invoice operations')
s=write_store(f,'draft.save',dict(revision=s['revision'],profile=PROFILE))
s=write_store(f,'profile.publish',dict(revision=s['revision'],confirmed=True))
payload['revision']=s['revision']
fails(rpc('jana_storefront_write',f['atok'],'review-fixture','intake.set',dict(payload,reviewed=dict(REVIEWED,inventory=False))),'storefront_review_required')
preview=val(rpc('jana_admin_create_product_version',f['atok'],'',dict(title='Fixture preview',description='بيانات معاينة تجريبية',category='fruit',kind='individual',offerings=[dict(sellable_key='preview',size_label='Fixture',sale_unit='kg',price_halalas=2000,components=[dict(stock_id=f['p']+'st',base_qty=1000)])])))
val(rpc('jana_admin_activate_product_version',f['atok'],preview['id']))
fails(rpc('jana_storefront_write',f['atok'],'preview-fixture','intake.set',payload),'storefront_not_ready')
run('UPDATE offerings SET active=false WHERE id='+literal(preview['offerings'][0]['id'])+';')
s=intake(f,True)
passed('opening requires complete operations attestation and rejects known preview merchandise')
opened=get_store(f);review=opened['last_opening_review']
assert review['reference']=='CI-FIXTURE-ONLY' and review['reviewed']==REVIEWED and review['actor']['id']==f['p']+'a'
assert review['published_id']==opened['published_id'] and opened['opening_review_matches_published'] is True
passed('latest immutable opening review is visible to administrators and tied to the published policy')
q2=val(quote(f,'after-policy-change'));assert q2['store_profile']['id']==s['published']['id'] and q2['store_profile']['id']!=old['id']
passed('new quote binds to the currently published seller and policy version')
s=get_store(f);payload=dict(revision=s['revision'],profile=dict(PROFILE,display_name='Concurrent saved store'))
query=rpc('jana_storefront_write',f['atok'],'same-key-store','draft.save',payload)
rows=successful(race([query]*6));assert len(rows)==6 and all(x==rows[0] for x in rows)
assert get_store(f)['revision']==s['revision']+1
fails(rpc('jana_storefront_write',f['atok'],'same-key-store','draft.save',dict(payload,profile=PROFILE)),'idempotency_conflict')
passed('concurrent same-key requests produce one stored revision and reject conflicting key reuse')
open_store=get_store(f);published_id=open_store['published_id']
fails(rpc('jana_storefront_write',f['atok'],'publish-while-open','profile.publish',dict(revision=open_store['revision'],confirmed=True)),'storefront_close_before_publish')
assert get_store(f)['accepting_orders'] and get_store(f)['published_id']==published_id
passed('a policy version cannot change under an open intake without a fresh opening review')
intake(f,False)
s=get_store(f)
rows=race([rpc('jana_storefront_write',f['atok'],'publish-'+uuid.uuid4().hex,'profile.publish',dict(revision=s['revision'],confirmed=True)) for _ in range(2)])
assert len(successful(rows))==1 and all(r['ok'] or 'storefront_changed' in r['error'] for r in rows)
passed('competing publications from the same revision cannot silently replace each other')
s=get_store(f);b=balance(f)
rows=race([quote(f,'concurrent-store-close'),rpc('jana_storefront_write',f['atok'],'close-race-fixture','intake.set',dict(revision=s['revision'],accepting_orders=False,message='Fixture closure message',reason='Fixture closure reason'))])
assert rows[1]['ok'] and not get_store(f)['accepting_orders']
if rows[0]['ok']:assert balance(f)['reserved']==b['reserved']+1000
else:assert 'storefront_closed' in rows[0]['error'] and balance(f)==b
passed('concurrent closure and quotation serialize admission without partial reservations')
intake(f,True)
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_public_storefront','jana_admin_storefront','jana_storefront_write','jana_storefront_readiness','jana_create_quote_store_base') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_storefront_readiness','jana_storefront_profile_valid','jana_create_quote_store_base','jana_admin_storefront_pre_acceptance','jana_storefront_write_pre_acceptance') AND has_function_privilege('service_role',oid,'EXECUTE');")==0
assert val("SELECT count(*) FROM pg_trigger WHERE tgrelid='storefront_profiles'::regclass AND tgfoid='jana_append_only()'::regprocedure AND NOT tgisinternal;")==1
assert val('SELECT jana_deep_health();')['ok']
passed('immutable published versions private helpers and business invariants remain enforced')
print(json.dumps(dict(passed=len(checks),checks=checks)))
