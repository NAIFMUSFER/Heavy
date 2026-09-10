// Publish a complete catalog only after every page succeeds. Never return a
// partial list as though unavailable later-page products no longer exist.
export function productImageUrl(value){
 if(typeof value!=='string'||value.length>300)return '';
 try{const u=new URL(value);return u.protocol==='https:'&&!u.username&&!u.password?u.href:''}catch{return ''}
}
export async function loadCatalog(call){
 const items=[],seen=new Set();let offset=0;
 for(let page=0;page<100;page++){
  const result=await call('/api/catalog?limit=100&offset='+offset);
  if(!Array.isArray(result.items))throw Error('تعذر قراءة قائمة المنتجات. أعد المحاولة.');
  for(const item of result.items){
   if(!item?.id||seen.has(item.id))throw Error('تغيرت قائمة المنتجات أثناء التحميل. حدّث القائمة.');
   seen.add(item.id);items.push(item);
  }
  if(result.next_offset==null)return items;
  if(!Number.isSafeInteger(result.next_offset)||result.next_offset<=offset)throw Error('تعذر تحميل الصفحة التالية من المنتجات.');
  offset=result.next_offset;
 }
 throw Error('قائمة المنتجات أكبر من حد التحميل الحالي. يرجى المحاولة لاحقًا.');
}
