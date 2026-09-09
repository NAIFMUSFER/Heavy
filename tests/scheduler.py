from database_support import *
import time
f=fixture();q=val(quote(f,'scheduler-fixture-key'));run('UPDATE quotes SET expires_at=1 WHERE id='+literal(q['id'])+';')
# Speed up only this disposable database. The production migration remains every minute.
run("SELECT cron.schedule('jana-quote-expiry','2 seconds','SELECT public.jana_expiry_worker();');")
for _ in range(15):
 if balance(f)['reserved']==0:break
 time.sleep(1)
assert balance(f)['reserved']==0 and balance(f)['booked']==0
assert val("SELECT count(*) FROM cron.job_run_details d JOIN cron.job j USING(jobid) WHERE j.jobname='jana-quote-expiry' AND d.status='succeeded';")>=1
assert val("SELECT count(*) FROM worker_runs WHERE name='quote_expiry' AND last_success_at>extract(epoch from now()-interval '30 seconds')*1000;")==1
assert val("SELECT to_jsonb(has_function_privilege('anon','public.jana_expiry_worker()','EXECUTE'));") is False
print(json.dumps({'passed':4,'checks':['scheduled stock release','scheduled slot release','successful cron execution and worker heartbeat','no direct anonymous worker execution']}))
