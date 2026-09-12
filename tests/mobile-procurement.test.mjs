import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {
 appendProcurementPage,canSeeProcurementFinance,isProcurementRole,procurementAdjustmentFacts,
 procurementAssignmentFacts,procurementPageUrl,procurementPurchaseFacts,procurementPurchasePayload,
 procurementFundingFacts,procurementFundingPayload,procurementSettlementFacts,procurementSettlementPayload,
 procurementHandoverPrepareFacts,procurementHandoverPreparePayload,procurementHandoverAcceptFacts,procurementHandoverAcceptPayload,
 procurementQuantity,procurementQuantityValue,procurementStateLabel
} from '../mobile/procurement.mjs';

const id='prc-'+'1'.repeat(32);
test('native procurement access includes the courier custody role without finance visibility',()=>{
 for(const role of ['admin','finance','picker','courier'])assert.equal(isProcurementRole(role),true);
 for(const role of ['customer','inventory',null])assert.equal(isProcurementRole(role),false);
 assert.equal(canSeeProcurementFinance('finance'),true);assert.equal(canSeeProcurementFinance('picker'),false);
});
test('native procurement pagination encodes a bounded state and complete cursor',()=>{
 assert.equal(procurementPageUrl(),'/api/ops/procurement?limit=30');
 assert.equal(procurementPageUrl({state:'collecting',cursor:{before_at:1789000000000,before_id:id}}),`/api/ops/procurement?limit=30&state=collecting&before_at=1789000000000&before_id=${id}`);
 assert.throws(()=>procurementPageUrl({state:'unknown'}),/مرشح/);assert.throws(()=>procurementPageUrl({cursor:{before_at:1,before_id:'bad'}}),/مؤشر/);
});
test('native procurement continuation replaces refreshed jobs without duplicating them',()=>{
 assert.deepEqual(appendProcurementPage([{id,state:'assigned'}],[{id,state:'collecting'},{id:'prc-'+'2'.repeat(32),state:'ready'}]).map(x=>x.state),['collecting','ready']);
 assert.equal(procurementStateLabel('handover_pending'),'بانتظار المندوب');assert.equal(procurementQuantity(1.25),'1.25');
});
test('native adjustment facts require finance visibility and exact approved shortage state',()=>{
 const data={job:{id,state:'shortage_approved',revision:5},customer_terms:{total_halalas:3000},shortage:{id:'shr-'+'2'.repeat(32),state:'approved',proposed_reduction_halalas:500,decision:{decision:'approve_removal'}},financial_detail_included:true};
 assert.deepEqual(procurementAdjustmentFacts(data,'finance'),{jobId:id,requestId:'shr-'+'2'.repeat(32),revision:5,before:3000,reduction:500,after:2500});
 assert.equal(procurementAdjustmentFacts(data,'picker'),null);assert.equal(procurementAdjustmentFacts({...data,job:{...data.job,state:'collecting'}},'admin'),null);assert.equal(procurementAdjustmentFacts({...data,shortage:{...data.shortage,proposed_reduction_halalas:3000}},'finance'),null);
});
test('native assignment and purchase facts fail closed to the responsible staff member and active states',()=>{
 const data={job:{id,state:'assigned',revision:2,assigned_to:'staff-fixture'},lines:[{line_id:'line-1',name:'تفاح',remaining_qty:1.5},{line_id:'line-2',name:'مكتمل',remaining_qty:0}]};
 assert.deepEqual(procurementAssignmentFacts({...data,job:{...data.job,state:'unassigned',assigned_to:null}},'admin'),{jobId:id,revision:2,assignedTo:''});
 assert.equal(procurementAssignmentFacts(data,'picker'),null);
 assert.deepEqual(procurementPurchaseFacts(data,{id:'staff-fixture',role:'picker'}),{jobId:id,revision:2,lines:[data.lines[0]]});
 assert.equal(procurementPurchaseFacts(data,{id:'other-staff',role:'picker'}),null);
 assert.equal(procurementPurchaseFacts({...data,job:{...data.job,state:'ready'}},{id:'staff-fixture',role:'picker'}),null);
});
test('native purchase payload accepts Arabic quantities and freezes only actual collection evidence',()=>{
 const facts={jobId:id,revision:4,lines:[{line_id:'line-1',remaining_qty:2},{line_id:'line-2',remaining_qty:1}]};
 const site={id:'pup-'+'2'.repeat(32),supplier_id:'supplier-fixture',active:true,supplier_active:true};
 assert.equal(procurementQuantityValue('١٫٢٥',2),1.25);
 const result=procurementPurchasePayload({facts,site,documentReference:'  INV-100  ',note:'  زيارة فعلية  ',drafts:{'line-1':{quantity:'١٫٢٥',cost:'١٢٫٥٠',quality:'  جودة مقبولة  '}}});
 assert.deepEqual(result,{body:{expected_revision:4,supplier_id:'supplier-fixture',pickup_site_id:site.id,document_reference:'INV-100',note:'زيارة فعلية',lines:[{line_id:'line-1',collected_qty:1.25,actual_cost_halalas:1250,quality_note:'جودة مقبولة'}]},total:1250});
 assert.equal(Object.hasOwn(result.body,'order_id'),false);assert.equal(Object.hasOwn(result.body,'customer_total_halalas'),false);
 assert.throws(()=>procurementPurchasePayload({facts,site,documentReference:'INV-100',note:'زيارة فعلية',drafts:{'line-1':{quantity:'2.001',cost:'10',quality:'جيد'}}}),/المتبقي/);
 assert.throws(()=>procurementPurchasePayload({facts,site,documentReference:'INV-100',note:'زيارة فعلية',drafts:{'line-1':{quantity:'1',cost:'10.001',quality:'جيد'}}}),/مبلغ/);
 assert.throws(()=>procurementPurchasePayload({facts,site,documentReference:'INV-100',note:'زيارة فعلية',drafts:{'line-1':{quantity:'1',cost:'10',quality:'x'}}}),/التكلفة الفعلية/);
});
test('native finance actions require explicit funding and cap settlement at the outstanding balance',()=>{
 const purchase={id:'pur-'+'2'.repeat(32),total_actual_cost_halalas:1250,supplier:{name:'مورد'}},data={job:{id},purchases:[purchase],funding:[],financial_detail_included:true};
 const facts=procurementFundingFacts(data,'finance');assert.deepEqual(facts,{jobId:id,purchases:[purchase]});assert.equal(procurementFundingFacts(data,'picker'),null);
 assert.deepEqual(procurementFundingPayload({facts,purchaseRecordId:purchase.id,fundingSource:'employee_paid',evidenceReference:' ADV-1 ',note:' دفع فعلي '}),{purchase_record_id:purchase.id,funding_source:'employee_paid',evidence_reference:'ADV-1',note:'دفع فعلي'});
 assert.throws(()=>procurementFundingPayload({facts,purchaseRecordId:purchase.id,fundingSource:'',evidenceReference:'ADV-1',note:'دفع فعلي'}),/مصدر/);
 assert.throws(()=>procurementFundingPayload({facts,purchaseRecordId:purchase.id,fundingSource:'automatic',evidenceReference:'ADV-1',note:'دفع فعلي'}),/مصدر/);
 const entry={id:'pfd-'+'3'.repeat(32),purchase_record_id:purchase.id,funding_source:'employee_paid',outstanding_halalas:750},settlement=procurementSettlementFacts({...data,funding:[entry]},'admin');
 assert.deepEqual(procurementSettlementPayload({facts:settlement,fundingId:entry.id,amount:'٧٫٥٠',paymentReference:' PAY-1 ',note:' سداد جزئي '}),{funding_id:entry.id,amount_halalas:750,payment_reference:'PAY-1',note:'سداد جزئي'});
 assert.throws(()=>procurementSettlementPayload({facts:settlement,fundingId:entry.id,amount:'7.51',paymentReference:'PAY-2',note:'سداد زائد'}),/المبلغ/);
});
test('native handover requires funded collection and explicit courier counting',()=>{
 const purchase={id:'pur-'+'2'.repeat(32)},funding={purchase_record_id:purchase.id},ready={job:{id,state:'ready',revision:7,assigned_to:'staff-fixture'},lines:[{line_id:'line-1'}],purchases:[purchase],funding:[funding],handover:null};
 const prepare=procurementHandoverPrepareFacts(ready,{id:'staff-fixture',role:'picker'});assert.deepEqual(prepare,{jobId:id,revision:7,lineCount:1});
 assert.deepEqual(procurementHandoverPreparePayload({facts:prepare,courierId:'courier-fixture',note:'  عهدة معدودة  '}),{courier_id:'courier-fixture',expected_revision:7,note:'عهدة معدودة'});
 assert.equal(procurementHandoverPrepareFacts({...ready,funding:[]},{id:'staff-fixture',role:'picker'}),null);
 const pending={job:{id,state:'handover_pending',revision:8},lines:[{line_id:'line-1'}],handover:{request_id:'phr-'+'3'.repeat(32)},courier_custody_only:true};
 const accept=procurementHandoverAcceptFacts(pending,'courier');assert.deepEqual(accept,{jobId:id,requestId:'phr-'+'3'.repeat(32),revision:8,lineCount:1});
 assert.deepEqual(procurementHandoverAcceptPayload({facts:accept,note:'  استلمت فعليًا  ',confirmed:true}),{request_id:accept.requestId,expected_revision:8,note:'استلمت فعليًا'});
 assert.throws(()=>procurementHandoverAcceptPayload({facts:accept,note:'استلمت فعليًا',confirmed:false}),/أكد/);assert.equal(procurementHandoverAcceptFacts(pending,'picker'),null);
});
test('native staff workspace exposes scoped assignment, purchase and approved-adjustment writes without customer contact',()=>{
 const source=readFileSync(new URL('../mobile/ProcurementWorkspace.js',import.meta.url),'utf8');
 assert.match(source,/\/api\/ops\/procurement/);assert.match(source,/\/assignment/);assert.match(source,/\/purchases/);assert.match(source,/\/funding/);assert.match(source,/\/settlements/);assert.match(source,/\/handover/);assert.match(source,/handover-accept/);assert.match(source,/shortage-adjustment/);assert.match(source,/method\s*:\s*['"]POST/);assert.doesNotMatch(source,/method\s*:\s*['"](?:PATCH|PUT|DELETE)/);
 assert.doesNotMatch(source,/customer_(?:name|phone|email|address)|recipient_(?:name|phone)/);
 assert.match(source,/financial_detail_included===true/);assert.match(source,/بيانات اتصال العميل غير معروضة/);assert.match(source,/لن تُضاف رسوم ولن يتغير السعر الأصلي/);assert.match(source,/لن يتغير سعر العميل أو المخزون/);assert.match(source,/ليست هذه تسوية دفع/);
 const app=readFileSync(new URL('../mobile/App.js',import.meta.url),'utf8');
 assert.match(app,/procurementCall=useMemo\(\(\)=>\(path,options=\{\}\)=>request\(path,\{\.\.\.options,token\}\)/);
 assert.match(app,/<ProcurementWorkspace[^>]*user=\{user\}/s);
});
