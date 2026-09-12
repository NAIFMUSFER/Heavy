import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {appendProcurementPage,canSeeProcurementFinance,isProcurementRole,procurementAdjustmentFacts,procurementPageUrl,procurementQuantity,procurementStateLabel} from '../mobile/procurement.mjs';

const id='prc-'+'1'.repeat(32);
test('native procurement access is limited to the three server read roles',()=>{
 for(const role of ['admin','finance','picker'])assert.equal(isProcurementRole(role),true);
 for(const role of ['customer','courier','inventory',null])assert.equal(isProcurementRole(role),false);
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
test('native staff workspace exposes only the approved adjustment write and omits customer contact rendering',()=>{
 const source=readFileSync(new URL('../mobile/ProcurementWorkspace.js',import.meta.url),'utf8');
 assert.match(source,/\/api\/ops\/procurement/);assert.match(source,/shortage-adjustment/);assert.match(source,/method\s*:\s*['"]POST/);assert.doesNotMatch(source,/method\s*:\s*['"](?:PATCH|PUT|DELETE)/);
 assert.doesNotMatch(source,/customer_(?:name|phone|email|address)|recipient_(?:name|phone)/);
 assert.match(source,/financial_detail_included===true/);assert.match(source,/بيانات اتصال العميل غير معروضة/);assert.match(source,/لن تُضاف رسوم ولن يتغير السعر الأصلي/);
});
