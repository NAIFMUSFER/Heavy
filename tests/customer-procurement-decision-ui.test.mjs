import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const web=readFileSync(new URL('../assets/shop.part03.js',import.meta.url),'utf8');
const native=readFileSync(new URL('../mobile/OrderDetails.js',import.meta.url),'utf8');

test('web shortage decision is explicit, note-backed and states the exact approved total',()=>{
 assert.match(web,/data-procurement-decision="approve_removal"/);
 assert.match(web,/data-procurement-decision="reject_removal"/);
 assert.match(web,/procurement-shortage-note/);
 assert.match(web,/progress\.shortage\.totalIfApproved/);
 assert.match(web,/expected_revision:progress\.revision/);
 assert.match(web,/procurement-shortage-decision/);
 assert.match(web,/لن تُضاف رسوم جديدة/);
});

test('native shortage decision uses the same explicit decisions and revision contract',()=>{
 assert.match(native,/TextInput/);
 assert.match(native,/approve_removal/);
 assert.match(native,/reject_removal/);
 assert.match(native,/expected_revision:progress\.revision/);
 assert.match(native,/procurement-shortage-decision/);
 assert.match(native,/لن تُضاف رسوم جديدة/);
});
