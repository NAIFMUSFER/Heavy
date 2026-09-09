export const esc = (s='') => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const id = () => globalThis.crypto.randomUUID ? crypto.randomUUID() : [...crypto.getRandomValues(new Uint8Array(24))].map(x => x.toString(16).padStart(2,'0')).join('');
export const $ = (s, root=document) => root.querySelector(s);
export const $$ = (s, root=document) => [...root.querySelectorAll(s)];
export const number = value => new Intl.NumberFormat('ar-SA-u-nu-latn').format(value);
export const money = value => { if (!Number.isSafeInteger(value)) return 'غير مسجل'; const v=Math.abs(value); return `${value<0?'-':''}${number(Math.floor(v/100))}.${String(v%100).padStart(2,'0')} ر.س`; };
export const parseMoney = text => { const v=String(text).trim(); if(!/^\d+(\.\d{1,2})?$/.test(v)) throw new Error('أدخل مبلغًا صحيحًا بحد أقصى منزلتين عشريتين'); const [a,b='']=v.split('.'); const n=Number(a)*100+Number(b.padEnd(2,'0')); if(!Number.isSafeInteger(n)) throw new Error('المبلغ أكبر من المسموح'); return n; };
export const moneyInput = value => `${Math.floor(value/100)}.${String(value%100).padStart(2,'0')}`;
export const date = (stamp, time=true) => new Intl.DateTimeFormat('ar-SA-u-ca-gregory-nu-latn', {timeZone:'Asia/Riyadh',calendar:'gregory',month:'short',day:'numeric', ...(time?{hour:'2-digit',minute:'2-digit'}:{})}).format(new Date(stamp*1000));
export const qty = c => c.base_unit==='piece' ? `${number(c.base_qty)} قطعة` : c.base_qty%1000===0 ? `${number(c.base_qty/1000)} كجم` : `${number(c.base_qty)} جرام`;
export const statusNames = {active:'نشط',completed:'مكتمل',cancelled:'ملغى',queued:'بانتظار التجهيز',picking:'قيد التجهيز',awaiting_customer:'بانتظار موافقتك',ready:'جاهز',unassigned:'لم يُسند',assigned:'أُسند للمندوب',out_for_delivery:'في الطريق',delivered:'تم التسليم',failed:'تعذر التنفيذ',awaiting_collection:'الدفع عند الاستلام',collected:'تم تسجيل التحصيل',partially_refunded:'استرداد جزئي',refunded:'تم الاسترداد',uncollected:'لم يُحصّل',held_by_courier:'عهدة لدى المندوب',settled:'العهدة مسواة',pending:'بانتظار المعالجة',accepted:'مقبول',rejected:'مرفوض',processing:'قيد التنفيذ',requested:'مطلوب',expired:'انتهت المهلة',open:'مفتوحة',closed:'مغلقة',paused:'متوقفة',approved:'معتمد'};
export const badge = state => `<span class="badge ${['completed','delivered','ready','accepted','settled'].includes(state)?'success':['failed','cancelled','rejected','expired'].includes(state)?'danger':'neutral'}">${esc(statusNames[state]||state)}</span>`;
export const roleNames = {customer:'عميل',admin:'الإدارة',picker:'التجهيز',courier:'التوصيل',inventory:'المخزون',finance:'المالية',support:'الدعم'};
export const icon = name => ({bag:'🛍',leaf:'✦',arrow:'←',plus:'＋',minus:'−',close:'×',search:'⌕',pin:'⌖',check:'✓',box:'▦',clock:'◷',user:'◉',menu:'☰',truck:'🚚',bell:'♧'}[name]||name);
export const empty = (title, description, action='') => `<section class="empty-state"><div class="empty-symbol">✧</div><h3>${esc(title)}</h3><p>${esc(description)}</p>${action}</section>`;
let lastFocus;
export function modal(title, content, className='') {
  lastFocus=document.activeElement;
  let dialog=$('#app-dialog'); if(!dialog){dialog=document.createElement('dialog');dialog.id='app-dialog';document.body.append(dialog);}
  if(dialog.open) dialog.close();
  dialog.className=`modal ${className}`;
  dialog.innerHTML=`<header class="modal-head"><div><span class="eyebrow">جَنى / ${esc(title)}</span><h2>${esc(title)}</h2></div><button type="button" class="icon-btn" data-close aria-label="إغلاق">×</button></header><div class="modal-body">${content}</div>`;
  dialog.showModal();
  dialog.querySelector('[data-close]').onclick=()=>dialog.close();
  dialog.onclose=()=>{if(lastFocus?.isConnected) lastFocus.focus();};
  dialog.addEventListener('click', e=>{if(e.target===dialog && e.clientX===0 && e.clientY===0) return;}, {once:true});
  return dialog;
}
export function closeModal(){ $('#app-dialog')?.close(); }
export function toast(message, bad=false) {
  let box=$('#toast'); if(!box){box=document.createElement('div');box.id='toast';box.setAttribute('role','status');box.setAttribute('aria-live','polite');document.body.append(box);}
  box.className=bad?'toast error':'toast';box.textContent=message;box.hidden=false;
  clearTimeout(box.timer);box.timer=setTimeout(()=>box.hidden=true,6500);
}
export async function busy(element, fn) { if(element?.disabled)return; const original=element?.innerHTML; if(element){element.disabled=true;element.innerHTML='جارٍ التنفيذ…';} try {return await fn();} catch(e){toast(e.message||'تعذر إكمال العملية',true); if(e.code==='AUTH_REQUIRED') window.dispatchEvent(new Event('auth-required')); throw e;} finally {if(element?.isConnected){element.disabled=false;element.innerHTML=original;}} }
export function formData(form){return Object.fromEntries(new FormData(form));}
const pending = new Map();
const csrf = () => document.cookie.split('; ').find(x=>x.startsWith('jana_csrf='))?.split('=')[1] || '';
export class ApiError extends Error { constructor(message,code,status,details){super(message);this.code=code;this.status=status;this.details=details;} }
export async function request(path, {method='GET',body,key}={}) {
  const signature=method+' '+path+' '+JSON.stringify(body||{});
  const mutate=!['GET','HEAD'].includes(method);
  let storageKey=null;
  if(mutate && globalThis.crypto?.subtle){
    const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(csrf()+'|'+signature));
    storageKey='jana.idem.'+[...new Uint8Array(hash)].map(x=>x.toString(16).padStart(2,'0')).join('');
  }
  const stored=()=>{try{return storageKey?sessionStorage.getItem(storageKey):null;}catch{return null;}};
  let idemKey=key || (mutate ? pending.get(signature) || stored() || id() : null);
  if(storageKey){try{sessionStorage.setItem(storageKey,idemKey);}catch{}}
  const clearPending=()=>{pending.delete(signature);try{if(storageKey)sessionStorage.removeItem(storageKey);}catch{}};
  if(mutate) pending.set(signature,idemKey);
  const headers={};if(body!==undefined)headers['Content-Type']='application/json';
  if(mutate){headers['X-CSRF-Token']=decodeURIComponent(csrf());headers['Idempotency-Key']=idemKey;}
  let response;
  try { response=await fetch(path,{method,body:body===undefined?undefined:JSON.stringify(body),headers,credentials:'same-origin',cache:'no-store'}); }
  catch {throw new ApiError('انقطع الاتصال. لم نتأكد من النتيجة؛ ستستخدم إعادة المحاولة المفتاح نفسه لمنع التكرار.','NETWORK_UNKNOWN',0,{idempotency_key:idemKey});}
  let data;try{data=await response.json();}catch{throw new ApiError('وصل رد غير متوقع. لم يتم تأكيد نجاح العملية.','INVALID_RESPONSE',response.status);}
  if(!response.ok){if(response.status<500)clearPending();throw new ApiError(data.error?.message||'تعذر إكمال الطلب',data.error?.code,response.status,data.error?.details);}
  clearPending();return data;
}
export const get=path=>request(path);
export const post=(path,body={},key)=>request(path,{method:'POST',body,key});
export const patch=(path,body,key)=>request(path,{method:'PATCH',body,key});
export const remove=(path,key)=>request(path,{method:'DELETE',key});
export async function getAll(path){const all=[];let offset=0;for(let i=0;i<100;i++){const r=await get(`${path}${path.includes('?')?'&':'?'}limit=100&offset=${offset}`);all.push(...r.items);if(r.next_offset==null)return all;offset=r.next_offset;}throw new Error('القائمة كبيرة. استخدم التصفح المقسم بدل تحميل جميع السجلات.');}
export async function identity(){try{return (await get('/api/auth/me')).user;}catch(e){if(e.status===401)return null;throw e;}}
export function loginDialog(onSuccess, startRegister=false){
  const draw = signup => {
    const d=modal(signup?'حساب جديد':'أهلًا بعودتك',`<p class="muted">${signup?'ابدأ بسلة تناسب يومك.':'أدخل بيانات حسابك للمتابعة.'}</p><form id="auth-form" class="stack">${signup?'<label>الاسم<input name="name" required minlength="2" maxlength="100" autocomplete="name"></label>':''}<label>البريد الإلكتروني<input name="email" type="email" required autocomplete="email" dir="ltr"></label><label>كلمة المرور<input name="password" type="password" required ${signup?'minlength="12"':''} maxlength="128" autocomplete="${signup?'new-password':'current-password'}" dir="ltr"></label>${signup?'<small class="muted">12 حرفًا على الأقل. لا تستخدم كلمة مرور حساب آخر.</small>':''}<p id="auth-error" class="form-error" role="alert"></p><button class="btn primary" type="submit">${signup?'إنشاء الحساب':'تسجيل الدخول'}</button></form><button class="text-btn" id="auth-switch">${signup?'لديك حساب؟ سجّل الدخول':'جديد هنا؟ أنشئ حسابًا'}</button>`,'small-modal');
    $('#auth-switch',d).onclick=()=>draw(!signup);
    $('#auth-form',d).onsubmit=async e=>{e.preventDefault(); const f=e.target,button=$('button[type=submit]',f),data=formData(f);try{await busy(button,async()=>{if(signup)await post('/api/auth/register',data);const r=await post('/api/auth/login',{email:data.email,password:data.password,mode:'web'});closeModal();await onSuccess(r.user);});}catch(err){const out=$('#auth-error',d);if(out)out.textContent=err.message;}};
  };draw(startRegister);
}
export function setupConnectivity(){
  const refresh=()=>{document.documentElement.classList.toggle('is-offline',!navigator.onLine);let banner=$('#offline-banner');if(!banner){banner=document.createElement('div');banner.id='offline-banner';banner.className='offline-banner';banner.setAttribute('role','alert');document.body.prepend(banner);}banner.hidden=navigator.onLine;banner.textContent='أنت غير متصل. تبقى الصفحة المفتوحة فقط؛ تحديث الأسعار وتأكيد الطلب والتسليم يحتاجان اتصالًا.';};
  addEventListener('online',refresh);addEventListener('offline',refresh);refresh();
  if('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(()=>{});
}
export const field = (name,label,options={}) => `<label>${esc(label)}<input name="${esc(name)}" ${options.type?`type="${esc(options.type)}"`:''} ${options.value!==undefined?`value="${esc(options.value)}"`:''} ${options.required===false?'':'required'} ${options.placeholder?`placeholder="${esc(options.placeholder)}"`:''} ${options.min!==undefined?`min="${options.min}"`:''} ${options.step?`step="${options.step}"`:''} ${options.readonly?'readonly':''}></label>`;
export const selectField=(name,label,options,value='')=>`<label>${esc(label)}<select name="${esc(name)}" required>${options.map(([v,t])=>`<option value="${esc(v)}" ${String(v)===String(value)?'selected':''}>${esc(t)}</option>`).join('')}</select></label>`;
export function downloadJSON(name,data){const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);}
