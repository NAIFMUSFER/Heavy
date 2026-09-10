import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {addressPayload,coordinate,googleMapsLink,googleMapsSearch,parseMapLocation,saudiPhone} from '../mobile/address.mjs';
import {resolveMapLocation,admitMapRequest} from '../supabase/functions/jana-api/maps.mjs';
import {currentDeliveryLocation} from '../mobile/location.mjs';

const valid={label:'المنزل',details:'بوابة المبنى',recipient_name:'مستلم الاختبار',recipient_phone:'0500000001',latitude:'16.5',longitude:'42.5',is_default:false};
test('address normalization stays identical across web mobile and Edge',()=>{
 const source=readFileSync('assets/address.js','utf8');
 for(const path of ['mobile/address.mjs','supabase/functions/jana-api/address.mjs'])assert.equal(readFileSync(path,'utf8'),source,path);
});
test('Arabic and Persian numeric input becomes canonical coordinates and Saudi mobile without changing the original form',()=>{
 const input={...valid,city:' جازان ',latitude:'١٦٫٥',longitude:'۴۲٫۵',recipient_phone:'\u200f٠٠٩٦٦ ٥٠-٠٠٠-٠٠٠١',unrelated:'ignored'};
 const result=addressPayload(input);assert.deepEqual(result,{...valid,city:'جازان',recipient_phone:'+966500000001'});assert.equal(input.latitude,'١٦٫٥');
 for(const phone of ['+966 50 000 0001','966500000001','00966500000001'])assert.equal(saudiPhone(phone),'+966500000001');
 for(const phone of ['٠٥٠٠٠٠٠٠٠١','500000001'])assert.equal(saudiPhone(phone),'0500000001');
});
test('empty non-finite or out-of-range coordinates are never replaced by zero or a city centre',()=>{
 for(const value of ['',null,undefined,[],true,'NaN','Infinity','1e2','0x10','١٦،٥',91,-91])assert.throws(()=>coordinate(value,'latitude'));
 assert.equal(coordinate('0','latitude'),0);assert.equal(coordinate('-180','longitude'),-180);assert.throws(()=>coordinate('180.01','longitude'));
});
test('required address fields have actionable errors while patches preserve unspecified fields and explicit false',()=>{
 assert.deepEqual(addressPayload({notes:' مدخل جانبي ',is_default:false},{partial:true}),{notes:'مدخل جانبي',is_default:false});
 for(const [field,value] of [['label',''],['details','ab'],['recipient_name','a'],['recipient_phone','123'],['is_default','false']])assert.throws(()=>addressPayload({...valid,[field]:value}),e=>e.field===field);
 assert.throws(()=>addressPayload(null));assert.throws(()=>addressPayload({...valid,city:{name:'city'}}));
});
test('official keyless Maps URLs use an encoded search pin and never mix latitude with longitude',()=>{
 const url=new URL(googleMapsLink('١٦٫٥','٤٢٫٥'));assert.equal(url.origin,'https://www.google.com');assert.equal(url.searchParams.get('api'),'1');assert.equal(url.searchParams.get('query'),'16.5,42.5');assert.equal(url.searchParams.has('key'),false);
 assert.equal(new URL(googleMapsSearch({city:'جازان',street:'A&B'})).searchParams.get('query'),'جازان، A&B');
});
test('coordinate paste and explicit Maps pins import without fetching any third party',async()=>{
 for(const input of ['١٦٫٥، ٤٢٫٥','https://www.google.com/maps/search/?api=1&query=16.5%2C42.5','https://maps.google.com/?q=loc:16.5,42.5','https://www.google.com/maps/place/Fixture/@17,43,15z/data=!4m2!3d16.5!4d42.5'])assert.deepEqual(await resolveMapLocation(input,{transport:()=>{throw Error('Unexpected network')}}),{latitude:16.5,longitude:42.5});
});
test('camera centres place names and ambiguous points cannot silently become the delivery pin',()=>{
 for(const input of ['https://www.google.com/maps/@16.5,42.5,15z','https://www.google.com/maps/search/?api=1&query=Jazan','https://www.google.com/maps/search/?query=16.5,42.5&query=17,43','https://www.google.com/maps/search/?query=16.5,42.5&query_place_id=fixture','https://www.google.com/maps/place/Fixture/data=!3d16.5!4d42.5!3d17!4d43','https://example.invalid/maps?q=16.5,42.5'])assert.throws(()=>parseMapLocation(input));
});
test('short Google Maps redirect resolves a pin with no credentials and no fetch to its final map',async()=>{
 const seen=[];const result=await resolveMapLocation('https://maps.app.goo.gl/FixturePin',{transport:async(url,options)=>{seen.push({url,options});return new Response(null,{status:302,headers:{location:'https://www.google.com/maps/place/Fixture/data=!3d16.5!4d42.5'}});}});
 assert.deepEqual(result,{latitude:16.5,longitude:42.5});assert.equal(seen.length,1);assert.equal(seen[0].options.redirect,'manual');assert.equal(seen[0].options.credentials,'omit');assert.equal(seen[0].options.headers,undefined);
});
test('shortlink resolution is bounded and stops on non-Maps redirects or unsupported responses',async()=>{
 let calls=0;await assert.rejects(resolveMapLocation('https://maps.app.goo.gl/FixturePin',{transport:async()=>{calls++;return new Response(null,{status:302,headers:{location:'https://maps.app.goo.gl/FixturePin'}});}}));assert.equal(calls,3);
 for(const location of ['https://example.invalid/','https://www.google.com/accounts/']){calls=0;await assert.rejects(resolveMapLocation('https://maps.app.goo.gl/FixturePin',{transport:async()=>{calls++;return new Response(null,{status:302,headers:{location}});}}));assert.equal(calls,1);}
 await assert.rejects(resolveMapLocation('https://maps.app.goo.gl/FixturePin',{transport:async()=>new Response(null,{status:200})}));
});
test('shortlink admission is per authenticated user and recovers after the bounded window',()=>{
 assert.throws(()=>admitMapRequest(null));for(let i=0;i<8;i++)admitMapRequest('user-fixture',1000);assert.throws(()=>admitMapRequest('user-fixture',1000));admitMapRequest('other-fixture',1000);admitMapRequest('user-fixture',61000);
});
test('native delivery location requests foreground permission once and uses one position reading',async()=>{
 const calls=[];const location={Accuracy:{High:4},requestForegroundPermissionsAsync:async()=>{calls.push('permission');return{granted:true};},hasServicesEnabledAsync:async()=>true,getCurrentPositionAsync:async options=>{calls.push(options);return{coords:{latitude:16.5,longitude:42.5,accuracy:12}};}};
 assert.equal((await currentDeliveryLocation({platform:'ios',location})).latitude,16.5);assert.deepEqual(calls,['permission',{accuracy:4}]);
 location.requestForegroundPermissionsAsync=async()=>({granted:false});await assert.rejects(currentDeliveryLocation({platform:'android',location}),/إعدادات/);assert.equal(calls.length,2);
});
test('native disabled services and a location timeout produce retry guidance without a fallback address',async()=>{
 const location={Accuracy:{High:4},requestForegroundPermissionsAsync:async()=>({granted:true}),hasServicesEnabledAsync:async()=>false,getCurrentPositionAsync:()=>new Promise(()=>{})};
 await assert.rejects(currentDeliveryLocation({platform:'android',location}),/خدمات الموقع مغلقة/);location.hasServicesEnabledAsync=async()=>true;await assert.rejects(currentDeliveryLocation({platform:'ios',location,timeoutMs:5}),/وقتًا طويلًا/);
});
