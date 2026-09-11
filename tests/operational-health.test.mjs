import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import * as common from '../assets/common.js';
const bundle=[1,2,3,4].map(n=>readFileSync(new URL(`../assets/ops.part0${n}.js`,import.meta.url),'utf8')).join('\n').replace(/^import .*?;\n/,'');
function healthy(){return {ok:true,negative_stock:0,reserved_gt_on_hand:0,overbooked_slots:0,duplicate_quote_orders:0,cash_ledger_mismatches:0,cash_invariant_violations:0,operations:{schema_version:1,checked_at:1789120000000,ok:true,alert_count:0,scheduler_enabled:true,jobs:['quote_expiry','recurring_reminders'].map(code=>({code,status:'ok',last_success_at:1789119999000,age_ms:1000,stale_after_ms:180000})),queues:['expired_quotes','expired_substitutions','overdue_reminders'].map(code=>({code,status:'ok',count:0,capped:false,oldest_due_at:null,oldest_delay_ms:null,grace_ms:120000}))}}}
function harness(get){
 const root={innerHTML:''},context=vm.createContext({...common,document:{body:{dataset:{workspace:'admin'}},addEventListener(){}},$:()=>root,setupConnectivity(){},identity:()=>new Promise(()=>{}),get});
 vm.runInContext(bundle,context);vm.runInContext("state.user={name:'Admin fixture',role:'admin'};state.page='health'",context);
 return {root,context,render:()=>vm.runInContext('render()',context)};
}
test('operational page shows a stopped task and truthful capped backlog with next actions',async()=>{
 const h=healthy();h.operations.jobs[0].status='disabled';Object.assign(h.operations.queues[0],{status:'backlog',count:1000,capped:true,oldest_due_at:1789110000000,oldest_delay_ms:10000000});h.operations.ok=false;h.operations.alert_count=2;
 const r=harness(async path=>{assert.equal(path,'/api/ops/deep-health');return h});await r.render();
 assert.match(r.root.innerHTML,/data-operational-summary="attention"/);assert.match(r.root.innerHTML,/المهمة متوقفة/);assert.match(r.root.innerHTML,/أكثر من 1,000/);assert.match(r.root.innerHTML,/راجع المهمة المسؤولة/);assert.doesNotMatch(r.root.innerHTML,/<pre>|command|password|token/);
});
test('healthy operations are observed at a stated time with no claim of external alert delivery',async()=>{
 const r=harness(async()=>healthy());await r.render();assert.match(r.root.innerHTML,/data-operational-summary="ok"/);assert.match(r.root.innerHTML,/وقت الفحص/);assert.match(r.root.innerHTML,/مضى 1 ثانية/);assert.match(r.root.innerHTML,/تحتاج قناة تشغيل معتمدة/);assert.equal((r.root.innerHTML.match(/data-operational-job=/g)||[]).length,2);assert.equal((r.root.innerHTML.match(/data-operational-queue=/g)||[]).length,3);
});
test('old or malformed operational evidence cannot be presented as healthy',async()=>{
 const samples=[{ok:true},healthy(),healthy(),healthy(),healthy()];samples[1].operations.jobs[0]=null;samples[2].operations.queues[0].count=2;samples[3].operations.alert_count=1;samples[4].operations.jobs[0].status='unexpected';
 for(const sample of samples){const r=harness(async()=>sample);await r.render();assert.match(r.root.innerHTML,/data-operational-summary="unknown"/);assert.doesNotMatch(r.root.innerHTML,/badge success/);}
});
test('refresh immediately clears old success and a failed read stays unknown until a successful retry',async()=>{
 let mode='healthy',reject;const r=harness(()=>mode==='healthy'?Promise.resolve(healthy()):new Promise((_,no)=>{reject=no}));await r.render();assert.match(r.root.innerHTML,/data-operational-summary="ok"/);
 mode='failure';const pending=r.render();assert.match(r.root.innerHTML,/data-operational-loading/);assert.doesNotMatch(r.root.innerHTML,/data-operational-summary="ok"/);reject(Error('fixture offline'));await pending;
 assert.match(r.root.innerHTML,/data-operational-summary="unknown"/);mode='healthy';await r.render();assert.match(r.root.innerHTML,/data-operational-summary="ok"/);
});
test('superseded responses and responses from a previous session cannot restore a green status',async()=>{
 const pending=[];const r=harness(()=>new Promise(resolve=>pending.push(resolve)));const old=r.render(),newer=r.render();const unhealthy=healthy();unhealthy.ok=false;unhealthy.cash_ledger_mismatches=1;
 pending[1](unhealthy);await newer;pending[0](healthy());await old;assert.match(r.root.innerHTML,/تحتاج مراجعة/);assert.doesNotMatch(r.root.innerHTML,/data-operational-summary="ok"/);
 const loggedOut=r.render();vm.runInContext("state.user=null;root.innerHTML='Signed out'",r.context);pending[2](healthy());await loggedOut;assert.equal(r.root.innerHTML,'Signed out');
});
test('admin dashboard exposes monitoring failure while financial reporting remains usable',async()=>{
 const paths=[];const r=harness(async path=>{paths.push(path);if(path==='/api/ops/deep-health')throw Error('fixture unavailable');return {cost_status:'recorded',today_orders:3}});vm.runInContext("state.page='dashboard'",r.context);await r.render();assert.deepEqual(paths,['/api/ops/reports','/api/ops/deep-health']);assert.match(r.root.innerHTML,/data-operational-summary="unknown"/);assert.match(r.root.innerHTML,/طلبات اليوم/);assert.match(r.root.innerHTML,/مراجعة تنبيهات التشغيل/);
});
test('expired session replaces private monitoring content with login',async()=>{
 const r=harness(async()=>{throw Object.assign(Error('expired'),{code:'AUTH_REQUIRED'})});await r.render();assert.match(r.root.innerHTML,/تسجيل دخول الموظفين/);assert.doesNotMatch(r.root.innerHTML,/data-operational-job/);assert.equal(vm.runInContext('state.user',r.context),null);
});
