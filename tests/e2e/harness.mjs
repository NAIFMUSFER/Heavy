import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {AsyncLocalStorage} from 'node:async_hooks';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
export async function startHarness(){
 assert.equal(process.env.JANA_TEST_DATABASE,'disposable');assert.equal(process.env.PGHOST,'127.0.0.1');assert.equal(process.env.PGDATABASE,'jana_test');
 const nativeFetch=globalThis.fetch,project='https://jjdsajiwoqanefmnikls.supabase.co';
 const b64=v=>Buffer.from(JSON.stringify(v)).toString('base64url');const payload=b64({alg:'HS256',typ:'JWT'})+'.'+b64({role:'service_role',exp:Math.floor(Date.now()/1000)+900});const serviceJWT=payload+'.'+crypto.createHmac('sha256','jana-disposable-browser-test-secret-32-characters-only').update(payload).digest('base64url');
 const handlers={};let capture;
 globalThis.Deno={env:{get:k=>({SUPABASE_URL:project,SUPABASE_SERVICE_ROLE_KEY:serviceJWT}[k])},serve:h=>{capture=h}};
 const requestScope=new AsyncLocalStorage();
 globalThis.fetch=async(url,init)=>{const u=new URL(url);assert.equal(u.origin,project,'No external dependency is allowed in disposable browser tests');assert.ok(u.pathname.startsWith('/rest/v1/'),'Only actual database requests may cross this bridge');if(requestScope.getStore()?.legacyAdmission&&u.pathname==='/rest/v1/rpc/jana_supplier_pickup_quote_gateway')u.pathname='/rest/v1/rpc/jana_create_quote_idempotent';return nativeFetch('http://127.0.0.1:3001'+u.pathname.slice('/rest/v1'.length)+u.search,init)};
 for(const name of ['jana-api','jana-critical','jana-ops-extra']){await import('../../supabase/functions/'+name+'/index.ts');const handler=capture;handlers[name]=request=>requestScope.run({legacyAdmission:request.headers.get('x-jana-disposable-legacy-admission')==='true'},()=>handler(request))}
 const {createGateway,config}=require('../../server.js');const failures=[],control={edgeDelayMs:0};
 const server=createGateway({settings:{...config({}),commit:'disposable-e2e',development:false},fetchImpl:async(url,init)=>{const u=new URL(url);assert.equal(u.origin,project);const name=u.pathname.split('/')[3];assert.ok(handlers[name],'Only canonical Edge handlers are allowed');if(control.edgeDelayMs)await new Promise(resolve=>setTimeout(resolve,control.edgeDelayMs));return handlers[name](new Request(url,init))},log:r=>{if(r.status>=500)failures.push(r)}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const base='http://127.0.0.1:'+server.address().port;
 return{base,fetchLocal:(pathname,init)=>{const url=new URL(pathname,base);assert.equal(url.origin,base);return nativeFetch(url,init)},failures,setEdgeDelay:milliseconds=>{assert.ok(Number.isInteger(milliseconds)&&milliseconds>=0&&milliseconds<=2000);control.edgeDelayMs=milliseconds},close:async()=>{await new Promise(resolve=>{server.close(resolve);server.closeAllConnections()});globalThis.fetch=nativeFetch}};
}
export async function attachBrowser(context,base,control={}){
 // Every browser request is fulfilled by the real local gateway/Edge/PostgreSQL.
 // Retain the canonical browser origin to exercise Secure cookies, CSRF and CSP.
 // There is no route.continue fallback, so this cannot reach production.
 await context.route('**/*',async route=>{const u=new URL(route.request().url());if(u.origin!=='https://jana-fresh-app.onrender.com')return route.abort('blockedbyclient');const headers=control.legacyAdmission?{...route.request().headers(),'x-jana-disposable-legacy-admission':'true'}:undefined;const response=await route.fetch({url:base+u.pathname+u.search,headers,maxRedirects:0,timeout:20000});const decision=await control.beforeResponse?.(u,response,route.request());if(decision==='disconnect')return route.abort('connectionreset');await route.fulfill({response})});
}
