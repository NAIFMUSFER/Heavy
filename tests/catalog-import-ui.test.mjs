import test from 'node:test';
import assert from 'node:assert/strict';
import {catalogImportCsvTemplate,catalogImportFromCsv,catalogImportTemplate,validateCatalogImport} from '../assets/catalog-import.js';
const stock=[{id:'stock-apples',name:'تفاح، أحمر',base_unit:'gram',active:true},{id:'stock-box',name:'صندوق',base_unit:'piece',active:true},{id:'stock-disabled',active:false}];
const product=(title='تفاح أحمر')=>({title,kind:'sized',category:'fruit',description:'',emoji:'🍎',image_url:'https://images.example.invalid/apple.jpg',offerings:[{sellable_key:'one-kg',size_label:'1 كجم',sale_unit:'kg',price_halalas:1295,components:[{stock_id:'stock-apples',base_qty:1000,list_price_halalas:900}]}]});
test('catalog template is explicitly empty and only demonstrates the current active stock identity',()=>{const x=catalogImportTemplate(stock);assert.equal(x.products.length,0);assert.equal(x._example.offerings[0].components[0].stock_id,'stock-apples')});
test('catalog file is normalized to server fields and summarized without activating products',()=>{const x=validateCatalogImport({schema_version:1,products:[product()]},stock);assert.deepEqual(x.summary,{products:1,offerings:1,components:1});assert.equal(x.products[0].offerings[0].weight_under_bps,10000);assert.equal(x.products[0].offerings[0].weight_over_bps,0);assert.equal(Object.hasOwn(x.products[0],'active'),false)});
test('catalog validation rejects unknown stock duplicate titles duplicate components and unsafe images',()=>{
 const samples=[];let x=product();x.offerings[0].components[0].stock_id='stock-disabled';samples.push(x);
 samples.push([product('منتج مكرر'),product('  منتج   مكرر  ')]);
 x=product();x.offerings[0].components.push({...x.offerings[0].components[0]});samples.push(x);
 x=product();x.image_url='http://images.example.invalid/a.jpg';samples.push(x);
 for(const sample of samples)assert.throws(()=>validateCatalogImport({schema_version:1,products:Array.isArray(sample)?sample:[sample]},stock));
});
test('Excel CSV template is BOM-safe, empty of products and lists only active stock as comments',()=>{
 const template=catalogImportCsvTemplate(stock);assert.equal(template.charCodeAt(0),0xfeff);assert.match(template,/مفتاح_المنتج/);assert.match(template,/stock-apples/);assert.match(template,/تفاح، أحمر/);assert.match(template,/stock-box/);assert.doesNotMatch(template,/stock-disabled/);assert.throws(()=>catalogImportFromCsv(template,stock),/1 إلى 50/);
});
test('CSV groups repeated product and offering rows and converts Arabic riyal values exactly',()=>{
 const header=catalogImportCsvTemplate(stock).split('\r\n')[0];
 const rows=[
  ['basket-one','سلة "العائلة"','basket','baskets','وصف، مع فاصلة\nوسطر جديد','🧺','','family','سلة عائلية','basket','١٢٫٩٥','','','stock-apples','١٠٠٠','٩٫٠٠'],
  ['basket-one','','','','','','','family','','','','','','stock-box','٢','٠٫٥٠']
 ];
 const csv=[header,...rows.map(row=>row.map(value=>/[",\n]/.test(value)?`"${value.replace(/"/g,'""')}"`:value).join(','))].join('\r\n');
 const result=catalogImportFromCsv(csv,stock);assert.deepEqual(result.summary,{products:1,offerings:1,components:2});assert.equal(result.products[0].title,'سلة "العائلة"');assert.equal(result.products[0].description,'وصف، مع فاصلة\nوسطر جديد');assert.equal(result.products[0].offerings[0].price_halalas,1295);assert.equal(result.products[0].offerings[0].components[1].list_price_halalas,50);assert.equal(Object.hasOwn(result.products[0],'active'),false);
});
test('CSV rejects changed repeated terms, duplicate components, unsafe headers and broken quotes',()=>{
 const header=catalogImportCsvTemplate(stock).split('\r\n')[0],base=['apple','تفاح','sized','fruit','','','','one','1 كجم','kg','10','','','stock-apples','1000',''];
 const line=values=>values.join(',');
 const changed=[...base];changed[1]='موز';
 assert.throws(()=>catalogImportFromCsv([header,line(base),line(changed)].join('\n'),stock),/غير متطابقة/);
 const duplicate=[...base];duplicate[1]='';duplicate[2]='';duplicate[3]='';duplicate[8]='';duplicate[9]='';duplicate[10]='';
 assert.throws(()=>catalogImportFromCsv([header,line(base),line(duplicate)].join('\n'),stock),/مكرر/);
 assert.throws(()=>catalogImportFromCsv(header.replace('مفتاح_المنتج','عمود_مجهول')+'\n'+line(base),stock),/أعمدة نموذج/);
 assert.throws(()=>catalogImportFromCsv(header+'\n"apple,'+line(base.slice(1)),stock),/اقتباس/);
});
