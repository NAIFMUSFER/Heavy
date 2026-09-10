import test from 'node:test';
import assert from 'node:assert/strict';
import {loadCatalog} from '../mobile/catalog.mjs';
test('mobile catalog includes products beyond the first hundred for saved-list resolution',async()=>{
 const paths=[];const rows=await loadCatalog(async path=>{paths.push(path);return paths.length===1?{items:Array.from({length:100},(_,i)=>({id:'item-'+i})),next_offset:100}:{items:[{id:'later-page-product'}],next_offset:null}});
 assert.equal(rows.length,101);assert.equal(rows.at(-1).id,'later-page-product');assert.equal(paths[1],'/api/catalog?limit=100&offset=100');
});
test('an unavailable later catalog page rejects instead of publishing partial availability',async()=>{
 let calls=0;await assert.rejects(loadCatalog(async()=>{if(++calls===1)return{items:[{id:'first'}],next_offset:100};throw Error('Offline')}),/Offline/);
});
test('nonadvancing pagination and changing duplicate pages fail with a retryable message',async()=>{
 await assert.rejects(loadCatalog(async()=>({items:[],next_offset:0})),/الصفحة التالية/);
 let calls=0;await assert.rejects(loadCatalog(async()=>({items:[{id:'duplicate'}],next_offset:++calls*100})),/تغيرت قائمة/);
});
