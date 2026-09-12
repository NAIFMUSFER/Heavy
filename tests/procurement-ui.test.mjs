import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import * as common from '../assets/common.js';

const bundle=[1,2,3,4].map(n=>readFileSync(new URL(`../assets/ops.part0${n}.js`,import.meta.url),'utf8')).join('\n').replace(/^import .*?;\n/,'');
const jobId='prc-'+'1'.repeat(32);

function harness({role='picker',workspace=role==='picker'?'picker':'admin',read=async()=>({items:[],next:null})}={}){
 const root={innerHTML:''},filter={},paths=[],listeners={},location={hash:''};
 const context=vm.createContext({...common,URLSearchParams,
  document:{body:{dataset:{workspace}},addEventListener(type,fn){(listeners[type]??=[]).push(fn)}},
  location,history:{replaceState(a,b,hash){location.hash=hash},pushState(a,b,hash){location.hash=hash}},addEventListener(){},
  $:selector=>selector==='#ops-app'?root:selector==='[name="procurement_state"]'?filter:null,$$:()=>[],
  setupConnectivity(){},identity:()=>new Promise(()=>{}),get:async path=>{paths.push(path);return read(path)},toast(){}});
 vm.runInContext(bundle,context);vm.runInContext('state.user='+JSON.stringify({id:'staff-fixture',name:'Fixture',role}),context);
 return {context,root,filter,paths,listeners,run:code=>vm.runInContext(code,context)};
}

const pageItem=(id=jobId)=>({id,order_number:'JN-&-1',state:'collecting',revision:2,assigned_name:'موظف <أ>',created_at:1789000000000,updated_at:1789000001000,requested_line_count:2,purchase_count:1,actual_cost_total_halalas:1250,unfunded_purchase_count:0,employee_reimbursement_outstanding_halalas:500,supplier_payable_outstanding_halalas:750,customer_total_halalas:3000});

test('picker lands on the warehouse-free procurement workspace and sees only read actions',async()=>{
 const h=harness();await h.run('setInitialOpsPage();render()');
 assert.equal(h.paths[0],'/api/ops/procurement?limit=50');
 assert.match(h.root.innerHTML,/مهام شراء الطلبات من الموردين والمحلات/);
 assert.match(h.root.innerHTML,/مساحة قراءة فقط/);
 assert.match(h.root.innerHTML,/التجهيز السابق/);
 assert.doesNotMatch(h.root.innerHTML,/data-action="(?:record-purchase|record-settlement|create-stock)"/);
});

test('picker cards paginate safely, escape stored text and hide finance-only totals',async()=>{
 let calls=0;const secondId='prc-'+'2'.repeat(32);
 const h=harness({read:async()=>++calls===1?{items:[pageItem()],next:{before_at:1789000000000,before_id:jobId}}:{items:[{...pageItem(),assigned_name:'اسم محدث'},pageItem(secondId)],next:null}});
 h.run("state.page='procurement';state.procurementFilter='collecting'");await h.run('procurementPage()');
 assert.match(h.paths[0],/limit=50/);assert.match(h.paths[0],/state=collecting/);
 assert.match(h.root.innerHTML,/JN-&amp;-1/);assert.match(h.root.innerHTML,/موظف &lt;أ&gt;/);
 assert.match(h.root.innerHTML,/12\.50 ر\.س/);assert.match(h.root.innerHTML,/عرض مهام أقدم/);
 assert.doesNotMatch(h.root.innerHTML,/مستحق موظف|مستحق مورد/);
 await h.run('procurementPage(true)');
 assert.match(h.paths[1],/before_at=1789000000000/);assert.match(h.paths[1],new RegExp('before_id='+jobId));
 assert.equal(h.run('state.procurementItems.length'),2);assert.match(h.root.innerHTML,/اسم محدث/);assert.doesNotMatch(h.root.innerHTML,/عرض مهام أقدم/);
});

test('picker detail reconciles quantities and purchase evidence without customer contact or settlement references',async()=>{
 let modalHtml='';const detail={job:{id:jobId,order_number:'JN-DETAIL',state:'collecting',revision:3,assigned_name:'المشتري',created_at:1789000000000,updated_at:1789000001000},customer_terms:{total_halalas:3000,original_total_halalas:3000,customer_contact_included:false},lines:[{line_id:'line-1',name:'تفاح <سكريبت>',qty:2,collected_qty:1,remaining_qty:1,line_total_halalas:2000}],purchases:[{id:'record-1',supplier:{name:'محل & مورد'},pickup_site:{name:'فرع جازان',city:'جازان',address_line:'السوق'},document_reference:'INV <1>',created_at:1789000000000,total_actual_cost_halalas:1250,lines:[{requested_qty:2,collected_qty:1,actual_cost_halalas:1250,quality_note:'جودة & جيدة'}]}],funding:[{funding_source:'employee_paid',principal_halalas:1250,outstanding_halalas:1250,evidence_reference:'ADV-1'}],settlements:[{amount_halalas:100,payment_reference:'SECRET-REF',note:'خاص'}],shortage:null,handover:null,financial_detail_included:false,customer_contact_included:false};
 const h=harness({read:async path=>{assert.equal(path,'/api/ops/procurement/'+jobId);return detail}});h.context.modal=(title,html)=>{modalHtml=html;return {}};h.run("state.page='procurement'");await h.run(`procurementDetail('${jobId}')`);
 assert.match(modalHtml,/تفاح &lt;سكريبت&gt;/);assert.match(modalHtml,/محل &amp; مورد/);assert.match(modalHtml,/INV &lt;1&gt;/);assert.match(modalHtml,/المطلوب 2 · جُمع 1 · المتبقي 1/);
 assert.match(modalHtml,/تفاصيل دفع التسويات محجوبة/);assert.doesNotMatch(modalHtml,/SECRET-REF|رقم جوال|عنوان العميل/);
 assert.doesNotMatch(modalHtml,/<سكريبت>/);
});

test('finance detail includes immutable settlement evidence but still offers no mutation control',async()=>{
 let modalHtml='';const detail={job:{id:jobId,order_number:'JN-FIN',state:'ready',revision:5,assigned_name:'المشتري',created_at:1789000000000},customer_terms:{total_halalas:4000},lines:[],purchases:[],funding:[],settlements:[{created_at:1789000000000,amount_halalas:750,payment_reference:'PAY-&-1',note:'سداد جزئي'}],financial_detail_included:true};
 const h=harness({role:'finance',read:async()=>detail});h.context.modal=(title,html)=>{modalHtml=html;return {}};h.run("state.page='procurement'");await h.run(`procurementDetail('${jobId}')`);
 assert.match(modalHtml,/دفعات التسوية/);assert.match(modalHtml,/PAY-&amp;-1/);assert.match(modalHtml,/7\.50 ر\.س/);
 assert.doesNotMatch(modalHtml,/<button|تسجيل تسوية|تعديل الطلب/);
});

test('a procurement response cannot repaint after session departure',async()=>{
 let resolve;const h=harness({read:()=>new Promise(done=>{resolve=done})});h.run("state.page='procurement'");const pending=h.run('procurementPage()');h.run("state.user=null;clearProcurementPages();root.innerHTML='Signed out'");resolve({items:[pageItem()],next:null});await pending;
 assert.equal(h.root.innerHTML,'Signed out');assert.equal(h.run('state.procurementItems.length'),0);
});
