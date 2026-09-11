# Canonical API overview

Base URL: `https://jana-fresh-app.onrender.com`. All clients use the same `/api` gateway. Browser requests use same-origin cookies with `credentials: same-origin`; mutations send `X-CSRF-Token` from the separate `jana_csrf` cookie. The session cookie remains HttpOnly. Mobile uses `Authorization: Bearer <opaque JANA session>` with SecureStore. These are JANA sessions, not Supabase JWTs. Never call privileged PostgreSQL RPCs from a client.

JSON mutations use `Content-Type: application/json`. Critical writes send a stable `Idempotency-Key` of 8–128 characters. Persist that key until an uncertain result is resolved. Same key and identical canonical operation return the original result; changed payloads are rejected. A cart read or local cart edit does not reserve stock. Quote creation does.

| Area | Routes | Rules |
|---|---|---|
| Health | GET `/health`, `/ready`, `/version` | Read-only liveness, dependencies and exact deployed commit |
| Public configuration | GET `/api/config`, `/api/features` | Provider availability and guarded feature evaluation; no private keys |
| Catalog | GET `/api/catalog?limit=50&offset=0&q=&category=` | Bounded PostgreSQL pagination; canonical current availability/prices |
| Identity | POST `/api/auth/register`, `/api/auth/login`, `/api/auth/logout`; GET `/api/auth/me` | Name/password and email or Saudi phone; phone ownership is not SMS-verified |
| Password change | POST `/api/auth/password` | Current password, validated replacement, all account sessions revoked; see ORDER-JOURNEY.md |
| Profile | GET `/api/profile`; PATCH `/api/profile` | Authenticated customer; contact/preferences allowlist and identity safeguards |
| Addresses | GET/POST `/api/addresses`; PATCH/DELETE `/api/addresses/:id`; PATCH `/api/addresses/:id/default` | Ownership, typed coordinates, structured address fields |
| Coverage | GET `/api/coverage/:addressId` | PostGIS polygon lookup and real slot availability |
| Map pin import | POST `/api/maps/resolve` | Authenticated, bounded supported Google Maps pin resolution; no embedded API key |
| Saved cart | GET/PUT `/api/cart` | Customer-only, revision check and persisted retry key on writes |
| Favorites | GET/POST `/api/favorites`; DELETE `/api/favorites/:familyId` | Stable sellable lineage; authenticated ownership |
| Shopping lists | GET/POST `/api/shopping-lists`; PATCH/DELETE `/api/shopping-lists/:id` | Revision-controlled canonical selections; no implicit reservation |
| Reminders | GET/POST `/api/recurring`; PATCH/DELETE `/api/recurring/:id` | Explicit reminder consent; does not create or charge an order |
| Quotes | POST `/api/quotes` | Key required; atomic stock, lot, slot and configured coupon reservation |
| Quote recovery/release | GET/DELETE `/api/quotes/:id` | Owned read with server time/existing-order summary; explicit reservation release |
| Orders | GET/POST `/api/orders`; GET `/api/orders/:id` | POST confirms an owned, unexpired quote once; original terms retained |
| Cancellation | POST `/api/orders/:id/cancel` | Reason, allowed business state, transactional resource release |
| Substitution | POST `/api/substitutions/:id/decision` | Owner's explicit boolean decision and stable key |
| Support | GET/POST `/api/tickets`; POST `/api/tickets/:id/reply` | Customer ownership; optional order; retained transcript |
| Notifications | GET `/api/notifications`; POST `/api/notifications/:id/read` | In-app, owned records |
| Operations orders | GET `/api/ops/orders` | Database roles and assignment scope; cash tasks remain visible |
| Staff and audit | `/api/ops/staff`, `/api/ops/orders/:id/assignment`, `/api/ops/audit` | See STAFF-AND-AUDIT.md for exact methods and role/cash safeguards |
| Customers | GET `/api/ops/customers`; GET `/api/ops/customers/:id` | Admin-only keyset directory; record access is audited |
| Products | POST `/api/ops/products`; POST `/api/ops/product-versions/:id/activate` | Admin creates immutable draft/version and explicitly activates |
| Inventory | `/api/ops/stock`, `/api/ops/lots`, `/api/ops/suppliers`, `/api/ops/counts` | Warehouse role, canonical units, inspection, counts and stock/cost ledgers |
| Delivery settings | POST `/api/ops/zones`, `/api/ops/slots`; PATCH item paths | Admin-only reason, revision, valid geometry and locked capacity |
| Picking | POST `/api/ops/orders/:id/start`, `/actual`, `/finalize`; GET `/picking` | Assigned picker/admin; sold weight limits, issues, FEFO and audited consumption |
| Courier | POST `/api/ops/orders/:id/dispatch`, `/deliver`, `/fail`, `/collect` | Assigned courier; proof, failure reason and cash are separate events |
| Recorded courier location | POST `/api/ops/orders/:id/location`; GET `/api/orders/:id/tracking` | Explicit foreground location, assignment/active-attempt checks, recorded time; no automatic background publishing |
| Finance | GET `/api/ops/finance`; POST `/api/ops/orders/:id/settle`; refund completion routes | Authorized finance/admin; explicit source/reference; liability limits |
| Reports | GET `/api/ops/reports`, `/api/ops/deep-health` | Authorized summaries; unknown cost is not converted into invented profit |

