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
 ['POST','/products',{title:'Fixture product',offerings:[]}],['POST','/product-versions/11111111-1111-1111-1111-111111111111/activate'],
 ['GET','/finance'],['POST','/orders/fixture/refunds',{amount_halalas:100,reason:'Fixture refund',reference:'Fixture paid',payment_source:'finance'}],['POST','/refunds/fixture/complete',{reference:'Fixture paid',payment_source:'finance'}],['POST','/refunds/fixture/reject',{reason:'Fixture rejected'}],
 ['GET','/catalog'],['POST','/suppliers',{name:'Fixture supplier',phone:''}],
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
