import {googleMapsLink,locationPoint,saudiPhone} from './address.mjs';

const events={order_created:'تم تأكيد الطلب',supplier_pickup_order_created:'تم تأكيد الطلب',picking:'بدأ تجهيز الطلب',start_picking:'بدأ تجهيز الطلب',ready:'اكتمل التجهيز',out_for_delivery:'خرج الطلب للتوصيل',delivery_failed:'تعذر التسليم',delivered:'تم تسليم الطلب',cancelled:'أُلغي الطلب',substitution_proposed:'طُرح بديل للمراجعة',substitution_accepted:'وافقت على البديل',substitution_rejected:'رفضت البديل',line_removal_proposed:'طُلبت موافقتك على حذف صنف',line_removal_accepted:'وافقت على حذف الصنف',line_removal_rejected:'رفضت حذف الصنف',line_removal_expired:'انتهت مهلة حذف الصنف',component_substitution_proposed:'طُلبت موافقتك على مكوّن بديل للسلة',component_substitution_accepted:'وافقت على مكوّن السلة البديل',component_substitution_rejected:'رفضت مكوّن السلة البديل',component_substitution_expired:'انتهت مهلة مكوّن السلة البديل',refund_completed:'سُجّل إرجاع مبلغ'};
export function orderFacts(order){
 const snapshot=order.snapshot||{},original=order.original_snapshot||{};
 const total=order.total_halalas,collected=order.collected_halalas,refunded=order.refunded_halalas;
 return {address:original.address||snapshot.address||{},slot:original.slot||snapshot.slot||{},lines:snapshot.lines||[],
  total,collected,refunded,
  due:order.status==='cancelled'?0:Number.isSafeInteger(total)&&Number.isSafeInteger(collected)?Math.max(0,total-collected):null,
  canCancel:order.status==='active'&&order.fulfillment_state==='queued'&&order.delivery_state==='unassigned',
  canRenewCode:order.status==='active'&&order.delivery_state==='out_for_delivery',
  canRefund:order.delivery_state==='delivered'&&Number.isSafeInteger(collected)&&Number.isSafeInteger(refunded)&&collected>refunded,
  timeline:(order.timeline||[]).filter(e=>events[e.event]&&Number.isSafeInteger(e.created_at)&&e.created_at>0).map(e=>({id:e.id,title:events[e.event],created_at:e.created_at}))};
}
const procurementStates={
 unassigned:['تم تأكيد الطلب','بانتظار تكليف موظف الشراء.'],
 assigned:['تم تكليف موظف الشراء','سيبدأ جمع احتياجات طلبك من الموردين والمحلات.'],
 collecting:['جارٍ جمع طلبك','يتم توثيق الكميات التي جُمعت فعليًا لكل صنف.'],
 awaiting_customer:['موافقتك مطلوبة','تعذر توفير جزء من الطلب، ولن يُحذف أو يتغير سعره قبل موافقتك الصريحة.'],
 shortage_approved:['تم تسجيل موافقتك','يتم تطبيق التخفيض الموافق عليه قبل تسليم الأصناف للتوصيل.'],
 ready:['اكتمل الجمع','تُراجع الأصناف المجمعة قبل تسليمها للمندوب.'],
 handover_pending:['بانتظار استلام المندوب','وثّق موظف الشراء العهدة، ولم يقبلها المندوب بعد.'],
 handed_over:['استلم المندوب الطلب','انتقلت عهدة الأصناف إلى المندوب للتوصيل.'],
 cancelled:['أُلغي مسار الجمع','لن تُسلّم أصناف من مسار الشراء لهذا الطلب.']
};
export function procurementProgressFacts(order){
 const p=order?.procurement_progress;if(!p||p.version!==1||!procurementStates[p.state]||!Number.isSafeInteger(p.updated_at)||p.updated_at<=0||!Array.isArray(p.lines))return null;
 const lines=[];for(const line of p.lines){const requested=Number(line.requested_qty),collected=Number(line.collected_qty),remaining=Number(line.remaining_qty);if(!Number.isFinite(requested)||requested<=0||!Number.isFinite(collected)||collected<0||!Number.isFinite(remaining)||remaining<0||Math.abs(requested-collected-remaining)>1e-6)return null;lines.push({lineId:String(line.line_id||''),name:String(line.name||'صنف'),sizeLabel:String(line.size_label||''),requested,collected,remaining})}
 if(!Number.isSafeInteger(p.revision)||p.revision<1||!Number.isSafeInteger(p.requested_line_count)||p.requested_line_count!==lines.length||p.inventory_reserved!==false||p.supplier_detail_included!==false||p.staff_identity_included!==false||p.actual_cost_included!==false)return null;
 let shortage=null;const s=p.shortage;if(s!=null){if(!['pending','approved','rejected'].includes(s.state)||!Number.isSafeInteger(s.proposed_reduction_halalas)||s.proposed_reduction_halalas<=0||!Number.isSafeInteger(s.customer_total_before_halalas)||!Number.isSafeInteger(s.customer_total_if_approved_halalas)||s.customer_total_if_approved_halalas!==s.customer_total_before_halalas-s.proposed_reduction_halalas)return null;const requestId=String(s.id||'');if(s.state==='pending'&&!/^shr-[0-9a-f]{32}$/.test(requestId))return null;shortage={requestId,state:s.state,reduction:s.proposed_reduction_halalas,totalBefore:s.customer_total_before_halalas,totalIfApproved:s.customer_total_if_approved_halalas}}
 const actionRequired=p.customer_action_required===true;if(actionRequired!==(p.state==='awaiting_customer'))return null;
 const [title,message]=procurementStates[p.state],canDecide=actionRequired&&shortage?.state==='pending'&&!!shortage.requestId;return {state:p.state,title,message,updatedAt:p.updated_at,revision:p.revision,actionRequired,canDecide,lines,shortage};
}
export function cashReceiptFacts(order){
 const receipt=order?.payment_receipt,profile=order?.original_snapshot?.store_profile||order?.snapshot?.store_profile||{},snapshot=order?.snapshot||{};
 if(!receipt||receipt.kind!=='cash_collection_receipt'||receipt.payment_method!=='cash_on_delivery'||receipt.tax_invoice!==false)return null;
 const collected=receipt.collected_halalas,refunded=receipt.refunded_halalas,net=receipt.net_collected_halalas,at=receipt.collected_at;
 if(typeof receipt.receipt_id!=='string'||!receipt.receipt_id||!Number.isSafeInteger(at)||at<=0||!Number.isSafeInteger(collected)||collected<0||!Number.isSafeInteger(refunded)||refunded<0||!Number.isSafeInteger(net)||net<0||net!==collected-refunded)return null;
 return {receiptId:receipt.receipt_id,orderNumber:String(order.number||''),collectedAt:at,collected,refunded,net,profile,lines:Array.isArray(snapshot.lines)?snapshot.lines:[],deliveryFee:Number.isSafeInteger(snapshot.delivery_fee_halalas)?snapshot.delivery_fee_halalas:null,discount:Number.isSafeInteger(snapshot.discount_halalas)?snapshot.discount_halalas:null,total:Number.isSafeInteger(order.total_halalas)?order.total_halalas:null};
}
export function cashReceiptHtml(order){
 const r=cashReceiptFacts(order);if(!r)throw Error('cash_receipt_unavailable');
 const escHtml=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const amount=value=>Number.isSafeInteger(value)?new Intl.NumberFormat('ar-SA-u-nu-latn',{style:'currency',currency:'SAR',minimumFractionDigits:2}).format(value/100):'—';
 const when=new Intl.DateTimeFormat('ar-SA-u-ca-gregory-nu-latn',{timeZone:'Asia/Riyadh',dateStyle:'medium',timeStyle:'short'}).format(new Date(r.collectedAt));
 const registration=[r.profile.registration_type,r.profile.registration_number].filter(Boolean).map(escHtml).join(' · ');
 const rows=r.lines.map(line=>`<tr><td>${escHtml(line.name||'صنف')}</td><td>${escHtml(line.qty??'')}</td><td>${escHtml(amount(line.line_total_halalas))}</td></tr>`).join('');
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>إيصال تحصيل نقدي ${escHtml(r.orderNumber)}</title><style>body{font-family:system-ui,-apple-system,sans-serif;color:#17392d;max-width:760px;margin:32px auto;padding:0 20px}header{border-bottom:3px solid #1b563d;padding-bottom:16px}.warning{background:#fff3df;border:1px solid #d68a23;padding:12px;border-radius:10px;font-weight:700}table{width:100%;border-collapse:collapse;margin:20px 0}th,td{padding:10px;border-bottom:1px solid #dfe7e2;text-align:right}.totals{margin-right:auto;max-width:360px}.totals p{display:flex;justify-content:space-between}.net{font-size:1.15rem;font-weight:800}footer{margin-top:32px;color:#52635c;font-size:.9rem}@media print{body{margin:0}.no-print{display:none}}</style></head><body><header><h1>إيصال تحصيل نقدي</h1><p class="warning">ليس فاتورة ضريبية ولا يثبت تسجيل المنشأة في ضريبة القيمة المضافة.</p><h2>${escHtml(r.profile.display_name||r.profile.legal_name||'')}</h2>${r.profile.legal_name&&r.profile.legal_name!==r.profile.display_name?`<p>${escHtml(r.profile.legal_name)}</p>`:''}${registration?`<p>${registration}</p>`:''}</header><main><p><strong>رقم الطلب:</strong> ${escHtml(r.orderNumber)}</p><p><strong>وقت التحصيل:</strong> ${escHtml(when)}</p><p><strong>طريقة الدفع:</strong> نقدًا عند الاستلام</p><table><thead><tr><th>الصنف</th><th>الكمية</th><th>المبلغ</th></tr></thead><tbody>${rows}</tbody></table><div class="totals">${r.deliveryFee!==null?`<p><span>رسوم التوصيل</span><strong>${escHtml(amount(r.deliveryFee))}</strong></p>`:''}${r.discount>0?`<p><span>الخصم</span><strong>−${escHtml(amount(r.discount))}</strong></p>`:''}<p><span>إجمالي الطلب</span><strong>${escHtml(amount(r.total))}</strong></p><p><span>المبلغ المحصّل نقدًا</span><strong>${escHtml(amount(r.collected))}</strong></p><p><span>المبلغ المُعاد</span><strong>${escHtml(amount(r.refunded))}</strong></p><p class="net"><span>صافي المبلغ المحصّل</span><strong>${escHtml(amount(r.net))}</strong></p></div></main><footer><p>أُنشئ هذا الإيصال من سجل التحصيل المرتبط بالطلب. راجع حالة الطلب داخل حسابك للاطلاع على أي استرداد لاحق.</p><p class="no-print">استخدم أمر الطباعة في المتصفح لحفظ نسخة PDF.</p></footer></body></html>`;
}
export function orderLinks(address={}){
 let map='',directions='',phone='';
 try{const p=locationPoint(address.latitude,address.longitude);map=googleMapsLink(p.latitude,p.longitude);directions='https://www.google.com/maps/dir/?api=1&destination='+encodeURIComponent(p.latitude+','+p.longitude)+'&travelmode=driving'}catch{}
 try{const n=saudiPhone(address.recipient_phone);phone='tel:'+(n.startsWith('+')?n:'+966'+n.slice(1))}catch{}
 return {map,directions,phone};
}
export function trackingView(tracking,now=Date.now()){
 const result={message:'لم يُسجّل موقع للمندوب في رحلة التوصيل الحالية.',map:'',updatedAt:null,accuracy:null};
 if(tracking?.delivery_state==='delivered')return {...result,message:'تم التسليم. انتهت مشاركة موقع هذه الرحلة.'};
 if(tracking?.delivery_state!=='out_for_delivery')return {...result,message:'موقع المندوب يتاح أثناء رحلة التوصيل عند تسجيله.'};
 const at=Number(tracking.updated_at);
 if(!Number.isSafeInteger(at)||at<=0||at>now)return result;
 try{result.map=googleMapsLink(tracking.latitude,tracking.longitude)}catch{return result}
 result.updatedAt=at;
 result.message=now-at>300000?'هذا موقع سابق؛ مضت أكثر من خمس دقائق دون تحديث.':'هذا آخر موقع مسجل للمندوب، وقد يتحرك بعد تسجيله.';
 const accuracy=Number(tracking.accuracy_m);if(tracking.accuracy_m!=null&&Number.isFinite(accuracy)&&accuracy>=0)result.accuracy=accuracy;
 return result;
}
export function orderPageUrl(next=null,limit=25){
 const query=new URLSearchParams({limit:String(limit)});
 if(next){query.set('before_at',String(next.before_at));query.set('before_id',next.before_id)}
 return '/api/orders?'+query;
}
export function appendOrderPage(previous,items){const seen=new Set(previous.map(o=>o.id));return [...previous,...items.filter(o=>{if(seen.has(o.id))return false;seen.add(o.id);return true})]}
export function passwordProblem(current,next,confirmation){
 if(!current)return 'أدخل كلمة المرور الحالية.';
 if(typeof next!=='string'||[...next].length<12)return 'كلمة المرور الجديدة يجب أن تحتوي 12 حرفًا على الأقل.';
 // Count UTF-8 bytes without relying on TextEncoder in native runtimes.
 const bytes=[...next].reduce((n,c)=>n+(c.codePointAt(0)<=0x7f?1:c.codePointAt(0)<=0x7ff?2:c.codePointAt(0)<=0xffff?3:4),0);
 if(bytes>72)return 'كلمة المرور طويلة جدًا. الحد 72 بايت؛ الحروف العربية والرموز قد تشغل أكثر من بايت.';
 if(next!==confirmation)return 'تأكيد كلمة المرور لا يطابق الكلمة الجديدة.';
 return '';
}
