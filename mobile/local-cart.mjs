// Shared web/native local cart. Stored selections are estimates, never a quote.
export class CartStorageError extends Error {
 constructor(code,message){super(message);this.name='CartStorageError';this.code=code;}
}
const invalid=()=>new CartStorageError('CART_INVALID','تعذر قراءة السلة المحفوظة. أعد المحاولة أو امسح سلة هذا الجهاز للبدء من جديد.');
export function validateCart(rows){
 if(!Array.isArray(rows)||rows.length>40)throw invalid();
 const ids=new Set();let total=0;
 return rows.map(row=>{
  if(!row||typeof row!=='object'||typeof row.offering_id!=='string'||!row.offering_id.trim()||row.offering_id.length>100||ids.has(row.offering_id)||!Number.isSafeInteger(row.quantity)||row.quantity<1||row.quantity>20||!Number.isSafeInteger(row.price_halalas)||row.price_halalas<0)throw invalid();
  ids.add(row.offering_id);total+=row.price_halalas*row.quantity;if(!Number.isSafeInteger(total))throw invalid();
  const result={offering_id:row.offering_id,quantity:row.quantity,price_halalas:row.price_halalas};
  for(const [key,max] of Object.entries({family_id:100,name:200,emoji:40,size_label:200})){
   if(row[key]==null)continue;
   if(typeof row[key]!=='string'||row[key].length>max)throw invalid();
   result[key]=row[key];
  }
  if(!result.name?.trim())throw invalid();
  return Object.freeze(result);
 });
}
export function readCart(raw){
 if(raw==null)return [];
 if(typeof raw!=='string'||raw.length>100000)throw invalid();
 try{return validateCart(JSON.parse(raw));}catch{throw invalid();}
}
export function createCartStore({storage,key,onChange=()=>{}}){
 let items=Object.freeze([]),ready=false,error=null,operations=0,queue=Promise.resolve();
 const snapshot=()=>Object.freeze({items,ready,busy:operations>0,error});
 const publish=()=>onChange(snapshot());
 function serial(fn){
  operations++;publish();
  const result=queue.then(async()=>{
   try{const value=await fn();error=null;return value;}
   catch(e){error=e instanceof CartStorageError?e:new CartStorageError('CART_STORAGE','تعذر الوصول إلى تخزين السلة. لم يُحفظ التعديل؛ أعد المحاولة.');throw error;}
   finally{operations--;publish();}
  });
  queue=result.catch(()=>{});return result;
 }
 async function persist(next){
  const valid=Object.freeze(validateCart(next));
  await storage.setItem(key,JSON.stringify(valid));items=valid;ready=true;return items;
 }
 return {
  get snapshot(){return snapshot();},
  load:()=>serial(async()=>{const valid=readCart(await storage.getItem(key));items=Object.freeze(valid);ready=true;return items;}),
  update:change=>serial(async()=>{if(!ready)throw error||invalid();const next=change(items);return next===items?items:persist(next);}),
  // Reset is an explicit user action, including when stored data cannot be read.
  reset:()=>serial(()=>persist([])),
  flush:async()=>{await queue;if(!ready)throw error||invalid();return items;}
 };
}
export function changeCartQuantity(items,product,delta){
 const index=items.findIndex(x=>x.offering_id===product.id),old=items[index],quantity=(old?.quantity||0)+delta;
 if(delta>0){
  if(index<0&&items.length>=40)throw new Error('الحد الأقصى للسلة 40 صنفًا');
  if(!Number.isInteger(product.available_units)||quantity>Math.min(20,product.available_units))throw new Error('لا تتوفر كمية إضافية من هذا الصنف');
 }
 if(!old&&delta<0)return items;
 const next=items.map(x=>({...x}));
 if(quantity<=0)next.splice(index,1);
 else if(old)next[index]={...old,quantity};
 else next.push({offering_id:product.id,family_id:product.family_id,quantity,name:product.name,price_halalas:product.price_halalas,emoji:product.emoji,size_label:product.size_label});
 return next;
}
