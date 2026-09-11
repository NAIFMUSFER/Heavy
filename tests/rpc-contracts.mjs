import fs from 'node:fs';
import assert from 'node:assert/strict';
if(process.env.JANA_TEST_DATABASE!=='disposable')throw Error('RPC schema contracts require disposable PostgreSQL');
const schema=JSON.parse(fs.readFileSync('evidence/local/rpc-schema.json','utf8'));
let handler;globalThis.Deno={env:{get:k=>k==='SUPABASE_URL'?'https://jjdsajiwoqanefmnikls.supabase.co':'fixture-only-key'},serve:f=>{handler=f}};
await import('../supabase/functions/jana-ops-extra/index.ts');
let calls=0;
globalThis.fetch=async(url,init)=>{
 const name=new URL(url).pathname.split('/').at(-1),body=JSON.parse(init.body),keys=Object.keys(body);
 const candidates=schema.filter(x=>x.name===name);
 assert.ok(candidates.some(x=>keys.every(k=>x.args.includes(k))&&x.required.every(k=>keys.includes(k))),`RPC ${name} does not accept supplied arguments: ${keys.join(', ')}`);
 calls++;return Response.json({id:'fixture-response'});
};
const cases=[
 ['GET','/pickup-sites?limit=50'],['POST','/pickup-sites',{supplier_id:'fixture',name:'Fixture shop',active:false,reason:'Fixture site'}],['PATCH','/pickup-sites/pup-11111111111111111111111111111111',{revision:1,city:'Fixture city',reason:'Fixture update'}],
 ['GET','/supplier-credits'],['POST','/disposals/11111111-1111-4111-8111-111111111111/supplier-credits',{amount_halalas:100,reference:'Fixture credit note',note:'Fixture supplier reconciliation'}],
 ['GET','/customer-returns/11111111-1111-1111-1111-111111111111/dispositions'],['POST','/customer-returns/11111111-1111-1111-1111-111111111111/dispositions',{kind:'destroyed',quantity_base:1,reference:'Fixture disposal',note:'Fixture actual disposal',recipient:null}],
 ['GET','/customer-returns'],['GET','/customer-returns/context?number=JANA-fixture'],['POST','/customer-returns',{source_movement_id:'fixture-movement',quantity_base:10,reference:'Fixture document',reason:'Fixture actual return'}],['POST','/customer-returns/11111111-1111-1111-1111-111111111111/inspection',{accepted_base:5,note:'Fixture inspected'}],
 ['GET','/notification-jobs'],['GET','/movements?reason=waste'],['GET','/disposals'],['GET','/lots/fixture/disposal'],['POST','/lots/fixture/disposal',{kind:'waste',quantity_base:1,revision:0,reason:'Fixture disposal',reference:'Fixture document'}],
 ['GET','/counts'],['POST','/counts',{location:'Fixture shelf',lot_ids:['fixture-lot']}],['POST','/counts/fixture/submit',{counts:[],note:'Fixture count'}],['POST','/counts/fixture/cancel',{reason:'Fixture cancellation'}],['POST','/count-lines/fixture/decision',{approve:true,reason:'Fixture approval'}],['PATCH','/stock/fixture',{reorder_base:500}],['PATCH','/suppliers/fixture',{notes:'Fixture supplier'}],
 ['POST','/products',{title:'Fixture product',offerings:[]}],['POST','/products/import',{schema_version:1,products:[]}],['POST','/stock/import',{schema_version:1,items:[]}],['POST','/product-versions/11111111-1111-1111-1111-111111111111/activate'],
 ['GET','/finance'],['POST','/orders/fixture/refunds',{amount_halalas:100,reason:'Fixture refund',reference:'Fixture paid',payment_source:'finance'}],['POST','/refunds/fixture/complete',{reference:'Fixture paid',payment_source:'finance'}],['POST','/refunds/fixture/reject',{reason:'Fixture rejected'}],
 ['PATCH','/zones/fixture',{revision:1,reason:'Fixture change',active:false,warehouse_id:'fixture-warehouse'}],['PATCH','/slots/fixture',{revision:1,reason:'Fixture change',capacity:2}],['POST','/warehouses',{name:'Fixture warehouse',city:'Fixture city',address_line:'Fixture address',latitude:16.5,longitude:42.5,active:false,reason:'Fixture setup'}],['PATCH','/warehouses/fixture',{revision:1,name:'Fixture warehouse updated',reason:'Fixture change'}],['GET','/catalog'],['POST','/suppliers',{name:'Fixture supplier',phone:''}],
 ['POST','/bins',{warehouse_id:'fixture-warehouse',code:'A-01',label:'Fixture',active:false,reason:'Fixture bin'}],['PATCH','/bins/fixture',{revision:1,code:'A-02',reason:'Fixture bin change'}],['POST','/stock/fixture/bin',{bin_id:'fixture-bin',reason:'Fixture assignment'}],
 ['POST','/coupons',{code:'FIXTURE',amount_halalas:500,minimum_halalas:0,max_uses:1,expires_at:4102444800000}],
 ['POST','/slots',{zone_id:'fixture-zone',starts_at:4102444800000,ends_at:4102448400000,cutoff_at:4102441200000,capacity:1}],
 ['POST','/stock',{name:'Fixture stock',base_unit:'gram'}],
 ['POST','/lots',{stock_id:'fixture-stock',received_base:1000,total_cost_halalas:null,expires_at:4102444800000}],
 ['POST','/lots/fixture/inspect',{state:'accepted',note:'Fixture'}],
 ['POST','/lots/fixture/adjust',{new_on_hand:500,reason:'Fixture count'}],
 ['POST','/families/fixture/versions',{price_halalas:2000}],
 ['POST','/zones',{name:'Fixture zone',polygon:{type:'Polygon',coordinates:[]},fee_halalas:0,minimum_halalas:0}],
 ['PATCH','/offerings/fixture/active',{active:false}],['PATCH','/coupons/fixture/active',{active:false}],['PATCH','/slots/fixture/active',{active:false}],
 ['POST','/orders/fixture/collect',{amount_halalas:2000}],['POST','/orders/fixture/settle',{reference:'Fixture deposit'}]
];
for(const [method,path,body] of cases){
 const before=calls;const r=await handler(new Request('https://edge.example/jana-ops-extra/api/ops'+path,{method,headers:{authorization:'Bearer fixture-session','content-type':'application/json','idempotency-key':'contract-fixture-key'},...(body?{body:JSON.stringify(body)}:{})}));
 assert.ok(r.ok,`${method} ${path} returned ${r.status}`);assert.equal(calls,before+1,`${path} must resolve exactly one verified RPC`);
}
console.log(JSON.stringify({passed:cases.length,contract_source:'restored PostgreSQL pg_proc',scope:'operations Edge RPC argument signatures'}));
await import('../supabase/functions/jana-api/index.ts');
const pickingCases=[['GET','/api/ops/orders/fixture/picking'],['POST','/api/ops/orders/fixture/actual',{line_id:'line',actual_base:900}],['POST','/api/ops/orders/fixture/substitution',{line_id:'line',offering_id:'offering',qty:1}],['POST','/api/ops/orders/fixture/unavailable',{line_id:'line',reason:'Fixture reason'}],['POST','/api/ops/orders/fixture/restore',{line_id:'line',reason:'Verified fixture'}],['POST','/api/ops/orders/fixture/finalize',{}],['POST','/api/ops/orders/fixture/ready',{}],['POST','/api/substitutions/fixture/decision',{accept:true}]];
for(const [method,path,body] of pickingCases){const before=calls;const r=await handler(new Request('https://edge.example/jana-api'+path,{method,headers:{authorization:'Bearer fixture-session','content-type':'application/json','idempotency-key':'contract-fixture-key'},...(body?{body:JSON.stringify(body)}:{})}));assert.ok(r.ok,`${path}: ${r.status}`);assert.equal(calls,before+1)}
console.log(JSON.stringify({passed:pickingCases.length,contract_source:'restored PostgreSQL pg_proc',scope:'picker and customer consent RPC signatures'}));
const staffCases=[['POST','/api/ops/orders/fixture/components',{line_id:'fixture-line',revision:1,items:[{stock_id:'one',actual_base:1000},{stock_id:'two',actual_base:3}]}],['GET','/api/ops/customers'],['GET','/api/ops/customers/fixture'],['GET','/api/ops/staff'],['GET','/api/ops/audit'],['POST','/api/ops/staff',{email:'fixture@example.invalid',name:'Fixture staff',password:'Fixture-only-password',role:'inventory'}],['PATCH','/api/ops/staff/fixture',{active:false,reason:'Fixture change'}],['POST','/api/ops/orders/fixture/assignment',{picker_id:'fixture-picker',reason:'Fixture assignment'}]];
for(const [method,path,body] of staffCases){const before=calls;const r=await handler(new Request('https://edge.example/jana-api'+path,{method,headers:{authorization:'Bearer fixture-session','content-type':'application/json','idempotency-key':'staff-contract-key'},...(body?{body:JSON.stringify(body)}:{})}));assert.ok(r.ok,`${path}: ${r.status}`);assert.equal(calls,before+1)}
console.log(JSON.stringify({passed:staffCases.length,contract_source:'restored PostgreSQL pg_proc',scope:'staff assignment and audit RPC signatures'}));
const savedCases=[['GET','/api/cart'],['PUT','/api/cart',{revision:0,items:[]}],['GET','/api/catalog?offset=0&limit=25&q=fruit'],['GET','/api/shopping-lists'],['POST','/api/shopping-lists',{name:'Fixture list',items:[]}],['PATCH','/api/shopping-lists/fixture',{revision:1,name:'Renamed'}],['DELETE','/api/shopping-lists/fixture',{revision:1}],['GET','/api/recurring'],['POST','/api/recurring',{name:'Fixture plan',cadence:'weekly',items:[],next_at:4102444800000}],['PATCH','/api/recurring/fixture',{revision:1,state:'paused'}],['GET','/api/profile'],['PATCH','/api/profile',{name:'Fixture customer'}]];
for(const [method,path,body] of savedCases){const before=calls;const r=await handler(new Request('https://edge.example/jana-api'+path,{method,headers:{authorization:'Bearer fixture-session','content-type':'application/json','idempotency-key':'saved-contract-key'},...(body?{body:JSON.stringify(body)}:{})}));assert.ok(r.ok,`${path}: ${r.status}`);assert.equal(calls,before+1)}
console.log(JSON.stringify({passed:savedCases.length,contract_source:'restored PostgreSQL pg_proc',scope:'customer saved-data RPC signatures'}));
const storeCases=[['GET','/api/storefront'],['GET','/api/storefront?version=11111111-1111-1111-1111-111111111111'],['GET','/api/ops/storefront'],['POST','/api/ops/storefront/draft',{revision:0,profile:{}}],['POST','/api/ops/storefront/publish',{revision:1,confirmed:true}],['POST','/api/ops/storefront/intake',{revision:2,accepting_orders:false,message:'Fixture closed',reason:'Fixture reason'}]];
for(const [method,path,body] of storeCases){const before=calls;const r=await handler(new Request('https://edge.example/jana-api'+path,{method,headers:{authorization:'Bearer fixture-session','content-type':'application/json','idempotency-key':'store-contract-key'},...(body?{body:JSON.stringify(body)}:{})}));assert.ok(r.ok,`${path}: ${r.status}`);assert.equal(calls,before+1)}
console.log(JSON.stringify({passed:storeCases.length,contract_source:'restored PostgreSQL pg_proc',scope:'published store and admin launch RPC signatures'}));

const journeyCases=[['GET','/api/ops/orders?limit=25&before_at=1800000000000&before_id=fixture'],['GET','/api/ops/orders?limit=100&offset=100'],['POST','/api/ops/orders/fixture/location',{latitude:16.5,longitude:42.5,accuracy_m:15}],['GET','/api/orders?limit=25&before_at=1800000000000&before_id=fixture'],['GET','/api/orders/fixture/tracking'],['POST','/api/auth/password',{current_password:'fixture-current-password',new_password:'fixture-new-password'}]];
for(const [method,path,body] of journeyCases){const before=calls;const r=await handler(new Request('https://edge.example/jana-api'+path,{method,headers:{authorization:'Bearer fixture-session','content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})}));assert.ok(r.ok,`${path}: ${r.status}`);assert.equal(calls,before+1)}
console.log(JSON.stringify({passed:journeyCases.length,contract_source:'restored PostgreSQL pg_proc',scope:'customer order pagination tracking and password RPC signatures'}));
