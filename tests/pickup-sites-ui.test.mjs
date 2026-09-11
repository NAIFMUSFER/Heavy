import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import * as common from '../assets/common.js';
import {orderLinks} from '../assets/order.js';
const bundle=[1,2,3,4].map(n=>fs.readFileSync('assets/ops.part0'+n+'.js','utf8')).join('\n').replace(/^import .*?;\n/,'');
function harness(role='picker',reader=async()=>({items:[],suppliers:[],can_manage:false})){
 const root={innerHTML:''},paths=[],nodes={},context=vm.createContext({...common,orderLinks,URLSearchParams,document:{body:{dataset:{workspace:role==='picker'?'picker':'admin'}},addEventListener(){}},location:{hash:'#pickup-sites'},history:{replaceState(){},pushState(){}},addEventListener(){},$:s=>s==='#ops-app'?root:(nodes[s]??={}),$$:()=>[],identity:()=>new Promise(()=>{}),setupConnectivity(){},get:async p=>{paths.push(p);return reader(p)}});
 vm.runInContext(bundle,context);vm.runInContext('state.user='+JSON.stringify({id:'fixture',role,name:'Fixture'}),context);
 return {context,root,paths,run:code=>vm.runInContext(code,context)};
}
test('picker directory is read-only and cannot imply stock or order-flow readiness',async()=>{
 const h=harness();await h.run('setInitialOpsPage();render()');assert.equal(h.paths[0],'/api/ops/pickup-sites?limit=50');assert.match(h.root.innerHTML,/جنى بدون مستودعات/);assert.match(h.root.innerHTML,/لا توجد نقاط استلام/);assert.doesNotMatch(h.root.innerHTML,/id="new-pickup-site"/);
});
test('only active supplier sites expose explicit safe navigation and phone actions',async()=>{
 const item={id:'pup-'+'1'.repeat(32),name:'Fixture shop',supplier_name:'Supplier',city:'City',address_line:'Address',latitude:16.5,longitude:42.5,supplier_phone:'+966500000001',active:true,supplier_active:true};
 const h=harness('picker',async()=>({items:[item],can_manage:false}));await h.run('setInitialOpsPage();render()');assert.match(h.root.innerHTML,/data-pickup-directions/);assert.match(h.root.innerHTML,/tel:\+966500000001/);assert.match(h.root.innerHTML,/rel="noopener noreferrer"/);
 item.supplier_active=false;await h.run('render()');assert.doesNotMatch(h.root.innerHTML,/data-pickup-directions|data-pickup-phone/);
});
test('directory ignores responses from departed sessions and preserves prior page on read failure',async()=>{
 let resolve;const h=harness('inventory',()=>new Promise(r=>{resolve=r}));h.run('setInitialOpsPage()');const pending=h.run('render()');h.run("state.user=null;root.innerHTML='Signed out'");resolve({items:[]});await pending;assert.equal(h.root.innerHTML,'Signed out');
 const failed=harness('picker',async()=>{throw Error('Read failed')});failed.run("setInitialOpsPage();root.innerHTML='Previous directory'");await assert.rejects(failed.run('render()'),/Read failed/);assert.equal(failed.root.innerHTML,'Previous directory');
});
test('coordinate entry supports Arabic digits without silently turning blanks into zero',()=>{
 const h=harness();assert.equal(h.run("pickupCoordinate('١٦٫٥')"),16.5);assert.equal(h.run("pickupCoordinate('')"),null);assert.equal(h.run("pickupCoordinate('-٤٢٫٥')"),-42.5);assert.throws(()=>h.run("pickupCoordinate('16,5')"));
});
