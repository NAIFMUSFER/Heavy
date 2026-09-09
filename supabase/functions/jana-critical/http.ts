// Shared transport controls. Business authorization remains inside PostgreSQL RPCs.
const MAX_BODY_BYTES = 65536;
const ORIGINS = new Set(['https://jana-fresh-app.onrender.com','https://jana-fresh.netlify.app','http://localhost:8888','http://127.0.0.1:8888']);
export function safeCookies(req: Request): Record<string,string> {
 const out: Record<string,string> = {};
 for (const part of (req.headers.get('cookie') || '').split(';')) {
  const at=part.indexOf('='); if(at<1) continue;
  const key=part.slice(0,at).trim();
  if(key!=='jana_session' && key!=='jana_csrf') continue;
  if(Object.prototype.hasOwnProperty.call(out,key)) throw Object.assign(new Error('invalid_cookie'),{status:400});
  try { out[key]=decodeURIComponent(part.slice(at+1).trim()); }
  catch { throw Object.assign(new Error('invalid_cookie'),{status:400}); }
 }
 return out;
}
export function rpcBusinessResult(data:any) {
 if(data && typeof data._error==='string') throw Object.assign(new Error(data._error),{status:Number.isInteger(data.status)?data.status:409});
 return data;
}
export function requiredIdempotency(req:Request):string {
 const key=(req.headers.get('idempotency-key')||'').trim();
 if(key.length<8 || key.length>128) throw Object.assign(new Error('invalid_idempotency_key'),{status:422});
 return key;
}
export function guard(handler:(req:Request)=>Promise<Response>) {
 return async (req:Request):Promise<Response> => {
  try {
   const origin=req.headers.get('origin');
   if(origin && !ORIGINS.has(origin)) return new Response(JSON.stringify({error:{code:'ORIGIN',message:'مصدر الطلب غير مسموح'}}),{status:403,headers:{'content-type':'application/json','cache-control':'no-store'}});
   if(req.method==='OPTIONS') return new Response(null,{status:204,headers:origin?{'access-control-allow-origin':origin,'access-control-allow-credentials':'true','access-control-allow-headers':'content-type,authorization,x-csrf-token,idempotency-key','access-control-allow-methods':'GET,POST,PATCH,DELETE,OPTIONS','vary':'Origin'}:{}});
   const cookies=safeCookies(req);
   const mutates=!['GET','HEAD','OPTIONS'].includes(req.method);
   if(mutates && cookies.jana_session && !/^Bearer\s+\S+$/i.test(req.headers.get('authorization')||'')) {
    const csrf=req.headers.get('x-csrf-token');
    if(!csrf || !cookies.jana_csrf || csrf!==cookies.jana_csrf) throw Object.assign(new Error('csrf_required'),{status:403});
   }
   if(mutates && req.body) {
    if(!(req.headers.get('content-type')||'').toLowerCase().startsWith('application/json')) throw Object.assign(new Error('unsupported_media_type'),{status:415});
    const len=req.headers.get('content-length');
    if(len && (!/^\d+$/.test(len)||Number(len)>MAX_BODY_BYTES)) throw Object.assign(new Error('payload_too_large'),{status:413});
    const reader=req.body.getReader(); const chunks:Uint8Array[]=[]; let size=0;
    while(true) { const {done,value}=await reader.read(); if(done)break; size+=value.byteLength;
     if(size>MAX_BODY_BYTES){await reader.cancel();throw Object.assign(new Error('payload_too_large'),{status:413});} chunks.push(value); }
    const bytes=new Uint8Array(size); let offset=0; for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
    req=new Request(req,{body:bytes});
   }
   const response=await handler(req);
   if(origin){response.headers.set('access-control-allow-origin',origin);response.headers.set('access-control-allow-credentials','true');response.headers.set('vary','Origin');}
   return response;
  } catch(e:any) {
   const status=[400,403,413,415,422].includes(e?.status)?e.status:500;
   const codes:Record<number,string>={400:'INVALID_COOKIE',403:'CSRF',413:'PAYLOAD_TOO_LARGE',415:'UNSUPPORTED_MEDIA_TYPE',422:'VALIDATION',500:'INTERNAL'};
   return new Response(JSON.stringify({error:{code:codes[status],message:status===403?'أعد تحميل الصفحة ثم حاول مجددًا':'تعذر قبول الطلب بأمان'}}),{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff'}});
  }
 };
}
