import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {mergeSavedCart as mobileMerge,saudiReminderDate} from '../mobile/saved-cart.mjs';
const source=fs.readFileSync('assets/shop.part04.js','utf8'),context=vm.createContext({});vm.runInContext(source.slice(source.indexOf('function mergeSavedCart('),source.indexOf('async function useSavedItems(')),context);
const webMerge=(...args)=>JSON.parse(JSON.stringify(context.mergeSavedCart(...args)));
const webCloudSource=source.slice(source.indexOf('async function cloudCart('),source.indexOf('const storePolicyLabels'));
const mobileCloudSource=fs.readFileSync('mobile/CloudCart.js','utf8');
for(const [client,merge] of [['web',webMerge],['mobile',mobileMerge]]){
 test(`${client}: saved cart addition resolves current size lineage and combines quantities`,()=>{
  const cart=[{offering_id:'old-version',family_id:'size-a',quantity:1,price_halalas:1000}];const catalog=[{id:'new-version',family_id:'size-a',name:'تفاح',price_halalas:2500,available_units:3}];const result=merge(cart,[{offering_family_id:'size-a',quantity:2}],catalog);assert.equal(result.length,1);assert.equal(result[0].offering_id,'new-version');assert.equal(result[0].quantity,3);assert.equal(result[0].price_halalas,2500);assert.equal(cart[0].offering_id,'old-version');
 });
 test(`${client}: unavailable item prevents partial mutation of the existing cart`,()=>{
  const cart=[{offering_id:'size-a-current',family_id:'size-a',quantity:1}];const original=JSON.stringify(cart);assert.throws(()=>merge(cart,[{offering_family_id:'size-a',quantity:1},{offering_family_id:'unavailable',quantity:1}],[{id:'size-a-current',family_id:'size-a',name:'موز',available_units:3}]));assert.equal(JSON.stringify(cart),original);
 });
 test(`${client}: merged cart respects current stock and per-line quantity bounds`,()=>{
  for(const quantity of [21,1.5,-1])assert.throws(()=>merge([],[{offering_family_id:'size-a',quantity}],[{id:'current',family_id:'size-a',name:'تفاح',available_units:50}]));assert.throws(()=>merge([{offering_id:'current',quantity:1}],[{offering_family_id:'size-a',quantity:2}],[{id:'current',family_id:'size-a',name:'تفاح',available_units:2}]));
 });
}
test('web and native saved-cart screens expose an explicit non-destructive merge choice',()=>{
 for(const client of [webCloudSource,mobileCloudSource]){
  assert.match(client,/دمج النسخة المحفوظة مع سلة هذا الجهاز/);
  assert.match(client,/mergeSavedCart\((?:state\.cart|cart),/);
  assert.match(client,/لن تتغير النسخة المحفوظة حتى تحفظها صراحةً/);
 }
});
test('mobile reminder input preserves Saudi time and rejects calendar rollover',()=>{
 assert.equal(new Date(saudiReminderDate('2027-01-31 10:00')).toISOString(),'2027-01-31T07:00:00.000Z');for(const text of ['2027-02-30 10:00','2027-01-31 24:00','31/1/2027 10:00','invalid'])assert.throws(()=>saudiReminderDate(text));
});
for(const [client,merge] of [['web',webMerge],['mobile',mobileMerge]])test(`${client}: restoring selections cannot exceed the checkout line bound`,()=>{
 const catalog=Array.from({length:41},(_,i)=>({id:'offering-'+i,family_id:'family-'+i,name:'صنف '+i,available_units:5,price_halalas:100}));const items=catalog.map(p=>({offering_family_id:p.family_id,quantity:1}));assert.throws(()=>merge([],items,catalog),/40/);
});
