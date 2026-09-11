import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const page=fs.readFileSync('assets/ops.part02.js','utf8');
const dialogs=fs.readFileSync('assets/ops.part03.js','utf8');

test('inventory workspace labels bin placement as a non-financial reference',()=>{
 assert.match(page,/مواقع الرفوف المرجعية/);
 assert.match(page,/الكميات والدفعات ليست مقسمة حسب الموقع أو المستودع/);
 assert.match(page,/data-action="assign-bin"/);
 assert.match(dialogs,/هذا التغيير لا يعدل المخزون ولا يحجز كمية ولا ينقل دفعة/);
});

test('bin forms preserve revision, explicit reason, and current warehouse ownership',()=>{
 assert.match(dialogs,/revision:current\.revision/);
 assert.match(dialogs,/warehouse_id:x\.warehouse_id/);
 assert.match(dialogs,/reason:x\.reason/);
 assert.match(dialogs,/\/api\/ops\/stock\/.*\/bin/);
});
