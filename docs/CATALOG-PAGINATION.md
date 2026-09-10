# Catalog query boundaries

Applied migration `20260910091656` moves public catalog filters and pagination into PostgreSQL. Each request selects at most 101 active offerings, orders ties by the immutable offering ID, and calculates inventory only for stock components on the returned page. Accepted, unexpired lots and active stock masters remain the source of advertised availability. The response remains `{items, next_offset}` and preserves current price, version, component and lineage fields.

Offsets are integers from 0 to 100,000, limits from 1 to 100 (default 50), search text at most 200 characters and category at most 100. Both Edge and PostgreSQL enforce the bounds. Search is a literal substring, including percent and underscore characters. Service-only execution privileges remain explicit. Catalog reads do not reserve anything; checkout revalidates availability transactionally.

This preserves the existing offset API. Independent page requests are not a cross-request database snapshot: concurrent product activation can shift offsets. The mobile loader rejects repeated IDs and incomplete page fetches, and customers review current commercial terms at checkout. Keyset pagination with an explicit catalog revision and server-filtered favorites/lists remain future performance work. Legacy internal full-catalog RPC callers are unchanged.

Eight disposable database groups compare the old and new item payloads, traverse 123 equal-timestamp offerings, verify literal filters and inactive/expired/pending inventory, and verify bounds and privileges. Two API tests check bounded dispatch and early validation. Application traffic and a load-tested capacity target are still required before claiming a performance SLA.

Ordering and offset tradeoffs follow the [PostgreSQL documentation](https://www.postgresql.org/docs/17/queries-limit.html). Database `34459538395`, browser `34459538351` and Node `34459538368` passed before application. Main API v19 is active. Production first-page checks return the actual requested count/next offset; original order and stock fingerprints remain unchanged.
