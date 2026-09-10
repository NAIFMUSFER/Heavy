import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {chromium} from 'playwright';
import {startHarness,attachBrowser} from './harness.mjs';

const harness=await startHarness();
const fixture=JSON.parse(await fs.readFile('evidence/local/e2e-fixture.json','utf8'));
const output='evidence/local/browser';await fs.mkdir(output,{recursive:true});
const origin='https://jana-fresh-app.onrender.com';
const password='Browser-fixture-only-password-12!'; // Disposable fixture, never a production account.
const browser=await chromium.launch({headless:true});
const pages={},errors=[],checks=[];let phase='initialization';
const literal=v=>"'"+String(v).replaceAll("'","''")+"'";
function sql(query){return execFileSync('psql',['-X','-qAt','-v','ON_ERROR_STOP=1'],{input:'SET statement_timeout=10000;\n'+query,encoding:'utf8',timeout:15000}).trim()}
function value(query){return JSON.parse(sql(query))}
function pass(name){checks.push(name);console.log('PASS '+name)}
const order=()=>value('SELECT jsonb_build_object(\'id\',id,\'total\',total_halalas,\'delivery\',delivery_state,\'collected\',collected_halalas,\'settled\',settled_halalas,\'refunded\',refunded_halalas,\'courier_refunded\',courier_refunded_halalas,\'fulfillment\',fulfillment_state) FROM orders WHERE user_id=(SELECT id FROM users WHERE email='+literal(fixture.prefix+'browser@example.invalid')+');');
const stock=()=>value('SELECT jsonb_build_object(\'on_hand\',on_hand_base,\'reserved\',reserved_base) FROM stock_balances WHERE stock_id='+literal(fixture.stock_id)+';');
async function pageFor(role,path='/'){
 const context=await browser.newContext({locale:'ar-SA',timezoneId:'Asia/Riyadh',viewport:{width:1365,height:1000},serviceWorkers:'block'});
 await attachBrowser(context,harness.base);const page=await context.newPage();pages[role]=page;page.setDefaultTimeout(15000);
 page.on('pageerror',e=>errors.push({role,message:e.message}));
 page.on('dialog',d=>d.accept(d.type()==='prompt'?'تم التحقق في اختبار المستودع':undefined));
 await page.goto(origin+path);return page;
}
async function change(page,path,action,method='POST'){
 const pending=page.waitForResponse(r=>new URL(r.url()).pathname===path&&r.request().method()===method);
 const [response]=await Promise.all([pending,action()]);
 assert.ok(response.ok(),path+' returned '+response.status()+': '+(await response.text()).slice(0,600));
 return response.json();
}
async function login(role){
 const page=await pageFor(role,role==='picker'?'/picker.html':role==='courier'?'/courier.html':'/admin.html');
 await page.locator('#ops-login').click();await page.locator('#auth-form [name=email]').fill(fixture.accounts[role]);await page.locator('#auth-form [name=password]').fill(password);
 await change(page,'/api/auth/login',()=>page.locator('#auth-form button[type=submit]').click());await page.locator('.ops-user').waitFor();return page;
}
const closeModal=page=>page.locator('dialog[open] [data-close]').first().click();
const nextSaudiDate=()=>new Date(Date.now()+2*86400000+3*3600000).toISOString().slice(0,16);
try{
 phase='warehouse receipt and inspection';
 const inventory=await login('inventory');
 await inventory.locator('[data-action=new-supplier]').click();await inventory.locator('#supplier-form [name=name]').fill('مورد اختبار المتصفح');
 const supplier=await change(inventory,'/api/ops/suppliers',()=>inventory.locator('#supplier-form button').click());
 await inventory.locator('[data-action=new-lot]').click();
 const lotForm=inventory.locator('#lot-form');await lotForm.locator('[name=stock_id]').selectOption(fixture.stock_id);await lotForm.locator('[name=supplier_id]').selectOption(supplier.id);
 await lotForm.locator('[name=receipt_reference]').fill('E2E-RECEIPT');await lotForm.locator('[name=received_base]').fill('10000');await lotForm.locator('[name=cost]').fill('100');await lotForm.locator('[name=expires_at]').fill(nextSaudiDate());
 const lot=await change(inventory,'/api/ops/lots',()=>lotForm.locator('button').click());
 assert.deepEqual(stock(),{on_hand:1,reserved:0});pass('warehouse receipt remains unavailable pending inspection');
 await change(inventory,'/api/ops/lots/'+lot.id+'/inspect',()=>inventory.locator('[data-action=inspect-lot][data-id="'+lot.id+'"][data-state=accepted]').click());
 assert.deepEqual(stock(),{on_hand:10001,reserved:0});pass('accepted warehouse lot increases usable stock once');

 phase='delivery administration';
 const admin=await login('admin');await admin.locator('[data-page=logistics]').click();await admin.locator('[data-action=new-zone]').click();
 const zoneForm=admin.locator('#zone-form');await zoneForm.locator('[name=name]').fill('منطقة اختبار التوسع');await zoneForm.locator('[name=city]').fill('الرياض');await zoneForm.locator('[name=fee]').fill('12');await zoneForm.locator('[name=minimum]').fill('20');await zoneForm.locator('[name=polygon]').fill(JSON.stringify({type:'Polygon',coordinates:[[[45,24],[46,24],[46,25],[45,25],[45,24]]]}));await zoneForm.locator('[name=reason]').fill('إنشاء تغطية اختبار مستقلة');
 const newZone=await change(admin,'/api/ops/zones',()=>zoneForm.locator('button').click());assert.equal(newZone.revision,1);
 await admin.locator('[data-action=edit-zone][data-id="'+newZone.id+'"]').click();await admin.locator('#zone-form [name=fee]').fill('15');await admin.locator('#zone-form [name=reason]').fill('تحديث الرسوم للاختبار');
 const revisedZone=await change(admin,'/api/ops/zones/'+newZone.id,()=>admin.locator('#zone-form button').click(),'PATCH');assert.equal(revisedZone.fee_halalas,1500);assert.equal(revisedZone.revision,2);
 await admin.locator('[data-action=new-slot]').click();const slotForm=admin.locator('#slot-form');await slotForm.locator('[name=zone_id]').selectOption(newZone.id);
 const stamp=hours=>new Date(Date.now()+(hours+3)*3600000).toISOString().slice(0,16);await slotForm.locator('[name=starts_at]').fill(stamp(48));await slotForm.locator('[name=ends_at]').fill(stamp(50));await slotForm.locator('[name=cutoff_at]').fill(stamp(46));await slotForm.locator('[name=capacity]').fill('3');await slotForm.locator('[name=reason]').fill('فتح نافذة اختبار');
 const newSlot=await change(admin,'/api/ops/slots',()=>slotForm.locator('button').click());assert.equal(newSlot.capacity,3);
 await admin.locator('[data-action=edit-slot][data-id="'+newSlot.id+'"]').click();await admin.locator('#slot-form [name=capacity]').fill('2');await admin.locator('#slot-form [name=reason]').fill('مراجعة سعة الاختبار');
 const revisedSlot=await change(admin,'/api/ops/slots/'+newSlot.id,()=>admin.locator('#slot-form button').click(),'PATCH');assert.equal(revisedSlot.capacity,2);assert.equal(revisedSlot.booked,0);pass('admin creates and revises geographic zones and delivery slot capacity through audited forms');
 await admin.locator('[data-page=orders]').click();

 phase='customer account and saved preferences';
 const customer=await pageFor('customer');await customer.locator('[data-view=account]').first().click();await customer.locator('[data-register]').click();
 const auth=customer.locator('#auth-form');await auth.locator('[name=name]').fill('عميل اختبار المتصفح');await auth.locator('[name=email]').fill(fixture.prefix+'browser@example.invalid');await auth.locator('[name=password]').fill(password);
 await change(customer,'/api/auth/login',()=>auth.locator('button[type=submit]').click());await customer.locator('[data-action=profile]').waitFor();
 const cookies=await customer.context().cookies(origin);assert.ok(cookies.some(c=>c.httpOnly&&c.secure&&c.sameSite==='Strict'));pass('customer registration and secure cookie login through real gateway');
 await customer.reload();await customer.locator('[data-view=account]').first().click();await customer.locator('[data-action=profile]').click();
 await customer.locator('#profile-form [name=name]').fill('عميل رحلة جنى');
 await change(customer,'/api/profile',()=>customer.locator('#profile-form button').click(),'PATCH');pass('session restoration and customer profile update');

 phase='address coverage quote and confirmation';
 await customer.locator('[data-view=shop]').first().click();await customer.locator('[data-action=custom]').click();await customer.locator('[data-builder-item]').first().fill('1');await customer.locator('[data-builder-item]').first().press('Tab');await customer.locator('#builder-add').click();await customer.locator('#cart-lines').waitFor();assert.equal(await customer.locator('#cart-lines .cart-line').count(),1);await closeModal(customer);pass('custom basket selection reaches the real cart with canonical catalog prices');
 await customer.locator('[data-action=cart]').first().click();await customer.locator('[data-action=cloud-cart]').click();
 const savedCart=await change(customer,'/api/cart',()=>customer.locator('[data-cloud-save]').click(),'PUT');assert.equal(savedCart.revision,1);
 const second=await pageFor('customer_second');await second.locator('[data-view=account]').first().click();await second.locator('[data-login]').click();await second.locator('#auth-form [name=email]').fill(fixture.prefix+'browser@example.invalid');await second.locator('#auth-form [name=password]').fill(password);await change(second,'/api/auth/login',()=>second.locator('#auth-form button[type=submit]').click());await second.locator('[data-action=profile]').waitFor();
 await second.locator('[data-action=cart]').first().click();await second.locator('[data-action=cloud-cart]').click();await second.locator('[data-cloud-restore]').click();await second.locator('#cart-lines').waitFor();assert.equal(await second.locator('#cart-lines .cart-line').count(),1);assert.deepEqual(stock(),{on_hand:10001,reserved:0});assert.equal(Number(sql('SELECT count(*) FROM orders;')),0);pass('saved cart restores through a separate authenticated browser without creating reservations');
 await closeModal(customer);await customer.locator('[data-action=cart]').first().click();await customer.locator('#checkout').click();
 const address=customer.locator('#addr');await address.locator('[name=city]').fill('جازان');await address.locator('[name=details]').fill('عنوان اختبار محلي ضمن منطقة الاختبار');await address.locator('[name=recipient_phone]').fill('0500000001');await address.locator('[name=latitude]').fill('16.5');await address.locator('[name=longitude]').fill('42.5');
 await change(customer,'/api/addresses',()=>address.locator('button[type=submit]').click());
 await customer.locator('[data-address]').first().click();
 const quote=await change(customer,'/api/quotes',()=>customer.locator('[data-slot="'+fixture.slot_id+'"]').click());
 assert.equal(quote.total_halalas,2000);assert.deepEqual(stock(),{on_hand:10001,reserved:1000});assert.equal(Number(sql('SELECT booked FROM delivery_slots WHERE id='+literal(fixture.slot_id)+';')),1);
 assert.equal(Number(sql('SELECT count(*) FROM orders;')),0);pass('quote reserves stock and zone capacity before any permanent order');
 const confirmed=await change(customer,'/api/orders',()=>customer.locator('#confirm-order').click());
 const code=(await customer.locator('.delivery-code').innerText()).trim();assert.match(code,/^\d{6}$/);assert.equal(order().id,confirmed.id);assert.equal(order().total,2000);pass('reviewed COD confirmation creates one immutable commercial order');
 await customer.screenshot({path:output+'/order-confirmed.png',fullPage:true});
 await customer.locator('.success-view [data-view=orders]').click();

 phase='picker assignment and actual weight';
 async function assign(role){
  await admin.locator('[data-action=refresh]').click();await admin.locator('[data-action=assign-order][data-id="'+confirmed.id+'"]').click();
  const form=admin.locator('#assignment-form');const id=sql('SELECT id FROM users WHERE email='+literal(fixture.accounts[role])+';');await form.locator('[name='+role+'_id]').selectOption(id);await form.locator('[name=reason]').fill('إسناد رحلة المتصفح');
  await change(admin,'/api/ops/orders/'+confirmed.id+'/assignment',()=>form.locator('button').click());
 }
 await assign('picker');const picker=await login('picker');
 await change(picker,'/api/ops/orders/'+confirmed.id+'/start',()=>picker.locator('[data-action=start][data-id="'+confirmed.id+'"]').click());
 await picker.locator('[data-action=open-pick]').click();await picker.locator('[data-actual] [name=actual_base]').fill('900');
 await change(picker,'/api/ops/orders/'+confirmed.id+'/actual',()=>picker.locator('[data-actual] button').click());
 assert.equal(order().total,1800);
 await change(picker,'/api/ops/orders/'+confirmed.id+'/finalize',()=>picker.locator('[data-finalize]').click());
 assert.equal(order().fulfillment,'ready');assert.deepEqual(stock(),{on_hand:9101,reserved:0});pass('assigned picker records actual weight and consumes FEFO inventory');

 phase='delivery proof and separate cash collection';
 await assign('courier');const courier=await login('courier');
 await change(courier,'/api/ops/orders/'+confirmed.id+'/dispatch',()=>courier.locator('[data-action=dispatch]').click());
 await courier.locator('[data-action=deliver]').click();await courier.locator('#deliver-form [name=code]').fill(code);
 await change(courier,'/api/ops/orders/'+confirmed.id+'/deliver',()=>courier.locator('#deliver-form button').click());
 assert.equal(order().delivery,'delivered');assert.equal(order().collected,0);assert.equal(order().settled,0);pass('delivery proof never collects or settles cash automatically');
 await change(courier,'/api/ops/orders/'+confirmed.id+'/collect',()=>courier.locator('[data-action=collect]').click());
 assert.equal(order().collected,1800);assert.equal(order().settled,0);pass('separate courier collection creates cash liability');

 phase='finance settlement';
 const finance=await login('finance');await finance.locator('[data-action=settle]').click();await finance.locator('#settlement-form [name=reference]').fill('E2E-DEPOSIT-001');
 await change(finance,'/api/ops/orders/'+confirmed.id+'/settle',()=>finance.locator('#settlement-form button').click());assert.equal(order().settled,1800);pass('finance settlement records actual reference and clears liability');

 phase='customer support and staff response';
 await customer.locator('[data-order="'+confirmed.id+'"]').click();await customer.locator('[data-support="'+confirmed.id+'"]').click();
 await customer.locator('#ticket [name=category]').selectOption('product');await customer.locator('#ticket [name=subject]').fill('مراجعة جودة الطلب');await customer.locator('#ticket [name=message]').fill('أحتاج مراجعة صنف من الطلب المسلم');
 const ticket=await change(customer,'/api/tickets',()=>customer.locator('#ticket button').click());
 const support=await login('support');await support.locator('[data-page=support]').click();await support.locator('details summary').first().click();
 const reply=support.locator('form[data-support-ticket]');await reply.locator('[name=message]').fill('تمت مراجعة طلبك وتوثيق النتيجة');await reply.locator('[name=state]').selectOption('closed');
 const ticketId=await reply.getAttribute('data-support-ticket');assert.ok(ticketId);
 await change(support,'/api/ops/support/'+ticketId,()=>reply.locator('button[type=submit]').click());
 await closeModal(customer);await customer.locator('[data-view=account]').first().click();await customer.locator('[data-action=tickets]').click();await customer.getByText('تمت مراجعة طلبك وتوثيق النتيجة',{exact:true}).waitFor();pass('customer order-linked support message reaches staff and reply reaches customer');

 phase='requested refund and finance cash source';
 await closeModal(customer);await customer.locator('[data-view=orders]').first().click();await customer.locator('[data-order="'+confirmed.id+'"]').click();await customer.locator('[data-refund-order]').click();await customer.locator('#refund-request [name=amount]').fill('1');await customer.locator('#refund-request [name=reason]').fill('مراجعة جودة موثقة');
 await change(customer,'/api/orders/'+confirmed.id+'/refunds',()=>customer.locator('#refund-request button').click());assert.equal(order().refunded,0);
 await finance.locator('[data-page=finance]').click();await finance.locator('[data-action=complete-refund]').click();await finance.locator('#paid-refund-form [name=payment_source]').selectOption('finance');await finance.locator('#paid-refund-form [name=reference]').fill('E2E-REFUND-001');
 const refundId=sql('SELECT id FROM refunds WHERE order_id='+literal(confirmed.id)+';');
 await change(finance,'/api/ops/refunds/'+refundId+'/complete',()=>finance.locator('#paid-refund-form button').click());
 assert.equal(order().refunded,100);assert.equal(order().courier_refunded,0);assert.equal(order().collected-order().settled-order().courier_refunded,0);pass('refund request becomes recorded company-funded refund without changing settled courier liability');
 await finance.screenshot({path:output+'/finance-ledger.png',fullPage:true});

 phase='saved lists and consented reminders';
 await closeModal(customer);await customer.locator('[data-view=account]').first().click();await customer.locator('[data-action=shopping-lists]').click();await customer.locator('[data-new-list]').click();await customer.locator('#saved-list-form [name=name]').fill('احتياجات الأسبوع');await customer.locator('[data-list-item]').first().fill('1');
 await change(customer,'/api/shopping-lists',()=>customer.locator('#saved-list-form button').click());await customer.locator('[data-remind-list]').click();await customer.locator('#reminder-form [name=next_at]').fill(nextSaudiDate());await customer.locator('#reminder-form [name=consent]').check();
 const reminder=await change(customer,'/api/recurring',()=>customer.locator('#reminder-form button').click());
 await change(customer,'/api/recurring/'+reminder.id,()=>customer.locator('[data-plan-state][data-state=paused]').click(),'PATCH');
 assert.equal(sql('SELECT state FROM recurring_plans WHERE id='+literal(reminder.id)+';'),'paused');assert.equal(Number(sql('SELECT count(*) FROM orders;')),1);assert.deepEqual(stock(),{on_hand:9101,reserved:0});pass('saved lists and explicit recurring reminder consent do not create or charge orders');
 await customer.screenshot({path:output+'/customer-reminders.png',fullPage:true});

 phase='optional email account';
 const phoneCustomer=await pageFor('phone_customer');await phoneCustomer.locator('[data-view=account]').first().click();await phoneCustomer.locator('[data-register]').click();await phoneCustomer.locator('#auth-form [name=name]').fill('عميل تسجيل الجوال');await phoneCustomer.locator('#auth-form [name=phone]').fill('0500000002');await phoneCustomer.locator('#auth-form [name=password]').fill(password);const phoneLogin=await change(phoneCustomer,'/api/auth/login',()=>phoneCustomer.locator('#auth-form button[type=submit]').click());assert.equal(phoneLogin.user.email,null);assert.equal(phoneLogin.user.verified_phone,false);await phoneCustomer.locator('[data-action=profile]').waitFor();await change(phoneCustomer,'/api/auth/logout',()=>phoneCustomer.locator('[data-action=logout]').click());await phoneCustomer.locator('[data-login]').click();await phoneCustomer.locator('#auth-form [name=email]').fill('+966500000002');await phoneCustomer.locator('#auth-form [name=password]').fill(password);const restoredPhone=await change(phoneCustomer,'/api/auth/login',()=>phoneCustomer.locator('#auth-form button[type=submit]').click());assert.equal(restoredPhone.user.id,phoneLogin.user.id);pass('customer registers without email and signs in using either phone format without false verification');
 assert.deepEqual(errors,[],'Browser JavaScript errors');assert.deepEqual(harness.failures,[],'Gateway server errors');
 pass('all seven role interfaces complete the real database journey without JavaScript or server errors');
 await fs.writeFile(output+'/results.json',JSON.stringify({status:'passed',checks},null,2));
 console.log('Browser journey complete: '+checks.length+' checks');
}catch(error){
 console.error('FAILED PHASE: '+phase);console.error(error);for(const [role,page] of Object.entries(pages))console.error('FIXTURE PAGE '+role+': '+(await page.locator('body').innerText()).slice(0,8000));
 for(const [role,page] of Object.entries(pages)){await page.screenshot({path:output+'/failure-'+role+'.png',fullPage:true}).catch(()=>{});await fs.writeFile(output+'/failure-'+role+'.txt',await page.locator('body').innerText()).catch(()=>{})}
 await fs.writeFile(output+'/results.json',JSON.stringify({status:'failed',phase,checks,error:String(error),browserErrors:errors,gatewayErrors:harness.failures},null,2));process.exitCode=1;
}finally{await browser.close();await harness.close()}
