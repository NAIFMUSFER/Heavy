import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {CHECKOUT_KEY,createCheckoutSession,quoteState,quoteRemaining,cartMatchesQuote} from '../mobile/checkout.mjs';
import {createApiClient} from '../mobile/api.mjs';

const quote={id:'quote-fixture',state:'active',server_now:1800000000000,expires_at:1800000300000,store_profile:{id:'policy-one'},lines:[{offering_id:'a',qty:2}]};
const order={id:'order-fixture',number:'JN-fixture',status:'active'};
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}};
function memory(){const data=new Map();return {data,getItem:async k=>data.get(k)||null,setItem:async(k,v)=>data.set(k,v),removeItem:async k=>data.delete(k)}}
function fixture(options={}){
 const storage=options.storage||memory(),calls=[];let session={owner:'customer-one',token:'session-one'},clock=100;
 const call=options.call|| (async(path,opts={})=>{calls.push([path,opts]);return path==='/api/orders'?order:structuredClone(quote)});
 const client=createCheckoutSession({storage,call,getSession:()=>session,now:()=>clock});
 return {client,storage,calls,setSession:s=>{session=s},advance:ms=>{clock+=ms}};
}
const body={address_id:'address',slot_id:'slot',lines:[{offering_id:'a',quantity:2}]};
test('web and mobile execute the same checkout recovery controller',()=>assert.equal(readFileSync('assets/checkout.js','utf8'),readFileSync('mobile/checkout.mjs','utf8')));
test('server clock drives expiry even when the device wall clock is wrong; an existing order wins',()=>{
 assert.equal(quoteState(quote,0),'active');assert.equal(quoteRemaining(quote,290001),10);
 assert.equal(quoteState(quote,300000),'expired');assert.equal(quoteRemaining(quote,300001),0);
 assert.equal(quoteState({...quote,order},999999999),'ordered');assert.equal(quoteState({...quote,state:'cancelled'}),'cancelled');
 assert.equal(quoteState({...quote,server_now:null,created_at:null}),'unknown');
});
test('cart completion clears only the exact reviewed quantities and keeps subsequent additions',()=>{
 assert.equal(cartMatchesQuote([{offering_id:'a',quantity:2}],quote),true);
 for(const cart of [[],[{offering_id:'a',quantity:3}],[{offering_id:'b',quantity:2}],[{offering_id:'a',quantity:2},{offering_id:'b',quantity:1}]])assert.equal(cartMatchesQuote(cart,quote),false);
});
test('quote survives controller restart as a small reference and restoration never submits an order',async()=>{
 const f=fixture();await f.client.create(body);
 const raw=await f.storage.getItem(CHECKOUT_KEY);assert.ok(raw.length<250);assert.deepEqual(JSON.parse(raw),{owner:'customer-one',quote_id:quote.id,attempted:false});
 const second=fixture({storage:f.storage});await second.client.load();assert.equal(second.client.snapshot.pending.quote_id,quote.id);assert.equal(second.calls.length,0);
 await second.client.refresh();assert.equal(second.client.snapshot.quote.id,quote.id);assert.deepEqual(second.calls.map(x=>x[0]),['/api/quotes/'+quote.id]);
});
test('unknown confirmation survives restart and reads the actual order without another mutation',async()=>{
 const storage=memory();let committed=false,confirmCount=0;
 const call=async(path,opts={})=>{if(path==='/api/orders'){confirmCount++;committed=true;throw Error('connection lost after commit')};return {...quote,...(committed?{order,state:'converted'}:{})}};
 const f=fixture({storage,call});await f.client.create(body);await assert.rejects(f.client.confirm('policy-one'));
 assert.equal(JSON.parse(await storage.getItem(CHECKOUT_KEY)).attempted,true);
 const next=fixture({storage,call});await next.client.load();await next.client.refresh();assert.equal(next.client.snapshot.quote.order.id,order.id);assert.equal(confirmCount,1);
});
test('an uncommitted order retries the same durable transport key after process restart',async()=>{
 const storage=memory(),secure={getItemAsync:storage.getItem,setItemAsync:storage.setItem,deleteItemAsync:storage.removeItem};let original,attempts=0;
 const fetchImpl=async(url,init)=>{
  if(url.endsWith('/api/orders')){attempts++;if(attempts===1){original=init.headers['idempotency-key'];throw Error('offline before commit')};assert.equal(init.headers['idempotency-key'],original);return Response.json(order)}
  return Response.json(quote);
 };
 const make=()=>fixture({storage,call:createApiClient({base:'https://jana-fresh-app.onrender.com',storage:secure,fetchImpl})});
 const f=make();await f.client.create(body);await assert.rejects(f.client.confirm('policy-one'));
 const next=make();await next.client.load();await next.client.refresh();assert.equal((await next.client.confirm('policy-one')).id,order.id);assert.equal(attempts,2);
});
test('expiry after returning to the app blocks confirmation until an explicit refreshed review',async()=>{
 const f=fixture();await f.client.create(body);f.advance(300001);await assert.rejects(f.client.confirm('policy-one'),/حدّث/);
 assert.equal(f.calls.some(x=>x[0]==='/api/orders'),false);
});
test('policy acceptance is scoped to the current quote version',async()=>{
 const f=fixture();await f.client.create(body);for(const id of [null,'old-policy'])await assert.rejects(f.client.confirm(id),/شروط البيع/);
 assert.equal(f.calls.some(x=>x[0]==='/api/orders'),false);
});
test('storage failure before confirmation prevents the order request and retains its review',async()=>{
 const f=fixture();await f.client.create(body);f.storage.setItem=async()=>{throw Error('secure storage unavailable')};
 await assert.rejects(f.client.confirm('policy-one'),/storage/);assert.equal(f.calls.some(x=>x[0]==='/api/orders'),false);assert.equal(f.client.snapshot.pending.quote_id,quote.id);
});
test('an unresolved persisted quote prevents a new reservation even before load has run',async()=>{
 const f=fixture();await f.client.create(body);const next=fixture({storage:f.storage});await assert.rejects(next.client.create(body),/الحجز السابق/);assert.equal(next.calls.length,0);
});
test('same-frame double confirmation produces one request',async()=>{
 const gate=deferred();let count=0;const f=fixture({call:async path=>{if(path==='/api/orders'){count++;await gate.promise;return order}return quote}});
 await f.client.create(body);const first=f.client.confirm('policy-one');const second=await f.client.confirm('policy-one');assert.equal(second,null);gate.resolve();await first;assert.equal(count,1);
});
test('late replies from logout or a different account cannot restore checkout state',async()=>{
 const gate=deferred();const f=fixture({call:async()=>gate.promise});const pending=f.client.create(body);
 await Promise.resolve();await Promise.resolve();f.setSession({owner:'customer-two',token:'session-two'});f.client.reset();gate.resolve(quote);assert.equal(await pending,null);assert.equal(f.client.snapshot.pending,null);assert.equal(await f.storage.getItem(CHECKOUT_KEY),null);
});
test('saved references remain account scoped while a new token for the same account can recover',async()=>{
 const f=fixture();await f.client.create(body);f.setSession({owner:'customer-two',token:'session-two'});await f.client.load();assert.equal(f.client.snapshot.pending,null);
 f.setSession({owner:'customer-one',token:'renewed'});await f.client.load();assert.equal(f.client.snapshot.pending.quote_id,quote.id);
});
test('read failures preserve reference and support an explicit retry',async()=>{
 const f=fixture();await f.client.create(body);const next=fixture({storage:f.storage,call:async()=>{throw Error('offline')}});await next.client.load();await assert.rejects(next.client.refresh());assert.equal(next.client.snapshot.pending.quote_id,quote.id);assert.equal(next.client.snapshot.busy,false);assert.equal(next.client.snapshot.error,'offline');
});
test('a server response for a different quote cannot enable confirmation',async()=>{
 const f=fixture();await f.client.create(body);const next=fixture({storage:f.storage,call:async()=>({...quote,id:'different'})});await next.client.load();await assert.rejects(next.client.refresh(),/مطابقة/);assert.equal(next.client.snapshot.quote,null);
});
test('cancel releases a reservation only after authoritative terminal state is read',async()=>{
 let cancelled=false;const f=fixture({call:async(path,opts={})=>{if(opts.method==='DELETE')cancelled=true;return {...quote,state:cancelled?'cancelled':'active'}}});await f.client.create(body);await f.client.cancel();assert.equal(f.client.snapshot.pending,null);assert.equal(await f.storage.getItem(CHECKOUT_KEY),null);
});
test('confirmation winning a concurrent cancellation is displayed as an order, never erased',async()=>{
 let ordered=false;const f=fixture({call:async(path,opts={})=>{if(opts.method==='DELETE')ordered=true;return {...quote,...(ordered?{order,state:'converted'}:{})}}});await f.client.create(body);await f.client.cancel();assert.equal(f.client.snapshot.quote.order.id,order.id);assert.ok(await f.storage.getItem(CHECKOUT_KEY));
});
test('failed cart persistence leaves the confirmed reference recoverable; success clears it afterward',async()=>{
 const f=fixture();await f.client.create(body);await f.client.confirm('policy-one');
 await assert.rejects(f.client.acknowledge(async()=>{throw Error('cart storage full')}));assert.ok(await f.storage.getItem(CHECKOUT_KEY));
 let saved=false;const o=await f.client.acknowledge(async()=>{saved=true;assert.ok(await f.storage.getItem(CHECKOUT_KEY))});assert.equal(saved,true);assert.equal(o.id,order.id);assert.equal(await f.storage.getItem(CHECKOUT_KEY),null);
});
test('logout clears the persisted reference after any older write finishes',async()=>{
 const f=fixture();await f.client.create(body);const gate=deferred(),started=deferred(),write=f.storage.setItem;
 f.storage.setItem=async(k,v)=>{started.resolve();await gate.promise;await write(k,v)};
 const confirm=f.client.confirm('policy-one');await started.promise;const forgotten=f.client.forget();gate.resolve();await confirm;await forgotten;
 assert.equal(f.client.snapshot.pending,null);assert.equal(await f.storage.getItem(CHECKOUT_KEY),null);assert.equal(f.calls.some(x=>x[0]==='/api/orders'),false);
});
