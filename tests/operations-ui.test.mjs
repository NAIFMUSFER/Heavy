import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const common=await import('data:text/javascript;base64,'+Buffer.from(readFileSync(new URL('../assets/common.js',import.meta.url),'utf8')).toString('base64'));
const bundle=[1,2,3,4].map(n=>readFileSync(new URL(`../assets/ops.part0${n}.js`,import.meta.url),'utf8')).join('\n').replace(/^import .*?;\n/,'');
async function reportPage(report){
 const root={innerHTML:''};const paths=[];
 const context=vm.createContext({...common,document:{body:{dataset:{workspace:'admin'}},addEventListener(){}},$:()=>root,setupConnectivity(){},identity:()=>new Promise(()=>{}),get:async path=>{paths.push(path);if(path==='/api/ops/reports')return report;throw new Error('Unexpected dependency '+path)}});
 vm.runInContext(bundle,context);
 await vm.runInContext("state.user={name:'Finance fixture',role:'finance'};state.page='dashboard';render()",context);
 return {html:root.innerHTML,paths};
}
test('assembled finance page preserves unknown profit and cost completeness',async()=>{
 const r=await reportPage({cost_status:'unknown',gross_profit_7d_halalas:null,gross_margin_bps:null,orders_with_unknown_cost:2,inventory_unknown_cost_lots:3});
 assert.deepEqual(r.paths,['/api/ops/reports']);
 assert.match(r.html,/تكلفة البضاعة غير مكتملة/);
 assert.match(r.html,/الربح التقديري<\/span><strong[^>]*>غير مسجل</);
 assert.match(r.html,/هامش الربح التقديري<\/span><strong[^>]*>غير متاح</);
 assert.match(r.html,/دفعات بتكلفة مجهولة: 3/);
});
test('assembled finance page displays recorded zero and negative estimates distinctly',async()=>{
 const r=await reportPage({cost_status:'recorded',gross_profit_7d_halalas:-1250,gross_margin_bps:-500,recorded_cogs_7d_halalas:0,top_items:[{item_name:'تفاح & موز',qty:2}]});
 assert.match(r.html,/تكلفة بضاعة مسجلة<\/span><strong[^>]*>0\.00 ر\.س/);
 assert.match(r.html,/الربح التقديري<\/span><strong[^>]*>-12\.50 ر\.س/);
 assert.match(r.html,/هامش الربح التقديري<\/span><strong[^>]*>[\u200e\u061c]?-5%/);
 assert.match(r.html,/تفاح &amp; موز/);
});
