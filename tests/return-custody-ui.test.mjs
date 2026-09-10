import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const common=await import('data:text/javascript;base64,'+Buffer.from(readFileSync(new URL('../assets/common.js',import.meta.url),'utf8')).toString('base64'));
const bundle=[1,2,3,4].map(n=>readFileSync(new URL(`../assets/ops.part0${n}.js`,import.meta.url),'utf8')).join('\n').replace(/^import .*?;\n/,'');
const returnId='11111111-1111-1111-1111-111111111111';
async function fixture(role='inventory',remaining=40){
 const root={innerHTML:''},history={innerHTML:'',isConnected:true},dialog={open:true},recipientLabel={hidden:true};
 const form={elements:{kind:{value:''},recipient:{value:'',disabled:true,required:false},completed:{checked:false}}};
 const h={html:'',calls:[],paths:[],consent:false,input:{kind:'destroyed',quantity_base:'15',reference:'DOC-1',recipient:'',note:'Observed physical disposal'},form,history,recipientLabel};
 const context=vm.createContext({...common,URLSearchParams,document:{body:{dataset:{workspace:'admin'}},addEventListener(){}},
  $:s=>s==='#ops-app'?root:s==='#return-custody-history'?history:s==='#return-disposition-form'?form:s==='#return-recipient-label'?recipientLabel:{},$$:()=>[],
  setupConnectivity(){},identity:()=>new Promise(()=>{}),modal:(title,html)=>{h.html=html;return dialog},
  closeModal(){dialog.open=false},toast(){},busy:async(b,fn)=>fn(),formData:()=>h.input,confirm:()=>h.consent,
  get:async path=>{h.paths.push(path);if(path==='/api/ops/customer-returns')return {items:[],summary:{},next:null};return {receipt:{id:returnId,order_number:'JN-fixture',stock_name:'تفاح & موز',base_unit:'gram',lot_id:'lot-fixture',inspection_complete:true,rejected_base:40,disposed_base:40-remaining,remaining_base:remaining},items:[{id:'document-1',kind:'supplier_handover',quantity_base:1,reference:'Doc & 1',recipient:'Supplier <one>',note:'Observed & recorded',actor_name:'Warehouse',created_at:1789060000000}],next:null}},
  post:async(path,body)=>{h.calls.push({path,body:JSON.parse(JSON.stringify(body))});return {remaining_base:25}}
 });
 vm.runInContext(bundle,context);
 await vm.runInContext(`state.user={name:'Fixture',role:'${role}'};state.page='customer-returns';returnCustodyDialog('${returnId}')`,context);
 return h;
}
test('warehouse custody form requires an actual quantity and explicit completed-action confirmation',async()=>{
 const h=await fixture();assert.match(h.html,/name="quantity_base"/);assert.doesNotMatch(h.html,/name="quantity_base"[^>]*value=/);
 assert.match(h.html,/name="completed" required/);assert.doesNotMatch(h.html,/name="completed"[^>]*checked/);
 const submit=()=>h.form.onsubmit({preventDefault(){}});
 h.consent=true;await submit();assert.equal(h.calls.length,0);
 h.form.elements.completed.checked=true;h.consent=false;await submit();assert.equal(h.calls.length,0);
 h.consent=true;h.input.quantity_base='';await submit();assert.equal(h.calls.length,0);
 h.input.quantity_base='41';await submit();assert.equal(h.calls.length,0);
 h.input.quantity_base='15';await submit();assert.equal(h.calls.length,1);
 assert.deepEqual(h.calls[0],{path:'/api/ops/customer-returns/'+returnId+'/dispositions',body:{kind:'destroyed',quantity_base:15,reference:'DOC-1',recipient:null,note:'Observed physical disposal'}});
});
test('supplier handover requires a named recipient and switching to destruction clears it',async()=>{
 const h=await fixture('admin');h.form.elements.kind.value='supplier_handover';h.form.elements.kind.onchange();
 assert.equal(h.recipientLabel.hidden,false);assert.equal(h.form.elements.recipient.required,true);assert.equal(h.form.elements.recipient.disabled,false);
 h.form.elements.completed.checked=true;h.consent=true;h.input.kind='supplier_handover';
 await h.form.onsubmit({preventDefault(){}});assert.equal(h.calls.length,0);
 h.input.recipient='Supplier & receiver';await h.form.onsubmit({preventDefault(){}});assert.equal(h.calls[0].body.recipient,'Supplier & receiver');
 h.form.elements.recipient.value='old recipient';h.form.elements.kind.value='destroyed';h.form.elements.kind.onchange();
 assert.equal(h.form.elements.recipient.value,'');assert.equal(h.form.elements.recipient.disabled,true);assert.equal(h.recipientLabel.hidden,true);
});
test('finance and support see escaped custody evidence without a disposition form',async()=>{
 for(const role of ['finance','support']){
  const h=await fixture(role);assert.doesNotMatch(h.html,/id="return-disposition-form"/);assert.match(h.html,/مراجعة السجل فقط/);
  assert.match(h.history.innerHTML,/Doc &amp; 1/);assert.match(h.history.innerHTML,/Supplier &lt;one&gt;/);assert.match(h.history.innerHTML,/Observed &amp; recorded/);
 }
});
test('fully closed rejected custody has no write form even for the administrator',async()=>{
 const h=await fixture('admin',0);assert.doesNotMatch(h.html,/id="return-disposition-form"/);assert.match(h.html,/لا توجد كمية مرفوضة متبقية في العهدة/);
});
