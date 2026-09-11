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
async function pageFor(role,path='/',networkControl={}){
 const context=await browser.newContext({locale:'ar-SA',timezoneId:'Asia/Riyadh',viewport:{width:1365,height:1000},serviceWorkers:'block'});
 await attachBrowser(context,harness.base,networkControl);const page=await context.newPage();pages[role]=page;page.setDefaultTimeout(15000);
 page.on('pageerror',e=>errors.push({role,message:e.message}));
 page.on('dialog',d=>d.accept(d.type()==='prompt'?'تم التحقق في اختبار المستودع':undefined));
 await page.goto(origin+path);return page;
}
async function change(page,path,action,method='POST'){
 const pending=page.waitForResponse(r=>new URL(r.url()).pathname===path&&r.request().method()===method);
 const [response]=await Promise.all([pending,action()]);
 assert.ok(response.ok(),path+' returned '+response.status()+': '+(await response.text()).slice(0,600));
 const result=await response.json();if(path.startsWith('/api/ops/storefront/'))await page.locator('[data-store-revision="'+result.revision+'"]').waitFor();return result;
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
 const zoneForm=admin.locator('#zone-form');await zoneForm.locator('[name=name]').fill('منطقة اختبار التوسع');await zoneForm.locator('[name=city]').fill('الرياض');await zoneForm.locator('[name=fee]').fill('12');await zoneForm.locator('[name=minimum]').fill('20');await zoneForm.locator('[name=reason]').fill('إنشاء تغطية اختبار مستقلة');
 const canvas=zoneForm.locator('.zone-canvas');const bounds=await canvas.boundingBox();assert.ok(bounds);
 for(const [x,y]of [[.25,.25],[.75,.25],[.75,.75],[.25,.75]])await canvas.click({position:{x:bounds.width*x,y:bounds.height*y}});
 await zoneForm.locator('[data-map=hole]').click();
 for(const [x,y]of [[.45,.45],[.55,.45],[.55,.55],[.45,.55]])await canvas.click({position:{x:bounds.width*x,y:bounds.height*y}});
 const drawn=JSON.parse(await zoneForm.locator('[name=polygon]').inputValue());assert.equal(drawn.coordinates.length,2);
 // Browser network interception blocks all third-party requests. No tile service is scanned in CI.
 assert.equal(await zoneForm.locator('.zone-tiles img').count(),0);
 const newZone=await change(admin,'/api/ops/zones',()=>zoneForm.locator('button[type=submit]').click());assert.equal(newZone.revision,1);
 const storedPolygon=value('SELECT polygon FROM delivery_zones WHERE id='+literal(newZone.id)+';');assert.deepEqual(storedPolygon,drawn);
 pass('visual map clicks persist exact geographic boundaries and an exclusion ring through PostGIS');
 await admin.locator('[data-action=edit-zone][data-id="'+newZone.id+'"]').click();await admin.locator('#zone-form [name=fee]').fill('15');await admin.locator('#zone-form [name=reason]').fill('تحديث الرسوم للاختبار');
 assert.deepEqual(JSON.parse(await admin.locator('#zone-form [name=polygon]').inputValue()),drawn);
 await admin.locator('#zone-form [data-map-ring]').selectOption('0');await admin.locator('#zone-form [data-map-point]').selectOption('0');
 const originalLongitude=await admin.locator('#zone-form [data-map-lng]').inputValue();await admin.locator('#zone-form [data-map-lng]').fill(String(Number(originalLongitude)+.001));await admin.locator('#zone-form [data-map=update-point]').click();
 assert.notDeepEqual(JSON.parse(await admin.locator('#zone-form [name=polygon]').inputValue()),drawn);await admin.locator('#zone-form [data-map=undo]').click();assert.deepEqual(JSON.parse(await admin.locator('#zone-form [name=polygon]').inputValue()),drawn);
 await admin.locator('.zone-canvas').scrollIntoViewIfNeeded();
 const handle=await admin.locator('.zone-handles circle').first().boundingBox();assert.ok(handle);await admin.mouse.move(handle.x+handle.width/2,handle.y+handle.height/2);await admin.mouse.down();await admin.mouse.move(handle.x+handle.width/2+20,handle.y+handle.height/2+10,{steps:3});await admin.mouse.up();assert.notDeepEqual(JSON.parse(await admin.locator('#zone-form [name=polygon]').inputValue()),drawn);await admin.locator('#zone-form [data-map=undo]').click();assert.deepEqual(JSON.parse(await admin.locator('#zone-form [name=polygon]').inputValue()),drawn);
 pass('existing exclusions survive coordinate editing dragging undo and a commercial-only zone revision');
 const revisedZone=await change(admin,'/api/ops/zones/'+newZone.id,()=>admin.locator('#zone-form button[type=submit]').click(),'PATCH');assert.equal(revisedZone.fee_halalas,1500);assert.equal(revisedZone.revision,2);
 await admin.locator('[data-action=edit-zone][data-id="'+newZone.id+'"]').click();
 await admin.locator('#zone-form [data-map=tiles]').click();await admin.locator('.zone-map-error').filter({hasText:'تعذر تحميل'}).waitFor();assert.deepEqual(JSON.parse(await admin.locator('#zone-form [name=polygon]').inputValue()),drawn);
 await admin.locator('.zone-advanced summary').click();await admin.locator('#zone-form [name=polygon]').fill(JSON.stringify({type:'Polygon',coordinates:[[[42,16],[43,17],[43,16],[42,17],[42,16]]]}));await admin.locator('#zone-form [name=reason]').fill('التحقق من رفض حدود متقاطعة');
 const rejected=admin.waitForResponse(r=>new URL(r.url()).pathname==='/api/ops/zones/'+newZone.id&&r.request().method()==='PATCH');await admin.locator('#zone-form button[type=submit]').click();assert.equal((await rejected).status(),422);
 assert.deepEqual(value('SELECT polygon FROM delivery_zones WHERE id='+literal(newZone.id)+';'),drawn);assert.equal(Number(sql('SELECT revision FROM delivery_zones WHERE id='+literal(newZone.id)+';')),2);await closeModal(admin);
 pass('street-layer failure preserves draft geometry and PostGIS rejects self-intersection without overwriting the zone');
 await admin.locator('[data-action=new-slot]').click();const slotForm=admin.locator('#slot-form');await slotForm.locator('[name=zone_id]').selectOption(newZone.id);
 const stamp=hours=>new Date(Date.now()+(hours+3)*3600000).toISOString().slice(0,16);await slotForm.locator('[name=starts_at]').fill(stamp(48));await slotForm.locator('[name=ends_at]').fill(stamp(50));await slotForm.locator('[name=cutoff_at]').fill(stamp(46));await slotForm.locator('[name=capacity]').fill('3');await slotForm.locator('[name=reason]').fill('فتح نافذة اختبار');
 const newSlot=await change(admin,'/api/ops/slots',()=>slotForm.locator('button').click());assert.equal(newSlot.capacity,3);
 await admin.locator('[data-action=edit-slot][data-id="'+newSlot.id+'"]').click();await admin.locator('#slot-form [name=capacity]').fill('2');await admin.locator('#slot-form [name=reason]').fill('مراجعة سعة الاختبار');
 const revisedSlot=await change(admin,'/api/ops/slots/'+newSlot.id,()=>admin.locator('#slot-form button').click(),'PATCH');assert.equal(revisedSlot.capacity,2);assert.equal(revisedSlot.booked,0);pass('admin creates and revises geographic zones and delivery slot capacity through audited forms');
 await admin.locator('[data-page=orders]').click();

 phase='merchant policies and intake administration';
 await admin.locator('[data-page=storefront]').click();await admin.locator('#store-draft').waitFor();
 await admin.locator('#store-draft [name=display_name]').fill('متجر اختبار السياسات');
 await change(admin,'/api/ops/storefront/draft',()=>admin.locator('#store-draft button[type=submit]').click());
 await admin.locator('#store-publish-confirm').check();
 const merchant=await change(admin,'/api/ops/storefront/publish',()=>admin.locator('#store-publish').click());assert.equal(merchant.published.profile.display_name,'متجر اختبار السياسات');
 await admin.locator('#store-intake [name=accepting_orders]').selectOption('false');await admin.locator('#store-intake [name=message]').fill('توقف استقبال الطلبات لاختبار التشغيل');await admin.locator('#store-intake [name=reason]').fill('اختبار إيقاف استقبال الطلبات');
 const paused=await change(admin,'/api/ops/storefront/intake',()=>admin.locator('#store-intake button[type=submit]').click());assert.equal(paused.accepting_orders,false);
 const guest=await pageFor('store-guest');await guest.locator('#announcement').filter({hasText:'توقف استقبال الطلبات'}).waitFor();await guest.locator('[data-action=store-info]').click();await guest.locator('dialog[open]').getByText('متجر اختبار السياسات',{exact:true}).waitFor();await closeModal(guest);
 await admin.locator('#store-intake [name=accepting_orders]').selectOption('true');await admin.locator('#store-intake [name=message]').fill('المتجر الاختباري يستقبل الطلبات');await admin.locator('#store-intake [name=reason]').fill('اكتمال اختبار تشغيل المتجر');await admin.locator('#store-intake [name=reference]').fill('E2E-OPERATIONS-APPROVAL');for(const k of ['catalog','inventory','coverage','tax','operations'])await admin.locator('#store-intake [name='+k+']').check();
 const opened=await change(admin,'/api/ops/storefront/intake',()=>admin.locator('#store-intake button[type=submit]').click());assert.equal(opened.accepting_orders,true);pass('admin publishes versioned merchant policies and guest sees intake state before operations reopen');

 phase='customer account and saved preferences';
 const customerNetwork={};const customer=await pageFor('customer','/',customerNetwork);await customer.locator('[data-view=account]').first().click();await customer.locator('[data-register]').click();
 const auth=customer.locator('#auth-form');await auth.locator('[name=name]').fill('عميل اختبار المتصفح');await auth.locator('[name=email]').fill(fixture.prefix+'browser@example.invalid');await auth.locator('[name=password]').fill(password);
 await change(customer,'/api/auth/login',()=>auth.locator('button[type=submit]').click());await customer.locator('[data-action=profile]').waitFor();
 const cookies=await customer.context().cookies(origin);assert.ok(cookies.some(c=>c.httpOnly&&c.secure&&c.sameSite==='Strict'));pass('customer registration and secure cookie login through real gateway');
 // Delay the actual database-backed favorites response; navigation must survive session restoration.
 let releaseFavorites,seenFavorites;
 const favoritesHeld=new Promise(resolve=>{releaseFavorites=resolve});const favoritesStarted=new Promise(resolve=>{seenFavorites=resolve});
 customerNetwork.beforeResponse=async u=>{if(u.pathname==='/api/favorites'){seenFavorites();await favoritesHeld}};
 await customer.reload();await favoritesStarted;
 await customer.locator('[data-view=account]').first().click();await customer.locator('#app [role=status]').waitFor();
 assert.equal(await customer.locator('[data-login]').count(),0,'Restoring a session must not show a premature signed-out account');
 releaseFavorites();await customer.locator('[data-action=profile]').waitFor();delete customerNetwork.beforeResponse;
 assert.equal(await customer.locator('#catalog-section').count(),0,'A delayed startup must preserve the chosen account view');
 pass('account navigation survives deliberately delayed session startup without a false signed-out state');
 await customer.locator('[data-action=profile]').click();
 await customer.locator('#profile-form [name=name]').fill('عميل رحلة جنى');
 await change(customer,'/api/profile',()=>customer.locator('#profile-form button').click(),'PATCH');pass('session restoration and customer profile update');

 phase='address coverage quote and confirmation';
 await customer.locator('[data-view=shop]').first().click();await customer.locator('[data-action=custom]').click();await customer.locator('[data-builder-item]').first().fill('1');await customer.locator('[data-builder-item]').first().press('Tab');await customer.locator('#builder-add').click();await customer.locator('#cart-lines').waitFor();assert.equal(await customer.locator('#cart-lines .cart-line').count(),1);await closeModal(customer);pass('custom basket selection reaches the real cart with canonical catalog prices');
 await customer.locator('[data-action=cart]').first().click();await customer.locator('[data-action=cloud-cart]').click();
 const savedCart=await change(customer,'/api/cart',()=>customer.locator('[data-cloud-save]').click(),'PUT');assert.equal(savedCart.revision,1);
 const second=await pageFor('customer_second');await second.locator('[data-view=account]').first().click();await second.locator('[data-login]').click();await second.locator('#auth-form [name=email]').fill(fixture.prefix+'browser@example.invalid');await second.locator('#auth-form [name=password]').fill(password);await change(second,'/api/auth/login',()=>second.locator('#auth-form button[type=submit]').click());await second.locator('[data-action=profile]').waitFor();
 await second.locator('[data-action=cart]').first().click();await second.locator('[data-action=cloud-cart]').click();await second.locator('[data-cloud-restore]').click();await second.locator('#cart-lines').waitFor();assert.equal(await second.locator('#cart-lines .cart-line').count(),1);assert.deepEqual(stock(),{on_hand:10001,reserved:0});assert.equal(Number(sql('SELECT count(*) FROM orders;')),0);pass('saved cart restores through a separate authenticated browser without creating reservations');
 await closeModal(customer);await customer.locator('[data-action=cart]').first().click();await customer.locator('#checkout').click();
 const address=customer.locator('#addr');await customer.setViewportSize({width:390,height:844});
 await address.locator('[name=city]').fill('جازان');await address.locator('[name=details]').fill('عنوان اختبار محلي ضمن منطقة الاختبار');await address.locator('[name=recipient_phone]').fill('٠٠٩٦٦ ٥٠ ٠٠٠ ٠٠٠١');
 await address.locator('button[type=submit]').click();await customer.locator('#address-error').waitFor();assert.match(await customer.locator('#address-error').innerText(),/الموقع|التوصيل/);assert.equal(Number(sql('SELECT count(*) FROM addresses WHERE user_id=(SELECT id FROM users WHERE email='+literal(fixture.prefix+'browser@example.invalid')+');')),0);pass('missing location keeps the address form intact and cannot create a saved address');
 await customer.context().grantPermissions(['geolocation'],{origin});await customer.context().setGeolocation({latitude:16.4,longitude:42.4,accuracy:10});await customer.locator('#locate-address').click();await customer.locator('#address-point-status').filter({hasText:/تم تحديد موقعك/}).waitFor();assert.equal(await address.locator('[name=latitude]').inputValue(),'16.4');assert.equal(await address.locator('[name=longitude]').inputValue(),'42.4');pass('foreground browser location fills actual coordinates and offers a Google Maps pin review');
 await customer.locator('#address-map-input').fill('https://www.google.com/maps/place/Fixture/@17,43,15z/data=!3d16.5!4d42.5');await customer.locator('#import-address-map').click();await customer.locator('#address-point-status').filter({hasText:/تم استيراد/}).waitFor();assert.equal(await address.locator('[name=latitude]').inputValue(),'16.5');assert.equal(await customer.locator('#review-address-map').getAttribute('href'),'https://www.google.com/maps/search/?api=1&query=16.5%2C42.5');
 await customer.locator('#address-map-input').fill('https://www.google.com/maps/@18,44,15z');await customer.locator('#import-address-map').click();await customer.locator('#address-error').filter({hasText:/دبوسًا محددًا/}).waitFor();assert.equal(await address.locator('[name=latitude]').inputValue(),'16.5');assert.equal(await address.locator('[name=details]').inputValue(),'عنوان اختبار محلي ضمن منطقة الاختبار');pass('Google pin import ignores the camera centre and preserves the last valid address on an ambiguous link');
 await customer.screenshot({path:output+'/address-form-phone.png',fullPage:true});assert.ok(await customer.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
 const savedAddress=await change(customer,'/api/addresses',()=>address.locator('button[type=submit]').click());assert.equal(savedAddress.recipient_phone,'+966500000001');await customer.locator('[data-address]').first().waitFor();pass('Arabic phone and coordinates are persisted through the real Edge and PostgreSQL address transaction');
 await closeModal(customer);await customer.setViewportSize({width:1365,height:1000});await customer.locator('[data-view=account]').first().click();await customer.locator('[data-action=addresses]').click();await customer.locator('[data-edit-address]').first().click();
 await customer.locator('#address-manual').evaluate(el=>el.open=true);await address.locator('[name=latitude]').fill('٠');await address.locator('[name=longitude]').fill('٠');await change(customer,'/api/addresses/'+savedAddress.id,()=>address.locator('button[type=submit]').click(),'PATCH');
 const outside=await change(customer,'/api/coverage/'+savedAddress.id,()=>customer.locator('[data-check-coverage]').first().click(),'GET');assert.equal(outside.covered,false);assert.equal(Number(sql('SELECT count(*) FROM orders;')),0);pass('saved out-of-zone address reports actual geographic coverage without creating an order');
 await customer.locator('[data-edit-address]').first().click();assert.equal(await address.locator('[name=details]').inputValue(),'عنوان اختبار محلي ضمن منطقة الاختبار');await customer.context().setGeolocation({latitude:16.5,longitude:42.5,accuracy:8});await customer.locator('#locate-address').click();await customer.locator('#address-point-status').filter({hasText:/تم تحديد موقعك/}).waitFor();await change(customer,'/api/addresses/'+savedAddress.id,()=>address.locator('button[type=submit]').click(),'PATCH');
 const inside=await change(customer,'/api/coverage/'+savedAddress.id,()=>customer.locator('[data-check-coverage]').first().click(),'GET');assert.equal(inside.covered,true);assert.ok(inside.slots.some(x=>x.id===fixture.slot_id));pass('editing the saved delivery pin retains address details and restores the correct zone and slots');
 await closeModal(customer);await customer.locator('[data-action=cart]').first().click();await customer.locator('#checkout').click();await customer.locator('[data-address]').first().click();
 const quote=await change(customer,'/api/quotes',()=>customer.locator('[data-slot="'+fixture.slot_id+'"]').click());
 assert.equal(quote.total_halalas,2000);assert.deepEqual(stock(),{on_hand:10001,reserved:1000});assert.equal(Number(sql('SELECT booked FROM delivery_slots WHERE id='+literal(fixture.slot_id)+';')),1);
 assert.equal(Number(sql('SELECT count(*) FROM orders;')),0);pass('quote reserves stock and zone capacity before any permanent order');
 assert.equal(quote.store_profile.id,merchant.published.id);await customer.locator('#quote-store-policies').getByText('متجر اختبار السياسات',{exact:true}).waitFor();pass('checkout loads the immutable published merchant policy before enabling confirmation');
 const confirmed=await change(customer,'/api/orders',()=>customer.locator('#confirm-order').click());
 const code=(await customer.locator('.delivery-code').innerText()).trim();assert.match(code,/^\d{6}$/);assert.equal(order().id,confirmed.id);assert.equal(order().total,2000);pass('reviewed COD confirmation creates one immutable commercial order');
 await customer.screenshot({path:output+'/order-confirmed.png',fullPage:true});
 await customer.locator('.success-view [data-view=orders]').click();
 phase='customer order detail';
 const initialDetail=await change(customer,'/api/orders/'+confirmed.id,()=>customer.locator('[data-order="'+confirmed.id+'"]').click(),'GET');
 assert.equal(initialDetail.original_snapshot.address.id,initialDetail.snapshot.address.id);assert.equal(initialDetail.original_snapshot.slot.id,fixture.slot_id);
 await customer.locator('.order-timeline').getByText('تم تأكيد الطلب',{exact:true}).waitFor();await customer.getByText('المبلغ المحصّل',{exact:true}).waitFor();await customer.getByText('المتبقي للتحصيل',{exact:true}).waitFor();
 await customer.getByText(initialDetail.snapshot.address.details,{exact:false}).waitFor();await closeModal(customer);
 pass('customer order shows frozen address appointment recorded timeline and separate COD amounts');


 phase='picker assignment and actual weight';
 async function assign(role){
  await admin.locator('[data-page=orders]').click();await admin.locator('[data-action=assign-order][data-id="'+confirmed.id+'"]').click();
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
 const directions=new URL(await courier.locator('[data-delivery-directions]').getAttribute('href'));assert.equal(directions.origin,'https://www.google.com');assert.equal(directions.searchParams.get('destination'),'16.5,42.5');assert.match(await courier.locator('[data-delivery-phone]').getAttribute('href'),/^tel:\+9665\d{8}$/);
 pass('assigned courier can open the exact delivery destination and validated recipient telephone');
 await courier.context().grantPermissions(['geolocation'],{origin});await courier.context().setGeolocation({latitude:16.51,longitude:42.51,accuracy:15});await change(courier,'/api/ops/orders/'+confirmed.id+'/location',()=>courier.locator('[data-action=share-location]').click());
 await customer.locator('[data-order="'+confirmed.id+'"]').click();const tracked=await change(customer,'/api/orders/'+confirmed.id+'/tracking',()=>customer.locator('#refresh-tracking').click(),'GET');assert.equal(tracked.location_state,'recent');
 await customer.locator('#order-tracking').getByText(/آخر موقع مسجل للمندوب/).waitFor();assert.match(await customer.locator('#order-tracking a').getAttribute('href'),/16.51%2C42.51/);await closeModal(customer);
 pass('customer tracking displays a real recorded point and its timestamp without a fabricated live route');

 await change(courier,'/api/ops/orders/'+confirmed.id+'/fail',()=>courier.locator('[data-action=fail]').click());assert.equal(order().delivery,'failed');assert.equal(order().collected,0);assert.equal(order().settled,0);assert.deepEqual(stock(),{on_hand:9101,reserved:0});
 const failedEvent=value('SELECT jsonb_build_object(\'actor_id\',actor_id,\'reason\',reason,\'created_at\',created_at) FROM order_events WHERE order_id='+literal(confirmed.id)+" AND event='delivery_failed';");assert.equal(failedEvent.actor_id,sql('SELECT id FROM users WHERE email='+literal(fixture.accounts.courier)+';'));assert.equal(failedEvent.reason,'تم التحقق في اختبار المستودع');assert.ok(failedEvent.created_at>0);
 await change(courier,'/api/ops/orders/'+confirmed.id+'/dispatch',()=>courier.locator('[data-action=dispatch]').click());pass('failed delivery preserves reason actor time and consumed stock without collecting cash before a real retry');
 await courier.locator('[data-action=deliver]').click();await courier.locator('#deliver-form [name=code]').fill(code);
 await change(courier,'/api/ops/orders/'+confirmed.id+'/deliver',()=>courier.locator('#deliver-form button').click());
 assert.equal(order().delivery,'delivered');assert.equal(order().collected,0);assert.equal(order().settled,0);pass('delivery proof never collects or settles cash automatically');
 await customer.locator('[data-order="'+confirmed.id+'"]').click();const endedTracking=await change(customer,'/api/orders/'+confirmed.id+'/tracking',()=>customer.locator('#refresh-tracking').click(),'GET');assert.equal(endedTracking.latitude,null);await customer.locator('#order-tracking').getByText(/انتهت مشاركة موقع/).waitFor();assert.equal(await customer.locator('#order-tracking a').count(),0);await closeModal(customer);
 pass('completed delivery removes location sharing while uncollected cash remains distinguishable');

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

 phase='administrator customer review';
 await admin.locator('[data-page=customers]').click();await admin.locator('#customer-search [name=q]').fill('عميل رحلة جنى');await change(admin,'/api/ops/customers',()=>admin.locator('#customer-search button').click(),'GET');const customerId=sql('SELECT id FROM users WHERE email='+literal(fixture.prefix+'browser@example.invalid')+';');const review=await change(admin,'/api/ops/customers/'+customerId,()=>admin.locator('[data-action=customer-detail][data-id="'+customerId+'"]').click(),'GET');assert.equal(review.orders_count,1);assert.equal(review.orders[0].total_halalas,1800);assert.equal(review.orders[0].refunded_halalas,100);assert.ok(Number(sql("SELECT count(*) FROM audit_log WHERE action='customer_record_viewed' AND entity_id="+literal(customerId)+';'))>=1);pass('administrator searches real customers and reviews audited order activity');

 phase='versioned weight policy and picking';
 await closeModal(admin);await admin.locator('[data-page=catalog]').click();await admin.locator('[data-action=new-product]').click();const productForm=admin.locator('#product-version-form');
 await productForm.locator('[name=title]').fill('فاكهة بحدود وزن الاختبار');await productForm.locator('[name=size_label]').fill('1 كجم');await productForm.locator('[name=price]').fill('20');await productForm.locator('[name=image_url]').fill(origin+'/assets/icon.svg');await productForm.locator('[name=stock_id]').selectOption(fixture.stock_id);await productForm.locator('[name=base_qty]').fill('1000');await productForm.locator('[name=weight_under]').fill('20');await productForm.locator('[name=weight_over]').fill('20');
 const weightVersion=await change(admin,'/api/ops/products',()=>productForm.locator('button[type=submit]').click());assert.equal(weightVersion.offerings[0].weight_over_bps,2000);assert.equal(weightVersion.offerings[0].weight_under_bps,2000);
 await admin.locator('details').filter({has:admin.locator('[data-action=activate-product-version][data-id="'+weightVersion.id+'"]')}).locator('summary').click();
 await change(admin,'/api/ops/product-versions/'+weightVersion.id+'/activate',()=>admin.locator('[data-action=activate-product-version][data-id="'+weightVersion.id+'"]').click());pass('administrator creates and activates an immutable sellable weight policy');
 await customer.reload();const publishedImage=customer.locator('[data-product="'+weightVersion.offerings[0].id+'"] img');await publishedImage.waitFor();await publishedImage.scrollIntoViewIfNeeded();await publishedImage.evaluate(img=>img.decode());assert.ok(await publishedImage.evaluate(img=>img.naturalWidth>0));pass('configured product image is rendered and decoded on the real storefront');await customer.locator('[data-add="'+weightVersion.offerings[0].id+'"]').click();await customer.locator('[data-action=cart]').first().click();await customer.locator('#checkout').click();await customer.locator('[data-address]').first().click();
 const weightQuote=await change(customer,'/api/quotes',()=>customer.locator('[data-slot="'+fixture.slot_id+'"]').click());assert.equal(weightQuote.lines[0].weight_policy.max_base,1200);await customer.getByText(/الزيادة المسموحة مجانًا/).waitFor();
 const weightOrder=await change(customer,'/api/orders',()=>customer.locator('#confirm-order').click());assert.deepEqual(stock(),{on_hand:9101,reserved:1000});
 await admin.locator('[data-page=orders]').click();await change(admin,'/api/ops/orders/'+weightOrder.id+'/start',()=>admin.locator('[data-action=start][data-id="'+weightOrder.id+'"]').click());await admin.locator('[data-action=open-pick][data-id="'+weightOrder.id+'"]').click();
 const actualInput=admin.locator('[data-actual] [name=actual_base]');assert.equal(await actualInput.getAttribute('min'),'800');assert.equal(await actualInput.getAttribute('max'),'1200');await actualInput.fill('1100');
 const weightResult=await change(admin,'/api/ops/orders/'+weightOrder.id+'/actual',()=>admin.locator('[data-actual] button').click());assert.equal(weightResult.total_halalas,2000);assert.deepEqual(stock(),{on_hand:9101,reserved:1100});
 await change(admin,'/api/ops/orders/'+weightOrder.id+'/finalize',()=>admin.locator('[data-finalize]').click());assert.deepEqual(stock(),{on_hand:8001,reserved:0});pass('reviewed weight range permits real extra stock with no extra customer charge and consumes actual quantity');
 phase='inventory disposal and finance evidence';
 await inventory.locator('[data-action=refresh]').click();
 let disposed=0;
 for(const [kind,quantity]of [['waste',100],['damage',50],['supplier_return',50]]){
  await inventory.locator('[data-action=dispose-lot][data-id="'+lot.id+'"]').click();const form=inventory.locator('#disposal-form');await form.locator('[name=kind]').selectOption(kind);await form.locator('[name=quantity_base]').fill(String(quantity));await form.locator('[name=reference]').fill('E2E-DISPOSAL-'+kind);await form.locator('[name=reason]').fill('إخراج موثق في اختبار المستودع');
  const event=await change(inventory,'/api/ops/lots/'+lot.id+'/disposal',()=>form.locator('button[type=submit]').click());assert.equal(event.kind,kind);assert.equal(event.quantity_base,quantity);assert.equal(event.value_halalas,quantity);assert.equal(event.cost_basis,'recorded');disposed+=quantity;assert.deepEqual(stock(),{on_hand:8001-disposed,reserved:0});
 }
 pass('warehouse records waste damage and supplier return with actual stock and cost movements');
 await finance.locator('[data-page=disposals]').click();await finance.getByText('E2E-DISPOSAL-supplier_return',{exact:false}).waitFor();assert.equal(await finance.locator('.data-table tbody tr').count(),3);assert.equal(await finance.locator('[data-action=dispose-lot]').count(),0);assert.equal(Number(sql("SELECT count(*) FROM audit_log WHERE action='inventory_disposed';")),3);
 pass('finance reviews immutable disposal documents without recording supplier repayment or gaining write access');
 phase='stock movement ledger';
 await finance.locator('[data-page=movements]').click();const movementForm=finance.locator('#movement-filters');await movementForm.locator('[name=reason]').selectOption('waste');await movementForm.locator('[name=reference]').fill('E2E-DISPOSAL-waste');
 const ledger=await change(finance,'/api/ops/movements',()=>movementForm.locator('button[type=submit]').click(),'GET');assert.equal(ledger.items.length,1);assert.equal(ledger.items[0].on_hand_delta,-100);assert.equal(ledger.items[0].reserved_delta,0);assert.equal(ledger.items[0].value_delta_halalas,-100);await finance.locator('[data-movement="'+ledger.items[0].id+'"]').waitFor();assert.equal(await finance.locator('.data-table tbody tr').count(),1);
 await change(finance,'/api/ops/movements',()=>finance.locator('#movements-reset').click(),'GET');assert.ok(await finance.locator('.data-table tbody tr').count()>3);assert.deepEqual(stock(),{on_hand:7801,reserved:0});
 pass('finance filters real signed stock and cost ledger by document then restores history without changing inventory');
 phase='customer return receipt and quality inspection';
 const beforeReturnOrder=value('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(confirmed.id)+';');
 await inventory.locator('[data-page=customer-returns]').click();await inventory.locator('[data-action=new-customer-return]').click();await inventory.locator('#return-lookup [name=order_number]').fill(confirmed.number);
 const returnContext=await change(inventory,'/api/ops/customer-returns/context',()=>inventory.locator('#return-lookup button').click(),'GET');const returnSource=returnContext.items.find(x=>x.lot_id===lot.id);assert.ok(returnSource&&returnSource.returnable_base>=130);
 const returnForm=inventory.locator('#customer-return-form');await returnForm.locator('[name=source_movement_id]').selectOption(returnSource.source_movement_id);await returnForm.locator('[name=quantity_base]').fill('100');await returnForm.locator('[name=reference]').fill('E2E-CUSTOMER-RETURN');await returnForm.locator('[name=reason]').fill('استلام مرتجع فعلي في اختبار المستودع');
 const receipt=await change(inventory,'/api/ops/customer-returns',()=>returnForm.locator('button[type=submit]').click());assert.equal(receipt.state,'pending');assert.deepEqual(stock(),{on_hand:7801,reserved:0});assert.deepEqual(value('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(confirmed.id)+';'),beforeReturnOrder);
 pass('physical customer return is linked to a shipped lot and stays quarantined without altering cash or usable stock');
 await inventory.locator('[data-action=inspect-customer-return][data-id="'+receipt.id+'"]').click();const inspectionForm=inventory.locator('#return-inspection-form');assert.equal(await inspectionForm.locator('[name=accepted_base]').inputValue(),'');await inspectionForm.locator('[name=accepted_base]').fill('60');await inspectionForm.locator('[name=note]').fill('قبول ستين جرامًا وعزل الباقي بعد الفحص');
 const inspected=await change(inventory,'/api/ops/customer-returns/'+receipt.id+'/inspection',()=>inspectionForm.locator('button[type=submit]').click());assert.equal(inspected.accepted_base,60);assert.equal(inspected.rejected_base,40);assert.equal(inspected.restored_cost_halalas,60);assert.deepEqual(stock(),{on_hand:7861,reserved:0});assert.deepEqual(value('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(confirmed.id)+';'),beforeReturnOrder);
 pass('warehouse quality approval restores only accepted quantity at original cost and preserves rejected quarantine and financial history');
 const returnFinance=await change(finance,'/api/ops/customer-returns',()=>finance.locator('[data-page=customer-returns]').click(),'GET');assert.equal(returnFinance.items.find(x=>x.id===receipt.id).inspection.restored_cost_halalas,60);assert.equal(await finance.locator('[data-action=new-customer-return]').count(),0);assert.equal(await finance.locator('[data-action=inspect-customer-return]').count(),0);
 const returnSupport=await change(support,'/api/ops/customer-returns',()=>support.locator('[data-page=customer-returns]').click(),'GET');assert.equal(returnSupport.items.find(x=>x.id===receipt.id).inspection.restored_cost_halalas,undefined);assert.equal(await support.locator('[data-action=inspect-customer-return]').count(),0);
 pass('finance reviews return cost while support receives redacted status and neither gains warehouse write controls');

 phase='rejected return custody closure';
 const custodyPath='/api/ops/customer-returns/'+receipt.id+'/dispositions',custodyStock=stock();
 const custodyEntries=sql("SELECT jsonb_build_object('cash',(SELECT count(*) FROM cash_entries),'cost',(SELECT count(*) FROM inventory_cost_entries),'movements',(SELECT count(*) FROM stock_movements));");
 for(const [kind,quantity,reference,remaining]of [['destroyed',15,'E2E-DESTROYED',25],['supplier_handover',25,'E2E-HANDOVER',0]]){
  await change(inventory,custodyPath,()=>inventory.locator('[data-action=return-custody][data-id="'+receipt.id+'"]').click(),'GET');
  const dispositionForm=inventory.locator('#return-disposition-form');assert.equal(await dispositionForm.locator('[name=quantity_base]').inputValue(),'');assert.equal(await dispositionForm.locator('[name=completed]').isChecked(),false);
  await dispositionForm.locator('[name=kind]').selectOption(kind);await dispositionForm.locator('[name=quantity_base]').fill(String(quantity));await dispositionForm.locator('[name=reference]').fill(reference);await dispositionForm.locator('[name=note]').fill('تسجيل التصرف المنفذ في بيئة الاختبار');
  if(kind==='supplier_handover')await dispositionForm.locator('[name=recipient]').fill('مورد الاختبار والجهة المستلمة');
  await dispositionForm.locator('[name=completed]').check();
  const recorded=await change(inventory,custodyPath,()=>dispositionForm.locator('button[type=submit]').click());assert.equal(recorded.remaining_base,remaining);assert.equal(recorded.state,remaining?'partial':'closed');assert.deepEqual(stock(),custodyStock);
 }
 assert.equal(sql("SELECT jsonb_build_object('cash',(SELECT count(*) FROM cash_entries),'cost',(SELECT count(*) FROM inventory_cost_entries),'movements',(SELECT count(*) FROM stock_movements));"),custodyEntries);
 assert.deepEqual(value('SELECT to_jsonb(o) FROM orders o WHERE id='+literal(confirmed.id)+';'),beforeReturnOrder);
 pass('warehouse closes rejected custody by partial destruction and documented handover without changing stock cost or money');
 await change(inventory,custodyPath,()=>inventory.locator('[data-action=return-custody][data-id="'+receipt.id+'"]').click(),'GET');assert.equal(await inventory.locator('#return-disposition-form').count(),0);assert.equal(await inventory.locator('[data-return-disposition]').count(),2);await inventory.getByText('لا توجد كمية مرفوضة متبقية في العهدة.',{exact:true}).waitFor();await closeModal(inventory);
 pass('closed custody displays two immutable documents and removes the warehouse disposition form');
 for(const reader of [finance,support]){
  const evidence=await change(reader,custodyPath,()=>reader.locator('[data-action=return-custody][data-id="'+receipt.id+'"]').click(),'GET');assert.equal(evidence.receipt.remaining_base,0);assert.equal(evidence.items.length,2);assert.equal(await reader.locator('#return-disposition-form').count(),0);await reader.getByText('E2E-HANDOVER',{exact:false}).waitFor();await closeModal(reader);
 }
 pass('finance and support review real custody documents without receiving warehouse write controls');
 phase='fixed basket component measurements';
 // Setup uses the real authenticated Edge/SQL path inside the disposable harness.
 const fixturePost=(page,path,body)=>page.evaluate(async({path,body})=>{const {post}=await import('/assets/common.js');return post(path,body)},{path,body});
 const basketPiece=await fixturePost(inventory,'/api/ops/stock',{name:'قطع اختبار مكونات السلة',base_unit:'piece'});
 const pieceLot=await fixturePost(inventory,'/api/ops/lots',{stock_id:basketPiece.id,received_base:100,total_cost_halalas:1000,expires_at:Date.now()+3*86400000,receipt_reference:'E2E-BASKET-PIECES'});
 await fixturePost(inventory,'/api/ops/lots/'+pieceLot.id+'/inspect',{state:'accepted',note:'فحص قطع اختبار المكونات'});
 await admin.locator('[data-page=catalog]').click();await admin.locator('[data-action=new-product]').click();const basketForm=admin.locator('#product-version-form');
 await basketForm.locator('[name=title]').fill('سلة اختبار القياس الفعلي');await basketForm.locator('[name=kind]').selectOption('basket');await basketForm.locator('[name=size_label]').fill('سلة');await basketForm.locator('[name=sale_unit]').selectOption('basket');await basketForm.locator('[name=price]').fill('20');await basketForm.locator('[name=stock_id]').selectOption(fixture.stock_id);await basketForm.locator('[name=base_qty]').fill('1000');
 await basketForm.locator('[data-add-component]').click();await basketForm.locator('.component-edit').nth(1).locator('[name=stock_id]').selectOption(basketPiece.id);await basketForm.locator('.component-edit').nth(1).locator('[name=base_qty]').fill('3');
 const basketVersion=await change(admin,'/api/ops/products',()=>basketForm.locator('button[type=submit]').click());
 await admin.locator('details').filter({has:admin.locator('[data-action=activate-product-version][data-id="'+basketVersion.id+'"]')}).locator('summary').click();await change(admin,'/api/ops/product-versions/'+basketVersion.id+'/activate',()=>admin.locator('[data-action=activate-product-version][data-id="'+basketVersion.id+'"]').click());
 await customer.reload();await customer.locator('[data-add="'+basketVersion.offerings[0].id+'"]').click();await customer.locator('[data-add="'+basketVersion.offerings[0].id+'"]').click();await customer.locator('[data-action=cart]').first().click();await customer.locator('#checkout').click();await customer.locator('[data-address]').first().click();
 const basketQuote=await change(customer,'/api/quotes',()=>customer.locator('[data-slot="'+fixture.slot_id+'"]').click());assert.equal(basketQuote.lines[0].qty,2);assert.equal(basketQuote.total_halalas,4000);
 const basketOrder=await change(customer,'/api/orders',()=>customer.locator('#confirm-order').click());const basketBalance=stock();assert.deepEqual(basketBalance,{on_hand:7861,reserved:2000});
 await admin.locator('[data-page=orders]').click();await change(admin,'/api/ops/orders/'+basketOrder.id+'/start',()=>admin.locator('[data-action=start][data-id="'+basketOrder.id+'"]').click());await admin.locator('[data-action=open-pick][data-id="'+basketOrder.id+'"]').click();
 await admin.locator('[data-components]').waitFor();assert.equal(await admin.locator('[data-components] [name=component_0]').inputValue(),'');assert.ok(await admin.locator('[data-finalize]').isDisabled());
 pass('fixed basket editor and checkout retain both sold components while preparation requires actual measurements');
 await admin.locator('[data-components] [name=component_0]').fill('1999');await admin.locator('[data-components] [name=component_1]').fill('6');await admin.locator('[data-components] [name=measured]').check();
 const shortage=await change(admin,'/api/ops/orders/'+basketOrder.id+'/components',()=>admin.locator('[data-components] button').click());assert.equal(shortage.matches,false);assert.equal(shortage.total_halalas,4000);await admin.getByText('يوجد فرق في مكونات السلة؛ عالجه قبل إنهاء التجهيز',{exact:true}).waitFor();assert.ok(await admin.locator('[data-finalize]').isDisabled());assert.deepEqual(stock(),basketBalance);
 pass('real component shortage is recorded and blocks finishing without changing price or stock');
 await admin.locator('[data-components] [name=component_0]').fill('2000');await admin.locator('[data-components] [name=measured]').check();
 const completeBasket=await change(admin,'/api/ops/orders/'+basketOrder.id+'/components',()=>admin.locator('[data-components] button').click());assert.ok(completeBasket.matches);await admin.getByText('تم تسجيل جميع المكونات بالكميات المطلوبة',{exact:true}).waitFor();
 await change(admin,'/api/ops/orders/'+basketOrder.id+'/finalize',()=>admin.locator('[data-finalize]').click());assert.deepEqual(stock(),{on_hand:5861,reserved:0});assert.equal(Number(sql('SELECT on_hand_base FROM stock_balances WHERE stock_id='+literal(basketPiece.id)+';')),94);assert.equal(Number(sql('SELECT total_halalas FROM orders WHERE id='+literal(basketOrder.id)+';')),4000);
 pass('corrected gram and piece measurements permit exact FEFO consumption at the customer-approved basket price');
 phase='external notification state';
 const channelState=await change(admin,'/api/ops/notification-jobs',()=>admin.locator('[data-page=notification-jobs]').click(),'GET');assert.ok(channelState.channels.every(x=>!x.enabled));assert.equal(channelState.items.length,0);assert.ok(Number(sql('SELECT count(*) FROM notifications;'))>0);assert.equal(Number(sql('SELECT count(*) FROM notification_outbox;')),0);await admin.getByText('لا توجد محاولات إرسال خارجية').waitFor();pass('core in-app notifications persist while all external channels and outbound jobs remain disabled');

 phase='customer order history pagination';
 const historyPrefix=fixture.prefix.slice(0,14)+'h';
 sql("INSERT INTO quotes SELECT clone.* FROM quotes q CROSS JOIN generate_series(1,115)n CROSS JOIN LATERAL jsonb_populate_record(NULL::quotes,to_jsonb(q)||jsonb_build_object('id',"+literal(historyPrefix)+"||'q'||lpad(n::text,3,'0'),'snapshot','{}'::json))clone WHERE q.id="+literal(confirmed.quote_id||sql('SELECT quote_id FROM orders WHERE id='+literal(confirmed.id)+';'))+';');
 sql("INSERT INTO orders SELECT clone.* FROM orders o CROSS JOIN generate_series(1,115)n CROSS JOIN LATERAL jsonb_populate_record(NULL::orders,to_jsonb(o)||jsonb_build_object('id',"+literal(historyPrefix)+"||'o'||lpad(n::text,3,'0'),'number',"+literal(historyPrefix)+"||lpad(n::text,3,'0'),'quote_id',"+literal(historyPrefix)+"||'q'||lpad(n::text,3,'0'),'snapshot','{}'::json,'original_snapshot','{}'::json,'status','cancelled','fulfillment_state','cancelled','delivery_state','cancelled','payment_state','cancelled','total_halalas',0,'collected_halalas',0,'refunded_halalas',0,'settled_halalas',0,'courier_refunded_halalas',0,'code_hash',NULL))clone WHERE o.id="+literal(confirmed.id)+';');
 const expectedHistory=Number(sql('SELECT count(*) FROM orders WHERE user_id='+literal(customerId)+';'));
 await closeModal(customer);await customer.setViewportSize({width:390,height:844});await customer.locator('[data-view=orders]:visible').first().click();await customer.locator('#more-orders').waitFor();assert.equal(await customer.locator('[data-order]').count(),25);
 await change(customer,'/api/orders',()=>customer.locator('#more-orders').click(),'GET');await customer.locator('[data-order]').nth(49).waitFor();assert.equal(await customer.locator('[data-order]').count(),50);
 while(await customer.locator('[data-order]').count()<expectedHistory){const nextCount=Math.min(expectedHistory,(await customer.locator('[data-order]').count())+25);await change(customer,'/api/orders',()=>customer.locator('#more-orders').click(),'GET');await customer.locator('[data-order]').nth(nextCount-1).waitFor()}assert.equal(await customer.locator('#more-orders').count(),0);
 const displayed=await customer.locator('[data-order]').evaluateAll(nodes=>nodes.map(n=>n.dataset.order));assert.equal(displayed.length,expectedHistory);assert.equal(new Set(displayed).size,expectedHistory);
 await customer.screenshot({path:output+'/order-history-phone.png',fullPage:true});
 pass('customer loads all older orders beyond 100 on phone width without missing or duplicated cards');

 phase='staff order pagination and failed page retry';
 const expectedStaff=Number(sql('SELECT count(*) FROM orders;'));
 await closeModal(admin);await admin.setViewportSize({width:390,height:844});
 await change(admin,'/api/ops/orders',()=>admin.locator('[data-page=orders]').click(),'GET');
 await admin.locator('[data-action=orders-more]').waitFor();assert.equal(await admin.locator('[data-action=detail]').count(),50);
 await admin.route('**/api/ops/orders?*',route=>route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({error:{code:'FIXTURE_UNAVAILABLE',message:'تعذر تحميل الصفحة التجريبية'}})}));
 await admin.locator('[data-action=orders-more]').click();await admin.getByText('تعذر تحميل الصفحة التجريبية',{exact:true}).waitFor();
 assert.equal(await admin.locator('[data-action=detail]').count(),50);assert.equal(await admin.locator('[data-action=orders-more]').isEnabled(),true);
 await admin.unroute('**/api/ops/orders?*');
 while(await admin.locator('[data-action=detail]').count()<expectedStaff){const nextCount=Math.min(expectedStaff,(await admin.locator('[data-action=detail]').count())+50);await change(admin,'/api/ops/orders',()=>admin.locator('[data-action=orders-more]').click(),'GET');await admin.locator('[data-action=detail]').nth(nextCount-1).waitFor()}
 const staffIds=await admin.locator('[data-action=detail]').evaluateAll(nodes=>nodes.map(n=>n.dataset.id));assert.equal(staffIds.length,expectedStaff);assert.equal(new Set(staffIds).size,expectedStaff);assert.equal(await admin.locator('[data-action=orders-more]').count(),0);
 assert.equal(await admin.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 pass('staff phone view retries a failed page and reaches all older orders beyond 100 without lost or duplicate cards');
 await change(admin,'/api/ops/orders',()=>admin.locator('[data-action=refresh]').click(),'GET');await admin.locator('[data-action=orders-more]').waitFor();assert.equal(await admin.locator('[data-action=detail]').count(),50);
 await admin.screenshot({path:output+'/staff-order-pages-phone.png',fullPage:false});
 pass('staff refresh resets the history cursor and loaded count to the current first page');

 phase='customer password change and session invalidation';
 const secondPhone=await pageFor('phone_second');await secondPhone.locator('[data-view=account]').first().click();await secondPhone.locator('[data-login]').click();await secondPhone.locator('#auth-form [name=email]').fill('0500000002');await secondPhone.locator('#auth-form [name=password]').fill(password);await change(secondPhone,'/api/auth/login',()=>secondPhone.locator('#auth-form button[type=submit]').click());
 await phoneCustomer.locator('[data-action=password]').click();const passwordForm=phoneCustomer.locator('#password-form'),replacement='Changed-browser-fixture-password!';
 await passwordForm.locator('[name=current]').fill(password);await passwordForm.locator('[name=next]').fill(replacement);await passwordForm.locator('[name=confirmation]').fill('mismatch');await passwordForm.locator('button').click();await phoneCustomer.locator('#password-error').getByText(/لا يطابق/).waitFor();
 await passwordForm.locator('[name=confirmation]').fill(replacement);const changedPassword=await change(phoneCustomer,'/api/auth/password',()=>passwordForm.locator('button').click());assert.equal(changedPassword.sign_in_again,true);await phoneCustomer.locator('[data-login]').waitFor();assert.equal(Number(sql('SELECT count(*) FROM sessions WHERE user_id='+literal(phoneLogin.user.id)+';')),0);
 assert.equal(await secondPhone.evaluate(async()=>{const r=await fetch('/api/auth/me');return r.status}),401);
 await phoneCustomer.locator('[data-login]').click();await phoneCustomer.locator('#auth-form [name=email]').fill('0500000002');await phoneCustomer.locator('#auth-form [name=password]').fill(replacement);const afterPassword=await change(phoneCustomer,'/api/auth/login',()=>phoneCustomer.locator('#auth-form button[type=submit]').click());assert.equal(afterPassword.user.id,phoneLogin.user.id);
 pass('password confirmation blocks mismatch and successful rotation signs out both browsers before new-password login');
 assert.deepEqual(errors,[],'Browser JavaScript errors');assert.deepEqual(harness.failures,[],'Gateway server errors');
 pass('all seven role interfaces complete the real database journey without JavaScript or server errors');
 await fs.writeFile(output+'/results.json',JSON.stringify({status:'passed',checks},null,2));
 console.log('Browser journey complete: '+checks.length+' checks');
}catch(error){
 console.error('FAILED PHASE: '+phase);console.error(error);for(const [role,page] of Object.entries(pages))console.error('FIXTURE PAGE '+role+': '+(await page.locator('body').innerText()).slice(0,8000));
 for(const [role,page] of Object.entries(pages)){await page.screenshot({path:output+'/failure-'+role+'.png',fullPage:true}).catch(()=>{});await fs.writeFile(output+'/failure-'+role+'.txt',await page.locator('body').innerText()).catch(()=>{})}
 await fs.writeFile(output+'/results.json',JSON.stringify({status:'failed',phase,checks,error:String(error),browserErrors:errors,gatewayErrors:harness.failures},null,2));process.exitCode=1;
}finally{await browser.close();await harness.close()}
