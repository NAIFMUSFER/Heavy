from database_support import *
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def call(name,*args):return 'SELECT '+name+'('+','.join('NULL' if a is None else literal(a) for a in args)+')::text;'
def phone():return '05'+str(int(uuid.uuid4().hex[:12],16)%100000000).zfill(8)
password='Account-fixture-only-12!';number=phone();canonical='+966'+number[1:]
r=val(call('jana_register',None,'عميل دون بريد',password,number));uid=r['user']['id'];token=r['token'];assert r['user']['email'] is None and r['user']['phone']==canonical and r['user']['verified_phone'] is False and r['user']['role']=='customer';passed('phone-only registration uses a real password account without claiming verified phone ownership')
for identifier in [number,canonical]:
 login=val(call('jana_login',identifier,password));assert login['user']['id']==uid and len(login['token'])==64
passed('local and international Saudi phone forms reach the same account')
for supplied in [number,canonical]:
 fail=run(call('jana_register','duplicate-'+uuid.uuid4().hex+'@example.invalid','Duplicate fixture',password,supplied),False);assert not fail['ok'] and 'account_exists' in fail['error']
passed('normalized phone uniqueness prevents duplicate accounts across formats')
email='account-'+uuid.uuid4().hex+'@example.invalid';e=val(call('jana_register',email,'Email fixture',password,None));assert val(call('jana_login',email.upper(),password))['user']['id']==e['user']['id'];passed('existing email and password authentication remains compatible')
for email_arg,phone_arg in [(None,None),('',None),(None,'bad'),('bad',None)]:
 fail=run(call('jana_register',email_arg,'Invalid fixture',password,phone_arg),False);assert not fail['ok'] and ('account_identifier_required' in fail['error'] or 'invalid_email' in fail['error'])
for secret in [None,'','short',('ع'*40),('a'*73)]:
 fail=run(call('jana_register',None,'Password fixture',secret,phone()),False);assert not fail['ok'] and 'weak_password' in fail['error']
passed('missing identifiers and invalid passwords fail before creating an account')
for secret in [None,'','wrong']:
 out=val(call('jana_login',number,secret));assert out.get('_error')=='invalid_credentials' and 'token' not in out
rate_key='login:'+__import__('hashlib').sha256(canonical.encode()).hexdigest();assert val('SELECT count FROM rate_windows WHERE key='+literal(rate_key)+';')==3
for i in range(7):assert val(call('jana_login',number if i%2 else canonical,'wrong')).get('_error')=='invalid_credentials'
assert val(call('jana_login',canonical,password)).get('_error')=='too_many_attempts';passed('phone aliases share persistent failed-attempt counters and a common lockout')
run('UPDATE rate_windows SET expires_at=0 WHERE key='+literal(rate_key)+';');assert val(call('jana_login',number,password))['user']['id']==uid;passed('expired attempt windows allow valid credentials and clear the counter')
both_phone=phone();both_email='both-'+uuid.uuid4().hex+'@example.invalid';both=val(call('jana_register',both_email,'Both identifiers',password,both_phone));assert val(call('jana_login',both_phone,'wrong')).get('_error')=='invalid_credentials';assert val(call('jana_login',both_email,'wrong')).get('_error')=='invalid_credentials';key='login:'+__import__('hashlib').sha256(both_email.encode()).hexdigest();assert val('SELECT count FROM rate_windows WHERE key='+literal(key)+';')==2;passed('email and phone login aliases also share the same account rate bucket')
bad=run(rpc('jana_customer_profile',token,{'phone':''}),False);assert not bad['ok'] and 'profile_validation' in bad['error'];assert val(call('jana_login',number,password))['user']['id']==uid;passed('profile editing cannot remove the last usable login identifier')
bad=run(rpc('jana_customer_profile',token,{'phone':both_phone}),False);assert not bad['ok'] and 'phone_already_used' in bad['error'];assert val(call('jana_login',number,password))['user']['id']==uid;passed('profile updates cannot claim another normalized phone identity')
concurrent_phone=phone();results=race([call('jana_register',None,'Concurrent fixture',password,concurrent_phone) for _ in range(8)]);assert len(successful(results))==1 and sum('account_exists' in x['error'] for x in results)==7;passed('concurrent phone registration produces one account')
f=fixture();run('UPDATE users SET phone='+literal(phone())+' WHERE id='+literal(f['p']+'a')+';');staff_phone=val('SELECT to_jsonb(phone) FROM users WHERE id='+literal(f['p']+'a')+';');assert val(call('jana_login',staff_phone,password)).get('_error')=='invalid_credentials';run('UPDATE users SET active=false WHERE id='+literal(uid)+';');assert val(call('jana_login',number,password)).get('_error')=='invalid_credentials';passed('inactive accounts and operational phone identifiers cannot open a customer session')
assert val("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('jana_register','jana_login','jana_normalize_phone','jana_customer_profile') AND (has_function_privilege('anon',oid,'EXECUTE') OR has_function_privilege('authenticated',oid,'EXECUTE'));")==0;passed('account and normalization functions retain the trusted service boundary')
print(json.dumps({'passed':len(checks),'checks':checks}))
