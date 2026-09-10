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
test('finance operations display remaining liability and distinguish requested from paid refunds',async()=>{
 const root={innerHTML:''};const context=vm.createContext({...common,document:{body:{dataset:{workspace:'admin'}},addEventListener(){}},$:()=>root,setupConnectivity(){},identity:()=>new Promise(()=>{}),get:async p=>{assert.equal(p,'/api/ops/finance');return {couriers:[{id:'courier-a',name:'المندوب',collected_halalas:2000,settled_halalas:700,courier_refunded_halalas:300,liability_halalas:1000}],refunds:[{id:'pending-a',order_number:'JN-fixture',amount_halalas:100,reason:'مراجعة',state:'requested'},{id:'paid-a',order_number:'JN-fixture',amount_halalas:200,reason:'مبلغ معاد',state:'completed',payment_source:'finance',reference:'receipt & 1'}],cash_entries:[]}}});
 vm.runInContext(bundle,context);await vm.runInContext("state.user={name:'Finance fixture',role:'finance'};state.page='finance';render()",context);
 assert.match(root.innerHTML,/10\.00 ر\.س/);assert.match(root.innerHTML,/data-action="complete-refund" data-id="pending-a"/);assert.doesNotMatch(root.innerHTML,/data-action="complete-refund" data-id="paid-a"/);assert.match(root.innerHTML,/أموال الشركة/);assert.match(root.innerHTML,/receipt &amp; 1/);
 vm.runInContext("root.innerHTML=task({id:'order-a',number:'JN-fixture',status:'completed',fulfillment_state:'ready',delivery_state:'delivered',payment_state:'partially_refunded',cash_state:'with_courier',collected_halalas:2000,refunded_halalas:300,settled_halalas:700,cash_liability_halalas:1000,total_halalas:2000,created_at:1789000000000})",context);
 assert.match(root.innerHTML,/تسوية عهدة 10\.00 ر\.س/);assert.doesNotMatch(root.innerHTML,/تسوية عهدة 20\.00/);
});
test('substitution review discloses quantities prices and expiry without silently allowing incomplete consent',()=>{
 const sub={id:'sub-a',state:'pending',expires_at:Date.now()+60000,proposed:{original_line:{name:'تفاح & موز',qty:1,components:[{name:'تفاح',base_unit:'gram',base_qty:1000}]},replacement_line:{name:'برتقال',qty:2,components:[{name:'برتقال',base_unit:'gram',base_qty:500}]},original_total_halalas:2000,total_halalas:2700,price_difference_halalas:700}};
 const html=common.substitutionReview(sub,'order-a',true);assert.match(html,/تفاح &amp; موز/);assert.match(html,/27\.00 ر\.س/);assert.match(html,/7\.00 ر\.س/);assert.match(html,/2 /);assert.match(html,/أوافق على البديل والإجمالي/);assert.match(html,/عدم الرد لا يعني الموافقة/);
 const incomplete=common.substitutionReview({...sub,proposed:{}},'order-a',true);assert.match(incomplete,/data-accept="true"[^>]*disabled/);
 const expired=common.substitutionReview({...sub,expires_at:1},'order-a',true);assert.doesNotMatch(expired,/data-accept=/);assert.match(expired,/انتهت المهلة/);
});
test('picker refreshes canonical order and disables completion for unresolved lines',async()=>{
 let html='',paths=[];const stub={onclick:null};const order={id:'order-a',number:'JN-fixture',fulfillment_state:'picking',total_halalas:2000,snapshot:{lines:[{line_id:'line-a',name:'تفاح',qty:1,components:[{name:'تفاح',base_unit:'gram',base_qty:1000}]}]},issues:[{line_id:'line-a',state:'open',reason:'لم يتوفر الصنف'}],substitutions:[]};
 const context=vm.createContext({...common,document:{body:{dataset:{workspace:'picker'}},addEventListener(){}},$:()=>stub,$$:()=>[],setupConnectivity(){},identity:()=>new Promise(()=>{}),modal:(title,content)=>{html=content;return {}},get:async path=>{paths.push(path);return order}});
 vm.runInContext(bundle,context);await vm.runInContext("state.user={name:'Picker fixture',role:'picker'};pickDialog({id:'order-a',snapshot:{lines:[]}})",context);
 assert.deepEqual(paths,['/api/ops/orders/order-a/picking']);assert.match(html,/تفاح/);assert.match(html,/لم يتوفر الصنف/);assert.match(html,/data-finalize="order-a" disabled/);assert.match(html,/تأكيد توفر الأصلي بعد التحقق/);
});
