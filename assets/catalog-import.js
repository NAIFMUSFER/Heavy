const kinds=new Set(['individual','basket','sized','usage','bulk','gift']);
const units=new Set(['kg','piece','pack','package','basket']);
const textValue=(value,name,min,max)=>{if(typeof value!=='string'||value.trim().length<min||value.trim().length>max)throw Error(`راجع ${name}`);return value.trim()};
const integer=(value,name,min,max)=>{if(!Number.isSafeInteger(value)||value<min||value>max)throw Error(`راجع ${name}`);return value};

export function catalogImportTemplate(stock=[]){
 const stockId=stock.find(x=>x.active)?.id||'REPLACE_WITH_STOCK_ID';
 return {schema_version:1,products:[],_example:{title:'استبدل باسم المنتج',kind:'sized',category:'fruit',description:'',emoji:'',image_url:'',offerings:[{sellable_key:'one-kg',size_label:'1 كجم',sale_unit:'kg',price_halalas:1000,weight_under_bps:10000,weight_over_bps:0,components:[{stock_id:stockId,base_qty:1000,list_price_halalas:0}]}]}};
}

export function validateCatalogImport(input,stock=[]){
 if(!input||typeof input!=='object'||Array.isArray(input)||input.schema_version!==1||!Array.isArray(input.products)||input.products.length<1||input.products.length>50)throw Error('الملف يحتاج schema_version=1 ومن 1 إلى 50 منتجًا');
 const known=new Set(stock.filter(x=>x.active).map(x=>x.id)),titles=new Set();let totalOfferings=0;
 const products=input.products.map((product,productIndex)=>{
  if(!product||typeof product!=='object'||Array.isArray(product)||product.family_id||product.copy_version_id)throw Error(`راجع المنتج ${productIndex+1}`);
  const title=textValue(product.title,`اسم المنتج ${productIndex+1}`,2,140),normalized=title.replace(/\s+/g,' ').toLocaleLowerCase('ar');
  if(titles.has(normalized))throw Error(`اسم المنتج مكرر داخل الملف: ${title}`);titles.add(normalized);
  if(!kinds.has(product.kind))throw Error(`راجع نوع المنتج: ${title}`);
  const category=textValue(product.category,`قسم ${title}`,1,40),description=typeof product.description==='string'?product.description:'',emoji=typeof product.emoji==='string'?product.emoji:'',image_url=typeof product.image_url==='string'?product.image_url:'';
  if(description.length>10000||emoji.length>20||image_url.length>300)throw Error(`راجع وصف أو صورة ${title}`);
  if(image_url){let url;try{url=new URL(image_url)}catch{}if(!url||url.protocol!=='https:'||url.username||url.password)throw Error(`رابط صورة ${title} يجب أن يكون HTTPS دون بيانات دخول`)}
  if(!Array.isArray(product.offerings)||product.offerings.length<1||product.offerings.length>30)throw Error(`أضف من 1 إلى 30 حجمًا للمنتج ${title}`);
  totalOfferings+=product.offerings.length;if(totalOfferings>500)throw Error('الملف يتجاوز 500 حجم قابل للبيع');
  const keys=new Set();const offerings=product.offerings.map((offering,offeringIndex)=>{
   if(!offering||typeof offering!=='object'||Array.isArray(offering))throw Error(`راجع الحجم ${offeringIndex+1} في ${title}`);
   const sellable_key=textValue(offering.sellable_key,'رمز الحجم',1,40);if(!/^[a-z0-9][a-z0-9_-]{0,39}$/.test(sellable_key)||keys.has(sellable_key))throw Error(`رمز حجم غير صالح أو مكرر في ${title}: ${sellable_key}`);keys.add(sellable_key);
   const size_label=textValue(offering.size_label,`وصف حجم ${title}`,1,40);if(!units.has(offering.sale_unit))throw Error(`راجع وحدة بيع ${title}`);
   if(!Array.isArray(offering.components)||offering.components.length<1||offering.components.length>50)throw Error(`راجع مكونات ${title} / ${size_label}`);
   const componentIds=new Set();const components=offering.components.map(component=>{
    const stock_id=textValue(component?.stock_id,'معرّف صنف المخزون',1,36);if(!known.has(stock_id))throw Error(`صنف المخزون غير نشط أو غير موجود: ${stock_id}`);if(componentIds.has(stock_id))throw Error(`صنف مخزون مكرر في ${title} / ${size_label}`);componentIds.add(stock_id);
    return {stock_id,base_qty:integer(component.base_qty,'كمية المكوّن',1,1000000000),list_price_halalas:integer(component.list_price_halalas??0,'القيمة المرجعية للمكوّن',0,9000000000000)};
   });
   return {sellable_key,size_label,sale_unit:offering.sale_unit,price_halalas:integer(offering.price_halalas,'السعر بالهللة',1,9000000000000),weight_under_bps:integer(offering.weight_under_bps??10000,'نسبة النقص',0,10000),weight_over_bps:integer(offering.weight_over_bps??0,'نسبة الزيادة',0,2000),components};
  });
  return {title,kind:product.kind,category,description,emoji,image_url,offerings};
 });
 return {schema_version:1,products,summary:{products:products.length,offerings:totalOfferings,components:products.reduce((n,p)=>n+p.offerings.reduce((m,o)=>m+o.components.length,0),0)}};
}
