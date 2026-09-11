"""Operational observations and fault/recovery scenarios, disposable PostgreSQL only."""
from database_support import *
import time

checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def observe(setup='',expression='public.jana_operational_health()'):
 return val('BEGIN;'+setup+'SELECT '+expression+';ROLLBACK;')
def job(data,code='quote_expiry'):return next(x for x in data['jobs'] if x['code']==code)
def queue(data,code):return next(x for x in data['queues'] if x['code']==code)
fresh="INSERT INTO worker_runs(name,last_success_at,detail) SELECT n,(extract(epoch from clock_timestamp())*1000)::bigint,'{}'::json FROM (VALUES('quote_expiry'),('recurring_reminders')) x(n) ON CONFLICT(name) DO UPDATE SET last_success_at=excluded.last_success_at;"

# Complete any earlier disposable-suite work, never manufacture a production heartbeat.
run('SELECT public.jana_expiry_worker();SELECT public.jana_recurring_reminders();')
f=fixture();p=f['p'];q=val(quote(f,'operational-health-quote'))
run('UPDATE sessions SET expires_at=(extract(epoch from now())*1000)::bigint+600000 WHERE user_id IN ('+','.join(literal(p+x) for x in ['u','a','c'])+');')
baseline=observe(fresh)
assert baseline['schema_version']==1 and baseline['scheduler_enabled'] is True
assert baseline['ok'] is True and baseline['alert_count']==0 and len(baseline['jobs'])==2 and len(baseline['queues'])==3
assert all(x['status']=='ok' and x['age_ms']>=0 for x in baseline['jobs'])
passed('healthy scheduled jobs and empty overdue queues are explicitly observed')

result=val('BEGIN READ ONLY;'+rpc('jana_admin_deep_health',f['atok'])+'COMMIT;')
assert result['ok'] is True and result['operations']['schema_version']==1
assert 'cash_ledger_mismatches' in result and 'reserved_gt_on_hand' in result
passed('admin endpoint stays additive and succeeds in a read-only transaction')

assert job(observe(fresh+"UPDATE cron.job SET active=false WHERE jobname='jana-quote-expiry';"))['status']=='disabled'
assert job(observe(fresh+"DELETE FROM cron.job WHERE jobname='jana-quote-expiry';"))['status']=='missing_job'
for change in ["schedule='0 * * * *'","database='different_fixture_database'","command='SELECT 1'"]:
 assert job(observe(fresh+'UPDATE cron.job SET '+change+" WHERE jobname='jana-quote-expiry';"))['status']=='misconfigured'
passed('disabled missing or incorrectly configured schedules cannot report success')

assert job(observe(fresh+"DELETE FROM worker_runs WHERE name='quote_expiry';"))['status']=='missing_heartbeat'
assert job(observe(fresh+"UPDATE worker_runs SET last_success_at=(extract(epoch from now())*1000)::bigint-181000 WHERE name='quote_expiry';"))['status']=='stale'
for stamp in ['0',"(extract(epoch from now())*1000)::bigint+60000"]:
 assert job(observe(fresh+'UPDATE worker_runs SET last_success_at='+stamp+" WHERE name='quote_expiry';"))['status']=='invalid_heartbeat'
assert job(observe(fresh+"UPDATE worker_runs SET last_success_at=(extract(epoch from now())*1000)::bigint-179000 WHERE name='quote_expiry';"))['status']=='ok'
passed('missing stale and invalid heartbeat times are distinct from the three-minute healthy window')

recent=observe(fresh+'UPDATE quotes SET expires_at=(extract(epoch from now())*1000)::bigint-60000 WHERE id='+literal(q['id'])+';')
assert queue(recent,'expired_quotes')['count']==0
expired='UPDATE quotes SET expires_at=(extract(epoch from now())*1000)::bigint-240000 WHERE id='+literal(q['id'])+';'
late=observe(fresh+expired)
assert queue(late,'expired_quotes')['count']==1 and late['ok'] is False and job(late)['status']=='ok'
assert queue(late,'expired_quotes')['oldest_delay_ms']>=240000
passed('late reservations alert even with a fresh heartbeat while the two-minute scheduling grace is respected')

amounts=balance(f)
result=val('BEGIN;'+expired+"DO $test$ DECLARE before_report jsonb;after_report jsonb;before_balance jsonb;after_balance jsonb;BEGIN before_report=public.jana_operational_health();SELECT jsonb_build_object('reserved',reserved_base) INTO before_balance FROM stock_balances WHERE stock_id="+literal(p+'st')+";PERFORM public.jana_expiry_worker();after_report=public.jana_operational_health();SELECT jsonb_build_object('reserved',reserved_base) INTO after_balance FROM stock_balances WHERE stock_id="+literal(p+'st')+";PERFORM set_config('jana.monitor_test',jsonb_build_object('before',before_report,'after',after_report,'reserved_before',before_balance,'reserved_after',after_balance)::text,true);END $test$;SELECT current_setting('jana.monitor_test')::jsonb;ROLLBACK;")
assert queue(result['before'],'expired_quotes')['count']==1 and queue(result['after'],'expired_quotes')['count']==0
assert result['reserved_before']['reserved']==amounts['reserved']>0 and result['reserved_after']['reserved']==0
assert balance(f)==amounts
passed('only the real expiry worker releases the fixture reservation and clears its backlog alert')

