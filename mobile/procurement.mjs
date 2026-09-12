export const PROCUREMENT_ROLES=new Set(['admin','finance','picker']);

export const PROCUREMENT_STATES=[
 ['','الكل'],['unassigned','غير مسندة'],['assigned','مسندة'],['collecting','قيد الجمع'],
 ['awaiting_customer','بانتظار العميل'],['shortage_approved','نقص موافق عليه'],['ready','جاهزة للعهدة'],
 ['handover_pending','بانتظار المندوب'],['handed_over','سُلّمت للمندوب'],['cancelled','ملغاة']
];

export function isProcurementRole(role){return PROCUREMENT_ROLES.has(role)}
export function canSeeProcurementFinance(role){return role==='admin'||role==='finance'}

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
