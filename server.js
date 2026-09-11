'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const JANA_SUPABASE = 'https://jjdsajiwoqanefmnikls.supabase.co';
const MAX_BODY = 65536, MAX_RESPONSE = 4 * 1024 * 1024;
const PUBLIC_FILES = ['index.html','admin.html','picker.html','courier.html','offline.html','manifest.webmanifest','sw.js','assets/icon.svg','assets/common.js','assets/zone-map.js','assets/address.js','assets/order.js','assets/checkout.js','assets/local-cart.js','assets/input.js'];
const BUNDLES = {'/assets/shop.js':['shop',5,'.js'],'/assets/ops.js':['ops',4,'.js'],'/assets/styles.css':['styles',2,'.css']};
const TYPES = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.webmanifest':'application/manifest+json'};
const OPS = /^\/api\/ops\/(customer-returns|customer-returns\/context|customer-returns\/[^/]+\/(inspection|dispositions)|notification-jobs|movements|disposals|supplier-credits|disposals\/[^/]+\/supplier-credits|lots\/[^/]+\/disposal|counts|counts\/[^/]+\/(submit|cancel)|count-lines\/[^/]+\/decision|stock\/[^/]+|suppliers\/[^/]+|zones\/[^/]+|slots\/[^/]+|catalog|finance|refunds\/[^/]+\/(complete|reject)|products|product-versions\/[^/]+\/activate|suppliers|coupons|slots|stock|lots|zones|lots\/[^/]+\/(inspect|adjust)|families\/[^/]+\/versions|offerings\/[^/]+\/active|coupons\/[^/]+\/active|slots\/[^/]+\/active|orders\/[^/]+\/(collect|settle|refunds))$/;
function config(env=process.env) {
  const supabase=(env.JANA_SUPABASE_URL||JANA_SUPABASE).replace(/\/$/,'');
  if(supabase!==JANA_SUPABASE) throw Error('JANA_SUPABASE_URL must identify the dedicated JANA project');
  const origin=env.JANA_PUBLIC_ORIGIN||'https://jana-fresh-app.onrender.com', u=new URL(origin);
  if(u.origin!==origin||u.username||u.password||u.protocol!=='https:') throw Error('Invalid JANA_PUBLIC_ORIGIN');
  const phHost=(env.JANA_POSTHOG_HOST||'https://us.i.posthog.com').replace(/\/$/,'');
  if(!['https://us.i.posthog.com','https://eu.i.posthog.com'].includes(phHost)) throw Error('Invalid JANA_POSTHOG_HOST');
  return {supabase,origin,phHost,phKey:/^\d+$/.test(env.JANA_POSTHOG_PROJECT_ID||'')?(env.JANA_POSTHOG_PROJECT_KEY||''):'',commit:env.RENDER_GIT_COMMIT||env.JANA_COMMIT||'local',timeout:15000,development:env.NODE_ENV!=='production'&&!env.RENDER};
}
function error(status,code){return Object.assign(Error(code),{status,code})}
function headers(res,id){
  for(const [k,v] of Object.entries({'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-request-id':id,'x-content-type-options':'nosniff','referrer-policy':'same-origin','x-frame-options':'DENY','permissions-policy':'camera=(), microphone=(), geolocation=(self)','content-security-policy':"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",'strict-transport-security':'max-age=31536000'}))res.setHeader(k,v);
}
function json(res,status,data){res.statusCode=status;res.end(JSON.stringify(data))}
function readBody(req){
  if(['GET','HEAD'].includes(req.method))return Promise.resolve(undefined);
  if(Number(req.headers['content-length']||0)>MAX_BODY)throw error(413,'PAYLOAD_TOO_LARGE');
  return new Promise((resolve,reject)=>{
    const chunks=[];let size=0,exceeded=false;
    req.on('data',chunk=>{size+=chunk.length;if(size>MAX_BODY){if(!exceeded)reject(error(413,'PAYLOAD_TOO_LARGE'));exceeded=true;return}if(!exceeded)chunks.push(chunk)});
    req.on('end',()=>{if(exceeded)return;if(size&&!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']||''))return reject(error(415,'UNSUPPORTED_MEDIA_TYPE'));resolve(size?Buffer.concat(chunks):undefined)});
    req.on('aborted',()=>reject(error(400,'REQUEST_ABORTED')));req.on('error',reject);
  });
}
async function boundedResponse(r){
  if(Number(r.headers.get('content-length'))>MAX_RESPONSE){await r.body?.cancel();throw error(502,'UPSTREAM_RESPONSE_TOO_LARGE')}
  if(!r.body)return Buffer.alloc(0);
  const reader=r.body.getReader(),chunks=[];let size=0;
  while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>MAX_RESPONSE){await reader.cancel();throw error(502,'UPSTREAM_RESPONSE_TOO_LARGE')}chunks.push(value)}
  return Buffer.concat(chunks);
}
function eventName(method,p,status){
  if(status>=500)return'jana_api_error';if(status>=400)return p==='/api/quotes'?'jana_quote_failed':'jana_api_rejected';
  if(method==='POST'&&p==='/api/quotes')return'jana_quote_created';if(method==='POST'&&p==='/api/orders')return'jana_order_created';
  if(method==='POST'&&/\/refunds$/.test(p))return'jana_refund_requested';if(method==='POST'&&/^\/api\/tickets/.test(p))return'jana_support_activity';
  if(method==='POST'&&/^\/api\/substitutions\/.+\/decision$/.test(p))return'jana_substitution_decided';
  if(!['GET','HEAD'].includes(method)&&/^\/api\/ops\//.test(p))return'jana_ops_change';return'jana_api_request';
}
function routeLabel(p){return p.replace(/^(\/api\/ops\/customer-returns)\/[^/]+\/(inspection|dispositions)$/,'$1/:id/$2').replace(/(\/orders|\/quotes|\/addresses|\/coverage|\/tickets|\/substitutions|\/notifications|\/lots|\/families|\/offerings|\/coupons|\/slots|\/zones|\/favorites|\/refunds|\/product-versions|\/support|\/customers|\/staff|\/stock|\/suppliers|\/counts|\/count-lines|\/disposals|\/shopping-lists|\/recurring)\/[^/]+/g,'$1/:id')}
function createGateway({settings=config(),fetchImpl=fetch,log=entry=>console.log(JSON.stringify(entry)),root=__dirname}={}){
  const salt=crypto.randomBytes(32),statics=new Map();let active=0;
  for(const file of PUBLIC_FILES)statics.set('/'+file,fs.readFileSync(path.join(root,file)));
  for(const [url,[prefix,count,ext]] of Object.entries(BUNDLES))statics.set(url,Buffer.concat(Array.from({length:count},(_,i)=>fs.readFileSync(path.join(root,'assets',`${prefix}.part${String(i+1).padStart(2,'0')}${ext}`)))));
  const upstream=settings.supabase+'/functions/v1/';
  return http.createServer({maxHeaderSize:16384,requestTimeout:20000,headersTimeout:10000},async(req,res)=>{
    const requestId=crypto.randomUUID(),started=Date.now();let p='/invalid',api=false;headers(res,requestId);active++;
    res.on('finish',()=>{
      const entry={event:'jana_request',request_id:requestId,route:routeLabel(p),method:req.method,status:res.statusCode,duration_ms:Date.now()-started};log(entry);
      if(!api||!settings.phKey)return;
      const seed=req.headers.authorization||(req.headers.cookie||'').match(/(?:^|;\s*)jana_session=([^;]+)/)?.[1];
      const distinct=seed?crypto.createHmac('sha256',salt).update(seed).digest('hex').slice(0,24):'anonymous';
      fetchImpl(settings.phHost+'/capture/',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({api_key:settings.phKey,event:eventName(req.method,p,res.statusCode),properties:{distinct_id:'jana-'+distinct,path:entry.route,method:req.method,status:res.statusCode,duration_ms:entry.duration_ms,service:'jana-gateway',environment:'production',$process_person_profile:false}}),signal:AbortSignal.timeout(2500)}).catch(()=>log({event:'jana_analytics_unavailable'}));
    });
    try{
      if(active>100)throw error(503,'BUSY');
      if(!req.url.startsWith('/')||req.url.startsWith('//')||/[\\\x00-\x1f]/.test(req.url))throw error(400,'INVALID_PATH');
      const u=new URL(req.url,settings.origin);p=u.pathname;
      if(!['GET','HEAD','POST','PATCH','DELETE','OPTIONS'].includes(req.method)&&!(req.method==='PUT'&&p==='/api/cart'))throw error(405,'METHOD_NOT_ALLOWED');
      if(p==='/health'&&req.method==='GET')return json(res,200,{ok:true,service:'jana-gateway'});
      if(p==='/version'&&req.method==='GET')return json(res,200,{service:'jana-gateway',commit:settings.commit});
      if(p==='/ready'&&req.method==='GET'){
        const dependencies=await Promise.all(['jana-api','jana-critical','jana-ops-extra'].map(async name=>{const r=await fetchImpl(upstream+name+'/health',{signal:AbortSignal.timeout(settings.timeout),redirect:'error'});const b=JSON.parse((await boundedResponse(r)).toString());return{name,ok:r.ok&&b.ok===true}}));
        const ok=dependencies.every(x=>x.ok);return json(res,ok?200:503,{ok,service:'jana-gateway',dependencies});
      }
      if(p.startsWith('/api/')){
        api=true;const origin=req.headers.origin,local=settings.development&&/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin||'');
        if(origin&&origin!==settings.origin&&!local)throw error(403,'ORIGIN');
        if(!origin&&req.headers['sec-fetch-site']==='cross-site')throw error(403,'ORIGIN');
        if(req.method==='OPTIONS'){res.statusCode=204;return res.end()}
        if(/%2f|%5c|%00/i.test(p))throw error(400,'INVALID_PATH');
        const name=req.method==='POST'&&p==='/api/quotes'?'jana-critical':OPS.test(p)?'jana-ops-extra':'jana-api';
        const h={'x-request-id':requestId};for(const k of ['content-type','authorization','x-csrf-token','idempotency-key','cookie'])if(req.headers[k])h[k]=req.headers[k];
        const bytes=await readBody(req),r=await fetchImpl(upstream+name+p+u.search,{method:req.method,headers:h,body:bytes,redirect:'manual',signal:AbortSignal.timeout(settings.timeout)});
        if(r.status>=300&&r.status<400)throw error(502,'UNEXPECTED_UPSTREAM_REDIRECT');
        const out=await boundedResponse(r);if(!(r.headers.get('content-type')||'').includes('application/json'))throw error(502,'INVALID_UPSTREAM_RESPONSE');
        res.statusCode=r.status;const cookies=r.headers.getSetCookie().filter(x=>/^jana_(session|csrf)=/.test(x));if(cookies.length)res.setHeader('set-cookie',cookies);
        const retry=r.headers.get('retry-after');if(retry)res.setHeader('retry-after',retry);
        return res.end(req.method==='HEAD'?undefined:out);
      }
      if(!['GET','HEAD'].includes(req.method))throw error(405,'METHOD_NOT_ALLOWED');
      if(p==='/robots.txt'){res.setHeader('content-type','text/plain; charset=utf-8');return res.end('User-agent: *\nAllow: /\nDisallow: /api/\nDisallow: /admin.html\nDisallow: /picker.html\nDisallow: /courier.html\n')}
      if(p==='/'||p==='/index.html')res.setHeader('content-security-policy',res.getHeader('content-security-policy').replace("img-src 'self' data:;","img-src 'self' data: https:;"));
      if(p==='/admin.html')res.setHeader('content-security-policy',res.getHeader('content-security-policy').replace("img-src 'self' data:;","img-src 'self' data: https://tile.openstreetmap.org;"));
      if(p==='/')p='/index.html';const bytes=statics.get(p);if(!bytes)throw error(404,'NOT_FOUND');
      res.setHeader('content-type',TYPES[path.extname(p)]||'application/octet-stream');res.setHeader('cache-control',p==='/sw.js'?'no-cache':'no-cache, must-revalidate');res.setHeader('content-length',bytes.length);res.end(req.method==='HEAD'?undefined:bytes);
    }catch(e){
      const timedOut=e.name==='TimeoutError'||e.name==='AbortError',status=e.status||(p==='/ready'?503:timedOut?504:502);
      if(status===413){req.resume();res.setHeader('connection','close')}
      if(!res.headersSent)json(res,status,{error:{code:e.code&&e.status?e.code:timedOut?'UPSTREAM_TIMEOUT':'GATEWAY_ERROR',message:'تعذر إكمال الطلب عبر بوابة جَنى'}});else res.destroy();
    }finally{active--}
  });
}
if(require.main===module){
  const port=Number(process.env.PORT||10000);if(!Number.isInteger(port)||port<1||port>65535)throw Error('Invalid PORT');
  const server=createGateway();server.listen(port,'0.0.0.0',()=>console.log(JSON.stringify({event:'jana_gateway_started',port})));
  for(const signal of ['SIGTERM','SIGINT'])process.once(signal,()=>{server.close(()=>process.exit(0));setTimeout(()=>{server.closeAllConnections();process.exit(1)},20000).unref()});
}
module.exports={createGateway,config,eventName,routeLabel};
