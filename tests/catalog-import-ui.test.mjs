import test from 'node:test';
import assert from 'node:assert/strict';
import {catalogImportTemplate,validateCatalogImport} from '../assets/catalog-import.js';
const stock=[{id:'stock-apples',active:true},{id:'stock-disabled',active:false}];
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
