import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const common=await import('data:text/javascript;base64,'+Buffer.from(readFileSync(new URL('../assets/common.js',import.meta.url),'utf8')).toString('base64'));
const bundle=[1,2,3,4].map(n=>readFileSync(new URL(`../assets/ops.part0${n}.js`,import.meta.url),'utf8')).join('\n').replace(/^import .*?;\n/,'');
async function reportPage(report){
 const root={innerHTML:''};const paths=[];
 const context=vm.createContext({...common,document:{body:{dataset:{workspace:'admin'}},addEventListener(){}},$:()=>root,setupConnectivity(){},identity:()=>new Promise(()=>{}),get:async path=>{paths.push(path);if(path==='/api/ops/reports')return report;throw new Error('Unexpected dependency '+path)}});
 vm.runInContext(bundle,context);
 await vm.runInContext("state.user={name:'Finance fixture',role:'finance'};state.page='dashboard';render()",context);
 return {html:root.innerHTML,paths};
}
test('assembled finance page preserves unknown profit and cost completeness',async()=>{
 const r=await reportPage({cost_status:'unknown',gross_profit_7d_halalas:null,gross_margin_bps:null,orders_with_unknown_cost:2,inventory_unknown_cost_lots:3});
 assert.deepEqual(r.paths,['/api/ops/reports']);
 assert.match(r.html,/تكلفة البضاعة غير مكتملة/);
 assert.match(r.html,/الربح التقديري<\/span><strong[^>]*>غير مسجل</);
 assert.match(r.html,/هامش الربح التقديري<\/span><strong[^>]*>غير متاح</);
 assert.match(r.html,/دفعات بتكلفة مجهولة: 3/);
});
test('assembled finance page displays recorded zero and negative estimates distinctly',async()=>{
 const r=await reportPage({cost_status:'recorded',gross_profit_7d_halalas:-1250,gross_margin_bps:-500,recorded_cogs_7d_halalas:0,top_items:[{item_name:'تفاح & موز',qty:2}]});
 assert.match(r.html,/تكلفة بضاعة مسجلة<\/span><strong[^>]*>0\.00 ر\.س/);
 assert.match(r.html,/الربح التقديري<\/span><strong[^>]*>-12\.50 ر\.س/);
 assert.match(r.html,/هامش الربح التقديري<\/span><strong[^>]*>[\u200e\u061c]?-5%/);
 assert.match(r.html,/تفاح &amp; موز/);
});
test('product administration renders grouped sizes and confirms draft activation separately',async()=>{
 const root={innerHTML:''};const listeners={};const calls=[];let consent=false;
 const catalog={product_families:[{id:'family',name:'فاكهة'}],product_versions:[{id:'active-version',family_id:'family',version:1,title:'فاكهة',description:'',state:'active'},{id:'draft-version',family_id:'family',version:2,title:'فاكهة جديدة',description:'',state:'draft'}],offerings:[{id:'size-a',product_version_id:'active-version',size_label:'500 g',sale_unit:'kg',price_halalas:1200,active:true},{id:'size-b',product_version_id:'active-version',size_label:'1 kg',sale_unit:'kg',price_halalas:2200,active:true},{id:'draft-size',product_version_id:'draft-version',size_label:'2 kg',sale_unit:'kg',price_halalas:4000,active:false}]};
 const context=vm.createContext({...common,document:{body:{dataset:{workspace:'admin'}},addEventListener:(type,fn)=>{listeners[type]=fn}},$:()=>root,setupConnectivity(){},identity:()=>new Promise(()=>{}),confirm:()=>consent,toast(){},get:async p=>{assert.equal(p,'/api/ops/catalog');return catalog},post:async p=>{calls.push(p);return {state:'active'}}});
 vm.runInContext(bundle,context);await vm.runInContext("state.user={name:'Admin fixture',role:'admin'};state.page='catalog';render()",context);
 assert.match(root.innerHTML,/500 g/);assert.match(root.innerHTML,/1 kg/);assert.match(root.innerHTML,/2 kg/);
 assert.equal((root.innerHTML.match(/data-action="activate-product-version"/g)||[]).length,1);
 assert.match(root.innerHTML,/data-action="activate-product-version" data-id="draft-version"/);
 assert.doesNotMatch(root.innerHTML,/data-action="toggle-offering" data-id="draft-size"/);
 const button={dataset:{action:'activate-product-version',id:'draft-version'},innerHTML:'Activate',isConnected:true};
 await listeners.click({target:{closest:()=>button}});assert.equal(calls.length,0);
 consent=true;await listeners.click({target:{closest:()=>button}});assert.deepEqual(calls,['/api/ops/product-versions/draft-version/activate']);
});
test('support workspace displays conversation history and closed-ticket access',async()=>{
 const root={innerHTML:''};const context=vm.createContext({...common,document:{body:{dataset:{workspace:'admin'}},addEventListener(){}},$:()=>root,$$:()=>[],setupConnectivity(){},identity:()=>new Promise(()=>{}),get:async p=>{assert.equal(p,'/api/ops/support');return {staff:[{id:'staff-a',name:'موظف الدعم'}],items:[{id:'ticket-a',subject:'مساعدة مفتوحة',customer_name:'عميل الاختبار',state:'pending_customer',priority:'high',category:'delivery',assigned_to:'staff-a',messages:[{actor:'customer',text:'رسالة أولى',at:1789000000000},{actor:'support',text:'رد & متابعة',at:1789000001000}]},{id:'ticket-b',subject:'طلب مغلق',customer_name:'عميل الاختبار',state:'closed',priority:'normal',category:'other',messages:[]}]}}});
 vm.runInContext(bundle,context);await vm.runInContext("state.user={name:'Support fixture',role:'support'};state.page='support';render()",context);
 assert.match(root.innerHTML,/رسالة أولى/);assert.match(root.innerHTML,/رد &amp; متابعة/);assert.match(root.innerHTML,/بانتظار العميل/);assert.match(root.innerHTML,/name="assigned_to"/);assert.doesNotMatch(root.innerHTML,/طلب مغلق/);
 await vm.runInContext("state.supportFilter='closed';render()",context);assert.match(root.innerHTML,/طلب مغلق/);
});
