const assert=require('node:assert/strict');
const base=process.env.JANA_SMOKE_BASE||'https://jana-fresh-app.onrender.com';
if(new URL(base).origin!=='https://jana-fresh-app.onrender.com')throw Error('Smoke target must be the verified JANA service');
const expected=process.env.JANA_EXPECTED_COMMIT;
async function get(p,options={}){return fetch(base+p,{...options,redirect:'error',signal:AbortSignal.timeout(20000)})}
async function smoke(){
 const v=await get('/version');assert.equal(v.status,200);const version=await v.json();if(expected)assert.equal(version.commit,expected,'deployed commit');
 for(const p of ['/health','/ready']){const r=await get(p);assert.equal(r.status,200,p);assert.equal((await r.json()).ok,true,p)}
 for(const p of ['/','/admin.html','/picker.html','/courier.html','/assets/shop.js','/assets/ops.js','/assets/common.js','/assets/styles.css','/sw.js']){const r=await get(p);assert.equal(r.status,200,p);assert.ok((await r.text()).length>100,p);assert.ok(r.headers.get('content-security-policy'),p)}
 const catalog=await get('/api/catalog?limit=2');assert.equal(catalog.status,200);assert.ok(Array.isArray((await catalog.json()).items));
 const unauth=await get('/api/auth/me');assert.equal(unauth.status,401);
 const login=await get('/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:'smoke-invalid@example.invalid',password:null})});assert.ok([401,429].includes(login.status),'invalid login must be rejected or rate limited');const loginBody=await login.json();assert.ok(['INVALID_LOGIN','RATE_LIMIT'].includes(loginBody.error?.code),'expected authentication error contract');const cookieNames=login.headers.getSetCookie().map(x=>x.split('=')[0]);assert.equal(cookieNames.filter(x=>/^jana_(session|csrf)$/.test(x)).length,0,'failed login must not issue JANA authentication cookies');
 for(const p of ['/server.js','/mobile/App.js','/supabase/functions/jana-api/index.ts'])assert.equal((await get(p)).status,404,p);
 console.log(JSON.stringify({ok:true,commit:version.commit,checks:18,base}));
}
async function waitForDeployment(){
 let failure;
 for(let attempt=0;attempt<36;attempt++){
  try{const r=await get('/version');assert.equal(r.status,200);const v=await r.json();if(expected)assert.equal(v.commit,expected,'deployed commit');return}
  catch(e){failure=e;console.error('Waiting for deployment '+(attempt+1));if(attempt<35)await new Promise(r=>setTimeout(r,10000))}
 }
 throw failure;
}
// Only deployment readiness is polled. Never repeatedly submit login during rollout.
waitForDeployment().then(smoke).catch(e=>{console.error(e);process.exitCode=1});
