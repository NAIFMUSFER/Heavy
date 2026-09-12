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

test('picker lands on the warehouse-free procurement workspace with assigned purchase capability only',async()=>{
 const h=harness();await h.run('setInitialOpsPage();render()');
 assert.equal(h.paths[0],'/api/ops/procurement?limit=50');
 assert.match(h.root.innerHTML,/مهام شراء الطلبات من الموردين والمحلات/);
 assert.match(h.root.innerHTML,/يسجل موظف الشراء المسند الكميات والتكلفة الفعلية/);
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
test('finance controls are derived only from unfunded purchases and open payable balances',async()=>{
 const purchase={id:'pur-'+'2'.repeat(32),supplier:{name:'مورد فعلي'},document_reference:'INV-1',total_actual_cost_halalas:1250,created_at:1789000000000,lines:[]},funding={id:'pfd-'+'3'.repeat(32),purchase_record_id:'pur-'+'4'.repeat(32),funding_source:'employee_paid',principal_halalas:900,outstanding_halalas:500};
 const detail={job:{id:jobId,order_number:'JN-FIN-WRITES',state:'collecting',revision:4,assigned_name:'المشتري',created_at:1789000000000},customer_terms:{total_halalas:3000},lines:[],purchases:[purchase],funding:[funding],settlements:[],financial_detail_included:true};
 let modalHtml='';const h=harness({role:'finance',read:async()=>detail});h.context.modal=(title,html)=>{modalHtml=html;return {}};h.run("state.page='procurement'");await h.run(`procurementDetail('${jobId}')`);
 assert.match(modalHtml,/id="procurement-funding-open"/);assert.match(modalHtml,/id="procurement-settlement-open"/);assert.match(modalHtml,/لا يوجد مصدر دفع أو توقيت سداد افتراضي/);
 assert.deepEqual(JSON.parse(JSON.stringify(h.run('procurementFundingFacts('+JSON.stringify(detail)+')'))),{job_id:jobId,purchases:[purchase]});
 assert.deepEqual(JSON.parse(JSON.stringify(h.run('procurementSettlementFacts('+JSON.stringify(detail)+')'))),{job_id:jobId,funding:[funding]});
 h.run("state.user.role='picker'");assert.equal(h.run('procurementFundingFacts('+JSON.stringify(detail)+')'),null);assert.equal(h.run('procurementSettlementFacts('+JSON.stringify(detail)+')'),null);
});

test('finance sees the exact approved reduction while picker and malformed totals fail closed',async()=>{
 let modalHtml='';const shortageId='shr-'+'2'.repeat(32),detail={job:{id:jobId,order_number:'JN-ADJUST',state:'shortage_approved',revision:5,assigned_name:'المشتري',created_at:1789000000000},customer_terms:{total_halalas:3000},lines:[],purchases:[],funding:[],settlements:[],shortage:{id:shortageId,state:'approved',proposed_reduction_halalas:500,reason:'صنف ناقص',decision:{decision:'approve_removal',note:'أوافق على الحذف'}},financial_detail_included:true};
 const h=harness({role:'finance',read:async()=>detail});h.context.modal=(title,html)=>{modalHtml=html;return {}};h.run("state.page='procurement'");await h.run(`procurementDetail('${jobId}')`);
 assert.match(modalHtml,/تطبيق التخفيض الموافق عليه/);assert.match(modalHtml,/30\.00 ر\.س/);assert.match(modalHtml,/5\.00 ر\.س/);assert.match(modalHtml,/25\.00 ر\.س/);assert.match(modalHtml,/لا يضيف رسومًا/);
 assert.deepEqual(JSON.parse(JSON.stringify(h.run('procurementAdjustmentFacts('+JSON.stringify(detail)+')'))),{job_id:jobId,request_id:shortageId,revision:5,before:3000,reduction:500,after:2500});
 h.run("state.user.role='picker'");assert.equal(h.run('procurementAdjustmentFacts('+JSON.stringify(detail)+')'),null);
 h.run("state.user.role='finance'");assert.equal(h.run('procurementAdjustmentFacts('+JSON.stringify({...detail,customer_terms:{total_halalas:500}})+')'),null);
});

test('assignment and purchase controls are derived from role, custody, state and remaining quantity',async()=>{
 const base={job:{id:jobId,order_number:'JN-ACTIONS',state:'unassigned',revision:1,assigned_to:null,created_at:1789000000000},customer_terms:{total_halalas:3000},lines:[{line_id:'line-1',name:'تفاح',qty:2,collected_qty:0,remaining_qty:2}],purchases:[],funding:[],settlements:[],shortage:null,handover:null,financial_detail_included:true};
 let modalHtml='';const admin=harness({role:'admin',read:async()=>base});admin.context.modal=(title,html)=>{modalHtml=html;return {}};admin.run("state.page='procurement'");await admin.run(`procurementDetail('${jobId}')`);
 assert.match(modalHtml,/id="procurement-assignment-open"/);assert.doesNotMatch(modalHtml,/id="procurement-purchase-open"/);
 assert.deepEqual(JSON.parse(JSON.stringify(admin.run('procurementAssignmentFacts('+JSON.stringify(base)+')'))),{job_id:jobId,revision:1,assigned_to:''});

 const assigned={...base,job:{...base.job,state:'assigned',revision:2,assigned_to:'staff-fixture',assigned_name:'المشتري'}};modalHtml='';const picker=harness({read:async()=>assigned});picker.context.modal=(title,html)=>{modalHtml=html;return {}};picker.run("state.page='procurement'");await picker.run(`procurementDetail('${jobId}')`);
 assert.match(modalHtml,/id="procurement-purchase-open"/);assert.doesNotMatch(modalHtml,/id="procurement-assignment-open"/);
 assert.deepEqual(JSON.parse(JSON.stringify(picker.run('procurementPurchaseFacts('+JSON.stringify(assigned)+')'))),{job_id:jobId,revision:2,lines:assigned.lines});
 picker.run("state.user.id='another-picker'");assert.equal(picker.run('procurementPurchaseFacts('+JSON.stringify(assigned)+')'),null);
 assert.equal(picker.run("procurementQuantityInput('١٫٢٥',2)"),1.25);assert.throws(()=>picker.run("procurementQuantityInput('2.001',2)"),/المتبقي/);
});

test('finance cannot assign or record purchases and collection copy preserves customer price boundaries',async()=>{
 let modalHtml='';const detail={job:{id:jobId,order_number:'JN-FIN-ACTIONS',state:'assigned',revision:2,assigned_to:'finance-fixture',created_at:1789000000000},customer_terms:{total_halalas:3000},lines:[{line_id:'line-1',name:'تفاح',qty:1,collected_qty:0,remaining_qty:1}],purchases:[],funding:[],settlements:[],financial_detail_included:true};
 const h=harness({role:'finance',read:async()=>detail});h.context.modal=(title,html)=>{modalHtml=html;return {}};h.run("state.user.id='finance-fixture';state.page='procurement'");await h.run(`procurementDetail('${jobId}')`);
 assert.doesNotMatch(modalHtml,/procurement-(?:assignment|purchase)-open/);assert.match(modalHtml,/السعر الأصلي محفوظ/);assert.match(modalHtml,/منفصلتان عن سعر العميل والمخزون/);
 const source=readFileSync(new URL('../assets/ops.part04.js',import.meta.url),'utf8');assert.match(source,/\/assignment/);assert.match(source,/\/purchases/);assert.match(source,/لن يتغير سعر العميل أو المخزون/);
});

test('a procurement response cannot repaint after session departure',async()=>{
 let resolve;const h=harness({read:()=>new Promise(done=>{resolve=done})});h.run("state.page='procurement'");const pending=h.run('procurementPage()');h.run("state.user=null;clearProcurementPages();root.innerHTML='Signed out'");resolve({items:[pageItem()],next:null});await pending;
 assert.equal(h.root.innerHTML,'Signed out');assert.equal(h.run('state.procurementItems.length'),0);
});
