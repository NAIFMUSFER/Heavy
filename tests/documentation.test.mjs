import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

// Guard the repository copies, not an upload's optimistic success response.
for(const [path,heading,min] of [
 ['docs/AUDIT-MATRIX.md','# JANA implementation',3000],
 ['docs/RELEASE-EVIDENCE.md','#',20000],
 ['docs/ORDER-JOURNEY.md','# Customer order',3000],
 ['docs/OWNER-HANDOFF-ar.md','# دليل',1500],
 ['docs/SUPPLIER-PICKUP.md','# Supplier',1500]
])test('required release document retains valid readable content: '+path,()=>{
 const content=new TextDecoder('utf-8',{fatal:true}).decode(fs.readFileSync(path));
 assert.ok(content.startsWith(heading),path+' heading missing');
 assert.ok(content.length>=min,path+' appears empty or truncated');
 assert.ok(content.split('\n').length>=15,path+' paragraphs missing');
 assert.ok(!content.includes('\uFFFD'),path+' contains damaged text');
});
test('supplier operating model supersedes warehouse launch instructions',()=>{
 const source=fs.readFileSync('docs/SUPPLIER-PICKUP.md','utf8');
 assert.match(source,/No warehouses/);assert.match(source,/intake remains closed/);
 assert.match(source,/Legacy/);assert.match(source,/customer-approved/);
 assert.match(fs.readFileSync('docs/OWNER-HANDOFF-ar.md','utf8'),/لا يلزم مستودع/);
});
