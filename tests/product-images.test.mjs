import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {productImageUrl as nativeImageUrl} from '../mobile/catalog.mjs';
const {productImageUrl,productImage,productImageFailed}=await import('../assets/common.js');
test('web and native product photos accept HTTPS metadata and reject credentials and other schemes',()=>{
 for(const parse of [productImageUrl,nativeImageUrl]){
  assert.equal(parse('https://images.example.invalid/fruit.jpg'),'https://images.example.invalid/fruit.jpg');
  for(const url of ['',null,{},'http://example.invalid/a.jpg','javascript:alert(1)','data:image/png;base64,a','file:///a','https://user:password@example.invalid/a','https://example.invalid/'+ 'a'.repeat(301)])assert.equal(parse(url),'');
 }
});
test('product photo uses escaped metadata named alt fixed dimensions and no referrer',()=>{
 const html=productImage({name:'تفاح "أحمر" & <طازج>',image_url:'https://images.example.invalid/a.jpg?q=1&size=small'});
 assert.match(html,/alt="تفاح &quot;أحمر&quot; &amp; &lt;طازج&gt;"/);assert.match(html,/q=1&amp;size=small/);
 assert.match(html,/referrerpolicy="no-referrer"/);assert.match(html,/width="400" height="320"/);assert.doesNotMatch(html,/onerror=/);
});
test('missing product photo retains an escaped fallback without issuing an image request',()=>{
 const html=productImage({name:'سلة',emoji:'<fallback>',image_url:''});assert.doesNotMatch(html,/<img/);assert.match(html,/&lt;fallback&gt;/);
});
test('a failed product photo reveals its fallback without touching unrelated failed resources',()=>{
 let removed=0;productImageFailed({target:{matches:s=>s==='img[data-product-image]',remove(){removed++}}});assert.equal(removed,1);
 productImageFailed({target:{matches:()=>false,remove(){removed++}}});assert.equal(removed,1);productImageFailed({});
});
