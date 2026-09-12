import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {appendProcurementPage,canSeeProcurementFinance,isProcurementRole,procurementPageUrl,procurementQuantity,procurementStateLabel} from '../mobile/procurement.mjs';

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
test('native staff workspace stays read-only and omits customer contact rendering',()=>{
 const source=readFileSync(new URL('../mobile/ProcurementWorkspace.js',import.meta.url),'utf8');
 assert.match(source,/\/api\/ops\/procurement/);assert.doesNotMatch(source,/method\s*:\s*['"](?:POST|PATCH|PUT|DELETE)/);
 assert.doesNotMatch(source,/customer_(?:name|phone|email|address)|recipient_(?:name|phone)/);
 assert.match(source,/financial_detail_included===true/);assert.match(source,/بيانات اتصال العميل غير معروضة/);
});
