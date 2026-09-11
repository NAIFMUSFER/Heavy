import test from 'node:test';
import assert from 'node:assert/strict';
import {catalogReviewCsv,inventoryReviewCsv} from '../assets/ops-exports.js';

const catalog={
 product_families:[{id:'family-a',name:'=صيغة خطرة'}],
 product_versions:[{id:'version-a',family_id:'family-a',version:2,state:'draft',title:'سلة، موسمية',kind:'basket',category:'baskets',description:'سطر أول\nسطر ثان',emoji:'🧺',image_url:'https://images.example.invalid/basket.jpg'}],
 offerings:[{id:'offering-a',product_version_id:'version-a',sellable_key:'family',size_label:'عائلية',sale_unit:'basket',price_halalas:1295,weight_under_bps:10000,weight_over_bps:0,active:false,components:[{stock_id:'stock-a',base_qty:1000,list_price_halalas:900}]}],
 stock:[{id:'stock-a',name:'+تفاح أحمر',base_unit:'gram',active:true,bin_code:'A-01-01',bin_label:'مبرد',bin_warehouse_id:'warehouse-a',on_hand_base:1200,reserved_base:200,available_base:1000,sellable_base:900,reorder_base:null,stock_status:'threshold_not_set'}],
 lots:[{id:'lot-a',stock_id:'stock-a',supplier_id:'supplier-a',receipt_reference:'=CMD()',received_base:1200,on_hand_base:1200,reserved_base:200,inspection_state:'accepted',expires_at:1800000000000}],
 suppliers:[{id:'supplier-a',name:'@مورد'}]
};

test('catalog review exports current immutable terms with exact SAR values and a BOM',()=>{
 const output=catalogReviewCsv(catalog);
 assert.equal(output.charCodeAt(0),0xfeff);
 assert.match(output,/عنوان_الإصدار/);
 assert.match(output,/12\.95/);
 assert.match(output,/سلة، موسمية/);
 assert.match(output,/سطر أول\nسطر ثان/);
 assert.match(output,/'=صيغة خطرة/);
 assert.match(output,/'\+تفاح أحمر/);
});

test('catalog review retains drafts without offerings and legacy unlinked offerings',()=>{
 const output=catalogReviewCsv({product_versions:[{id:'draft',title:'مسودة فقط',version:1,state:'draft'}],offerings:[{id:'legacy',size_label:'قديم',price_halalas:100,components:[]} ]});
 assert.match(output,/مسودة فقط/);
 assert.match(output,/قديم/);
});

test('inventory review includes stock and lot facts without supplier contacts or costs',()=>{
 const output=inventoryReviewCsv(catalog,1789000000000);
 assert.equal(output.charCodeAt(0),0xfeff);
 assert.match(output,/2026-09-10T00:26:40\.000Z/);
 assert.match(output,/stock-a/);
 assert.match(output,/'=CMD\(\)/);
 assert.match(output,/'@مورد/);
 assert.match(output,/A-01-01,مبرد,warehouse-a,1200,200,1000,900/);
 assert.match(output,/رمز_الموقع_المرجعي/);
 assert.doesNotMatch(output,/total_cost|تكلفة|جوال|هاتف/);
});

test('review exports leave unknown numeric values blank instead of inventing zero',()=>{
 const output=inventoryReviewCsv({stock:[{id:'stock-b',name:'صنف',base_unit:'piece',active:true}],lots:[]},0);
 assert.match(output,/stock-b,صنف,piece,نشط,,,,,,/);
 assert.doesNotMatch(output,/NaN|undefined|null/);
});
