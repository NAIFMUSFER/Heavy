import {googleMapsLink,locationPoint,saudiPhone} from './address.mjs';

const events={order_created:'تم تأكيد الطلب',picking:'بدأ تجهيز الطلب',start_picking:'بدأ تجهيز الطلب',ready:'اكتمل التجهيز',out_for_delivery:'خرج الطلب للتوصيل',delivery_failed:'تعذر التسليم',delivered:'تم تسليم الطلب',cancelled:'أُلغي الطلب',substitution_proposed:'طُرح بديل للمراجعة',substitution_accepted:'وافقت على البديل',substitution_rejected:'رفضت البديل',line_removal_proposed:'طُلبت موافقتك على حذف صنف',line_removal_accepted:'وافقت على حذف الصنف',line_removal_rejected:'رفضت حذف الصنف',line_removal_expired:'انتهت مهلة حذف الصنف',refund_completed:'سُجّل إرجاع مبلغ'};
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
