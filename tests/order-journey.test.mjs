import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {cashReceiptFacts,cashReceiptHtml,orderFacts,orderLinks,procurementProgressFacts,trackingView,orderPageUrl,appendOrderPage,passwordProblem} from '../mobile/order.mjs';

test('web and native order presentation use the same validated model',()=>{
 assert.equal(readFileSync('mobile/order.mjs','utf8'),readFileSync('assets/order.js','utf8').replace("from './address.js'","from './address.mjs'"));
});
test('partial refund does not ask the customer to pay refunded cash again',()=>{
 const f=orderFacts({status:'completed',delivery_state:'delivered',total_halalas:2000,collected_halalas:2000,refunded_halalas:500});
 assert.equal(f.due,0);assert.equal(f.refunded,500);assert.equal(f.canRefund,true);
 assert.equal(orderFacts({status:'active',total_halalas:2000,collected_halalas:0,refunded_halalas:0}).due,2000);
 assert.equal(orderFacts({}).due,null);assert.equal(orderFacts({status:'cancelled',total_halalas:2000,collected_halalas:0}).due,0);
});
test('cash receipt is downloadable only from validated collection facts and escapes frozen merchant and line text',()=>{
 const order={number:'JN-<script>',total_halalas:2000,collected_halalas:2000,refunded_halalas:100,original_snapshot:{store_profile:{display_name:'متجر <script>alert(1)</script>',legal_name:'شركة & شركاؤها',registration_type:'other_license',registration_number:'=1+1'}},snapshot:{lines:[{name:'تفاح <img src=x onerror=1>',qty:2,line_total_halalas:1800}],delivery_fee_halalas:200,discount_halalas:0},payment_receipt:{receipt_id:'cash-1',kind:'cash_collection_receipt',tax_invoice:false,payment_method:'cash_on_delivery',collected_at:1800000000000,collected_halalas:2000,refunded_halalas:100,net_collected_halalas:1900}};
 const facts=cashReceiptFacts(order),html=cashReceiptHtml(order);
 assert.equal(facts.net,1900);assert.equal(facts.refunded,100);assert.match(html,/إيصال تحصيل نقدي/);assert.match(html,/ليس فاتورة ضريبية/);assert.match(html,/&lt;script&gt;/);assert.match(html,/&lt;img/);assert.doesNotMatch(html,/<script>|<img/);
 for(const receipt of [null,{receipt_id:'cash-1',kind:'cash_collection_receipt',tax_invoice:true,payment_method:'cash_on_delivery',collected_at:1,collected_halalas:2000,refunded_halalas:0,net_collected_halalas:2000},{receipt_id:'cash-1',kind:'cash_collection_receipt',tax_invoice:false,payment_method:'cash_on_delivery',collected_at:1,collected_halalas:2000,refunded_halalas:100,net_collected_halalas:2000}])assert.equal(cashReceiptFacts({...order,payment_receipt:receipt}),null);
 assert.throws(()=>cashReceiptHtml({...order,payment_receipt:null}),/cash_receipt_unavailable/);
});
test('order address and appointment are frozen terms and cancellations match server state gates',()=>{
 const f=orderFacts({original_snapshot:{address:{details:'frozen'},slot:{starts_at:123}},snapshot:{address:{details:'edited'},slot:{starts_at:456}},status:'active',fulfillment_state:'queued',delivery_state:'unassigned'});
 assert.equal(f.address.details,'frozen');assert.equal(f.slot.starts_at,123);assert.equal(f.canCancel,true);
 for(const state of [{status:'cancelled'},{fulfillment_state:'picking'},{delivery_state:'assigned'}])assert.equal(orderFacts({status:'active',fulfillment_state:'queued',delivery_state:'unassigned',...state}).canCancel,false);
});
test('tracking labels historical points and hides ended absent invalid and future locations',()=>{
 const now=1800000000000,t={delivery_state:'out_for_delivery',latitude:16.5,longitude:42.5,updated_at:now-1000,accuracy_m:10};
 assert.ok(trackingView(t,now).map);assert.match(trackingView(t,now).message,/آخر موقع مسجل/);assert.equal(trackingView(t,now).accuracy,10);
 assert.match(trackingView({...t,updated_at:now-300001},now).message,/موقع سابق/);
 for(const patch of [{delivery_state:'delivered'},{delivery_state:'failed'},{updated_at:null},{updated_at:now+1},{latitude:null},{longitude:181}])assert.equal(trackingView({...t,...patch},now).map,'');
});
test('courier map and telephone links use a real valid destination without fallback pins',()=>{
 const links=orderLinks({latitude:'١٦٫٥',longitude:'٤٢٫٥',recipient_phone:'٠٥٠٠٠٠٠٠٠١'}),url=new URL(links.directions);
 assert.equal(url.origin,'https://www.google.com');assert.equal(url.searchParams.get('destination'),'16.5,42.5');assert.equal(links.phone,'tel:+966500000001');
 assert.deepEqual(orderLinks({latitude:'',longitude:'',recipient_phone:'bad'}),{map:'',directions:'',phone:''});
});
test('order pages keep a stable encoded cursor and deduplicate overlapping retries',()=>{
 const url=new URL(orderPageUrl({before_at:1800000000000,before_id:'id&?'}),'https://example.invalid');
 assert.equal(url.searchParams.get('before_id'),'id&?');assert.equal(url.searchParams.get('limit'),'25');assert.deepEqual(appendOrderPage([{id:'a'}],[{id:'a'},{id:'b'},{id:'b'},{id:'c'}]).map(x=>x.id),['a','b','c']);
});
test('password form checks confirmation and the database UTF-8 bcrypt boundary including Arabic and emoji',()=>{
 assert.equal(passwordProblem('current','ع'.repeat(36),'ع'.repeat(36)),'');assert.match(passwordProblem('current','ع'.repeat(37),'ع'.repeat(37)),/72/);
 assert.equal(passwordProblem('current','😀'.repeat(18),'😀'.repeat(18)),'');assert.match(passwordProblem('current','😀'.repeat(19),'😀'.repeat(19)),/72/);
 assert.match(passwordProblem('current','abcdef123456','different'),/يطابق/);assert.match(passwordProblem('','abcdef123456','abcdef123456'),/الحالية/);
});
test('customer timeline maps recorded public events and ignores internal entries without inventing timestamps',()=>{
 const f=orderFacts({timeline:[{id:'1',event:'order_created',created_at:1800000000000},{id:'2',event:'start_picking',created_at:1800000000001},{id:'3',event:'line_removal_proposed',created_at:1800000000002},{id:'4',event:'line_removal_accepted',created_at:1800000000003},{id:'5',event:'component_substitution_proposed',created_at:1800000000004},{id:'6',event:'component_substitution_accepted',created_at:1800000000005},{id:'7',event:'cash_settled',created_at:1800000000006},{id:'8',event:'delivered',created_at:null}]});
 assert.deepEqual(f.timeline.map(x=>x.title),['تم تأكيد الطلب','بدأ تجهيز الطلب','طُلبت موافقتك على حذف صنف','وافقت على حذف الصنف','طُلبت موافقتك على مكوّن بديل للسلة','وافقت على مكوّن السلة البديل']);
});
test('customer procurement progress validates quantities and exposes no supplier staff or actual-cost detail',()=>{
 const requestId='shr-'+'1'.repeat(32),progress=procurementProgressFacts({procurement_progress:{version:1,state:'awaiting_customer',revision:4,updated_at:1800000000000,requested_line_count:1,lines:[{line_id:'line-1',name:'مانجو',size_label:'1 كجم',requested_qty:2,collected_qty:1,remaining_qty:1}],customer_action_required:true,shortage:{id:requestId,state:'pending',proposed_reduction_halalas:750,customer_total_before_halalas:2000,customer_total_if_approved_halalas:1250},inventory_reserved:false,supplier_detail_included:false,staff_identity_included:false,actual_cost_included:false}});
 assert.equal(progress.title,'موافقتك مطلوبة');assert.equal(progress.actionRequired,true);assert.equal(progress.canDecide,true);assert.equal(progress.revision,4);assert.equal(progress.lines[0].remaining,1);assert.equal(progress.shortage.requestId,requestId);assert.equal(progress.shortage.reduction,750);
 assert.equal(procurementProgressFacts({procurement_progress:{...progress,version:2}}),null);
 for(const patch of [{state:'unknown'},{revision:0},{lines:[{line_id:'x',requested_qty:2,collected_qty:2,remaining_qty:1}]},{customer_action_required:true},{inventory_reserved:true},{supplier_detail_included:true},{actual_cost_included:true}])assert.equal(procurementProgressFacts({procurement_progress:{version:1,state:'collecting',revision:2,updated_at:1,requested_line_count:1,lines:[{line_id:'x',requested_qty:2,collected_qty:1,remaining_qty:1}],customer_action_required:false,shortage:null,inventory_reserved:false,supplier_detail_included:false,staff_identity_included:false,actual_cost_included:false,...patch}}),null);
 assert.equal(procurementProgressFacts({procurement_progress:{version:1,state:'awaiting_customer',revision:2,updated_at:1,requested_line_count:0,lines:[],customer_action_required:true,shortage:{id:'bad',state:'pending',proposed_reduction_halalas:1,customer_total_before_halalas:2,customer_total_if_approved_halalas:1},inventory_reserved:false,supplier_detail_included:false,staff_identity_included:false,actual_cost_included:false}}),null);
});
