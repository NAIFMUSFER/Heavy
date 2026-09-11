import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const common=await import('../assets/common.js');
const bundle=[1,2,3,4].map(n=>readFileSync(new URL(`../assets/ops.part0${n}.js`,import.meta.url),'utf8')).join('\n').replace(/^import .*?;\n/,'');
async function fixture(items){
 const line={line_id:'line-fixture',name:'سلة',qty:2,components:[{stock_id:'grams',name:'تفاح <واحد>',base_qty:1000,base_unit:'gram'},{stock_id:'pieces',name:'عبوة & اثنان',base_qty:3,base_unit:'piece'}],...(items?{component_check:{items}}:{})};
 const form={dataset:{components:line.line_id},elements:{measured:{checked:false}}};
 const h={html:'',calls:[],input:{component_0:'2000',component_1:'6'},form,line};
 const order={id:'order-fixture',number:'JN-Fixture',total_halalas:4000,picking_revision:7,fulfillment_state:'picking',snapshot:{lines:[line]},issues:[]};
 const context=vm.createContext({...common,document:{body:{dataset:{workspace:'admin'}},addEventListener(){}},
  $:()=>({}),$$:s=>s==='form[data-components]'?[form]:[],setupConnectivity(){},identity:()=>new Promise(()=>{}),
  modal:(title,html)=>{h.html=html;return {}},get:async()=>order,post:async(path,body)=>{h.calls.push({path,body:JSON.parse(JSON.stringify(body))});return {}},
  busy:async(b,fn)=>fn(),formData:()=>h.input,toast(){}});
 vm.runInContext(bundle,context);await vm.runInContext("pickDialog({id:'order-fixture'})",context);return h;
}
test('basket preparation starts with blank actual quantities and requires explicit physical measurement',async()=>{
 const h=await fixture();assert.match(h.html,/data-finalize="order-fixture" disabled/);
 assert.doesNotMatch(h.html,/name="component_[01]"[^>]*value=/);assert.match(h.html,/name="measured" required/);
 assert.match(h.html,/تفاح &lt;واحد&gt;/);assert.match(h.html,/عبوة &amp; اثنان/);
 await h.form.onsubmit({preventDefault(){}});assert.equal(h.calls.length,0);
 h.form.elements.measured.checked=true;await h.form.onsubmit({preventDefault(){}});
 assert.deepEqual(h.calls,[{path:'/api/ops/orders/order-fixture/components',body:{line_id:'line-fixture',revision:7,items:[{stock_id:'grams',actual_base:2000},{stock_id:'pieces',actual_base:6}]}}]);
});
test('blank fractional negative and excessive quantities cannot become recorded component evidence',async()=>{
 const h=await fixture();h.form.elements.measured.checked=true;
 for(const value of ['', ' ', '1.5','-1','20000000001']){h.input.component_0=value;await h.form.onsubmit({preventDefault(){}})}
 assert.equal(h.calls.length,0);h.input.component_0='0';await h.form.onsubmit({preventDefault(){}});assert.equal(h.calls[0].body.items[0].actual_base,0);
});
test('missing component or gram and piece variance keeps finishing disabled without aggregating different units',async()=>{
 for(const items of [[{stock_id:'grams',actual_base:2000}],[{stock_id:'grams',actual_base:1999},{stock_id:'pieces',actual_base:6}],[{stock_id:'grams',actual_base:2000},{stock_id:'pieces',actual_base:7}]]){
  const h=await fixture(items);assert.match(h.html,/data-finalize="order-fixture" disabled/);assert.match(h.html,/يوجد فرق/);
 }
});
test('complete measurements enable finishing while preserving the saved component values',async()=>{
 const h=await fixture([{stock_id:'grams',actual_base:2000},{stock_id:'pieces',actual_base:6}]);
 assert.doesNotMatch(h.html,/data-finalize="order-fixture" disabled/);assert.match(h.html,/تم تسجيل جميع المكونات/);
 assert.match(h.html,/name="component_0"[^>]*value="2000"/);assert.match(h.html,/name="component_1"[^>]*value="6"/);
});
