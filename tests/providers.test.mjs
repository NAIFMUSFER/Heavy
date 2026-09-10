import test from 'node:test';
import assert from 'node:assert/strict';
import {ResendEmailProvider,InAppProvider,SmsProvider,WhatsAppProvider,PushProvider} from '../server/providers/notifications.mjs';
import {paymentProvider} from '../server/providers/payments.mjs';
import {imageStorageProvider} from '../server/providers/images.mjs';
const now=1789030800000;
const env={JANA_EMAIL_ENABLED:'true',JANA_RESEND_API_KEY:'test-only-noncredential',JANA_EMAIL_DOMAIN:'jana.example',JANA_RESEND_DOMAIN_ID:'00000000-0000-4000-8000-000000000001',JANA_EMAIL_FROM:'orders@jana.example'};
const message={to:'customer@example.invalid',subject:'طلب جنى',text:'راجع حالة طلبك داخل التطبيق',idempotencyKey:'notification-fixture-key',createdAt:now};
const verified={id:env.JANA_RESEND_DOMAIN_ID,name:env.JANA_EMAIL_DOMAIN,status:'verified',capabilities:{sending:'enabled'}};
test('email remains disabled by default and generic unrelated keys cannot enable it',async()=>{let calls=0;const p=new ResendEmailProvider({env:{RESEND_API_KEY:'unrelated'},fetchImpl:async()=>{calls++;throw Error('Unexpected network')}});await assert.rejects(p.send(message),{code:'EMAIL_DISABLED'});assert.equal(calls,0)});
test('explicit email enable fails configuration before making network requests',()=>{assert.throws(()=>new ResendEmailProvider({env:{JANA_EMAIL_ENABLED:'true'}}),{code:'EMAIL_CONFIGURATION_INVALID'})});
test('Resend verification must match approved domain and sending capability before submission',async()=>{
 for(const response of [{...verified,status:'pending'},{...verified,name:'other.example'},{...verified,capabilities:{sending:'disabled'}}]){let calls=0;const p=new ResendEmailProvider({env,now:()=>now,fetchImpl:async()=>{calls++;return Response.json(response)}});await assert.rejects(p.send(message),{code:'EMAIL_DOMAIN_NOT_VERIFIED'});assert.equal(calls,1)}
});
test('Resend submission uses a fixed destination and retry key and reports submitted only',async()=>{
 const calls=[];const p=new ResendEmailProvider({env,now:()=>now,fetchImpl:async(url,options)=>{calls.push({url,options});return Response.json(calls.length===1?verified:{id:'provider-fixture-id'})}});
 assert.deepEqual(await p.send(message),{channel:'email',status:'submitted',id:'provider-fixture-id'});assert.equal(calls[1].url,'https://api.resend.com/emails');assert.equal(calls[1].options.headers['Idempotency-Key'],message.idempotencyKey);assert.equal(calls[1].options.redirect,'error');assert.equal(JSON.parse(calls[1].options.body).text,message.text);
});
test('email timeout preserves an unknown outcome and does not expose provider details',async()=>{
 let calls=0;const p=new ResendEmailProvider({env,now:()=>now,fetchImpl:async()=>{if(++calls===1)return Response.json(verified);throw Error('Sensitive provider fixture')}});await assert.rejects(p.send(message),e=>e.code==='PROVIDER_UNAVAILABLE'&&e.outcome==='unknown'&&!String(e).includes('Sensitive'));
});
test('expired uncertain email jobs require reconciliation before reusing an expired provider key',async()=>{const p=new ResendEmailProvider({env,now:()=>now+24*3600000,fetchImpl:async()=>{throw Error('Must not send')}});await assert.rejects(p.send(message),{code:'DELIVERY_RECONCILIATION_REQUIRED'})});
test('in-app adapter requires a real recorded identifier instead of reporting an invented success',async()=>{const p=new InAppProvider({insertOnce:async()=>null});await assert.rejects(p.send({eventId:'event',userId:'user',title:'عنوان',body:'رسالة'}),{code:'INVALID_PROVIDER_RESPONSE'})});
test('unconfigured external channels and storage return explicit configuration errors',async()=>{for(const p of [new SmsProvider(),new WhatsAppProvider(),new PushProvider()])await assert.rejects(p.send(message),{code:'PROVIDER_CONFIGURATION_REQUIRED'});const storage=imageStorageProvider();assert.equal(storage.publicUrl(),null);await assert.rejects(storage.upload(),{code:'IMAGE_STORAGE_CONFIGURATION_REQUIRED'})});
test('COD preparation never captures money and unconfigured online payment cannot pretend success',async()=>{const p=paymentProvider('cod');assert.equal((await p.prepare({orderId:'order-fixture',amountHalalas:1800})).status,'awaiting_collection');await assert.rejects(p.capture(),{code:'USE_TRANSACTIONAL_COD_COLLECTION'});await assert.rejects(p.refund(),{code:'USE_AUDITED_COD_REFUND'});await assert.rejects(paymentProvider('mada').prepare(),{code:'PAYMENT_CONFIGURATION_REQUIRED'})});
