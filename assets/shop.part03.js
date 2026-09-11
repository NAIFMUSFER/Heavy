function updateCheckoutBanner(){
 const box=$('#pending-checkout');if(!box)return;const pending=checkoutSession.snapshot.pending;
 box.hidden=!pending||!state.user;
 box.innerHTML=box.hidden?'':`<div class="panel row between"><span>لديك مراجعة طلب معلّقة. تحقق من نتيجتها قبل بدء طلب آخر.</span><button class="btn outline" data-resume-checkout ${checkoutSession.snapshot.busy?'disabled':''}>متابعة مراجعة الطلب</button></div>`;
 const button=$('[data-resume-checkout]',box);if(button)button.onclick=()=>resumeCheckout().catch(e=>toast(e.message,true));
}
async function createQuote(address_id,slot_id,coupon_code=''){
 try{const q=await checkoutSession.create({address_id,slot_id,coupon_code,lines:state.cart.map(x=>({offering_id:x.offering_id,quantity:x.quantity}))});if(q)await showCheckout()}
 catch(e){if(checkoutSession.snapshot.pending)await showCheckout();throw e}
}
async function resumeCheckout(){
 if(!state.user)return;
 try{await checkoutSession.refresh()}catch{/* The saved reference and error remain visible for retry. */}
 if(checkoutSession.snapshot.pending)await showCheckout();
}
async function finishCheckout(){
 const user=state.user;let cartKept=false;
 const order=await checkoutSession.acknowledge(q=>{if(q.order.status!=='cancelled'&&cartMatchesQuote(state.cart,q)){localStorage.setItem(cartKey,'[]');state.cart=[];save()}else cartKept=state.cart.length>0});
 if(!order||state.user!==user)return;
 if(order.status==='cancelled'){await showOrder(order.id);return}
 modal('تم تأكيد طلبك',`<div class="success-view"><div class="success-symbol">✓</div><h2>${esc(order.number)}</h2>${cartKept?'<p class="notice">تغيرت سلتك بعد عرض السعر، فاحتفظنا بها. راجعها قبل شراء جديد.</p>':''}<p>طلبك مسجل. احتفظ برمز التسليم ولا تشاركه إلا عند الاستلام.</p>${order.delivery_code?`<div class="delivery-code">${esc(order.delivery_code)}</div>`:'<p>يمكنك متابعة الطلب وطلب رمز تسليم جديد من تفاصيله عند الحاجة.</p>'}<strong class="price">${money(order.total_halalas)}</strong><button class="btn primary" data-view="orders">متابعة الطلب</button></div>`,'small-modal');
}
async function showCheckout(){
 const snap=checkoutSession.snapshot,q=snap.quote;if(!snap.pending)return;
 if(q?.order?.id){await finishCheckout();return}
 const d=modal('مراجعة الطلب',`<div class="stack"><p id="quote-error" class="notice" role="alert"></p>${snap.pending.attempted?'<p class="notice">سبق الضغط على التأكيد. تحقق من نتيجة هذا الحجز قبل بدء طلب آخر.</p>':''}${q?`<div class="panel">${(q.lines||[]).map(x=>`<div class="component-row"><span>${esc(x.name)} × ${number(x.qty)}${x.weight_policy?`<small>الوزن المسموح ${number(x.weight_policy.min_base)}–${number(x.weight_policy.max_base)} جرام. النقص يخفض السعر والزيادة المسموحة مجانًا.</small>`:''}</span><strong>${money(x.line_total_halalas)}</strong></div>`).join('')}</div><div class="summary"><div><span>المنتجات</span><strong>${money(q.subtotal_halalas)}</strong></div>${q.discount_halalas?`<div><span>خصم ${esc(q.coupon?.code||'')}</span><strong>−${money(q.discount_halalas)}</strong></div>`:''}<div><span>التوصيل</span><strong>${money(q.delivery_fee_halalas)}</strong></div><div class="total"><span>الإجمالي</span><strong>${money(q.total_halalas)}</strong></div></div>${storeVersionMarkup(q.store_profile)}`:''}<p id="quote-state" class="notice"></p><div id="quote-store-policies"></div><p>الدفع عند الاستلام. الضغط على التأكيد ينشئ طلبًا فعليًا ويعني الموافقة على شروط البيع المعروضة.</p><button class="btn primary wide" id="confirm-order" disabled>تأكيد الطلب والموافقة على شروط البيع</button><button class="btn outline" id="refresh-quote">التحقق من حالة الحجز ونتيجة الطلب</button><button class="btn outline" id="quote-signin" hidden>تسجيل الدخول لاستكمال المراجعة</button><button class="btn outline" id="cancel-quote">إلغاء الحجز والعودة للسلة</button></div>`);
 let readyPolicy=null;const reference=snap.pending.quote_id;
 const controls=()=>{
  if(!d.open||!$('#quote-state',d)||checkoutSession.snapshot.pending?.quote_id!==reference)return;
  const s=checkoutSession.snapshot,status=quoteState(s.quote,checkoutSession.elapsed()),seconds=quoteRemaining(s.quote,checkoutSession.elapsed());
  $('#quote-state',d).textContent=status==='active'?`متبقي لحجز السعر والمخزون ${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`:status==='expired'?'انتهت مهلة الحجز. تحقق من نتيجة الطلب أو ألغِ الحجز للعودة للسلة.':status==='ordered'?'طلبك مسجل. أكمل التحقق لعرضه.':status==='cancelled'?'أُلغي هذا الحجز. عد إلى السلة.':'حدّث حالة الحجز للمتابعة.';
  $('#quote-error',d).textContent=s.error;$('#quote-signin',d).hidden=s.errorCode!=='AUTH_REQUIRED';
  $('#confirm-order',d).disabled=s.busy||status!=='active'||!s.quote?.store_profile?.id||readyPolicy!==s.quote.store_profile.id;
  $('#refresh-quote',d).disabled=s.busy;$('#cancel-quote',d).disabled=s.busy||status==='ordered';
 };
 updateQuoteControls=controls;controls();
 const timer=setInterval(()=>{if(!d.open||!$('#quote-state',d)||updateQuoteControls!==controls){clearInterval(timer);return}controls()},1000);
 const act=async fn=>{try{await fn()}catch(e){toast(e.message,true)}finally{controls()}};
 $('#quote-signin',d).onclick=()=>loginDialog(async u=>{state.user=u;checkoutIdentity++;await checkoutSession.load();await resumeCheckout()});
 $('#refresh-quote',d).onclick=()=>act(async()=>{await checkoutSession.refresh();await showCheckout()});
 $('#cancel-quote',d).onclick=()=>act(async()=>{
  if(!confirm('إلغاء حجز هذا العرض؟ إن كان قد تحول إلى طلب فسيظهر الطلب دون إلغائه.'))return;
  await checkoutSession.cancel();if(checkoutSession.snapshot.pending)await showCheckout();else await showCart();
 });
 $('#confirm-order',d).onclick=()=>act(async()=>{const order=await checkoutSession.confirm(readyPolicy);if(order)await finishCheckout()});
 if(q?.store_profile?.id&&quoteState(q,checkoutSession.elapsed())==='active')loadQuotePolicies(d,q,id=>{if(updateQuoteControls!==controls)return;readyPolicy=id;controls()});
}
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&$('#app-dialog')?.open&&$('#quote-state')&&!checkoutSession.snapshot.busy)resumeCheckout().catch(e=>toast(e.message,true))});
function orderCard(o){return `<button class="order-card" data-order="${o.id}"><div class="row between"><strong>${esc(o.number)}</strong>${badge(o.status)}</div><div class="row wrap">${badge(o.fulfillment_state)} ${badge(o.delivery_state)} ${badge(o.payment_state)}</div><div class="row between"><span>${date(o.created_at)}</span><strong>${money(o.total_halalas)}</strong></div></button>`}
let orderGeneration=0;
async function renderOrders(){
 if(!await needCustomer(renderOrders)){if(!state.user)$('#app').innerHTML=empty('سجّل الدخول','تابع طلباتك من هنا.');return}
 const generation=++orderGeneration,customerId=state.user.id;let items=[],next=null,loading=false;
 const current=()=>generation===orderGeneration&&state.view==='orders'&&state.user?.id===customerId;
 async function load(more=false){
  if(loading)return;loading=true;try{
  const r=await get(orderPageUrl(more?next:null));if(!current())return;
  items=more?appendOrderPage(items,r.items||[]):r.items||[];next=r.next;
  $('#app').innerHTML=`<div class="page-heading"><span class="eyebrow">حسابك</span><h1>طلباتك</h1><p>الأحدث أولًا · ${items.length} طلبًا معروضًا</p><button class="btn outline" id="refresh-orders">تحديث الطلبات</button></div><div class="stack">${items.map(orderCard).join('')||empty('لا توجد طلبات','ابدأ أول طلب من المتجر.')} ${next?'<button class="btn outline" id="more-orders">عرض طلبات أقدم</button>':''}</div>`;
  $('#refresh-orders').onclick=()=>busy($('#refresh-orders'),()=>load()).catch(()=>{});
  if(next)$('#more-orders').onclick=()=>busy($('#more-orders'),()=>load(true)).catch(()=>{});
  }finally{loading=false}
 }
 await load();
}
function orderFactsMarkup(o){
 const f=orderFacts(o),a=f.address,sl=f.slot,links=orderLinks(a);
 return `<section class="panel stack"><h3>تفاصيل التوصيل</h3><p>${esc([a.city,a.district,a.street,a.details].filter(Boolean).join('، ')||'تفاصيل العنوان غير مسجلة')}</p>${a.building||a.floor||a.apartment?`<p>${esc([a.building&&'مبنى '+a.building,a.floor&&'طابق '+a.floor,a.apartment&&'وحدة '+a.apartment].filter(Boolean).join(' · '))}</p>`:''}<p>${esc(a.recipient_name||'')} · ${esc(a.recipient_phone||'')}</p>${a.notes?`<p>${esc(a.notes)}</p>`:''}<p>${sl.starts_at&&sl.ends_at?`الموعد المحجوز: ${date(sl.starts_at)} — ${date(sl.ends_at)}`:'موعد التوصيل غير مسجل'}</p>${links.map?`<a class="btn outline" href="${esc(links.map)}" target="_blank" rel="noopener noreferrer">موقع التوصيل على Google Maps</a>`:''}</section>
 <section class="panel stack"><h3>أصناف الطلب والمبالغ</h3>${f.lines.map(x=>`<div class="component-row"><span>${esc(x.name)} × ${esc(x.qty)}${x.actual_base_qty!=null?`<small>الكمية المجهزة: ${esc(x.actual_base_qty)} ${x.components?.[0]?.base_unit==='piece'?'قطعة':'جرام'}</small>`:''}</span><strong>${money(x.line_total_halalas)}</strong></div>`).join('')}
 <div class="summary">${Number.isSafeInteger(o.snapshot?.delivery_fee_halalas)?`<div><span>رسوم التوصيل</span><strong>${money(o.snapshot.delivery_fee_halalas)}</strong></div>`:''}${o.snapshot?.discount_halalas>0?`<div><span>الخصم</span><strong>−${money(o.snapshot.discount_halalas)}</strong></div>`:''}<div class="total"><span>إجمالي الطلب</span><strong>${money(f.total)}</strong></div><div><span>المبلغ المحصّل</span><strong>${money(f.collected)}</strong></div><div><span>المبلغ المُعاد لك</span><strong>${money(f.refunded)}</strong></div><div><span>المتبقي للتحصيل</span><strong>${money(f.due)}</strong></div></div></section>
 <section class="panel stack"><h3>تحديثات الطلب</h3>${o.timeline_has_earlier?'<p class="muted">أحدث 100 تحديث مسجل لهذا الطلب.</p>':''}${f.timeline.length?`<ol class="order-timeline">${f.timeline.map(e=>`<li><strong>${esc(e.title)}</strong><time>${date(e.created_at)}</time></li>`).join('')}</ol>`:'<p>لا توجد تحديثات مؤرخة متاحة.</p>'}</section>`;
}
async function showOrder(id){
 const o=await get('/api/orders/'+id),f=orderFacts(o);
 const d=modal('طلب '+o.number,`<div class="stack">${storeVersionMarkup(o.original_snapshot?.store_profile||o.snapshot?.store_profile)}<div class="row wrap">${badge(o.status)} ${badge(o.fulfillment_state)} ${badge(o.delivery_state)} ${badge(o.payment_state)}</div>${orderFactsMarkup(o)}<section class="panel stack"><h3>موقع المندوب</h3><div id="order-tracking" role="status">اضغط التحديث لمعرفة آخر موقع مسجل.</div><button class="btn outline" id="refresh-tracking">تحديث موقع المندوب</button></section>${(o.substitutions||[]).map(s=>substitutionReview(s,o.id,true)).join('')}<section class="panel stack"><h3>الاستردادات</h3>${(o.refunds||[]).map(r=>`<div><div class="row between"><strong>${money(r.amount_halalas)}</strong>${badge(r.state)}</div><p>${esc(r.reason)}</p>${r.decision_note?`<p>${esc(r.decision_note)}</p>`:''}</div>`).join('')||'<p>لا توجد طلبات استرداد.</p>'}</section><div class="row wrap">${f.canRefund?`<button class="btn outline" data-refund-order="${esc(o.id)}">طلب استرداد مبلغ</button>`:''}${f.canCancel?`<button class="btn danger" data-cancel="${esc(o.id)}">إلغاء قبل التجهيز</button>`:''}${f.canRenewCode?`<button class="btn outline" data-code="${esc(o.id)}">تجديد رمز التسليم</button>`:''}<button class="btn outline" id="refresh-order">تحديث الطلب</button><button class="btn outline" data-support="${esc(o.id)}">الدعم</button></div></div>`);
 const target=$('#order-tracking',d);
 $('#refresh-tracking',d).onclick=()=>busy($('#refresh-tracking',d),async()=>{
  const t=trackingView(await get('/api/orders/'+id+'/tracking'));if(!target.isConnected)return;
  target.innerHTML=`<p>${esc(t.message)}</p>${t.updatedAt?`<p>وقت التسجيل: ${date(t.updatedAt)}</p>`:''}${t.accuracy!=null?`<p>دقة الموقع التقريبية: ${number(t.accuracy)} متر</p>`:''}${t.map?`<a class="btn outline" target="_blank" rel="noopener noreferrer" href="${esc(t.map)}">فتح آخر موقع مسجل</a>`:''}`;
 }).catch(()=>{});
 $('#refresh-order',d).onclick=()=>busy($('#refresh-order',d),()=>showOrder(id)).catch(()=>{});
}
async function loadFavorites(){if(!state.user||state.user.role!=='customer')return;const r=await get('/api/favorites');state.favorites=new Set((r.items||[]).map(x=>x.offering_family_id))}

function requestRefundDialog(orderId){const d=modal('طلب استرداد',`<form id="refund-request" class="stack">${field('amount','المبلغ المطلوب بالريال')}${field('reason','سبب الطلب')}<p class="notice">هذا طلب مراجعة؛ لا يعني أن مبلغًا أُعيد. يُتحقق من النقد المحصّل والطلبات المعلقة في الخادم.</p><button class="btn primary">إرسال الطلب</button></form>`);$('#refund-request',d).onsubmit=e=>{e.preventDefault();busy($('button',e.target),async()=>{const x=formData(e.target);await post('/api/orders/'+orderId+'/refunds',{amount_halalas:parseMoney(x.amount),reason:x.reason,component_id:null});closeModal();toast('تم إرسال طلب الاسترداد للمراجعة');await showOrder(orderId)}).catch(()=>{})}}
