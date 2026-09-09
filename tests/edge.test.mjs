import test from 'node:test';
import assert from 'node:assert/strict';
const handlers={};
globalThis.Deno={env:{get:key=>key==='SUPABASE_URL'?'https://jjdsajiwoqanefmnikls.supabase.co':'test-only-key'},serve:fn=>{globalThis.captured=fn}};
for(const name of ['jana-api','jana-critical','jana-ops-extra']) {
 await import(`../supabase/functions/${name}/index.ts`); handlers[name]=globalThis.captured;
}
let calls=[];let response={ok:true};
globalThis.fetch=async (url,init)=>{calls.push({url:String(url),body:JSON.parse(init.body||'{}')});return Response.json(response)};
function request(name,path,options={}) {return new Request(`https://edge.example/${name}${path}`,options)}
const bearer={authorization:'Bearer test-only-token-01234567890123456789','content-type':'application/json'};
for(const name of Object.keys(handlers)) {
 test(`${name}: blocks cookie write without CSRF before database`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{cookie:'jana_session=test-session; jana_csrf=known','content-type':'application/json'},body:'{}'}));assert.equal(r.status,403);assert.equal(calls.length,0);
 });
 test(`${name}: rejects malformed cookie before database`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{cookie:'jana_session=%XY','content-type':'application/json'},body:'{}'}));assert.equal(r.status,400);assert.equal(calls.length,0);
 });
 test(`${name}: limits bodies without trusting content-length`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:bearer,body:JSON.stringify({x:'a'.repeat(65536)})}));assert.equal(r.status,413);assert.equal(calls.length,0);
 });
 test(`${name}: rejects non-JSON mutation`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{authorization:bearer.authorization,'content-type':'text/plain'},body:'{}'}));assert.equal(r.status,415);assert.equal(calls.length,0);
 });
}
for(const name of ['jana-api','jana-critical']) {
 test(`${name}: missing idempotency key cannot reserve`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:bearer,body:'{"lines":[]}'}));assert.equal(r.status,422);assert.equal(calls.length,0);
 });
 test(`${name}: routes quotes through persisted idempotency`,async()=>{
  calls=[];response={id:'quote-test'};const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{...bearer,'idempotency-key':'quote-test-123'},body:'{"slot_id":"slot-test","address_id":"address-test","lines":[{"offering_id":"off-test","quantity":1}]}'}));assert.equal(r.status,201);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_create_quote_idempotent'));assert.equal(calls[0].body.p_idem_key,'quote-test-123');
 });
}
test('login backend business error never sets authentication cookies',async()=>{
 calls=[];response={_error:'invalid_credentials',status:401};const r=await handlers['jana-api'](request('jana-api','/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:'{"email":"fixture@example.invalid","password":null}'}));assert.equal(r.status,401);assert.equal(r.headers.getSetCookie().length,0);assert.equal((await r.json()).error.code,'INVALID_LOGIN');
});
test('login emits two separate secure cookies',async()=>{
 response={user:{id:'fixture'},token:'test-token',csrf:'test-csrf'};const r=await handlers['jana-api'](request('jana-api','/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:'{"email":"fixture@example.invalid","password":"fixture-only"}'}));assert.equal(r.status,200);const c=r.headers.getSetCookie();assert.equal(c.length,2);assert.match(c[0],/HttpOnly/);assert.ok(c.every(x=>x.includes('Secure')&&x.includes('SameSite=Strict')));
});
test('mobile login uses bearer response and no browser cookie',async()=>{
 response={user:{id:'fixture'},token:'test-token',csrf:'test-csrf'};const r=await handlers['jana-api'](request('jana-api','/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:'{"mode":"mobile","email":"fixture@example.invalid","password":"fixture-only"}'}));assert.equal((await r.json()).access_token,'test-token');assert.equal(r.headers.getSetCookie().length,0);
});
test('delivery invalid-code result is an HTTP error',async()=>{
 response={_error:'invalid_delivery_code',status:409};const r=await handlers['jana-api'](request('jana-api','/api/ops/orders/fixture/deliver',{method:'POST',headers:{...bearer,'idempotency-key':'deliver-fixture'},body:'{"code":"000000"}'}));assert.equal(r.status,409);assert.equal((await r.json()).error.code,'INVALID_DELIVERY_CODE');
});
test('failed delivery forwards the reason to the transactional operation',async()=>{
 calls=[];response={id:'fixture'};const r=await handlers['jana-api'](request('jana-api','/api/ops/orders/fixture/fail',{method:'POST',headers:bearer,body:'{"reason":"customer unavailable"}'}));assert.equal(r.status,200);assert.equal(calls[0].body.p_code,'customer unavailable');
});
for(const name of Object.keys(handlers)) {
 test(`${name}: forged Netlify header cannot bypass Origin guard`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/auth/login',{method:'POST',headers:{...bearer,origin:'https://attacker.invalid','x-nf-request-id':'forged'},body:'{}'}));assert.equal(r.status,403);assert.equal((await r.json()).error.code,'ORIGIN');assert.equal(calls.length,0);
 });
 test(`${name}: Render origin preflight is explicit`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'OPTIONS',headers:{origin:'https://jana-fresh-app.onrender.com'}}));assert.equal(r.status,204);assert.equal(r.headers.get('access-control-allow-origin'),'https://jana-fresh-app.onrender.com');assert.equal(calls.length,0);
 });
}
for(const [name,path,operation,body] of [
 ['jana-api','/api/orders','order.confirm',{quote_id:'fixture-quote'}],
 ['jana-api','/api/ops/orders/fixture/deliver','order.deliver',{code:'123456'}],
 ['jana-ops-extra','/api/ops/orders/fixture/collect','cod.collect',{amount_halalas:2000}],
 ['jana-ops-extra','/api/ops/orders/fixture/settle','cod.settle',{reference:'fixture-deposit'}]
]) {
 test(`${operation}: persisted critical-write dispatch receives caller key`,async()=>{
  calls=[];response={id:'fixture-order'};
  const r=await handlers[name](request(name,path,{method:'POST',headers:{...bearer,'idempotency-key':'critical-fixture-key'},body:JSON.stringify(body)}));
  assert.equal(r.status,operation==='order.confirm'?201:200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_critical_write'));assert.equal(calls[0].body.p_key,'critical-fixture-key');assert.equal(calls[0].body.p_operation,operation);
 });
 test(`${operation}: rejects missing key before write`,async()=>{
  calls=[];const r=await handlers[name](request(name,path,{method:'POST',headers:bearer,body:JSON.stringify(body)}));assert.equal(r.status,422);assert.equal(calls.length,0);
 });
}
for(const name of Object.keys(handlers))test(`${name}: bearer casing cannot bypass cookie CSRF`,async()=>{
 calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{authorization:'bearer fake-value',cookie:'jana_session=fixture; jana_csrf=known','content-type':'application/json'},body:'{}'}));assert.equal(r.status,403);assert.equal(calls.length,0);
});
for(const name of ['jana-api','jana-critical']) {
 test(`${name}: malformed cart is rejected before stock reservation`,async()=>{
  for(const lines of [null,{},[{offering_id:'test',quantity:0}],[{offering_id:'test',quantity:'1'}]]){
   calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{...bearer,'idempotency-key':'bad-cart-key'},body:JSON.stringify({slot_id:'s',address_id:'a',lines})}));assert.equal(r.status,422);assert.equal(calls.length,0);
  }
 });
 test(`${name}: coupon remains closed without isolated analytics configuration`,async()=>{
  calls=[];const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{...bearer,'idempotency-key':'flag-closed-key'},body:JSON.stringify({slot_id:'s',address_id:'a',coupon_code:'TEST',lines:[{offering_id:'o',quantity:1}]})}));assert.equal(r.status,409);assert.equal((await r.json()).error.code,'FEATURE_UNAVAILABLE');assert.equal(calls.length,0);
 });
 test(`${name}: allowed coupon uses server evaluation and normalized transactional RPC`,async()=>{
  const oldEnv=Deno.env.get,oldFetch=globalThis.fetch;const token='flag-test-'+name;const seen=[];
  try {
   Deno.env.get=k=>({JANA_POSTHOG_PROJECT_KEY:'fixture-project-key',JANA_POSTHOG_PROJECT_ID:'fixture-jana',JANA_POSTHOG_HOST:'https://us.i.posthog.com'}[k]||oldEnv(k));
   globalThis.fetch=async(url,init)=>{const body=JSON.parse(init.body);seen.push({url:String(url),body});return Response.json(String(url).includes('/flags?')?{errorsWhileComputingFlags:false,flags:{'jana-checkout-coupons':{enabled:true}}}:{id:'fixture-quote',discount_halalas:500})};
   const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{...bearer,authorization:'Bearer '+token,'idempotency-key':'flag-open-key'},body:JSON.stringify({slot_id:'s',address_id:'a',coupon_code:' test ',lines:[{offering_id:'o',quantity:1}]})}));assert.equal(r.status,201);assert.equal(seen.length,2);assert.ok(seen[1].url.endsWith('/jana_create_quote_with_coupon'));assert.equal(seen[1].body.p_coupon_code,'TEST');assert.ok(!JSON.stringify(seen[0].body).includes(token));assert.match(seen[0].body.distinct_id,/^jana-session-[0-9a-f]{64}$/);
  } finally {Deno.env.get=oldEnv;globalThis.fetch=oldFetch;}
 });
}
for(const scenario of ['offline','partial-error','quota','off'])test(`coupon flag fails closed on ${scenario}`,async()=>{
 const {couponFeature}=await import('../supabase/functions/jana-api/http.ts');const oldEnv=Deno.env.get,oldFetch=globalThis.fetch;
 try {
  Deno.env.get=k=>({JANA_POSTHOG_PROJECT_KEY:'fixture-project-key',JANA_POSTHOG_PROJECT_ID:'fixture-'+scenario,JANA_POSTHOG_HOST:'https://us.i.posthog.com'}[k]||oldEnv(k));
  globalThis.fetch=async()=>{if(scenario==='offline')throw Error('test-network');return Response.json({errorsWhileComputingFlags:scenario==='partial-error',quotaLimited:scenario==='quota'?['feature_flags']:[],flags:{'jana-checkout-coupons':{enabled:scenario!=='off'}}})};
  assert.equal(await couponFeature('fixture-session-'+scenario),false);
 } finally {Deno.env.get=oldEnv;globalThis.fetch=oldFetch;}
});
