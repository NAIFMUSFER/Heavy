import test from 'node:test';
import assert from 'node:assert/strict';
import {stockImportCsvTemplate,stockImportFromCsv,stockImportTemplate,validateStockImport} from '../assets/stock-import.js';

test('stock templates are empty and explain that imported definitions have no balance',()=>{
 const json=stockImportTemplate(),csv=stockImportCsvTemplate();assert.deepEqual(json.items,[]);assert.equal(csv.charCodeAt(0),0xfeff);assert.match(csv,/اسم_الصنف/);assert.match(csv,/أرصدة صفرية/);assert.throws(()=>stockImportFromCsv(csv),/1 إلى 200/);
});

test('Arabic Excel quantities become canonical inactive stock definition fields',()=>{
 const header=stockImportCsvTemplate().split('\r\n')[0];
 const csv=header+'\r\n'+['تفاح أحمر','Red apples','فاكهة','gram','١٥٠٠'].join(',')+'\r\n'+['صندوق','Box','','piece',''].join(',');
 const result=stockImportFromCsv(csv);assert.deepEqual(result.summary,{items:2,gram:1,piece:1});assert.equal(result.items[0].reorder_base,1500);assert.equal(result.items[1].reorder_base,null);for(const item of result.items){assert.equal(Object.hasOwn(item,'active'),false);assert.equal(Object.hasOwn(item,'on_hand_base'),false)}
});

test('stock validation rejects duplicate names, write fields, invalid units and fractional thresholds',()=>{
 const base={schema_version:1,items:[{name:'تفاح أحمر',name_en:'',category:'فاكهة',base_unit:'gram',reorder_base:null}]};
 assert.throws(()=>validateStockImport({...base,items:[base.items[0],{...base.items[0],name:'  تفاح   أحمر  '}]}),/مكرر/);
 for(const changed of [{...base.items[0],active:true},{...base.items[0],on_hand_base:10},{...base.items[0],base_unit:'kg'},{...base.items[0],reorder_base:'١٫٥'}])assert.throws(()=>validateStockImport({...base,items:[changed]}));
});

test('stock CSV accepts quoted names and rejects changed or malformed columns',()=>{
 const header=stockImportCsvTemplate().split('\r\n')[0],line='"تفاح، أحمر",Red apple,فاكهة,gram,1000';
 assert.equal(stockImportFromCsv(header+'\n'+line).items[0].name,'تفاح، أحمر');
 assert.throws(()=>stockImportFromCsv(header.replace('اسم_الصنف','اسم_مجهول')+'\n'+line),/أعمدة نموذج/);
 assert.throws(()=>stockImportFromCsv(header+'\n"تفاح,Red apple,فاكهة,gram,1000'),/اقتباس/);
});