For rows grouping an operational family, the actual supported methods and payloads are defined in the Edge entrypoints and their PostgreSQL RPC signature contracts. This table does not authorize arbitrary verbs or suffixes. The gateway has a fixed upstream/path allowlist.

Checkout body:

```json
{
  "address_id": "owned-address-id",
  "slot_id": "available-slot-id",
  "lines": [{"offering_id": "active-offering-id", "quantity": 1}]
}
```

These IDs are descriptive placeholders, not production records. The server supplies product versions, stock requirements, fees, discounts and the final price. A quote returns its ID, expiry and immutable line/pricing terms. Confirmation sends `{"quote_id":"reviewed-quote-id"}` with a different stable operation key. Never trust a locally computed price as the order amount.

Errors have the form `{"error":{"code":"OUT_OF_STOCK","message":"الكمية لم تعد متوفرة"}}`. Clients distinguish validation, authentication, authorization, conflict, expiration, availability and timeout. Internal SQL and stack traces are not client errors. A network timeout is an unknown result, not success or proof of rollback; retry the same operation/key. Mobile central networking and browser common networking implement this contract.

Money uses integer halalas, quantities integer canonical grams/pieces and timestamps epoch milliseconds. Human schedules use Asia/Riyadh. Stock, slot, cash and original-price invariants are database constraints and transactional RPC rules; UI controls only guide users. Provider/tax configuration and actual operator acceptance remain separately documented release requirements.

Warehouse outbound events: `GET /api/ops/lots/:id/disposal` returns current canonical context; `POST` records explicitly confirmed waste/damage/supplier return with `Idempotency-Key`. `GET /api/ops/disposals` provides paired keyset pagination for admin/inventory/finance. See INVENTORY-DISPOSALS.md.

Supplier credit evidence: `GET /api/ops/supplier-credits` lists physical supplier returns with their reference inventory cost and recorded credit notes. `POST /api/ops/disposals/:id/supplier-credits` lets admin/finance attach an actually received immutable credit-note reference and amount with `Idempotency-Key`; inventory is read-only. It does not record bank cash, alter inventory cost, or infer accounting/tax treatment. See SUPPLIER-CREDITS.md.

`GET /api/ops/movements` provides signed stock/reservation/cost history with 50-row keyset pages and exact stock/lot/type/reference plus time filters. See STOCK-MOVEMENTS.md.

Optional notification monitoring: `GET /api/ops/notification-jobs` is authenticated admin/support only and returns redacted channel states, state counts and the last 50 jobs. It cannot enable channels or send messages. See NOTIFICATION-OUTBOX.md.

Customer returns: exact shipment lookup, physical quarantined receipt, quality decision, rejected-custody disposition and role-filtered history under `/api/ops/customer-returns`. See CUSTOMER-RETURNS.md for methods, invariants and limitations; RELEASE-EVIDENCE.md records the deployed source.
