import test from 'node:test';import assert from 'node:assert/strict';
import {createApiClient,restoreSession,ApiError} from '../mobile/api.mjs';
function store(){const m=new Map();return{getItemAsync:async k=>m.get(k)||null,setItemAsync:async(k,v)=>m.set(k,v),deleteItemAsync:async k=>m.delete(k)}}
const base='https://jana-fresh-app.onrender.com';
test('uncertain quote retry survives client restart with same key',async()=>{const storage=store();let key;const one=createApiClient({base,storage,fetchImpl:async(u,i)=>{key=i.headers['idempotency-key'];throw Error('offline')}});const opts={method:'POST',token:'fixture',body:{lines:[]}};await assert.rejects(one('/api/quotes',opts),e=>e.code==='NETWORK_UNKNOWN');const two=createApiClient({base,storage,fetchImpl:async(u,i)=>{assert.equal(i.headers['idempotency-key'],key);return Response.json({id:'quote'})}});assert.equal((await two('/api/quotes',opts)).id,'quote')});
test('retry metadata is isolated by session',async()=>{const storage=store(),keys=[];let counter=0;const request=createApiClient({base,storage,newKey:()=>String(++counter),fetchImpl:async(u,i)=>{keys.push(i.headers['idempotency-key']);throw Error('offline')}});for(const token of ['customer-one','customer-two'])await assert.rejects(request('/api/orders',{method:'POST',token,body:{quote_id:'same'}}));assert.notEqual(keys[0],keys[1])});
test('successful completed intent obtains a new key next time',async()=>{const storage=store(),keys=[];let counter=0;const request=createApiClient({base,storage,newKey:()=>String(++counter),fetchImpl:async(u,i)=>{keys.push(i.headers['idempotency-key']);return Response.json({ok:true})}});const opts={method:'POST',token:'fixture',body:{}};await request('/api/quotes',opts);await request('/api/quotes',opts);assert.notEqual(keys[0],keys[1])});
test('GET retries a transient server failure once',async()=>{let n=0;const request=createApiClient({base,storage:store(),fetchImpl:async()=>++n===1?Response.json({error:{code:'BUSY'}},{status:503}):Response.json({items:[]})});assert.deepEqual(await request('/api/catalog'),{items:[]});assert.equal(n,2)});
test('mutation timeout is explicit and not automatically retried',async()=>{let n=0;const request=createApiClient({base,storage:store(),timeoutMs:5,fetchImpl:async(u,i)=>{n++;return new Promise((resolve,reject)=>i.signal.addEventListener('abort',()=>reject(Error('timeout'))))}});await assert.rejects(request('/api/orders',{method:'POST',token:'fixture',body:{}}),e=>e.code==='NETWORK_UNKNOWN');assert.equal(n,1)});
test('network outage never deletes stored session',async()=>{const storage=store();await storage.setItemAsync('token','fixture');await assert.rejects(restoreSession({storage,key:'token',request:async()=>{throw new ApiError('offline','NETWORK_UNKNOWN')}}));assert.equal(await storage.getItemAsync('token'),'fixture')});
test('expired session is cleared only on authentication rejection',async()=>{const storage=store();await storage.setItemAsync('token','fixture');assert.deepEqual(await restoreSession({storage,key:'token',request:async()=>{throw new ApiError('expired','AUTH_REQUIRED',401)}}),{token:null,user:null});assert.equal(await storage.getItemAsync('token'),null)});
test('customer substitution approval retry survives restart with its original decision key',async()=>{
 const storage=store();let original;const path='/api/substitutions/sub-fixture/decision',options={method:'POST',token:'fixture',body:{accept:true}};
 const one=createApiClient({base,storage,fetchImpl:async(u,i)=>{original=i.headers['idempotency-key'];throw Error('offline after decision')}});await assert.rejects(one(path,options),e=>e.code==='NETWORK_UNKNOWN');
 const two=createApiClient({base,storage,fetchImpl:async(u,i)=>{assert.equal(i.headers['idempotency-key'],original);return Response.json({state:'accepted'})}});assert.equal((await two(path,options)).state,'accepted');
});
for(const path of ['/api/shopping-lists','/api/recurring'])test(`${path}: uncertain creation retains its key across mobile restart`,async()=>{
 const storage=store(),options={method:'POST',token:'fixture',body:{name:'Saved fixture',items:[]}};let original;const one=createApiClient({base,storage,fetchImpl:async(u,i)=>{original=i.headers['idempotency-key'];throw Error('offline')}});await assert.rejects(one(path,options));const two=createApiClient({base,storage,fetchImpl:async(u,i)=>{assert.equal(i.headers['idempotency-key'],original);return Response.json({id:'saved-fixture'})}});assert.equal((await two(path,options)).id,'saved-fixture');
});
test('uncertain saved cart PUT retains its revision and key across mobile restart',async()=>{
 const storage=store(),options={method:'PUT',token:'fixture',body:{revision:4,items:[]}};let original;const one=createApiClient({base,storage,fetchImpl:async(u,i)=>{original=i.headers['idempotency-key'];throw Error('offline')}});await assert.rejects(one('/api/cart',options));const two=createApiClient({base,storage,fetchImpl:async(u,i)=>{assert.equal(i.headers['idempotency-key'],original);assert.equal(JSON.parse(i.body).revision,4);return Response.json({revision:5,saved:true})}});assert.equal((await two('/api/cart',options)).revision,5);
});
test('an older successful request cannot erase a newer session pending confirmation',async()=>{
 const storage=store();let release,seen;const started=new Promise(resolve=>seen=resolve),held=new Promise(resolve=>release=resolve);
 const request=createApiClient({base,storage,fetchImpl:async(u,i)=>{if(i.headers.authorization==='Bearer old-session'){seen();await held;return Response.json({id:'old-order'})}throw Error('new session offline')}});
 const old=request('/api/orders',{method:'POST',token:'old-session',body:{quote_id:'old-quote'}});await started;
 await assert.rejects(request('/api/orders',{method:'POST',token:'new-session',body:{quote_id:'new-quote'}}));
 const pending=await storage.getItemAsync('jana.mobile.retry.v1');release();await old;
 assert.equal(await storage.getItemAsync('jana.mobile.retry.v1'),pending);
});
test('a late completed request does not recreate retry credentials removed at logout',async()=>{
 const storage=store();let release,seen;const started=new Promise(resolve=>seen=resolve),held=new Promise(resolve=>release=resolve);
 const request=createApiClient({base,storage,fetchImpl:async()=>{seen();await held;return Response.json({id:'order'})}});
 const old=request('/api/orders',{method:'POST',token:'old-session',body:{quote_id:'quote'}});await started;
 await storage.deleteItemAsync('jana.mobile.retry.v1');release();await old;
 assert.equal(await storage.getItemAsync('jana.mobile.retry.v1'),null);
});
