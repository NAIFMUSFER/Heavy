import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import * as common from '../assets/common.js';
const bundle=[1,2,3,4].map(n=>readFileSync(new URL(`../assets/ops.part0${n}.js`,import.meta.url),'utf8')).join('\n').replace(/^import .*?;\n/,'');
const store=()=>({revision:4,accepting_orders:false,published:{version:2},draft:{},readiness:{profile_published:true,tax_supported:true,warehouse_ready:true,active_warehouses:1,routed_available_slots:7,unrouted_available_slots:0,active_products:4,preview_products:0,available_products:3,available_slots:7}});
const health=()=>({ok:true,operations:{schema_version:1,checked_at:1789120000000,ok:true,alert_count:0,jobs:['quote_expiry','recurring_reminders'].map(code=>({code,status:'ok'})),queues:['expired_quotes','expired_substitutions','overdue_reminders'].map(code=>({code,status:'ok',count:0,capped:false}))}});
function harness({role='admin',workspace='admin',hash='#launch',get,confirm=()=>true}={}){
 const root={innerHTML:''},paths=[],writes=[],events={},clicks={},nodes={},location={hash};
 const defaults=path=>path==='/api/ops/storefront'?store():path==='/api/ops/deep-health'?health():path==='/api/ops/reports'?{cost_status:'unknown'}:path==='/api/ops/staff'?{items:[]}:path==='/api/ops/finance'?{couriers:[],refunds:[],cash_entries:[]}:path==='/api/ops/support'?{items:[],staff:[]}:{items:[]};
 const context=vm.createContext({...common,URLSearchParams,location,history:{pushState:(a,b,url)=>{location.hash=url},replaceState:(a,b,url)=>{location.hash=url}},addEventListener:(name,fn)=>{events[name]=fn},document:{body:{dataset:{workspace}},addEventListener:(name,fn)=>{clicks[name]=fn}},$:selector=>selector==='#ops-app'?root:(nodes[selector]??={innerHTML:'',disabled:false,isConnected:true}),$$:()=>[],setupConnectivity(){},identity:()=>new Promise(()=>{}),toast(){},confirm,get:async path=>{paths.push(path);return get?get(path):defaults(path)},post:async(...args)=>{writes.push(args);throw Error('No automatic writes allowed')}});
 vm.runInContext(bundle,context);vm.runInContext('state.user='+JSON.stringify({id:'fixture-'+role,role,name:'Fixture staff'}),context);
 return {root,context,paths,writes,events,clicks,location,nodes,run:code=>vm.runInContext(code,context)};
}
test('launch center reports recorded checks separately from mandatory physical review and never opens sales',async()=>{
 const h=harness();await h.run('setInitialOpsPage();render()');
 assert.deepEqual(h.paths,['/api/ops/storefront','/api/ops/deep-health']);assert.equal(h.writes.length,0);assert.match(h.root.innerHTML,/data-launch-state="closed"/);
 assert.equal((h.root.innerHTML.match(/data-launch-check=/g)||[]).length,8);assert.match(h.root.innerHTML,/data-launch-check="supplier-sites" data-launch-check-state="review"/);assert.match(h.root.innerHTML,/data-launch-check="team" data-launch-check-state="review"/);assert.match(h.root.innerHTML,/data-launch-check="procurement" data-launch-check-state="attention"/);
 assert.match(h.root.innerHTML,/لا يُستنتج اكتمالها من الاختبارات البرمجية/);assert.match(h.root.innerHTML,/href="\/admin.html#storefront"/);assert.match(h.root.innerHTML,/href="\/start.html"/);
 assert.match(h.root.innerHTML,/data-launch-opening-review="none"/);
 assert.match(h.root.innerHTML,/data-launch-download/);assert.match(h.root.innerHTML,/download="jana-launch-readiness.json"/);
});
test('downloadable launch observation excludes private merchant content and preserves unknowns',async()=>{
 const s=store();s.draft={display_name:'Private fixture',support_email:'private@example.invalid',privacy_policy:'SECRET POLICY'};
 const h=harness();const report=JSON.parse(JSON.stringify(h.run(`launchReport(${JSON.stringify(s)},${JSON.stringify(health())})`)));
 assert.equal(report.schema,'jana-launch-observation/v1');assert.deepEqual(report.admission,{state:'closed',storefront_revision:4,published_policy_version:2,opening_review:null});
 assert.equal(report.checks.length,8);assert.ok(report.checks.every(x=>Object.keys(x).sort().join(',')==='action,action_url,id,state,title'));
 assert.equal(report.operations.ok,true);assert.equal(report.manual_acceptance_required,true);assert.doesNotMatch(JSON.stringify(report),/Private fixture|private@example|SECRET POLICY/);
 const unknown=JSON.parse(JSON.stringify(h.run(`launchReport({},null)`)));assert.deepEqual(unknown.admission,{state:'unknown',storefront_revision:null,published_policy_version:null,opening_review:null});assert.equal(unknown.operations,null);assert.ok(unknown.checks.every(x=>x.id==='procurement'?x.state==='attention':['unknown','review'].includes(x.state)));
});
test('launch displays a validated opening record while the download omits its private reference and actor',async()=>{
 const s=store();s.last_opening_review={recorded_at:1789140000000,storefront_revision:4,published_id:'fixture-policy',reference:'OWNER-APPROVAL-17<script>',reviewed:{catalog:true,inventory:true,coverage:true,tax:true,operations:true},actor:{id:'fixture-admin',name:'مسؤول <script>'}};s.opening_review_matches_published=true;
 const h=harness({get:p=>p==='/api/ops/storefront'?s:health()});await h.run('setInitialOpsPage();render()');
 assert.match(h.root.innerHTML,/data-launch-opening-review="current"/);assert.match(h.root.innerHTML,/OWNER-APPROVAL-17&lt;script&gt;/);assert.doesNotMatch(h.root.innerHTML,/<script>/);
 const report=JSON.parse(JSON.stringify(h.run(`launchReport(${JSON.stringify(s)},${JSON.stringify(health())})`)));
 assert.deepEqual(report.admission.opening_review,{recorded_at:1789140000000,matches_published_policy:true});assert.doesNotMatch(JSON.stringify(report),/OWNER-APPROVAL|fixture-admin|مسؤول/);
 s.opening_review_matches_published=false;const stale=harness({get:p=>p==='/api/ops/storefront'?s:health()});await stale.run('setInitialOpsPage();render()');assert.match(stale.root.innerHTML,/data-launch-opening-review="historical"/);
 s.last_opening_review.reviewed.inventory=false;const invalid=harness({get:p=>p==='/api/ops/storefront'?s:health()});await invalid.run('setInitialOpsPage();render()');assert.match(invalid.root.innerHTML,/data-launch-opening-review="none"/);
});
test('preview products, empty availability and stopped jobs remain actionable blockers',async()=>{
 const s=store(),o=health();s.readiness.preview_products=1;s.readiness.available_slots=0;o.operations.jobs[0].status='disabled';o.operations.alert_count=1;o.operations.ok=false;
 const h=harness({get:p=>p==='/api/ops/storefront'?s:o});await h.run('setInitialOpsPage();render()');
 for(const id of ['catalog','delivery','operations'])assert.match(h.root.innerHTML,new RegExp('data-launch-check="'+id+'" data-launch-check-state="attention"'));
 assert.match(h.root.innerHTML,/منتجات معاينة نشطة: 1/);assert.equal(h.writes.length,0);
});
test('missing or malformed readiness never turns into zero counts or a completed launch',async()=>{
 for(const sample of [{},{revision:0,accepting_orders:'true',readiness:{}},{revision:1,accepting_orders:false,readiness:{preview_products:null,active_products:'5',available_products:3,available_slots:-1}}]){
  const h=harness({get:p=>p==='/api/ops/storefront'?sample:{ok:true}});await h.run('setInitialOpsPage();render()');
  assert.doesNotMatch(h.root.innerHTML,/data-launch-check-state="observed"/);assert.doesNotMatch(h.root.innerHTML,/data-launch-state="open"/);assert.equal(h.writes.length,0);
 }
});
test('a failed health read preserves owner setup links while reporting the monitoring state as unknown',async()=>{
 const h=harness({get:p=>{if(p==='/api/ops/deep-health')throw Error('Fixture outage');return store()}});await h.run('setInitialOpsPage();render()');
 assert.match(h.root.innerHTML,/data-launch-check="operations" data-launch-check-state="unknown"/);assert.match(h.root.innerHTML,/data-launch-check="merchant" data-launch-check-state="observed"/);assert.match(h.root.innerHTML,/href="\/admin.html#pickup-sites"/);
});
test('refresh clears old open status and only the newest request can paint the launch center',async()=>{
 const pending=[];const h=harness({get:p=>new Promise(resolve=>pending.push({p,resolve}))});h.run('setInitialOpsPage()');const first=h.run('render()');const second=h.run('render()');assert.match(h.root.innerHTML,/data-launch-loading/);
 pending[2].resolve(store());pending[3].resolve(health());await second;const old=store();old.accepting_orders=true;pending[0].resolve(old);pending[1].resolve(health());await first;
 assert.match(h.root.innerHTML,/data-launch-state="closed"/);assert.doesNotMatch(h.root.innerHTML,/data-launch-state="open"/);
 const stale=h.run('render()');h.run("state.user=null;root.innerHTML='Signed out'");pending[4].resolve(old);pending[5].resolve(health());await stale;assert.equal(h.root.innerHTML,'Signed out');
});
test('expired login is handled without leaving private setup data visible',async()=>{
 const h=harness({get:()=>{throw Object.assign(Error('Expired'),{code:'AUTH_REQUIRED'})}});await h.run('setInitialOpsPage();render()');assert.equal(h.run('state.user'),null);assert.match(h.root.innerHTML,/تسجيل دخول الموظفين/);assert.doesNotMatch(h.root.innerHTML,/data-launch-center/);
});
test('bookmarked pages respect the actual role and workspace before requesting any private endpoint',async()=>{
 for(const [role,workspace,hash,page,first] of [['admin','admin','#launch','launch','/api/ops/storefront'],['finance','admin','#finance','finance','/api/ops/finance'],['finance','admin','#launch','dashboard','/api/ops/reports'],['support','admin','#support','support','/api/ops/support'],['picker','picker','#staff','procurement','/api/ops/procurement?limit=50'],['courier','courier','#orders','orders','/api/ops/orders?limit=50'],['admin','admin','#%3Cscript%3E','dashboard','/api/ops/reports']]){
  const h=harness({role,workspace,hash});await h.run('setInitialOpsPage();render()');assert.equal(h.run('state.page'),page);assert.equal(h.location.hash,'#'+page);assert.equal(h.paths[0],first);if(role!=='admin')assert.ok(h.paths.every(p=>!['/api/ops/storefront','/api/ops/deep-health'].includes(p)));
 }
 const h=harness({role:'customer'});await h.run('setInitialOpsPage();render()');assert.equal(h.paths.length,0);assert.match(h.root.innerHTML,/غير مصرح/);
});
test('navigation updates a bookmark and refuses an unsaved owner draft until the owner discards it',async()=>{
 let approved=false;const h=harness({hash:'#storefront',confirm:()=>approved});h.run("state.page='storefront';state.storefrontDirty=true;root.innerHTML='Unsaved owner input'");h.location.hash='#launch';await h.run("navigateOpsPage('launch',true)");
 assert.equal(h.run('state.page'),'storefront');assert.equal(h.location.hash,'#storefront');assert.equal(h.root.innerHTML,'Unsaved owner input');assert.equal(h.paths.length,0);
 let prevented=false;h.events.beforeunload({preventDefault:()=>{prevented=true}});assert.equal(prevented,true);
 approved=true;await h.run("navigateOpsPage('launch')");assert.equal(h.location.hash,'#launch');assert.equal(h.run('state.storefrontDirty'),false);assert.match(h.root.innerHTML,/data-launch-center/);assert.equal(h.writes.length,0);
});
test('selecting an active task section refreshes changed orders while reselecting a dirty draft preserves input',async()=>{
 const h=harness({hash:'#orders'});await h.run('setInitialOpsPage();render()');await h.run("navigateOpsPage('orders')");
 assert.deepEqual(h.paths,['/api/ops/orders?limit=50','/api/ops/orders?limit=50']);
 h.run("state.page='storefront';state.storefrontDirty=true;root.innerHTML='Unsaved merchant input'");await h.run("navigateOpsPage('storefront')");
 assert.equal(h.paths.length,2);assert.equal(h.root.innerHTML,'Unsaved merchant input');assert.equal(h.run('state.storefrontDirty'),true);
});