cap="INSERT INTO quotes SELECT clone.* FROM quotes q CROSS JOIN generate_series(1,1001)n CROSS JOIN LATERAL jsonb_populate_record(NULL::quotes,to_jsonb(q)||jsonb_build_object('id',"+literal(p)+"||'cap'||n,'expires_at',1))clone WHERE q.id="+literal(q['id'])+';'
capped=queue(observe(cap),'expired_quotes')
assert capped['count']==1000 and capped['capped'] is True and capped['oldest_due_at']==1
assert queue(observe(cap.replace('1,1001','1,1000')),'expired_quotes')['capped'] is False
assert balance(f)==amounts
passed('large backlogs expose a truthful capped count and oldest time without changing reservations')

plan="INSERT INTO recurring_plans(id,user_id,address_id,cart,interval_days,next_at,state) VALUES("+','.join(map(literal,[p+'plan',p+'u',p+'addr']))+",'[]',7,1,'active');"
assert queue(observe(plan),'overdue_reminders')['count']==1
assert queue(observe(plan+"UPDATE recurring_plans SET state='paused' WHERE id="+literal(p+'plan')+';'),'overdue_reminders')['count']==0
assert queue(observe(plan+'UPDATE users SET active=false WHERE id='+literal(p+'u')+';'),'overdue_reminders')['count']==0
passed('reminder backlog excludes paused plans and inactive recipients')

g=fixture();gq=val(quote(g,'monitor-substitution-quote'))
go=val(rpc('jana_critical_write',g['t'],'monitor-substitution-confirm','order.confirm',{'quote_id':gq['id']}))
sub="INSERT INTO substitutions(id,order_id,line_id,component_id,proposed,default_action,state,expires_at,actor_id,created_at) VALUES("+','.join(map(literal,[g['p']+'sub',go['id'],gq['lines'][0]['line_id'],g['p']+'st']))+",'{}','hold_for_resolution','pending',1,"+literal(g['p']+'a')+",1);"
assert queue(observe(sub),'expired_substitutions')['count']==1
assert queue(observe(sub.replace("'pending',1,","'rejected',1,")),'expired_substitutions')['count']==0
passed('only unresolved expired substitution decisions enter the operational backlog')

for role in ['customer','courier','picker','inventory','support','finance']:
 token=secrets.token_hex(32);uid=p+role
 run("INSERT INTO users(id,email,name,password_hash,role,verified_phone,active,created_at) VALUES("+','.join(map(literal,[uid,uid+'@example.invalid','Monitor fixture','unused',role]))+",false,true,1);INSERT INTO sessions(token_hash,user_id,csrf_hash,expires_at,created_at) VALUES(encode(extensions.digest("+literal(token)+",'sha256'),'hex'),"+literal(uid)+",'unused',(extract(epoch from now())*1000)::bigint+600000,1);")
 denied=run(rpc('jana_admin_deep_health',token),False);assert not denied['ok'] and 'forbidden' in denied['error']
assert not run(rpc('jana_admin_deep_health','invalid-session'),False)['ok']
passed('all non-admin roles and invalid sessions are denied without exposing observations')

grants=val("SELECT jsonb_build_object('helper_private',NOT has_function_privilege('anon','public.jana_operational_health()','EXECUTE') AND NOT has_function_privilege('authenticated','public.jana_operational_health()','EXECUTE') AND NOT has_function_privilege('service_role','public.jana_operational_health()','EXECUTE'),'wrapper_private',NOT has_function_privilege('anon','public.jana_admin_deep_health(text)','EXECUTE') AND NOT has_function_privilege('authenticated','public.jana_admin_deep_health(text)','EXECUTE'),'service_wrapper',has_function_privilege('service_role','public.jana_admin_deep_health(text)','EXECUTE'));")
assert all(grants.values())
assert p not in json.dumps(baseline) and all(word not in json.dumps(baseline) for word in ['password','token','command','return_message','recipient','detail'])
passed('private helpers and redacted observations preserve existing session and data boundaries')

reads=race(['BEGIN READ ONLY;'+rpc('jana_admin_deep_health',f['atok'])+'COMMIT;' for _ in range(16)])
assert len(successful(reads))==16 and balance(f)==amounts
assert val('SELECT public.jana_deep_health();')['ok'] is True
passed('sixteen concurrent read-only checks preserve stock capacity and all business invariants')

# pg_cron launch is a SIGHUP setting: change only the disposable server and always restore it.
previous=run("SELECT current_setting('cron.launch_active_jobs');")['data']
try:
 run("ALTER SYSTEM SET cron.launch_active_jobs=off;SELECT pg_reload_conf();")
 for _ in range(20):
  if run("SELECT current_setting('cron.launch_active_jobs');")['data']=='off':break
  time.sleep(.1)
 stopped=observe(fresh)
 assert stopped['scheduler_enabled'] is False and all(x['status']=='scheduler_disabled' for x in stopped['jobs']) and stopped['ok'] is False
 passed('global scheduler suspension remains visible even with recent success evidence')
finally:
 assert previous in ['on','off']
 run('ALTER SYSTEM SET cron.launch_active_jobs='+previous+';SELECT pg_reload_conf();')
 for _ in range(20):
  if run("SELECT current_setting('cron.launch_active_jobs');")['data']==previous:break
  time.sleep(.1)
 assert run("SELECT current_setting('cron.launch_active_jobs');")['data']==previous
print(json.dumps({'passed':len(checks),'checks':checks}))
