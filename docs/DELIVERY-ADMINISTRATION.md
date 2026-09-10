# Delivery zones and slot administration

New delivery-administration transactions are under validation. Do not apply the draft migration until the database/browser gates pass. They add revisions and operational metadata to zones and revisions to slots; no historical quote/order monetary data is rewritten.

Admin may create or edit a zone's name, polygon, fee, minimum spend, active state and small operational metadata object. GeoJSON is validated as a nonempty valid two-dimensional Polygon with legal coordinate bounds, positive area and at most 2,000 points. Existing application PostGIS triggers still enforce geometry; extension-owned objects are not modified. The city metadata is descriptive and does not grant coverage. Existing reserved quote terms remain fixed when prices change. Deactivation blocks new quotes; existing quotes and orders are preserved.

Admin may create or edit a slot's zone, start/end/cutoff, capacity and activation. New windows must be future dates within one year, at most 24 hours long, in an active zone. All timestamps are epoch milliseconds; web forms explicitly interpret Saudi time even on an administrator's browser in another timezone. Existing slots that have ever been referenced by a quote cannot have their zone/start/end silently changed, including through direct database updates. Create another slot instead. Capacity cannot fall below the booked count. A slot lock serializes this check with quote creation.

Each administration write requires an idempotency key. Editing also requires the previously read revision and a documented reason. A stale revision is rejected. Slot booking-count changes do not themselves advance the administration revision; the save transaction reads the locked current count. Other slot/zone changes do advance it. Audit records retain actor, previous/new settings and reason. Zone and slot deactivation require explicit confirmation in the UI. The old service creation RPC names delegate to the same validated implementation, and client roles cannot execute them directly.

The operations interface adds zone/settings review and slot/capacity review. It does not yet include a visual draw-on-map editor. The current shared inventory pool still needs warehouse segregation and fulfillment routing before operating independent city warehouses.

POST `/api/ops/zones` and POST `/api/ops/slots` create settings. PATCH `/api/ops/zones/:id` and PATCH `/api/ops/slots/:id` require `revision` and `reason`. Only explicitly allowed commercial/scheduling fields are forwarded to the database. The generic activation endpoints require actual JSON booleans.

Database coverage includes polygon/type rejection, zone-price snapshot preservation, deactivation, repeated create attempts, stale edits, booking/capacity races, schedule immutability and role/privilege constraints. The extended browser journey adds actual zone/slot creation and editing before customer checkout.
