import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createCartStore,readCart,validateCart,changeCartQuantity} from '../mobile/local-cart.mjs';
const product={id:'off-cart',family_id:'family-cart',name:'صنف اختبار محلي',price_halalas:1234,available_units:20};
const line={offering_id:product.id,family_id:product.family_id,name:product.name,price_halalas:product.price_halalas,quantity:1};
function memory(raw=JSON.stringify([line])){
 const writes=[];return{raw,writes,getItem(){return this.raw},setItem(key,value){writes.push(value);this.raw=value}};
}
const deferred=()=>{let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j});return{promise,resolve,reject}};
test('web and native execute identical cart persistence source',()=>assert.equal(readFileSync('assets/local-cart.js','utf8'),readFileSync('mobile/local-cart.mjs','utf8')));
test('stored selections round-trip without treating cached metadata as a quote',()=>{
 const input=[{...line,delivery_code:'not-cart-data',token:'not-cart-data'}];
 assert.deepEqual(readCart(JSON.stringify(input)),[line]);assert.equal(input[0].token,'not-cart-data');assert.deepEqual(readCart(null),[]);
});
test('invalid local data cannot enter either client render state',()=>{
 for(const raw of ['null','{}','[null]','false','[1]','"cart"','[',JSON.stringify([{...line,quantity:1.5}]),JSON.stringify([{...line,quantity:21}]),JSON.stringify([{...line,quantity:'2'}]),JSON.stringify([{...line,price_halalas:null}]),JSON.stringify([line,line]),JSON.stringify([{...line,name:{}}])])assert.throws(()=>readCart(raw),{code:'CART_INVALID'});
 assert.throws(()=>validateCart([{...line,price_halalas:Number.MAX_SAFE_INTEGER,quantity:2}]));
});
test('damaged stored cart is preserved until an explicit reset succeeds',async()=>{
 const storage=memory('[null]'),store=createCartStore({storage,key:'cart'});
 await assert.rejects(store.load(),{code:'CART_INVALID'});assert.equal(storage.raw,'[null]');assert.equal(storage.writes.length,0);assert.equal(store.snapshot.ready,false);
 await assert.rejects(store.update(()=>[line]));assert.equal(storage.raw,'[null]');
 await store.reset();assert.equal(storage.raw,'[]');assert.equal(store.snapshot.ready,true);assert.equal(store.snapshot.error,null);
});
test('transient read failure permits retry and never overwrites saved selections',async()=>{
 const storage=memory(),original=storage.getItem;let failure=true;storage.getItem=function(){if(failure)throw Error('temporarily unavailable');return original.call(this)};
 const store=createCartStore({storage,key:'cart'});await assert.rejects(store.load(),{code:'CART_STORAGE'});assert.equal(storage.writes.length,0);
 failure=false;await store.load();assert.deepEqual(store.snapshot.items,[line]);assert.equal(store.snapshot.error,null);
});
test('quota failure keeps visible and persisted quantities unchanged; retry works',async()=>{
 const storage=memory(),write=storage.setItem;let failure=true;storage.setItem=function(...args){if(failure)throw Error('quota');return write.apply(this,args)};
 const store=createCartStore({storage,key:'cart'});await store.load();
 await assert.rejects(store.update(rows=>changeCartQuantity(rows,product,1)),{code:'CART_STORAGE'});assert.equal(store.snapshot.items[0].quantity,1);assert.equal(JSON.parse(storage.raw)[0].quantity,1);
 failure=false;await store.update(rows=>changeCartQuantity(rows,product,1));assert.equal(store.snapshot.items[0].quantity,2);assert.equal(JSON.parse(storage.raw)[0].quantity,2);
});
test('rapid edits wait for storage and compose against the last committed selection',async()=>{
 const storage=memory(),write=storage.setItem,first=deferred(),started=deferred();let count=0;
 storage.setItem=async function(...args){if(++count===1){started.resolve();await first.promise;}return write.apply(this,args)};
 const store=createCartStore({storage,key:'cart'});await store.load();
 const a=store.update(rows=>changeCartQuantity(rows,product,1)),b=store.update(rows=>changeCartQuantity(rows,product,1));
 await started.promise;assert.equal(count,1);assert.equal(store.snapshot.items[0].quantity,1);assert.equal(store.snapshot.busy,true);
 first.resolve();await Promise.all([a,b]);assert.equal(store.snapshot.items[0].quantity,3);assert.equal(JSON.parse(storage.raw)[0].quantity,3);assert.equal(store.snapshot.busy,false);
});
test('checkout acknowledgement sees a queued cart change and preserves the newer selection',async()=>{
 const storage=memory(),store=createCartStore({storage,key:'cart'});await store.load();
 const addition=store.update(rows=>changeCartQuantity(rows,product,1));
 const acknowledge=store.update(rows=>rows[0].quantity===1?[]:rows);
 await Promise.all([addition,acknowledge]);assert.equal((await store.flush())[0].quantity,2);assert.equal(JSON.parse(storage.raw)[0].quantity,2);
});
test('a failed reset retains both old selections and the error for retry',async()=>{
 const storage=memory(),store=createCartStore({storage,key:'cart'});await store.load();storage.setItem=()=>{throw Error('storage failure')};
 await assert.rejects(store.reset());assert.deepEqual(store.snapshot.items,[line]);assert.deepEqual(JSON.parse(storage.raw),[line]);assert.equal(store.snapshot.busy,false);
});
test('cart snapshots cannot be mutated outside the persistence queue',async()=>{
 const storage=memory(),store=createCartStore({storage,key:'cart'});await store.load();
 assert.throws(()=>{store.snapshot.items[0].quantity=8});assert.throws(()=>store.snapshot.items.push(line));assert.equal(JSON.parse(storage.raw)[0].quantity,1);
});
test('quantity changes enforce available stock and allow removing an unavailable old product',()=>{
 const input=[line];assert.throws(()=>changeCartQuantity(input,{...product,available_units:1},1));assert.deepEqual(changeCartQuantity(input,{...product,available_units:0},-1),[]);assert.deepEqual(input,[line]);
 assert.throws(()=>changeCartQuantity([{...line,quantity:20}],{...product,available_units:50},1));
 const full=Array.from({length:40},(_,i)=>({...line,offering_id:'old-'+i}));assert.throws(()=>changeCartQuantity(full,product,1));
});
test('an unavailable quantity keeps its business message and does not suggest resetting storage',async()=>{
 const storage=memory(),store=createCartStore({storage,key:'cart'});await store.load();
 await assert.rejects(store.update(rows=>changeCartQuantity(rows,{...product,available_units:1},1)),/لا تتوفر كمية إضافية/);
 assert.equal(store.snapshot.error,null);assert.equal(storage.writes.length,0);assert.deepEqual(store.snapshot.items,[line]);
});
test('cooperating web tabs serialize concurrent edits and adopt the latest persisted cart',async()=>{
 let raw=JSON.stringify([line]),locked=Promise.resolve();const listeners=new Map();
 const tab=id=>({
  storage:{getItem:()=>raw,setItem:(key,value)=>{raw=value;for(const [other,listener] of listeners)if(other!==id)queueMicrotask(listener)}},
  lock:fn=>{const result=locked.then(fn);locked=result.catch(()=>{});return result},
  subscribe:listener=>{listeners.set(id,listener);return()=>listeners.delete(id)}
 });
 const aOptions=tab('a'),bOptions=tab('b');
 const a=createCartStore({key:'cart',...aOptions}),b=createCartStore({key:'cart',...bOptions});await Promise.all([a.load(),b.load()]);
 await Promise.all([a.update(rows=>changeCartQuantity(rows,product,1)),b.update(rows=>changeCartQuantity(rows,product,1))]);
 await new Promise(resolve=>setImmediate(resolve));await Promise.all([a.flush(),b.flush()]);
 assert.equal(JSON.parse(raw)[0].quantity,3);assert.equal(a.snapshot.items[0].quantity,3);assert.equal(b.snapshot.items[0].quantity,3);
 a.close();b.close();assert.equal(listeners.size,0);
});
test('an invalid external cart never replaces the last valid visible selection',async()=>{
 const storage=memory(),store=createCartStore({storage,key:'cart'});await store.load();storage.raw='[null]';
 await assert.rejects(store.sync(),{code:'CART_INVALID'});assert.deepEqual(store.snapshot.items,[line]);assert.equal(store.snapshot.error.code,'CART_INVALID');
});
