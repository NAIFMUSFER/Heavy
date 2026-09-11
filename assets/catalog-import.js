import {integerValue,moneyValue} from './input.js';

const kinds=new Set(['individual','basket','sized','usage','bulk','gift']);
const units=new Set(['kg','piece','pack','package','basket']);
const textValue=(value,name,min,max)=>{if(typeof value!=='string'||value.trim().length<min||value.trim().length>max)throw Error(`راجع ${name}`);return value.trim()};
const integer=(value,name,min,max)=>{if(!Number.isSafeInteger(value)||value<min||value>max)throw Error(`راجع ${name}`);return value};
const csvFields=[
 ['product_key','مفتاح_المنتج'],['title','اسم_المنتج'],['kind','النوع'],['category','القسم'],['description','الوصف'],['emoji','الرمز'],['image_url','رابط_الصورة'],
 ['sellable_key','مفتاح_الحجم'],['size_label','وصف_الحجم'],['sale_unit','وحدة_البيع'],['price_sar','السعر_بالريال'],['weight_under_percent','نسبة_النقص'],['weight_over_percent','نسبة_الزيادة'],
 ['stock_id','معرف_المخزون'],['base_qty','كمية_المكون'],['list_price_sar','قيمة_المكون_بالريال']
];
const csvEscape=value=>{const text=String(value??'');return /[",\r\n]/.test(text)?`"${text.replace(/"/g,'""')}"`:text};

function csvRows(text){
 if(typeof text!=='string'||text.includes('\0'))throw Error('ملف CSV غير صالح');
 const rows=[];let row=[],cell='',quoted=false,afterQuote=false;
 for(let i=0;i<text.length;i++){
  const char=text[i];
  if(quoted){if(char==='"'){if(text[i+1]==='"'){cell+='"';i++}else{quoted=false;afterQuote=true}}else cell+=char;continue}
  if(afterQuote&&char!==','&&char!=='\r'&&char!=='\n')throw Error('راجع علامات الاقتباس في ملف CSV');
  if(char==='"'){if(cell)throw Error('راجع علامات الاقتباس في ملف CSV');quoted=true;continue}
  if(char===','){row.push(cell);cell='';afterQuote=false;continue}
  if(char==='\r'||char==='\n'){if(char==='\r'&&text[i+1]==='\n')i++;row.push(cell);rows.push(row);row=[];cell='';afterQuote=false;continue}
  cell+=char;afterQuote=false;
 }
 if(quoted)throw Error('علامة اقتباس غير مكتملة في ملف CSV');
 if(cell||row.length){row.push(cell);rows.push(row)}
 return rows.filter(values=>values.some(value=>value.trim()));
}

export function catalogImportCsvTemplate(stock=[]){
 const lines=['\ufeff'+csvFields.map(([,arabic])=>csvEscape(arabic)).join(',')];
 lines.push(csvEscape('# صف واحد لكل مكوّن. كرر مفتاح المنتج والحجم، ويمكن ترك تفاصيلهما المكررة فارغة. الأسعار بالريال والكميات بوحدة المخزون الأساسية.'));
 lines.push(csvEscape('# الأنواع: individual | basket | sized | usage | bulk | gift — وحدات البيع: kg | piece | pack | package | basket'));
 for(const item of stock.filter(x=>x.active))lines.push(csvEscape(`# مخزون نشط: ${item.id} — ${item.name||'دون اسم'} — ${item.base_unit||'وحدة غير مسجلة'}`));
 return lines.join('\r\n')+'\r\n';
}

export function catalogImportFromCsv(text,stock=[]){
 const rows=csvRows(text);if(!rows.length)throw Error('ملف CSV فارغ');
 const aliases=new Map(csvFields.flatMap(([canonical,arabic])=>[[canonical,canonical],[arabic,canonical]]));
 const header=rows.shift().map((value,index)=>index?value.trim():value.replace(/^\ufeff/,'').trim()).map(value=>aliases.get(value));
 if(header.some(value=>!value)||new Set(header).size!==header.length||header.length!==csvFields.length||csvFields.some(([name])=>!header.includes(name)))throw Error('استخدم أعمدة نموذج CSV كما هي دون حذف أو تكرار');
 const index=Object.fromEntries(header.map((name,i)=>[name,i])),products=[],productByKey=new Map(),offeringByKey=new Map();
 const read=(row,name)=>String(row[index[name]]??'').trim();
 const requireValue=(row,name,label)=>textValue(read(row,name),label,1,10000);
 const same=(incoming,current,label,convert=value=>value)=>{if(incoming==='')return;const value=convert(incoming);if(value!==current)throw Error(`تفاصيل ${label} غير متطابقة في الصفوف المكررة`)};
 for(let rowIndex=0;rowIndex<rows.length;rowIndex++){
  const row=rows[rowIndex];if(read(row,'product_key').startsWith('#'))continue;
  if(row.length>header.length||row.slice(header.length).some(value=>value.trim()))throw Error(`يوجد عمود زائد في صف البيانات ${rowIndex+2}`);
  const productKey=requireValue(row,'product_key',`مفتاح المنتج في الصف ${rowIndex+2}`);if(!/^[a-z0-9][a-z0-9_-]{0,39}$/.test(productKey))throw Error(`مفتاح المنتج غير صالح في الصف ${rowIndex+2}`);
  let product=productByKey.get(productKey);
  if(!product){
   product={title:requireValue(row,'title',`اسم المنتج في الصف ${rowIndex+2}`),kind:requireValue(row,'kind',`نوع المنتج في الصف ${rowIndex+2}`),category:requireValue(row,'category',`قسم المنتج في الصف ${rowIndex+2}`),description:read(row,'description'),emoji:read(row,'emoji'),image_url:read(row,'image_url'),offerings:[]};
   productByKey.set(productKey,product);products.push(product);
  }else{
   same(read(row,'title'),product.title,'اسم المنتج');same(read(row,'kind'),product.kind,'نوع المنتج');same(read(row,'category'),product.category,'قسم المنتج');same(read(row,'description'),product.description,'وصف المنتج');same(read(row,'emoji'),product.emoji,'رمز المنتج');same(read(row,'image_url'),product.image_url,'رابط الصورة');
  }
  const sellableKey=requireValue(row,'sellable_key',`مفتاح الحجم في الصف ${rowIndex+2}`),compound=productKey+'\0'+sellableKey;
  let offering=offeringByKey.get(compound);
  if(!offering){
   offering={sellable_key:sellableKey,size_label:requireValue(row,'size_label',`وصف الحجم في الصف ${rowIndex+2}`),sale_unit:requireValue(row,'sale_unit',`وحدة البيع في الصف ${rowIndex+2}`),price_halalas:moneyValue(requireValue(row,'price_sar',`السعر في الصف ${rowIndex+2}`)),weight_under_bps:read(row,'weight_under_percent')===''?10000:moneyValue(read(row,'weight_under_percent')),weight_over_bps:read(row,'weight_over_percent')===''?0:moneyValue(read(row,'weight_over_percent')),components:[]};
   offeringByKey.set(compound,offering);product.offerings.push(offering);
  }else{
   same(read(row,'size_label'),offering.size_label,'وصف الحجم');same(read(row,'sale_unit'),offering.sale_unit,'وحدة البيع');same(read(row,'price_sar'),offering.price_halalas,'السعر',moneyValue);same(read(row,'weight_under_percent'),offering.weight_under_bps,'نسبة النقص',moneyValue);same(read(row,'weight_over_percent'),offering.weight_over_bps,'نسبة الزيادة',moneyValue);
  }
  offering.components.push({stock_id:requireValue(row,'stock_id',`معرّف المخزون في الصف ${rowIndex+2}`),base_qty:integerValue(requireValue(row,'base_qty',`كمية المكوّن في الصف ${rowIndex+2}`),{min:1,max:1000000000,label:'كمية المكوّن'}),list_price_halalas:read(row,'list_price_sar')===''?0:moneyValue(read(row,'list_price_sar'))});
 }
 return validateCatalogImport({schema_version:1,products},stock);
}

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
