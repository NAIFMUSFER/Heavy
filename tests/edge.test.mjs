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
test('staff order pages use one bounded role-scoped RPC and preserve legacy offsets',async()=>{
 for(const [query,expected] of [['limit=25&before_at=1800000000000&before_id=staff-order',{p_limit:25,p_before_at:1800000000000,p_before_id:'staff-order',p_offset:0}],['limit=100&offset=100',{p_limit:100,p_before_at:null,p_before_id:null,p_offset:100}]]){
  calls=[];response={items:[{id:'fixture'}],next:null,next_offset:null};
  const r=await handlers['jana-api'](request('jana-api','/api/ops/orders?'+query,{headers:bearer}));
  assert.equal(r.status,200);assert.deepEqual(await r.json(),response);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_ops_orders_page'));assert.deepEqual(calls[0].body,{p_token:bearer.authorization.slice(7),...expected});
 }
 for(const query of ['limit=1.5','offset=-1','before_at=NaN','before_at=9007199254740992','limit=']){calls=[];const r=await handlers['jana-api'](request('jana-api','/api/ops/orders?'+query,{headers:bearer}));assert.equal(r.status,422);assert.equal(calls.length,0)}
 calls=[];const anonymous=await handlers['jana-api'](request('jana-api','/api/ops/orders'));assert.equal(anonymous.status,401);assert.equal(calls.length,0);
 response={_error:'forbidden',status:403};const denied=await handlers['jana-api'](request('jana-api','/api/ops/orders',{headers:bearer}));assert.equal(denied.status,403);
});
test('courier foreground location preserves the path order and validates coordinates before its scoped RPC',async()=>{
 calls=[];response={order_id:'fixture-order',latitude:16.5,longitude:42.5};
 const r=await handlers['jana-api'](request('jana-api','/api/ops/orders/fixture-order/location',{method:'POST',headers:bearer,body:JSON.stringify({order_id:'ignored-body-order',latitude:'١٦٫٥',longitude:'٤٢٫٥',accuracy_m:15})}));
 assert.equal(r.status,200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_courier_update_location'));assert.deepEqual(calls[0].body,{p_token:bearer.authorization.slice(7),p_order_id:'fixture-order',p_lat:16.5,p_lng:42.5,p_accuracy:15});
 for(const payload of [{latitude:null,longitude:42},{latitude:16,longitude:181},{latitude:16,longitude:42,accuracy_m:-1}]){calls=[];const bad=await handlers['jana-api'](request('jana-api','/api/ops/orders/fixture-order/location',{method:'POST',headers:bearer,body:JSON.stringify(payload)}));assert.equal(bad.status,422);assert.equal(calls.length,0)}
});
test('customer order pages pass a typed stable cursor to PostgreSQL instead of loading the full order history',async()=>{
 calls=[];response={items:[],next:null,next_offset:null};
 const r=await handlers['jana-api'](request('jana-api','/api/orders?limit=25&before_at=1800000000000&before_id=order-x',{headers:bearer}));
 assert.equal(r.status,200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_orders_page'));assert.deepEqual(calls[0].body,{p_token:bearer.authorization.slice(7),p_limit:25,p_before_at:1800000000000,p_before_id:'order-x',p_offset:0});
 for(const query of ['limit=1.5','offset=-1','before_at=NaN','before_at=9007199254740992','limit=']){calls=[];const bad=await handlers['jana-api'](request('jana-api','/api/orders?'+query,{headers:bearer}));assert.equal(bad.status,422);assert.equal(calls.length,0)}
});
test('password success clears both web cookies only after PostgreSQL confirms the change',async()=>{
 calls=[];response={ok:true,all_sessions_revoked:true};
 const options={method:'POST',headers:{...bearer,cookie:'jana_session=known; jana_csrf=known','x-csrf-token':'known'},body:JSON.stringify({current_password:'fixture-current',new_password:'fixture-new-password'})};
 const r=await handlers['jana-api'](request('jana-api','/api/auth/password',options));assert.equal(r.status,200);assert.equal((await r.json()).sign_in_again,true);assert.equal(r.headers.getSetCookie().filter(c=>c.includes('Max-Age=0')).length,2);assert.ok(calls[0].url.endsWith('/jana_change_password'));
 response={_error:'invalid_credentials',status:401};const bad=await handlers['jana-api'](request('jana-api','/api/auth/password',options));assert.equal(bad.status,401);assert.equal(bad.headers.getSetCookie().length,0);
});
test('address API normalizes Arabic input before the atomic save and keeps partial edits partial',async()=>{
 calls=[];response={id:'fixture-address'};
 const r=await handlers['jana-api'](request('jana-api','/api/addresses/fixture-address',{method:'PATCH',headers:bearer,body:JSON.stringify({latitude:'١٦٫٥',longitude:'٤٢٫٥',recipient_phone:'٠٠٩٦٦ ٥٠ ٠٠٠ ٠٠٠١',is_default:false})}));
 assert.equal(r.status,200);assert.equal(calls.length,1);assert.deepEqual(calls[0].body.p_address,{latitude:'16.5',longitude:'42.5',recipient_phone:'+966500000001',is_default:false});
 calls=[];const invalid=await handlers['jana-api'](request('jana-api','/api/addresses/fixture-address',{method:'PATCH',headers:bearer,body:'{"recipient_phone":"123"}'}));assert.equal(invalid.status,422);assert.equal((await invalid.json()).error.code,'ADDRESS_PHONE');assert.equal(calls.length,0);
});
test('Maps resolution authenticates a customer before parsing and performs no external fetch for coordinate URLs',async()=>{
 calls=[];const anonymous=await handlers['jana-api'](request('jana-api','/api/maps/resolve',{method:'POST',headers:{'content-type':'application/json'},body:'{"url":"16.5,42.5"}'}));assert.equal(anonymous.status,401);assert.equal(calls.length,0);
 response={id:'fixture-map-customer',role:'customer'};const r=await handlers['jana-api'](request('jana-api','/api/maps/resolve',{method:'POST',headers:bearer,body:'{"url":"https://www.google.com/maps/search/?api=1&query=16.5%2C42.5"}'}));assert.equal(r.status,200);assert.deepEqual(await r.json(),{latitude:16.5,longitude:42.5});assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_me'));
 calls=[];response={id:'fixture-map-staff',role:'picker'};const staff=await handlers['jana-api'](request('jana-api','/api/maps/resolve',{method:'POST',headers:bearer,body:'{"url":"https://maps.app.goo.gl/FixturePin"}'}));assert.equal(staff.status,403);assert.equal(calls.length,1);
});
test('basket component evidence requires a persistent key before reaching PostgreSQL',async()=>{
 calls=[];const r=await handlers['jana-api'](request('jana-api','/api/ops/orders/fixture/components',{method:'POST',headers:bearer,body:'{}'}));assert.equal(r.status,422);assert.equal(calls.length,0);
});
test('basket component route preserves typed evidence and authoritative path order for transactional validation',async()=>{
 calls=[];response={matches:false};const body={order_id:'wrong-body-order',line_id:'fixture-line',revision:7,items:[{stock_id:'grams',actual_base:0},{stock_id:'pieces',actual_base:3}]};
 const r=await handlers['jana-api'](request('jana-api','/api/ops/orders/fixture/components',{method:'POST',headers:{...bearer,'idempotency-key':'component-test-key'},body:JSON.stringify(body)}));
 assert.equal(r.status,200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_picker_record_components'));assert.equal(calls[0].body.p_idem_key,'component-test-key');assert.deepEqual(calls[0].body.p_payload,{...body,order_id:'fixture'});
});
test('basket stale revision and unresolved quantity errors are actionable conflicts',async()=>{
 for(const [message,code]of [['component_check_changed','COMPONENT_CHANGED'],['basket_components_unresolved','BASKET_UNRESOLVED']]){
  response={_error:message,status:409};const r=await handlers['jana-api'](request('jana-api','/api/ops/orders/fixture/components',{method:'POST',headers:{...bearer,'idempotency-key':'component-test-key'},body:'{}'}));assert.equal(r.status,409);assert.equal((await r.json()).error.code,code);
 }
});
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
for(const [path,method,body,addressId] of [
 ['/api/addresses','POST',{label:'fixture',city:'Jazan',details:'Fixture door',recipient_name:'Fixture customer',latitude:'16.5',longitude:'42.5',recipient_phone:'0500000000'},null],
 ['/api/addresses/fixture-id','PATCH',{notes:'fixture note'},'fixture-id'],
 ['/api/addresses/fixture-id/default','PATCH',{},'fixture-id']
])test(`${method} ${path}: one transactional address RPC owns validation`,async()=>{
 calls=[];response={id:'fixture-address'};const r=await handlers['jana-api'](request('jana-api',path,{method,headers:bearer,body:JSON.stringify(body)}));assert.equal(r.status,method==='POST'?201:200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_save_address'));assert.equal(calls[0].body.p_address_id,addressId);assert.deepEqual(calls[0].body.p_address,path.endsWith('/default')?{is_default:true}:body);
});
test('goods receipt preserves unknown cost with idempotency and excludes unrelated fields',async()=>{
 calls=[];response={id:'fixture-lot'};const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/lots',{method:'POST',headers:{...bearer,'idempotency-key':'receipt-fixture-key'},body:JSON.stringify({stock_id:'fixture-stock',received_base:1000,total_cost_halalas:null,expires_at:4102444800000,discount_type:'fixed'})}));assert.equal(r.status,201);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_inventory_write'));assert.equal(calls[0].body.p_payload.total_cost_halalas,null);assert.equal(calls[0].body.p_payload.discount_type,undefined);assert.equal(calls[0].body.p_idem_key,'receipt-fixture-key');assert.equal(calls[0].body.p_operation,'lot.receive');
});
test('supplier credit note forwards only audited fields with caller idempotency',async()=>{
 calls=[];response={id:'credit-fixture',amount_halalas:100};const id='11111111-1111-4111-8111-111111111111';
 const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/disposals/'+id+'/supplier-credits',{method:'POST',headers:{...bearer,'idempotency-key':'supplier-credit-key'},body:JSON.stringify({disposal_id:'foreign',amount_halalas:100,reference:'CN-1',note:'Actual supplier note',cash_received:true})}));
 assert.equal(r.status,201);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_supplier_credit_record'));assert.equal(calls[0].body.p_idem_key,'supplier-credit-key');assert.deepEqual(calls[0].body.p_payload,{disposal_id:id,amount_halalas:100,reference:'CN-1',note:'Actual supplier note'});
});
test('supplier credit route rejects malformed identifiers before database access',async()=>{
 for(const id of ['not-a-uuid','------------------------------------','11111111-1111-1111-1111-111111111111']){calls=[];const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/disposals/'+id+'/supplier-credits',{method:'POST',headers:{...bearer,'idempotency-key':'supplier-credit-key'},body:'{}'}));assert.equal(r.status,404);assert.equal(calls.length,0)}
});
for(const [path,operation,input,expected] of [
 ['/api/tickets','ticket.create',{subject:'Support subject',message:'Customer message',category:'delivery'},{order_id:null,subject:'Support subject',message:'Customer message',category:'delivery'}],
 ['/api/tickets/ticket-a/reply','ticket.reply',{message:'Customer reply',state:'closed',ticket_id:'unrelated'},{ticket_id:'ticket-a',message:'Customer reply'}],
 ['/api/ops/support/ticket-a','ticket.update',{message:'Staff reply',state:'closed',priority:'high',assigned_to:null,user_id:'unrelated',ticket_id:'unrelated'},{ticket_id:'ticket-a',message:'Staff reply',state:'closed',priority:'high',assigned_to:null}]
])test(`${operation} forwards a persisted key and approved fields only`,async()=>{
 calls=[];response={id:'ticket-a',state:'open'};const r=await handlers['jana-api'](request('jana-api',path,{method:'POST',headers:{...bearer,'idempotency-key':'support-key-123'},body:JSON.stringify(input)}));assert.ok(r.ok);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_ticket_write'));assert.equal(calls[0].body.p_key,'support-key-123');assert.equal(calls[0].body.p_operation,operation);assert.deepEqual(calls[0].body.p_payload,expected);
});
test('customer refund request uses durable idempotency and never forwards a paid state',async()=>{
 calls=[];response={id:'refund-fixture',state:'requested'};const r=await handlers['jana-api'](request('jana-api','/api/orders/order-fixture/refunds',{method:'POST',headers:{...bearer,'idempotency-key':'refund-request-key'},body:JSON.stringify({amount_halalas:100,reason:'Requested refund',state:'completed',payment_source:'courier'})}));assert.equal(r.status,201);assert.equal((await r.json()).state,'requested');assert.equal(calls[0].body.p_operation,'refund.request');assert.deepEqual(calls[0].body.p_payload,{order_id:'order-fixture',component_id:null,amount_halalas:100,reason:'Requested refund'});
});
test('partial settlement forwards the explicit amount while legacy full settlement omits it',async()=>{
 for(const body of [{reference:'Paid receipt',amount_halalas:500},{reference:'Paid receipt'}]){calls=[];response={cash_state:'with_courier'};const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/orders/order-fixture/settle',{method:'POST',headers:{...bearer,'idempotency-key':'settle-test-key'},body:JSON.stringify(body)}));assert.equal(r.status,200);assert.deepEqual(calls[0].body.p_payload,{order_id:'order-fixture',...body});}
});
for(const [path,operation,payload] of [
 ['/api/ops/orders/order-a/actual','line.actual',{line_id:'line-a',actual_base:900}],
 ['/api/ops/orders/order-a/substitution','substitution.propose',{line_id:'line-a',offering_id:'offer-a',qty:1}],
 ['/api/ops/orders/order-a/component-substitution','component.substitution.propose',{line_id:'line-a',component_id:'stock-a',replacement_stock_id:'stock-b'}],
 ['/api/ops/orders/order-a/removal','line.removal.propose',{line_id:'line-a'}],
 ['/api/ops/orders/order-a/unavailable','line.unavailable',{line_id:'line-a',reason:'Unavailable fixture'}],
 ['/api/ops/orders/order-a/restore','line.restore',{line_id:'line-a',reason:'Verified original fixture'}],
 ['/api/ops/orders/order-a/finalize','picking.finish',{}],
 ['/api/ops/orders/order-a/ready','picking.finish',{}],
 ['/api/substitutions/sub-a/decision','substitution.decide',{accept:false}]
])test(`${operation}: picking requests use persisted idempotency with explicit payload`,async()=>{
 calls=[];response={id:'fixture'};
 let r=await handlers['jana-api'](request('jana-api',path,{method:'POST',headers:bearer,body:JSON.stringify(payload)}));assert.equal(r.status,422);assert.equal(calls.length,0);
 r=await handlers['jana-api'](request('jana-api',path,{method:'POST',headers:{...bearer,'idempotency-key':'picking-fixture-key'},body:JSON.stringify({...payload,price_halalas:1,role:'admin',state:'accepted'})}));
 assert.equal(r.status,operation.endsWith('.propose')?201:200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_picking_write'));assert.equal(calls[0].body.p_operation,operation);assert.equal(calls[0].body.p_idem_key,'picking-fixture-key');assert.equal(calls[0].body.p_payload.price_halalas,undefined);assert.equal(calls[0].body.p_payload.state,undefined);if(operation==='substitution.decide')assert.equal(calls[0].body.p_payload.accept,false);
});
test('expired substitute business error is not displayed as successful consent',async()=>{
 calls=[];response={_error:'substitution_expired',status:409};const r=await handlers['jana-api'](request('jana-api','/api/substitutions/sub-a/decision',{method:'POST',headers:{...bearer,'idempotency-key':'expired-fixture-key'},body:'{"accept":true}'}));assert.equal(r.status,409);assert.equal((await r.json()).error.code,'SUBSTITUTION_EXPIRED');
});
for(const [path,operation,payload] of [['/api/ops/counts','count.start',{location:'Shelf fixture',lot_ids:['lot-a']}],['/api/ops/counts/count-a/submit','count.submit',{counts:[],note:'Count fixture'}],['/api/ops/counts/count-a/cancel','count.cancel',{reason:'Recount needed'}],['/api/ops/count-lines/count-a/decision','count.decide',{approve:false,reason:'Stale fixture'}],['/api/ops/lots/lot-a/inspect','lot.inspect',{state:'rejected',note:'Quality fixture'}],['/api/ops/lots/lot-a/adjust','lot.adjust',{new_on_hand:500,reason:'Count fixture'}]])test(`${operation}: warehouse writes require a persisted caller key`,async()=>{
 calls=[];response={id:'fixture'};const invoke=headers=>handlers['jana-ops-extra'](request('jana-ops-extra',path,{method:'POST',headers,body:JSON.stringify({...payload,approved_by:'client-cannot-choose',system_revision:0})}));let r=await invoke(bearer);assert.equal(r.status,422);assert.equal(calls.length,0);r=await invoke({...bearer,'idempotency-key':'warehouse-fixture-key'});assert.ok(r.ok);assert.equal(calls[0].body.p_operation,operation);assert.equal(calls[0].body.p_idem_key,'warehouse-fixture-key');assert.equal(calls[0].body.p_payload.approved_by,undefined);assert.equal(calls[0].body.p_payload.system_revision,undefined);if(operation==='count.decide')assert.equal(calls[0].body.p_payload.approve,false);
});
for(const [method,path,operation,input,expected] of [
 ['POST','/api/ops/staff','staff.create',{name:'Fixture',email:'fixture@example.invalid',password:'Fixture-password',role:'inventory',active:false},{name:'Fixture',email:'fixture@example.invalid',password:'Fixture-password',role:'inventory'}],
 ['PATCH','/api/ops/staff/staff-a','staff.update',{name:'New fixture',active:false,reason:'Fixture documented change',user_id:'foreign',password_hash:'never-forward'},{user_id:'staff-a',changes:{name:'New fixture',active:false},reason:'Fixture documented change'}],
 ['POST','/api/ops/orders/order-a/assignment','order.assign',{picker_id:'picker-a',reason:'Fixture assignment',courier_refunded_halalas:0,order_id:'foreign'},{order_id:'order-a',assignments:{picker_id:'picker-a'},reason:'Fixture assignment'}]
])test(`${operation}: enforces caller key and forwards allowed membership fields`,async()=>{
 calls=[];response={id:'fixture'};const invoke=headers=>handlers['jana-api'](request('jana-api',path,{method,headers,body:JSON.stringify(input)}));let r=await invoke(bearer);assert.equal(r.status,422);assert.equal(calls.length,0);r=await invoke({...bearer,'idempotency-key':'staff-write-fixture'});assert.ok(r.ok);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_staff_write'));assert.equal(calls[0].body.p_operation,operation);assert.deepEqual(calls[0].body.p_payload,expected);
});
test('own membership change clears both browser cookies when reauthentication is required',async()=>{
 calls=[];response={id:'self-fixture',sign_in_again:true};const r=await handlers['jana-api'](request('jana-api','/api/ops/staff/self-fixture',{method:'PATCH',headers:{...bearer,'idempotency-key':'self-role-fixture'},body:JSON.stringify({role:'inventory',reason:'Fixture role change'})}));assert.equal(r.status,200);assert.equal(r.headers.getSetCookie().length,2);assert.ok(r.headers.getSetCookie().every(x=>x.includes('Max-Age=0')));
});
test('last administrator business constraint is a clear conflict without database details',async()=>{
 calls=[];response={_error:'last_active_admin',status:409};const r=await handlers['jana-api'](request('jana-api','/api/ops/staff/staff-a',{method:'PATCH',headers:{...bearer,'idempotency-key':'last-admin-fixture'},body:'{"active":false,"reason":"Fixture change"}'}));assert.equal(r.status,409);assert.equal((await r.json()).error.code,'LAST_ADMIN');
});
for(const [method,path,operation,input,expected] of [
 ['POST','/api/shopping-lists','list.save',{name:'Weekly fixture',items:[],user_id:'foreign'},{name:'Weekly fixture',items:[]}],
 ['PATCH','/api/shopping-lists/list-a','list.save',{name:'Renamed',revision:2,list_id:'foreign'},{list_id:'list-a',revision:2,name:'Renamed'}],
 ['DELETE','/api/shopping-lists/list-a','list.delete',{revision:2,list_id:'foreign'},{list_id:'list-a',revision:2}],
 ['POST','/api/recurring','recurring.save',{name:'Reminder',cadence:'monthly',next_at:4102444800000,items:[],auto_charge:true},{plan_id:null,changes:{name:'Reminder',items:[],cadence:'monthly',next_at:4102444800000}}],
 ['PATCH','/api/profile','profile.update',{name:'Customer',phone:'0500000000',role:'admin',verified_phone:true},{name:'Customer',phone:'0500000000'}]
])test(`${operation}: saved customer writes require a key and retain only allowed fields`,async()=>{
 calls=[];response={id:'saved-a'};const invoke=headers=>handlers['jana-api'](request('jana-api',path,{method,headers,body:JSON.stringify(input)}));let r=await invoke(bearer);assert.equal(r.status,422);assert.equal(calls.length,0);r=await invoke({...bearer,'idempotency-key':'saved-data-fixture'});assert.ok(r.ok);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_customer_saved_write'));assert.equal(calls[0].body.p_operation,operation);assert.deepEqual(calls[0].body.p_payload,expected);
});
test('catalog forwards one bounded query to PostgreSQL and preserves the page response',async()=>{
 calls=[];response={items:[{id:'catalog-fixture',available_units:2}],next_offset:100};
 const r=await handlers['jana-api'](request('jana-api','/api/catalog?offset=50&limit=50&q=%25_&category=fruit'));
 assert.equal(r.status,200);assert.deepEqual(await r.json(),response);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_catalog_page'));assert.deepEqual(calls[0].body,{p_offset:50,p_limit:50,p_query:'%_',p_category:'fruit'});
});
test('catalog rejects invalid pagination before database work',async()=>{
 for(const query of ['offset=-1','offset=1.5','offset=Infinity','offset=100001','limit=0','limit=101','limit=1e2','q='+('q'.repeat(201))]){
  calls=[];const r=await handlers['jana-api'](request('jana-api','/api/catalog?'+query));assert.equal(r.status,422,query);assert.equal((await r.json()).error.code,'CATALOG_PAGE');assert.equal(calls.length,0);
 }
});
test('saved cart persists only revision canonical selections and the retry key',async()=>{
 calls=[];response={revision:1,saved:true};const r=await handlers['jana-api'](request('jana-api','/api/cart',{method:'PUT',headers:{...bearer,'idempotency-key':'cart-fixture-key'},body:JSON.stringify({revision:0,items:[],user_id:'other',price_halalas:1})}));assert.equal(r.status,200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_save_customer_cart'));assert.deepEqual(Object.keys(calls[0].body).sort(),['p_items','p_key','p_revision','p_token']);assert.equal(calls[0].body.p_revision,0);assert.equal(calls[0].body.p_key,'cart-fixture-key');
});
test('saved cart rejects missing key or invalid revision before database mutation',async()=>{
 for(const [revision,key] of [[0,null],[-1,'cart-key-fixture'],[1.2,'cart-key-fixture'],['1','cart-key-fixture']]){calls=[];const r=await handlers['jana-api'](request('jana-api','/api/cart',{method:'PUT',headers:{...bearer,...(key?{'idempotency-key':key}:{})},body:JSON.stringify({revision,items:[]})}));assert.ok([409,422].includes(r.status));assert.equal(calls.length,0)}
});
test('optional-email registration forwards no invented address and only customer fields',async()=>{
 calls=[];response={user:{id:'fixture',email:null,phone:'+966500000002',verified_phone:false,role:'customer'},token:'fixture-created-session'};const r=await handlers['jana-api'](request('jana-api','/api/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({phone:'0500000002',name:'Fixture',password:'Fixture-password-123',role:'admin',verified_phone:true})}));assert.equal(r.status,201);assert.equal(calls[0].body.p_email,null);assert.equal(calls[0].body.p_phone,'0500000002');assert.equal(calls[0].body.role,undefined);assert.equal(calls[0].body.verified_phone,undefined);assert.equal((await r.json()).user.email,null);
});
test('phone login uses the canonical password authentication RPC',async()=>{
 calls=[];response={user:{id:'fixture'},token:'fixture-token',csrf:'fixture-csrf'};const r=await handlers['jana-api'](request('jana-api','/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({identifier:'0500000002',password:'Fixture-password-123'})}));assert.equal(r.status,200);assert.ok(calls[0].url.endsWith('/jana_login'));assert.equal(calls[0].body.p_email,'0500000002');assert.equal(r.headers.getSetCookie().length,2);
});
test('disposal requires idempotency and forwards only canonical operation inputs',async()=>{
 calls=[];response={id:'disposal-fixture'};const body={kind:'waste',quantity_base:100,revision:0,reason:'Fixture reason',reference:'Fixture reference',actor_id:'ignored-client-actor',value_halalas:1};
 let r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/lots/fixture-lot/disposal',{method:'POST',headers:bearer,body:JSON.stringify(body)}));assert.equal(r.status,422);assert.equal(calls.length,0);
 r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/lots/fixture-lot/disposal',{method:'POST',headers:{...bearer,'idempotency-key':'disposal-fixture-key'},body:JSON.stringify(body)}));assert.equal(r.status,201);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_inventory_dispose'));assert.equal(calls[0].body.p_payload.actor_id,undefined);assert.equal(calls[0].body.p_payload.value_halalas,undefined);assert.equal(calls[0].body.p_payload.lot_id,'fixture-lot');
});
test('malformed disposal pagination is rejected before database access',async()=>{
 calls=[];const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/disposals?before_at=123',{headers:bearer}));assert.equal(r.status,422);assert.equal(calls.length,0);
});

test('movement pagination validates ranges and filters before canonical RPC',async()=>{
 for(const q of ['before_at=123','from_at=20&to_at=10','from_at=abc','secret=x','lot_id='+('x'.repeat(37))]){calls=[];const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/movements?'+q,{headers:bearer}));assert.equal(r.status,422);assert.equal(calls.length,0)}
 calls=[];response={items:[],next:null};const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/movements?reason=waste&reference=DOC%25&before_at=123&before_id=mov-fixture',{headers:bearer}));assert.equal(r.status,200);assert.deepEqual(calls[0].body,{p_token:bearer.authorization.slice(7),p_filters:{reason:'waste',reference:'DOC%'},p_before_at:123,p_before_id:'mov-fixture'});
});

test('warehouse returns require idempotency and derive actor cost and order from the canonical shipment',async()=>{
 calls=[];response={id:'return-fixture'};
 const body={source_movement_id:'shipped-movement',quantity_base:10,reference:'Warehouse receipt',reason:'Physical return fixture',actor_id:'untrusted',stock_id:'untrusted',order_id:'untrusted',restored_cost_halalas:10000};
 let r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/customer-returns',{method:'POST',headers:bearer,body:JSON.stringify(body)}));assert.equal(r.status,422);assert.equal(calls.length,0);
 r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/customer-returns',{method:'POST',headers:{...bearer,'idempotency-key':'return-fixture-key'},body:JSON.stringify(body)}));assert.equal(r.status,201);assert.deepEqual(calls[0].body.p_payload,{source_movement_id:body.source_movement_id,quantity_base:10,reference:body.reference,reason:body.reason});
});
test('return inspection accepts only the observed quality decision and cannot set a price or financial outcome',async()=>{
 calls=[];response={accepted_base:5};const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/customer-returns/11111111-1111-1111-1111-111111111111/inspection',{method:'POST',headers:{...bearer,'idempotency-key':'quality-fixture-key'},body:JSON.stringify({accepted_base:5,note:'Physical inspection',refund:500,cost_basis:'recorded'})}));assert.equal(r.status,201);assert.deepEqual(calls[0].body.p_payload,{return_id:'11111111-1111-1111-1111-111111111111',accepted_base:5,note:'Physical inspection'});
});
test('malformed return history or order lookup is rejected before database access',async()=>{
 for(const path of ['/api/ops/customer-returns?before_at=1','/api/ops/customer-returns/context','/api/ops/customer-returns?before_at=x&before_id=bad']){calls=[];const r=await handlers['jana-ops-extra'](request('jana-ops-extra',path,{headers:bearer}));assert.equal(r.status,422);assert.equal(calls.length,0)}
});
test('return disposition requires an idempotency key and forwards only canonical document fields',async()=>{
 calls=[];response={id:'fixture-disposition'};
 const path='/api/ops/customer-returns/11111111-1111-1111-1111-111111111111/dispositions';
 const body={kind:'destroyed',quantity_base:10,reference:'Fixture document',note:'Physical disposal recorded',actor_id:'ignored',refund:100};
 let r=await handlers['jana-ops-extra'](request('jana-ops-extra',path,{method:'POST',headers:bearer,body:JSON.stringify(body)}));assert.equal(r.status,422);assert.equal(calls.length,0);
 r=await handlers['jana-ops-extra'](request('jana-ops-extra',path,{method:'POST',headers:{...bearer,'idempotency-key':'custody-fixture-key'},body:JSON.stringify(body)}));assert.equal(r.status,201);
 assert.ok(calls[0].url.endsWith('/jana_customer_return_dispose'));
 assert.deepEqual(calls[0].body.p_payload,{return_id:'11111111-1111-1111-1111-111111111111',kind:'destroyed',quantity_base:10,reference:body.reference,recipient:null,note:body.note});
});
test('return disposition history validates identifiers and paired keyset cursors',async()=>{
 const path='/api/ops/customer-returns/11111111-1111-1111-1111-111111111111/dispositions';
 for(const invalid of [path+'?before_at=1',path+'?before_at=x&before_id=bad','/api/ops/customer-returns/invalid/dispositions']){
  calls=[];const r=await handlers['jana-ops-extra'](request('jana-ops-extra',invalid,{headers:bearer}));assert.equal(r.status,422);assert.equal(calls.length,0);
 }
 calls=[];response={items:[]};const r=await handlers['jana-ops-extra'](request('jana-ops-extra',path+'?before_at=123&before_id=22222222-2222-2222-2222-222222222222',{headers:bearer}));assert.equal(r.status,200);
 assert.deepEqual(calls[0].body,{p_token:bearer.authorization.slice(7),p_return_id:'11111111-1111-1111-1111-111111111111',p_before_at:123,p_before_id:'22222222-2222-2222-2222-222222222222'});
});
test('custody business conflicts surface as actionable HTTP errors',async()=>{
 for(const [code,status]of [['return_disposition_requires_rejection',409],['return_disposition_exceeds_remaining',409],['return_disposition_reference_exists',409],['return_disposition_validation',422]]){
  calls=[];response={_error:code,status};
  const r=await handlers['jana-ops-extra'](request('jana-ops-extra','/api/ops/customer-returns/11111111-1111-1111-1111-111111111111/dispositions',{method:'POST',headers:{...bearer,'idempotency-key':'custody-error-fixture'},body:'{}'}));assert.equal(r.status,status);assert.match((await r.json()).error.code,/RETURN_DISPOSITION/);
 }
});

for(const [route,operation]of [['draft','draft.save'],['publish','profile.publish'],['intake','intake.set']])test(`store ${operation} requires idempotency and forwards the canonical operation`,async()=>{
 calls=[];response={revision:1};const path='/api/ops/storefront/'+route,body={revision:0,profile:{}};
 let r=await handlers['jana-api'](request('jana-api',path,{method:'POST',headers:bearer,body:JSON.stringify(body)}));assert.equal(r.status,422);assert.equal(calls.length,0);
 r=await handlers['jana-api'](request('jana-api',path,{method:'POST',headers:{...bearer,'idempotency-key':'store-write-fixture'},body:JSON.stringify(body)}));assert.equal(r.status,200);assert.equal(calls.length,1);assert.ok(calls[0].url.endsWith('/jana_storefront_write'));assert.equal(calls[0].body.p_operation,operation);assert.deepEqual(calls[0].body.p_payload,body);
});
test('publishing while intake is open returns an actionable policy-review conflict',async()=>{
 calls=[];response={_error:'storefront_close_before_publish',status:409};const r=await handlers['jana-api'](request('jana-api','/api/ops/storefront/publish',{method:'POST',headers:{...bearer,'idempotency-key':'publish-open-fixture'},body:JSON.stringify({revision:7,confirmed:true})}));
 assert.equal(r.status,409);assert.equal((await r.json()).error.code,'STORE_CLOSE_BEFORE_PUBLISH');
});
test('public store version lookup validates IDs and uses only the public RPC',async()=>{
 calls=[];let r=await handlers['jana-api'](request('jana-api','/api/storefront?version=invalid'));assert.equal(r.status,404);assert.equal(calls.length,0);
 response={published:null,accepting_orders:false};r=await handlers['jana-api'](request('jana-api','/api/storefront'));assert.equal(r.status,200);assert.deepEqual(calls[0].body,{p_version_id:null});assert.ok(calls[0].url.endsWith('/jana_public_storefront'));
});
for(const name of ['jana-api','jana-critical'])test(`${name} reports closed store without pretending stock failed`,async()=>{
 response={_error:'storefront_closed',status:409};const r=await handlers[name](request(name,'/api/quotes',{method:'POST',headers:{...bearer,'idempotency-key':'closed-quote-fixture'},body:JSON.stringify({address_id:'fixture',slot_id:'fixture',lines:[{offering_id:'fixture',quantity:1}]})}));assert.equal(r.status,409);assert.equal((await r.json()).error.code,'STORE_CLOSED');
});
