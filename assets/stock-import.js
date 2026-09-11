import {integerValue} from './input.js';

const units=new Set(['gram','piece']);
const fields=[['name','اسم_الصنف'],['name_en','الاسم_بالإنجليزية'],['category','التصنيف'],['base_unit','وحدة_الأساس'],['reorder_base','حد_إعادة_الطلب']];
const csvEscape=value=>{const text=String(value??'');return /[",\r\n]/.test(text)?`"${text.replace(/"/g,'""')}"`:text};
const cleanText=(value,label,min,max,{optional=false}={})=>{
 if(value==null&&optional)return '';
 if(typeof value!=='string')throw Error(`راجع ${label}`);
 const text=value.trim();if((!optional&&text.length<min)||text.length>max)throw Error(`راجع ${label}`);return text;
};
function rows(text){
 if(typeof text!=='string'||text.includes('\0'))throw Error('ملف CSV غير صالح');
 const output=[];let row=[],cell='',quoted=false,afterQuote=false;
 for(let i=0;i<text.length;i++){
  const char=text[i];
  if(quoted){if(char==='"'){if(text[i+1]==='"'){cell+='"';i++}else{quoted=false;afterQuote=true}}else cell+=char;continue}
  if(afterQuote&&char!==','&&char!=='\r'&&char!=='\n')throw Error('راجع علامات الاقتباس في ملف CSV');
  if(char==='"'){if(cell)throw Error('راجع علامات الاقتباس في ملف CSV');quoted=true;continue}
  if(char===','){row.push(cell);cell='';afterQuote=false;continue}
  if(char==='\r'||char==='\n'){if(char==='\r'&&text[i+1]==='\n')i++;row.push(cell);output.push(row);row=[];cell='';afterQuote=false;continue}
  cell+=char;afterQuote=false;
 }
 if(quoted)throw Error('علامة اقتباس غير مكتملة في ملف CSV');
 if(cell||row.length){row.push(cell);output.push(row)}
 return output.filter(values=>values.some(value=>value.trim()));
}

export function stockImportCsvTemplate(){
 return '\ufeff'+fields.map(([,arabic])=>arabic).join(',')+'\r\n'+
  csvEscape('# وحدة الأساس: gram للجرام أو piece للقطعة. اترك حد إعادة الطلب فارغًا إذا لم تعتمد المنشأة حدًا بعد. الاستيراد ينشئ تعريفات متوقفة بأرصدة صفرية.')+'\r\n';
}

export function stockImportTemplate(){
 return {schema_version:1,items:[],_example:{name:'استبدل باسم الصنف',name_en:'',category:'',base_unit:'gram',reorder_base:null}};
}

export function validateStockImport(input){
 if(!input||typeof input!=='object'||Array.isArray(input)||input.schema_version!==1||!Array.isArray(input.items)||input.items.length<1||input.items.length>200)throw Error('الملف يحتاج schema_version=1 ومن 1 إلى 200 صنف مخزون');
 const names=new Set();const items=input.items.map((item,index)=>{
  if(!item||typeof item!=='object'||Array.isArray(item)||Object.hasOwn(item,'id')||Object.hasOwn(item,'active')||Object.hasOwn(item,'on_hand_base')||Object.hasOwn(item,'reserved_base'))throw Error(`راجع الصنف ${index+1}`);
  const name=cleanText(item.name,`اسم الصنف ${index+1}`,2,140),normalized=name.replace(/\s+/g,' ').toLocaleLowerCase('ar');
  if(names.has(normalized))throw Error(`اسم الصنف مكرر داخل الملف: ${name}`);names.add(normalized);
  const name_en=cleanText(item.name_en??'',`الاسم الإنجليزي للصنف ${name}`,0,140,{optional:true});
  const category=cleanText(item.category??'',`تصنيف الصنف ${name}`,0,80,{optional:true});
  if(!units.has(item.base_unit))throw Error(`راجع وحدة الأساس للصنف ${name}`);
  const reorder_base=item.reorder_base==null||item.reorder_base===''?null:integerValue(item.reorder_base,{min:0,max:9000000000000,label:`حد إعادة الطلب للصنف ${name}`});
  return {name,name_en,category,base_unit:item.base_unit,reorder_base};
 });
 return {schema_version:1,items,summary:{items:items.length,gram:items.filter(x=>x.base_unit==='gram').length,piece:items.filter(x=>x.base_unit==='piece').length}};
}

export function stockImportFromCsv(text){
 const data=rows(text);if(!data.length)throw Error('ملف CSV فارغ');
 const aliases=new Map(fields.flatMap(([canonical,arabic])=>[[canonical,canonical],[arabic,canonical]]));
 const header=data.shift().map((value,index)=>index?value.trim():value.replace(/^\ufeff/,'').trim()).map(value=>aliases.get(value));
 if(header.some(value=>!value)||new Set(header).size!==header.length||header.length!==fields.length||fields.some(([name])=>!header.includes(name)))throw Error('استخدم أعمدة نموذج CSV كما هي دون حذف أو تكرار');
 const index=Object.fromEntries(header.map((name,i)=>[name,i])),items=[];
 for(let rowIndex=0;rowIndex<data.length;rowIndex++){
  const row=data[rowIndex],read=name=>String(row[index[name]]??'').trim();if(read('name').startsWith('#'))continue;
  if(row.length>header.length||row.slice(header.length).some(value=>value.trim()))throw Error(`يوجد عمود زائد في صف البيانات ${rowIndex+2}`);
  items.push({name:read('name'),name_en:read('name_en'),category:read('category'),base_unit:read('base_unit'),reorder_base:read('reorder_base')||null});
 }
 return validateStockImport({schema_version:1,items});
}
