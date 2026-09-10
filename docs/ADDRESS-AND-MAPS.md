# Delivery addresses and Google Maps

The address editor supports foreground GPS, pasted latitude/longitude and explicit Google Maps pin links on the website and Expo app. It offers an official Google Maps URL to search externally and review the selected point. Location permission is requested only after pressing the location button. Native background/always permissions and tracking are disabled.

Arabic/Persian digits and the Arabic decimal separator are normalized in clients and at the authenticated API boundary. Saudi mobile numbers accept `05`, `5`, `+9665`, `9665` and `009665` with spaces or hyphens. Invalid/empty coordinates never become zero or a default city centre. City searches only open Google Maps; they do not claim a delivery pin. Text descriptions and recipient details remain required; GPS does not invent a street/building address.

`jana_save_address` still owns the atomic save, ownership checks, address limits and default-address invariant. PATCH normalization preserves omitted fields. Saved addresses can be checked against the real coverage API without entering checkout. Editing or deleting a saved address never rewrites an existing order snapshot. Store admission and actual geographic zones remain authoritative.

## What is enabled and what is free

- [Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started) open Google Maps on Android, iOS or web, require no key and are the enabled integration. Pin review uses `maps/search/?api=1&query=LAT,LNG`.
- [Maps Embed API](https://developers.google.com/maps/documentation/embed/usage-and-billing) has unlimited no-charge usage, but requires an owner-provided Google Cloud API key and the platform's account setup. It is **not enabled** here and cannot provide an address-selection callback merely by showing an iframe.
- Embedded interactive Maps JavaScript/Places/Geocoding are **not configured**. A production key and owner-approved billing/quota configuration would be required for those services. Prototype/demo keys are not production credentials. No third-party, shared or scraped API keys are used.
- The [Expo SDK 54 Location API](https://docs.expo.dev/versions/v54.0.0/sdk/location/) is pinned to `~19.0.8`. GPS does not need a Google Maps key.

## Link resolution limits

Direct coordinate URLs are parsed locally. Camera-only `@lat,lng` URLs, place names, conflicting pins and place-ID overrides are rejected with guidance to copy the delivery pin's coordinates. An `@` position is the map camera centre and is not necessarily the selected place. Full place-link `!3d…!4d…` parsing is best effort; Google may change that share-link format.

`POST /api/maps/resolve` handles Maps short links for authenticated customers, with the existing cookie CSRF/bearer guards. It follows at most three manual redirects, for at most 7.5 seconds, only between explicitly allowed HTTPS Google Maps hosts/paths. It sends no JANA credentials and reads no HTML. Redirects to other products/hosts are rejected. A best-effort per-user limit allows eight attempts per minute per Edge isolate, with at most 500 entries; it is not a distributed quota guarantee. No pasted URLs or location coordinates are retained in the limiter or logged.

Some short links require an app or a Google response that cannot be resolved by redirects. The editor then asks the customer to open the link and copy coordinates. It keeps their last valid coordinates and address details. An imported pin must be reviewed by the customer; link parsing does not verify physical delivery access or coverage.

## Source and checks

`assets/address.js` is the canonical portable module. After changing it, copy it unchanged to `mobile/address.mjs` and `supabase/functions/jana-api/address.mjs`; `tests/address.test.mjs` enforces equality. Deploy `index.ts`, `http.ts`, `address.mjs` and `maps.mjs` together for `jana-api`, preserving custom opaque-session authentication (`verify_jwt:false`). No database migration is required for this address release.

Node tests cover normalization, partial edits, explicit versus ambiguous pins, bounded resolver behavior and foreground location failure handling. The disposable browser journey covers a narrow phone viewport, GPS fixture permission, Google pin import, persistence of Arabic input, failed import retaining the form, editing coordinates and geographic coverage before a real isolated checkout. CI also replays PostgreSQL address/default/ownership/snapshot regressions and exports Expo plus Android debug and iOS simulator builds. These checks do not establish physical-device location acceptance or signed app-store release readiness.
