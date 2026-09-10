import {locationFailure} from './address.mjs';

export async function currentDeliveryLocation({platform, location, browser = globalThis.navigator, timeoutMs = 12000}) {
  if (platform === 'web') {
    if (!browser?.geolocation) throw Error('تحديد الموقع غير متاح هنا. استخدم رابط Google Maps');
    return new Promise((resolve,reject) => browser.geolocation.getCurrentPosition(p => resolve(p.coords), e => reject(Error(locationFailure(e))), {enableHighAccuracy:true,timeout:timeoutMs,maximumAge:0}));
  }
  const permission = await location.requestForegroundPermissionsAsync();
  if (!permission.granted) throw Error(locationFailure({code:1}));
  if (!await location.hasServicesEnabledAsync()) throw Error('خدمات الموقع مغلقة. فعّلها من إعدادات الجهاز أو استخدم رابط Google Maps');
  let timer;
  try {
    const result = await Promise.race([
      location.getCurrentPositionAsync({accuracy:location.Accuracy.High}),
      new Promise((_,reject) => { timer = setTimeout(() => reject(Error(locationFailure({code:3}))), timeoutMs); })
    ]);
    return result.coords;
  } finally { clearTimeout(timer); }
}
