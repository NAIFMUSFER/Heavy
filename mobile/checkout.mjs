// Only a small, account-scoped reference is persisted. Prices, addresses and
// order outcomes are always reloaded from the authenticated server.
export const CHECKOUT_KEY='jana.checkout.v1';
export function quoteState(q,elapsed=0){
 if(!q)return 'unknown';
 if(q.order?.id)return 'ordered';
 if(q.state!=='active')return q.state||'unknown';
 const server=Number(q.server_now??q.created_at),expires=Number(q.expires_at);
 if(!Number.isSafeInteger(server)||!Number.isSafeInteger(expires)||server<=0)return 'unknown';
 return expires<=server+Math.max(0,elapsed)?'expired':'active';
}
export function quoteRemaining(q,elapsed=0){return quoteState(q,elapsed)==='active'?Math.max(0,Math.ceil((q.expires_at-(q.server_now??q.created_at)-Math.max(0,elapsed))/1000)):0}
export function cartMatchesQuote(cart,q){
 const normalize=(rows,quantity)=>Array.isArray(rows)?rows.map(x=>[x.offering_id,Number(x[quantity])]).sort((a,b)=>String(a[0]).localeCompare(String(b[0]))):[];
 const a=normalize(cart,'quantity'),b=normalize(q?.lines,'qty');
 return a.length>0&&a.length===b.length&&a.every((x,i)=>x[0]===b[i][0]&&Number.isSafeInteger(x[1])&&x[1]>0&&x[1]===b[i][1]);
}
export function createCheckoutSession({storage,call,getSession,onChange=()=>{},now=()=>performance.now()}){
 let generation=0,storageQueue=Promise.resolve();
 let state={pending:null,quote:null,busy:false,error:'',errorCode:'',observedAt:0};
 const emit=patch=>{state={...state,...patch};onChange(state)};
 const scope=()=>{const s=getSession();if(!s?.owner||!s.token)throw Error('سجّل الدخول لمراجعة الطلب');return {...s,generation}};
 const current=s=>s.generation===generation&&s.owner===getSession()?.owner&&s.token===getSession()?.token;
 const write=(s,fn)=>{const next=storageQueue.then(()=>current(s)?fn():undefined);storageQueue=next.catch(()=>{});return next};
 const parse=(raw,s)=>{
  if(!raw)return null;let value;try{value=JSON.parse(raw)}catch{throw Error('تعذر قراءة مراجعة الطلب المحفوظة. راجع طلباتك قبل بدء شراء جديد.');}
  if(!value||typeof value!=='object'||typeof value.owner!=='string')throw Error('تعذر قراءة مراجعة الطلب المحفوظة. راجع طلباتك قبل بدء شراء جديد.');
  if(value.owner!==s.owner)return null;
  if(typeof value.quote_id!=='string'||!value.quote_id||value.quote_id.length>160)throw Error('تعذر قراءة مرجع الطلب المحفوظ. راجع طلباتك قبل بدء شراء جديد.');
  return {owner:s.owner,quote_id:value.quote_id,attempted:value.attempted===true};
 };
 const remember=async(s,pending)=>{await write(s,()=>storage.setItem(CHECKOUT_KEY,JSON.stringify(pending)));if(current(s))emit({pending})};
 const observe=(s,q)=>{
  if(!current(s))return null;
  if(!q||q.id!==state.pending?.quote_id)throw Error('تعذر مطابقة عرض السعر المحفوظ');
  emit({quote:q,observedAt:now()});return q;
 };
 const read=async s=>observe(s,await call('/api/quotes/'+encodeURIComponent(state.pending.quote_id),{token:s.token}));
 async function run(fn){
  if(state.busy)return null;const s=scope();emit({busy:true,error:'',errorCode:''});
  try{return await fn(s)}catch(e){if(!current(s))return null;emit({error:e.message||'تعذر تحديث مراجعة الطلب',errorCode:e.code||''});throw e}
  finally{if(current(s))emit({busy:false})}
 }
 async function clear(s){await write(s,()=>storage.removeItem(CHECKOUT_KEY));if(current(s))emit({pending:null,quote:null,error:''})}
 return {
  get snapshot(){return state},
  elapsed:()=>Math.max(0,now()-state.observedAt),
  reset(){generation++;emit({pending:null,quote:null,busy:false,error:'',errorCode:'',observedAt:0})},
  async forget(){this.reset();const g=generation;await storageQueue;if(g===generation)await storage.removeItem(CHECKOUT_KEY)},
  load(){this.reset();return run(async s=>{const pending=parse(await storage.getItem(CHECKOUT_KEY),s);if(current(s))emit({pending});return current(s)?pending:null})},
  create(body){return run(async s=>{
   const saved=parse(await storage.getItem(CHECKOUT_KEY),s);if(!current(s))return null;
   if(saved||state.pending){if(saved)emit({pending:saved});throw Error('أكمل مراجعة الحجز السابق أو ألغِ حجزه قبل إنشاء عرض آخر');}
   const q=await call('/api/quotes',{method:'POST',token:s.token,body});if(!current(s))return null;
   if(!q?.id)throw Error('تعذر قراءة عرض السعر. أعد المحاولة بنفس الاختيارات.');
   // Keep the reference in memory on a storage error; confirmation must first
   // persist it successfully, so an order cannot outlive its recovery reference.
   emit({pending:{owner:s.owner,quote_id:q.id,attempted:false}});observe(s,q);
   await remember(s,state.pending);return current(s)?read(s):null;
  })},
  refresh(){return run(async s=>state.pending?read(s):null)},
  confirm(policyVersion){return run(async s=>{
   const q=state.quote;
   if(quoteState(q,this.elapsed())!=='active')throw Error('حدّث حالة الحجز قبل تأكيد الطلب');
   if(!q.store_profile?.id||policyVersion!==q.store_profile.id)throw Error('راجع شروط البيع الخاصة بهذا العرض أولًا');
   await remember(s,{...state.pending,attempted:true});if(!current(s))return null;
   const order=await call('/api/orders',{method:'POST',token:s.token,body:{quote_id:q.id}});if(!current(s))return null;
   if(!order?.id)throw Error('تعذر التأكد من نتيجة الطلب. حدّث حالة الحجز.');
   observe(s,{...q,state:'converted',order});return order;
  })},
  cancel(){return run(async s=>{
   if(!state.pending)return null;
   await call('/api/quotes/'+encodeURIComponent(state.pending.quote_id),{method:'DELETE',token:s.token});if(!current(s))return null;
   // Confirmation can win the race against cancellation. Read its outcome;
   // never interpret a converted quote as a cancelled order.
   const q=await read(s);if(!current(s))return null;
   if(q.order?.id)return q;
   if(!['cancelled','expired'].includes(quoteState(q,this.elapsed())))throw Error('لم يتأكد إلغاء الحجز. حدّث حالته.');
   await clear(s);return null;
  })},
  acknowledge(beforeClear=()=>{}){return run(async s=>{if(!state.quote?.order?.id)throw Error('تحقق من الطلب المسجل أولًا');const order=state.quote.order;await beforeClear(state.quote);if(!current(s))return null;await clear(s);return current(s)?order:null})}
 };
}
