export class ApiError extends Error {
 constructor(message,code,status=0){super(message);this.name='ApiError';this.code=code;this.status=status}
}
// SecureStore holds retry metadata because it includes account and order identifiers.
// No password or authentication request is persisted in this journal.
export function createApiClient({base,storage,fetchImpl=fetch,timeoutMs=20000,newKey=()=>`${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`}={}){
 if(base!=='https://jana-fresh-app.onrender.com')throw Error('Invalid JANA API origin');
 let queue=Promise.resolve();const pending=new Map();
 const serialized=fn=>{const next=queue.then(fn,fn);queue=next.catch(()=>{});return next};
 const journalKey='jana.mobile.retry.v1';
 const critical=(method,path)=>(method==='PUT'&&path==='/api/cart')||method==='POST'&&(path==='/api/quotes'||path==='/api/orders'||path==='/api/shopping-lists'||path==='/api/recurring'||/\/refunds$/.test(path)||/\/procurement-shortage-decision$/.test(path)||/\/shortage-adjustment$/.test(path)||/^\/api\/substitutions\/[^/]+\/decision$/.test(path));
 async function journal(token,signature,clear=false){return serialized(async()=>{
  const raw=await storage.getItemAsync(journalKey);let data=raw?JSON.parse(raw):{token,entries:{}};
  // A response may arrive after logout or after another account started work.
  // Clearing that old request must not resurrect or replace a newer journal.
  if(clear&&(!raw||data.token!==token))return;
  if(data.token!==token)data={token,entries:{}};
  if(clear)delete data.entries[signature];
  else if(!data.entries[signature]){
   if(Object.keys(data.entries).length>=30)throw new ApiError('راجع الطلبات المعلقة قبل إنشاء طلب آخر','PENDING_LIMIT');
   data.entries[signature]=newKey();
  }
  await storage.setItemAsync(journalKey,JSON.stringify(data));return data.entries[signature];
 })}
 return async function request(path,{method='GET',body,token}={}){
  if(!path.startsWith('/api/')||path.includes('://'))throw Error('Invalid API path');
  const mut=!['GET','HEAD'].includes(method),signature=method+' '+path+' '+JSON.stringify(body||{}),scope=(token||'anonymous')+' '+signature;
  const durable=critical(method,path)&&!!token;
  let key=mut?(durable?await journal(token,signature):pending.get(scope)||newKey()):null;
  if(mut)pending.set(scope,key);
  const clear=async()=>{pending.delete(scope);if(durable)await journal(token,signature,true)};
  const headers={accept:'application/json'};
  if(body!==undefined)headers['content-type']='application/json';if(token)headers.authorization=`Bearer ${token}`;if(key)headers['idempotency-key']=key;
  for(let attempt=0;attempt<(mut?1:2);attempt++){
   const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeoutMs);
   try{
    let r;
    try{r=await fetchImpl(base+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body),signal:controller.signal})}
    catch{if(!mut&&attempt===0)continue;throw new ApiError('تعذر الاتصال. لم تُؤكد العملية؛ أعد المحاولة بأمان.','NETWORK_UNKNOWN')}
    let data;try{data=await r.json()}catch{throw new ApiError('رد غير متوقع. لم يتم تأكيد نجاح العملية.','INVALID_RESPONSE',r.status)}
    if(!r.ok){
     if(!mut&&r.status>=500&&attempt===0)continue;
     if(mut&&r.status<500)await clear();
     throw new ApiError(data?.error?.message||'تعذر إكمال العملية',data?.error?.code||'API_ERROR',r.status);
    }
    if(mut)await clear();return data;
   }finally{clearTimeout(timer)}
  }
 };
}
export async function restoreSession({storage,key,request}){
 const token=await storage.getItemAsync(key);if(!token)return{token:null,user:null};
 try{return{token,user:(await request('/api/auth/me',{token})).user}}
 catch(e){if(e.status===401){await storage.deleteItemAsync(key);return{token:null,user:null}}throw e}
}
