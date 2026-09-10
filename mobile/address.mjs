// Canonical address helpers. Keep the Edge and mobile copies identical (checked by tests).
export class AddressInputError extends Error {
  constructor(code, message, field = '') { super(message); this.name = 'AddressInputError'; this.code = code; this.field = field; }
}
export function latinDigits(value) {
  return String(value).replace(/[٠-٩]/g, c => String(c.charCodeAt(0) - 1632))
    .replace(/[۰-۹]/g, c => String(c.charCodeAt(0) - 1776))
    .replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '').trim();
}
export function coordinate(value, field) {
  const name = field === 'latitude' ? 'خط العرض' : 'خط الطول', limit = field === 'latitude' ? 90 : 180;
  const text = (typeof value === 'number' || typeof value === 'string') ? latinDigits(value).replace(/٫/g, '.') : '';
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(text) || !Number.isFinite(Number(text)) || Math.abs(Number(text)) > limit)
    throw new AddressInputError('INVALID_COORDINATES', `حدّد موقع التوصيل أو أدخل ${name} صحيحًا`, field);
  return Number(text);
}
export function locationPoint(latitude, longitude) {
  return {latitude: coordinate(latitude, 'latitude'), longitude: coordinate(longitude, 'longitude')};
}
export function saudiPhone(value) {
  let phone = typeof value === 'string' ? latinDigits(value).replace(/[\s()\-]/g, '') : '';
  if (/^009665\d{8}$/.test(phone)) phone = '+' + phone.slice(2);
  if (/^9665\d{8}$/.test(phone)) phone = '+' + phone;
  if (/^5\d{8}$/.test(phone)) phone = '0' + phone;
  if (!/^(05\d{8}|\+9665\d{8})$/.test(phone))
    throw new AddressInputError('ADDRESS_PHONE', 'أدخل رقم جوال سعوديًا مثل 05xxxxxxxx أو +9665xxxxxxxx', 'recipient_phone');
  return phone;
}
const textFields = {label:['اسم العنوان',1,40],details:['وصف العنوان',3,500],recipient_name:['اسم المستلم',2,80],city:['المدينة',0,100],district:['الحي',0,100],street:['الشارع',0,100],building:['المبنى',0,100],floor:['الدور',0,100],apartment:['الشقة',0,100],notes:['ملاحظات التوصيل',0,500]};
export function addressPayload(input, {partial = false} = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new AddressInputError('ADDRESS_VALIDATION', 'راجع بيانات العنوان');
  const output = {};
  for (const [field,[label,min,max]] of Object.entries(textFields)) {
    if (!Object.hasOwn(input, field) && (partial || min === 0)) continue;
    const raw = input[field], value = typeof raw === 'string' ? raw.trim() : '';
    if ((raw != null && typeof raw !== 'string') || value.length < min || value.length > max)
      throw new AddressInputError('ADDRESS_VALIDATION', `راجع ${label}: ${min ? `من ${min} إلى` : 'بحد أقصى'} ${max} حرفًا`, field);
    output[field] = value;
  }
  if (!partial || Object.hasOwn(input, 'recipient_phone')) output.recipient_phone = saudiPhone(input.recipient_phone);
  for (const field of ['latitude','longitude']) if (!partial || Object.hasOwn(input, field)) output[field] = String(coordinate(input[field], field));
  if (Object.hasOwn(input, 'is_default')) {
    if (typeof input.is_default !== 'boolean') throw new AddressInputError('ADDRESS_VALIDATION', 'راجع اختيار العنوان الافتراضي', 'is_default');
    output.is_default = input.is_default;
  }
  return output;
}
export function googleMapsLink(latitude, longitude) {
  const point = locationPoint(latitude, longitude);
  return 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(`${point.latitude},${point.longitude}`);
}
export function googleMapsSearch(address = {}) {
  const query = [address.city,address.district,address.street].filter(x => typeof x === 'string' && x.trim()).join('، ');
  return 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(query || 'جازان');
}
export function googleMapsUrl(value) {
  if (typeof value !== 'string' || value.length > 4096) throw new AddressInputError('MAP_LINK_INVALID', 'ألصق رابط موقع من Google Maps أو الإحداثيات');
  let url;
  try { url = new URL(value.trim()); } catch { throw new AddressInputError('MAP_LINK_INVALID', 'ألصق رابط موقع من Google Maps أو الإحداثيات'); }
  const host = url.hostname, path = url.pathname;
  const short = (host === 'maps.app.goo.gl' && /^\/[a-zA-Z0-9]{5,128}\/?$/.test(path)) || (host === 'goo.gl' && /^\/maps\/[a-zA-Z0-9]{3,128}\/?$/.test(path));
  const full = (['google.com','www.google.com','google.com.sa','www.google.com.sa'].includes(host) && /^\/maps(?:\/|$)/.test(path)) || (host === 'maps.google.com' && (path === '/' || /^\/maps(?:\/|$)/.test(path)));
  if (url.protocol !== 'https:' || url.username || url.password || url.port || (!short && !full))
    throw new AddressInputError('MAP_LINK_INVALID', 'استخدم رابط HTTPS مباشرًا من Google Maps');
  return {url, short};
}
const missingPoint = () => new AddressInputError('MAP_POINT_REQUIRED', 'لم نجد دبوسًا محددًا. افتح Google Maps، اضغط مطولًا على موقع التوصيل ثم انسخ إحداثيات الدبوس');
function coordinatePair(value) {
  const pair = latinDigits(value).replace(/٫/g, '.').replace(/،/g, ',').replace(/^loc:/i, '').split(',');
  if (pair.length !== 2) throw missingPoint();
  return locationPoint(pair[0], pair[1]);
}
export function parseMapLocation(value) {
  if (typeof value !== 'string' || value.length > 4096 || !value.trim()) throw missingPoint();
  if (!/^https:/i.test(value.trim())) return coordinatePair(value);
  const {url, short} = googleMapsUrl(value);
  if (short) return null;
  const points = [];
  for (const key of ['query','q','destination']) {
    const values = url.searchParams.getAll(key);
    if (values.length > 1) throw missingPoint();
    if (values.length) {
      if (url.searchParams.has('query_place_id') || url.searchParams.has('destination_place_id')) throw missingPoint();
      points.push(coordinatePair(values[0]));
    }
  }
  // @lat,lng is a camera centre, never evidence of the selected delivery pin.
  // Full place links sometimes include an explicit pin in !3dLAT!4dLNG data.
  let data;
  try { data = decodeURIComponent(url.pathname + url.search); } catch { throw missingPoint(); }
  const pins = [...data.matchAll(/!3d([+-]?[\d.]+)!4d([+-]?[\d.]+)/g)];
  if (pins.length > 1 || (/\/maps\/dir\//.test(url.pathname) && pins.length)) throw missingPoint();
  if (pins.length) points.push(locationPoint(pins[0][1], pins[0][2]));
  if (!points.length || points.some(p => p.latitude !== points[0].latitude || p.longitude !== points[0].longitude)) throw missingPoint();
  return points[0];
}
export function locationFailure(error) {
  if (error?.code === 1) return 'السماح بالموقع مغلق. فعّله من إعدادات المتصفح أو الجهاز، أو استخدم رابط Google Maps';
  if (error?.code === 3) return 'استغرق تحديد الموقع وقتًا طويلًا. حاول في مكان مفتوح أو استخدم رابط Google Maps';
  return 'تعذر تحديد موقعك. تأكد من تشغيل خدمات الموقع أو استخدم رابط Google Maps';
}
