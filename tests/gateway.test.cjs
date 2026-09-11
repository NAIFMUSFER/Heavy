const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {createGateway,config}=require('../server.js');
async function fixture(t,upstream=async()=>Response.json({ok:true}),overrides={}){
 const calls=[],logs=[];const server=createGateway({settings:{...config({}),...overrides},fetchImpl:async(...args)=>{calls.push(args);return upstream(...args)},log:x=>logs.push(x)});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>{server.close(r);server.closeAllConnections()}));
 return {base:'http://127.0.0.1:'+server.address().port,calls,logs};
}
test('only approved public files can be served',async t=>{const f=await fixture(t);for(const p of ['/server.js','/.env','/.git/config','/mobile/App.js','/supabase/functions/jana-api/index.ts','/tests/gateway.test.cjs','/assets/shop.part01.js'])assert.equal((await fetch(f.base+p)).status,404,p);assert.equal(f.calls.length,0)});
test('customer and operations bundles remain valid and protected',async t=>{const f=await fixture(t);for(const p of ['/','/admin.html','/picker.html','/courier.html','/assets/shop.js','/assets/ops.js','/assets/styles.css','/assets/common.js','/assets/catalog-import.js','/assets/stock-import.js','/assets/ops-exports.js','/assets/zone-map.js','/assets/address.js','/assets/checkout.js','/assets/local-cart.js','/assets/input.js']){const r=await fetch(f.base+p);assert.equal(r.status,200);assert.ok((await r.text()).length>100);assert.match(r.headers.get('content-security-policy'),/script-src 'self';/);assert.equal(r.headers.get('x-frame-options'),'DENY')}});
test('health and version do not depend on database',async t=>{const f=await fixture(t,async()=>{throw Error('offline')},{commit:'test-commit'});assert.equal((await fetch(f.base+'/health')).status,200);assert.equal((await(await fetch(f.base+'/version')).json()).commit,'test-commit');assert.equal(f.calls.length,0);assert.equal((await fetch(f.base+'/ready')).status,503)});
test('owner handoff links are served without a database and retain real workspace destinations',async t=>{
 const f=await fixture(t,async()=>{throw Error('No backend needed for public links')});const response=await fetch(f.base+'/start.html');assert.equal(response.status,200);const html=await response.text();
 for(const href of ['/admin.html#launch','/admin.html#inventory','/picker.html#orders','/courier.html#orders','/admin.html#finance','/admin.html#support']){assert.ok(html.includes('href="'+href+'"'));assert.equal((await fetch(f.base+href.split('#')[0],{method:'HEAD'})).status,200)}
 assert.equal(f.calls.length,0);assert.equal(response.headers.getSetCookie().length,0);assert.match(response.headers.get('content-security-policy'),/script-src 'self';/);assert.doesNotMatch(html,/href="https:\/\/(apps\.apple\.com|play\.google\.com)|password|token|onclick=/);
});
test('readiness checks all three canonical Edge dependencies',async t=>{const f=await fixture(t);const r=await(await fetch(f.base+'/ready')).json();assert.equal(r.ok,true);assert.equal(r.dependencies.length,3);assert.ok(f.calls.every(([u])=>u.startsWith('https://jjdsajiwoqanefmnikls.supabase.co/functions/v1/')))});
test('failed dependency makes readiness fail even with HTTP 200',async t=>{const f=await fixture(t,async u=>Response.json({ok:!u.includes('jana-critical')}));assert.equal((await fetch(f.base+'/ready')).status,503)});
test('preserves separate cookies including comma in Expires',async t=>{const f=await fixture(t,async()=>{const h=new Headers({'content-type':'application/json'});h.append('set-cookie','jana_session=fixture; HttpOnly; Secure; SameSite=Strict; Expires=Wed, 09 Sep 2026 21:00:00 GMT');h.append('set-cookie','jana_csrf=fixture; Secure; SameSite=Strict');return new Response('{}',{headers:h})});const r=await fetch(f.base+'/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:'{}'});assert.equal(r.headers.getSetCookie().length,2);assert.match(r.headers.getSetCookie()[0],/Wed, 09 Sep/)});
test('rejects hostile login Origin before forwarding',async t=>{const f=await fixture(t);const r=await fetch(f.base+'/api/auth/login',{method:'POST',headers:{origin:'https://attacker.invalid','x-nf-request-id':'spoof','content-type':'application/json'},body:'{}'});assert.equal(r.status,403);assert.equal(f.calls.length,0)});
test('safe headers and body reach correct fixed upstream',async t=>{const f=await fixture(t);for(const [p,name] of [['/api/quotes','jana-critical'],['/api/ops/lots','jana-ops-extra'],['/api/ops/products','jana-ops-extra'],['/api/ops/products/import','jana-ops-extra'],['/api/ops/product-versions/fixture/activate','jana-ops-extra'],['/api/orders','jana-api']]){const r=await fetch(f.base+p,{method:'POST',headers:{origin:'https://jana-fresh-app.onrender.com',authorization:'Bearer fixture','idempotency-key':'fixture-key','x-csrf-token':'csrf','x-nf-request-id':'spoof','content-type':'application/json'},body:'{}'});assert.equal(r.status,200);const [url,init]=f.calls.at(-1);assert.ok(url.includes('/'+name+p));assert.equal(init.headers['idempotency-key'],'fixture-key');assert.equal(init.headers['x-nf-request-id'],undefined);assert.equal(init.redirect,'manual');assert.ok(init.signal)}});
test('large declared request returns structured 413 without upstream',async t=>{const f=await fixture(t);const r=await fetch(f.base+'/api/quotes',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({x:'a'.repeat(65536)})});assert.equal(r.status,413);assert.equal((await r.json()).error.code,'PAYLOAD_TOO_LARGE');assert.equal(f.calls.length,0)});
test('chunked request cannot evade body limit',async t=>{const f=await fixture(t);const r=await new Promise((resolve,reject)=>{const req=http.request(f.base+'/api/quotes',{method:'POST',headers:{'content-type':'application/json','transfer-encoding':'chunked'}},res=>{let b='';res.on('data',x=>b+=x);res.on('end',()=>resolve({status:res.statusCode,body:JSON.parse(b)}))});req.on('error',reject);req.write('a'.repeat(40000));req.end('b'.repeat(40000))});assert.equal(r.status,413);assert.equal(f.calls.length,0)});
test('unsupported content type rejected before upstream',async t=>{const f=await fixture(t);assert.equal((await fetch(f.base+'/api/quotes',{method:'POST',body:'{}'})).status,415);assert.equal(f.calls.length,0)});
test('upstream redirect is not followed',async t=>{const f=await fixture(t,async()=>new Response(null,{status:302,headers:{location:'https://attacker.invalid'}}));assert.equal((await fetch(f.base+'/api/catalog')).status,502);assert.equal(f.calls.length,1)});
test('timeout is explicit, never success',async t=>{const f=await fixture(t,async()=>{throw new DOMException('fixture','TimeoutError')});const r=await fetch(f.base+'/api/catalog');assert.equal(r.status,504);assert.equal((await r.json()).error.code,'UPSTREAM_TIMEOUT')});
test('analytics and logs omit tokens, query values, raw order IDs',async t=>{const f=await fixture(t,async()=>Response.json({ok:true}),{phKey:'test-project'});await fetch(f.base+'/api/orders/private-order?phone=private-phone',{headers:{authorization:'Bearer private-token',cookie:'private-cookie'}});await new Promise(r=>setImmediate(r));const payload=JSON.stringify(f.logs)+f.calls.filter(([url])=>url.includes('posthog.com')).map(([,init])=>init.body).join('');for(const secret of ['private-order','private-phone','private-token','private-cookie'])assert.ok(!payload.includes(secret),secret)});
test('configuration rejects an unrelated Supabase target',()=>assert.throws(()=>config({JANA_SUPABASE_URL:'https://unrelated.supabase.co'}),/dedicated JANA/));
test('upstream infrastructure cookies are not forwarded to JANA clients',async t=>{const f=await fixture(t,async()=>new Response('{}',{headers:{'content-type':'application/json','set-cookie':'upstream-infrastructure=fixture; Secure'}}));const r=await fetch(f.base+'/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:'{}'});assert.equal(r.headers.getSetCookie().length,0)});

test('generic analytics keys cannot enable capture without dedicated JANA configuration',()=>{assert.equal(config({POSTHOG_PROJECT_KEY:'unrelated-fixture-key'}).phKey,'');assert.equal(config({JANA_POSTHOG_PROJECT_KEY:'fixture-key'}).phKey,'');assert.equal(config({JANA_POSTHOG_PROJECT_ID:'12345',JANA_POSTHOG_PROJECT_KEY:'fixture-key'}).phKey,'fixture-key')});
test('financial and staff route identifiers are redacted from telemetry',()=>{const {routeLabel}=require('../server.js');for(const p of ['/api/ops/refunds/private-id/complete','/api/ops/support/private-id','/api/ops/product-versions/private-id/activate','/api/ops/staff/private-id'])assert.ok(!routeLabel(p).includes('private-id'))});
test('warehouse count routes remain on the fixed operations service with redacted identifiers',async t=>{
 const f=await fixture(t),{routeLabel}=require('../server.js');for(const p of ['/api/ops/counts/count-private/submit','/api/ops/count-lines/line-private/decision','/api/ops/stock/stock-private','/api/ops/suppliers/supplier-private']){const r=await fetch(f.base+p,{method:'POST',headers:{'content-type':'application/json'},body:'{}'});assert.equal(r.status,200);assert.ok(f.calls.at(-1)[0].includes('/jana-ops-extra'+p));assert.ok(!routeLabel(p).includes('private'))}
});

test('stock master import stays on the operations Edge and preserves the idempotency key',async t=>{
 const f=await fixture(t),body=JSON.stringify({schema_version:1,items:[]});
 const r=await fetch(f.base+'/api/ops/stock/import',{method:'POST',headers:{'content-type':'application/json','idempotency-key':'stock-import-fixture'},body});
 assert.equal(r.status,200);const [url,init]=f.calls.at(-1);assert.ok(url.endsWith('/jana-ops-extra/api/ops/stock/import'));assert.equal(init.headers['idempotency-key'],'stock-import-fixture');assert.equal(init.body.toString(),body);
});

test('saved list and recurring identifiers are redacted from telemetry',()=>{const {routeLabel}=require('../server.js');for(const p of ['/api/shopping-lists/private-list','/api/recurring/private-plan'])assert.ok(!routeLabel(p).includes('private-'))});

test('supplier credit routes use the operations service and redact disposal identifiers',async t=>{
 const f=await fixture(t),{routeLabel}=require('../server.js'),id='11111111-1111-4111-8111-111111111111';
 for(const [method,p] of [['GET','/api/ops/supplier-credits'],['POST','/api/ops/disposals/'+id+'/supplier-credits']]){
  const r=await fetch(f.base+p,{method,headers:method==='POST'?{'content-type':'application/json'}:undefined,body:method==='POST'?'{}':undefined});
  assert.equal(r.status,200);assert.ok(f.calls.at(-1)[0].includes('/jana-ops-extra'+p));assert.ok(!routeLabel(p).includes(id));
 }
});

test('delivery setting edits reach the operations Edge and redact resource identifiers',async t=>{
 const f=await fixture(t),{routeLabel}=require('../server.js');
 for(const p of ['/api/ops/zones/zone-private','/api/ops/slots/slot-private']){
  const r=await fetch(f.base+p,{method:'PATCH',headers:{'content-type':'application/json'},body:JSON.stringify({revision:1,reason:'Fixture setting change',active:false})});
  assert.equal(r.status,200);assert.ok(f.calls.at(-1)[0].includes('/jana-ops-extra'+p));assert.ok(!routeLabel(p).includes('private'));
 }
});
test('saved cart PUT reaches the fixed API while unrelated PUT methods stay rejected',async t=>{
 const f=await fixture(t);const r=await fetch(f.base+'/api/cart',{method:'PUT',headers:{'content-type':'application/json'},body:'{"revision":0,"items":[]}'});assert.equal(r.status,200);assert.ok(f.calls[0][0].endsWith('/jana-api/api/cart'));assert.equal(f.calls[0][1].method,'PUT');const prior=f.calls.length;assert.equal((await fetch(f.base+'/api/orders',{method:'PUT',headers:{'content-type':'application/json'},body:'{}'})).status,405);assert.equal(f.calls.length,prior);
});
test('customer directory contact search and record identifiers stay out of telemetry',async t=>{
 const f=await fixture(t);await fetch(f.base+'/api/ops/customers/private-customer?q=private-phone');const text=JSON.stringify(f.logs);assert.ok(!text.includes('private-customer'));assert.ok(!text.includes('private-phone'));assert.equal(f.logs[0].route,'/api/ops/customers/:id');
});
test('map images are allowed only on the operations document without expanding script or connection origins',async t=>{
 const f=await fixture(t);const admin=await fetch(f.base+'/admin.html'),shop=await fetch(f.base+'/');
 assert.match(admin.headers.get('content-security-policy'),/img-src 'self' data: https:\/\/tile.openstreetmap.org;/);
 assert.match(admin.headers.get('content-security-policy'),/connect-src 'self';/);assert.match(admin.headers.get('content-security-policy'),/script-src 'self';/);
 assert.ok(!shop.headers.get('content-security-policy').includes('tile.openstreetmap.org'));assert.equal(admin.headers.get('referrer-policy'),'same-origin');
});
test('disposal history and lot disposal routes use the trusted operations Edge',async t=>{
 const f=await fixture(t);for(const [path,method]of [['/api/ops/disposals','GET'],['/api/ops/lots/fixture-lot/disposal','GET'],['/api/ops/lots/fixture-lot/disposal','POST']]){const r=await fetch(f.base+path,{method,...(method==='POST'?{headers:{'content-type':'application/json'},body:'{}'}:{})});assert.equal(r.status,200);assert.ok(f.calls.at(-1)[0].includes('/jana-ops-extra'+path))}
});

test('stock movement reads use the canonical operations Edge',async t=>{const f=await fixture(t);const r=await fetch(f.base+'/api/ops/movements?reason=waste');assert.equal(r.status,200);assert.ok(f.calls.at(-1)[0].includes('/jana-ops-extra/api/ops/movements?reason=waste'))});

test('customer return routes preserve operations requests while omitting document identifiers from logs',async t=>{
 const f=await fixture(t);
 for(const [path,method]of [
  ['/api/ops/customer-returns?before_at=1789050000000&before_id=private-cursor','GET'],
  ['/api/ops/customer-returns/context?number=private-order','GET'],
  ['/api/ops/customer-returns','POST'],
  ['/api/ops/customer-returns/private-return/dispositions?before_at=1&before_id=private-cursor','GET'],
  ['/api/ops/customer-returns/private-return/dispositions','POST'],
  ['/api/ops/customer-returns/private-return/inspection','POST']
 ]){
  const body=JSON.stringify({reference:'private-document'});
  const response=await fetch(f.base+path,{method,...(method==='POST'?{headers:{'content-type':'application/json','idempotency-key':'return-fixture-key'},body}:{})});
  assert.equal(response.status,200);
  const [url,init]=f.calls.at(-1);
  assert.equal(url,config({}).supabase+'/functions/v1/jana-ops-extra'+path);
  if(method==='POST'){assert.equal(init.body.toString(),body);assert.equal(init.headers['idempotency-key'],'return-fixture-key')}
 }
 assert.ok(!JSON.stringify(f.logs).includes('private-'));
 assert.equal(f.logs.at(-1).route,'/api/ops/customer-returns/:id/inspection');
});
