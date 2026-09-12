import {moneyValue} from './input.mjs';
import {latinDigits} from './address.mjs';

export const PROCUREMENT_ROLES=new Set(['admin','finance','picker']);

export const PROCUREMENT_STATES=[
 ['','الكل'],['unassigned','غير مسندة'],['assigned','مسندة'],['collecting','قيد الجمع'],
 ['awaiting_customer','بانتظار العميل'],['shortage_approved','نقص موافق عليه'],['ready','جاهزة للعهدة'],
 ['handover_pending','بانتظار المندوب'],['handed_over','سُلّمت للمندوب'],['cancelled','ملغاة']
];

export function isProcurementRole(role){return PROCUREMENT_ROLES.has(role)}
export function canSeeProcurementFinance(role){return role==='admin'||role==='finance'}

export function procurementAdjustmentFacts(data,role){
 const job=data?.job||{},shortage=data?.shortage||{},before=Number(data?.customer_terms?.total_halalas),reduction=Number(shortage.proposed_reduction_halalas);
 if(!canSeeProcurementFinance(role)||data?.financial_detail_included!==true||job.state!=='shortage_approved'||shortage.state!=='approved'||shortage.decision?.decision!=='approve_removal'||!/^prc-[0-9a-f]{32}$/.test(job.id||'')||!/^shr-[0-9a-f]{32}$/.test(shortage.id||'')||!Number.isSafeInteger(Number(job.revision))||Number(job.revision)<1||!Number.isSafeInteger(before)||!Number.isSafeInteger(reduction)||reduction<1||before-reduction<1)return null;
 return {jobId:job.id,requestId:shortage.id,revision:Number(job.revision),before,reduction,after:before-reduction};
}

export function procurementAssignmentFacts(data,role){
 const job=data?.job||{};
 if(role!=='admin'||!['unassigned','assigned'].includes(job.state)||!/^prc-[0-9a-f]{32}$/.test(job.id||'')||!Number.isSafeInteger(Number(job.revision))||Number(job.revision)<1)return null;
 return {jobId:job.id,revision:Number(job.revision),assignedTo:job.assigned_to||''};
}

export function procurementPurchaseFacts(data,user){
 const job=data?.job||{},lines=(data?.lines||[]).filter(line=>Number(line.remaining_qty)>0);
 if(!['admin','picker'].includes(user?.role)||job.assigned_to!==user?.id||!['assigned','collecting'].includes(job.state)||!/^prc-[0-9a-f]{32}$/.test(job.id||'')||!Number.isSafeInteger(Number(job.revision))||Number(job.revision)<1||!lines.length)return null;
 return {jobId:job.id,revision:Number(job.revision),lines};
}

export function procurementQuantityValue(value,max){
 const text=(typeof value==='string'||typeof value==='number'?latinDigits(value):'').replace(/٫/g,'.').trim();
 if(!/^\d+(\.\d{1,3})?$/.test(text))throw Error('أدخل كمية موجبة بحد أقصى ثلاث منازل عشرية');
 const quantity=Number(text);if(!Number.isFinite(quantity)||quantity<=0||quantity>Number(max))throw Error('الكمية تتجاوز المتبقي المطلوب من العميل');return quantity;
}

export function procurementPurchasePayload({facts,site,documentReference,note,drafts}){
 if(!facts||!site?.id||!site?.supplier_id||site.active!==true||site.supplier_active!==true)throw Error('اختر نقطة استلام نشطة');
 const reference=String(documentReference||'').trim(),visitNote=String(note||'').trim();
 if(reference.length<3||reference.length>180||visitNote.length<3||visitNote.length>1000)throw Error('راجع مرجع المستند وملاحظة الزيارة');
 const lines=[];
 for(const line of facts.lines){
  const draft=drafts?.[line.line_id]||{},raw=String(draft.quantity||'').trim(),rawCost=String(draft.cost||'').trim(),quality=String(draft.quality||'').trim();
  if(!raw){if(rawCost||quality)throw Error('أدخل كمية الصنف أو امسح تكلفة وملاحظة هذا السطر');continue}
  const collected_qty=procurementQuantityValue(raw,line.remaining_qty),actual_cost_halalas=moneyValue(rawCost);
  if(actual_cost_halalas>9000000000000||quality.length<3||quality.length>1000)throw Error('راجع التكلفة الفعلية وملاحظة الجودة لكل صنف');
  lines.push({line_id:line.line_id,collected_qty,actual_cost_halalas,quality_note:quality});
 }
 if(!lines.length)throw Error('سجّل صنفًا واحدًا على الأقل استلمته فعليًا');
 const total=lines.reduce((sum,line)=>sum+line.actual_cost_halalas,0);if(!Number.isSafeInteger(total))throw Error('إجمالي التكلفة أكبر من المسموح');
 return {body:{expected_revision:facts.revision,supplier_id:site.supplier_id,pickup_site_id:site.id,document_reference:reference,note:visitNote,lines},total};
}

export function procurementStateLabel(value){
 return new Map(PROCUREMENT_STATES).get(value)||value||'غير معروفة';
}

export function procurementPageUrl({state='',cursor=null,limit=30}={}){
 if(!Number.isInteger(limit)||limit<1||limit>100)throw Error('حد صفحة مهام الشراء غير صالح');
 if(!PROCUREMENT_STATES.some(([key])=>key===state))throw Error('مرشح حالة مهام الشراء غير صالح');
 const params=new URLSearchParams({limit:String(limit)});
 if(state)params.set('state',state);
 if(cursor){
  if(!Number.isSafeInteger(cursor.before_at)||!/^prc-[0-9a-f]{32}$/.test(cursor.before_id||''))throw Error('مؤشر صفحة مهام الشراء غير صالح');
  params.set('before_at',String(cursor.before_at));params.set('before_id',cursor.before_id);
 }
 return '/api/ops/procurement?'+params;
}

export function appendProcurementPage(current,incoming){
 const rows=new Map(current.map(item=>[item.id,item]));
 for(const item of incoming)if(item&&typeof item.id==='string')rows.set(item.id,item);
 return [...rows.values()];
}

export function procurementQuantity(value){
 const n=Number(value);return Number.isFinite(n)?new Intl.NumberFormat('ar-SA-u-nu-latn',{maximumFractionDigits:3}).format(n):'غير مسجلة';
}

export function procurementRoleLabel(role){return({admin:'الإدارة',finance:'المالية',picker:'موظف الشراء'})[role]||role}
