// Read-only owner review exports. These files are deliberately not accepted by
// the import endpoint: they describe current state and never mutate inventory.
const formulaPrefix=/^[\t\r\n ]*[=+\-@]/;
const textCell=value=>{
 const text=String(value??'');
 const safe=formulaPrefix.test(text)?"'"+text:text;
 return /[",\r\n]/.test(safe)?`"${safe.replace(/"/g,'""')}"`:safe;
};
const numberCell=value=>Number.isFinite(value)?String(value):'';
const csv=(headers,rows)=>'\ufeff'+headers.map(textCell).join(',')+'\r\n'+rows.map(row=>row.map(({value,numeric=false})=>numeric?numberCell(value):textCell(value)).join(',')).join('\r\n')+'\r\n';
const t=value=>({value});
const n=value=>({value,numeric:true});
const sar=value=>Number.isSafeInteger(value)?value/100:null;
const bps=value=>Number.isSafeInteger(value)?value/100:null;
const iso=value=>{
 const stamp=Number(value);if(!Number.isFinite(stamp))return '';
 try{return new Date(stamp>1e12?stamp:stamp*1000).toISOString()}catch{return ''}
};

export function catalogReviewCsv(catalog={}){
 const families=new Map((catalog.product_families||[]).map(x=>[x.id,x]));
 const stock=new Map((catalog.stock||[]).map(x=>[x.id,x]));
 const versions=Array.isArray(catalog.product_versions)?catalog.product_versions:[];
 const offerings=Array.isArray(catalog.offerings)?catalog.offerings:[];
 const rows=[],linked=new Set();
 const add=(version,offering=null)=>{
  if(offering?.id)linked.add(offering.id);
  const components=Array.isArray(offering?.components)&&offering.components.length?offering.components:[null];
  for(const component of components){
   const item=component?stock.get(component.stock_id):null,family=version?families.get(version.family_id):null;
   rows.push([
    t(family?.name||''),t(version?.title||''),n(Number.isSafeInteger(version?.version)?version.version:null),t(version?.state||''),t(version?.kind||offering?.kind||''),t(version?.category||offering?.category||''),t(version?.description||offering?.description||''),t(version?.emoji||offering?.emoji||''),t(version?.image_url||offering?.image_url||''),
    t(offering?.sellable_key||''),t(offering?.size_label||''),t(offering?.sale_unit||''),n(sar(offering?.price_halalas)),n(bps(offering?.weight_under_bps)),n(bps(offering?.weight_over_bps)),t(offering?.active===true?'نشط':offering?'متوقف':''),
    t(component?.stock_id||''),t(item?.name||''),t(item?.base_unit||''),n(Number.isSafeInteger(component?.base_qty)?component.base_qty:null),n(sar(component?.list_price_halalas))
   ]);
  }
 };
 for(const version of versions){const current=offerings.filter(x=>x.product_version_id===version.id);if(current.length)current.forEach(x=>add(version,x));else add(version)}
 for(const offering of offerings)if(!linked.has(offering.id))add(null,offering);
 return csv(['العائلة','عنوان_الإصدار','رقم_الإصدار','حالة_الإصدار','النوع','القسم','الوصف','الرمز','رابط_الصورة','مفتاح_الحجم','وصف_الحجم','وحدة_البيع','السعر_بالريال','نسبة_النقص','نسبة_الزيادة','حالة_الحجم','معرف_المخزون','اسم_المخزون','وحدة_المخزون','كمية_المكون','قيمة_المكون_بالريال'],rows);
}

export function inventoryReviewCsv(catalog={},generatedAt=Date.now()){
 const stocks=Array.isArray(catalog.stock)?catalog.stock:[],lots=Array.isArray(catalog.lots)?catalog.lots:[];
 const suppliers=new Map((catalog.suppliers||[]).map(x=>[x.id,x]));
 const rows=[],linked=new Set(),generated=iso(generatedAt);
 const add=(item=null,lot=null)=>{
  if(lot?.id)linked.add(lot.id);
  rows.push([
   t(generated),t(item?.id||lot?.stock_id||''),t(item?.name||''),t(item?.base_unit||''),t(item?.active===true?'نشط':item?'متوقف':''),
   t(item?.bin_code||''),t(item?.bin_label||''),t(item?.bin_warehouse_id||''),
   n(Number.isSafeInteger(item?.on_hand_base)?item.on_hand_base:null),n(Number.isSafeInteger(item?.reserved_base)?item.reserved_base:null),n(Number.isSafeInteger(item?.available_base)?item.available_base:null),n(Number.isSafeInteger(item?.sellable_base)?item.sellable_base:null),n(Number.isSafeInteger(item?.reorder_base)?item.reorder_base:null),t(item?.stock_status||''),
   t(lot?.id||''),t(lot?.supplier_id?suppliers.get(lot.supplier_id)?.name||'':''),t(lot?.receipt_reference||''),n(Number.isSafeInteger(lot?.received_base)?lot.received_base:null),n(Number.isSafeInteger(lot?.on_hand_base)?lot.on_hand_base:null),n(Number.isSafeInteger(lot?.reserved_base)?lot.reserved_base:null),t(lot?.inspection_state||''),t(iso(lot?.expires_at))
  ]);
 };
 for(const item of stocks){const current=lots.filter(x=>x.stock_id===item.id);if(current.length)current.forEach(x=>add(item,x));else add(item)}
 for(const lot of lots)if(!linked.has(lot.id))add(null,lot);
 return csv(['تاريخ_التصدير_UTC','معرف_المخزون','اسم_المخزون','وحدة_الأساس','حالة_الصنف','رمز_الموقع_المرجعي','وصف_الموقع','معرف_المستودع','الموجود_الإجمالي','المحجوز_الإجمالي','غير_المحجوز','الصالح_للبيع','حد_إعادة_الطلب','حالة_الرصيد','معرف_الدفعة','المورد','مرجع_الاستلام','الكمية_المستلمة','موجود_الدفعة','محجوز_الدفعة','حالة_الفحص','انتهاء_الصلاحية_UTC'],rows);
}
