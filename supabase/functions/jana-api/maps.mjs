import {AddressInputError, googleMapsUrl, parseMapLocation} from './address.mjs';

// Only resolve Google-owned Maps short redirects. No arbitrary URL proxy or HTML scraping.
export async function resolveMapLocation(input, {transport = fetch} = {}) {
  const direct = parseMapLocation(input);
  if (direct) return direct;
  let {url} = googleMapsUrl(input);
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 7500);
  try {
    for (let hop = 0; hop < 3; hop++) {
      const response = await transport(url.href, {method:'GET', redirect:'manual', credentials:'omit', referrerPolicy:'no-referrer', signal:controller.signal});
      await response.body?.cancel();
      const location = response.headers.get('location');
      if (![301,302,303,307,308].includes(response.status) || !location) break;
      const next = googleMapsUrl(new URL(location, url).href);
      const point = parseMapLocation(next.url.href);
      if (point) return point;
      url = next.url;
    }
    throw new AddressInputError('MAP_POINT_REQUIRED', 'تعذر قراءة الدبوس من الرابط المختصر. افتحه في Google Maps ثم انسخ إحداثيات موقع التوصيل');
  } catch (error) {
    if (error instanceof AddressInputError) throw error;
    throw new AddressInputError('MAP_UNAVAILABLE', 'تعذر فتح رابط الخرائط الآن. انسخ إحداثيات الدبوس أو استخدم موقعك الحالي');
  } finally { clearTimeout(timer); }
}

// Best-effort per-user admission within an Edge isolate; no URLs or locations are retained.
const attempts = new Map();
export function admitMapRequest(userId, now = Date.now()) {
  if (!userId) throw Object.assign(new Error('auth_required'), {status:401});
  for (const [key,value] of attempts) if (value.until <= now) attempts.delete(key);
  const value = attempts.get(userId) || {count:0,until:now + 60000};
  if (value.count >= 8 || (!attempts.has(userId) && attempts.size >= 500)) throw new Error('too_many_attempts');
  value.count++; attempts.set(userId, value);
}
