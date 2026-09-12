# Supplier pickup operating model — JANA

## Owner decision — 12 September 2026 (Saudi Arabia)

**No warehouses.** Staff collect/purchase the customer's requested goods from suppliers, shops and other approved sources, then hand them over for delivery. This explicit clarification supersedes warehouse, shelf and inventory-count launch requirements in earlier plans. Do not ask the owner to create a warehouse, bin or fictitious opening balance. Legacy data and endpoints are retained for compatibility and audit, not as the target business model.

The commercial intake remains closed during this transition. Do not bypass the current stock/route guards or open sales merely because pickup addresses have been entered. A location directory does not implement order procurement.

## Implemented phase 1: supplier locations

- Existing supplier IDs remain authoritative; each supplier/retailer can have multiple pickup locations. No suppliers, locations or balances are seeded.
- Admin and the existing `inventory` operations role maintain draft/active locations with an explicit reason, optimistic revision, durable idempotency and an audit trail. Technical role identifiers remain unchanged to preserve sessions and permissions.
- An active location needs a real city, address, valid coordinate pair and an active supplier. Deactivating the supplier removes its sites from picker reads immediately. A site cannot be reassigned to another supplier.
- The picker has a read-only, paged directory of active locations. Navigation and phone links require an explicit tap; no tracking or message is sent automatically. Supplier email/financial notes are not exposed by this endpoint.
- The directory has no quantity, item-availability, order assignment, purchase, receipt, stock movement or payment side effects. The response explicitly reports `order_flow_ready:false`.
- Web operations and owner handoff point to suppliers, not warehouse setup. Historical stock screens remain labelled as legacy. Native application source is not changed by this phase.

`GET /api/ops/pickup-sites?limit=50&after_id=...` returns bounded sites, a continuation ID, at most 250 supplier choices for maintainers, and an explicit truncation flag. `POST /api/ops/pickup-sites` and `PATCH /api/ops/pickup-sites/:id` require the current custom session, CSRF for cookie writes, an idempotency key, reason, and current revision for updates. Location activation means a reviewed address, not a promise of stock or commercial supplier approval.

## Implemented phase 2 backend: dormant admission and assignment

- New quotes snapshot the current displayed retail price, published seller-policy version, address and delivery slot. They reserve delivery capacity only and explicitly carry `inventory_reserved:false`, empty allocations and `to_be_purchased` lines.
- Confirmation creates exactly one order and one procurement job with immutable requested lines. It creates no balance, lot, movement, supplier cost or settlement record.
- Admin can assign an active purchasing employee through a revisioned, idempotent and audited database primitive. The legacy picker field is mirrored only for compatibility.
- The table is private with RLS. All new entry functions are revoked from clients and `service_role`; no Edge route calls them. This phase is therefore deployed backend structure, not an enabled customer or staff journey.
- Disposable tests cover concurrency, retry, cancellation, ownership, role isolation, immutable lines, unchanged inventory and deep health. Production contains zero procurement jobs and intake stays closed.
- Release `62e152d0` publishes this dormant structure through the production source and Render gateway. Publication does not grant or route the four functions; Edge and native source remain unchanged. Exact CI, deployment and post-publication safety evidence is recorded in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 3 backend: dormant purchase evidence

- The assigned employee can atomically record one supplier/site visit with an immutable supplier/location snapshot, document reference, quality note, collected quantity and actual line cost. Multiple suppliers and visits may contribute to the same order.
- Expected revisions and row locks serialize staff activity; durable idempotency returns the original result after response loss. Cumulative collected quantity cannot exceed the frozen customer request.
- Partial collection remains `collecting`; exact completion becomes `ready`. Neither state creates courier custody, supplier payable, employee reimbursement or cash settlement.
- The two tables have RLS and append-only triggers. Direct table access and the write function remain revoked from clients and `service_role`, so this structure is not reachable through Edge.
- Customer order total and displayed retail price remain unchanged. Production contains zero purchase records/lines and intake remains closed.
- Release `da417eb3` publishes this dormant evidence structure through the production source and Render gateway. The exact post-publication read confirms zero rows, unchanged business fingerprints and no Edge grant or route.

## Next engineering gates — not complete

1. **Complete order admission without warehouse stock.** The dormant quote/order core and slot-only reservation are implemented. Add the remaining collection/exception/handover primitives and only then grant the complete flow and replace the one-warehouse readiness prerequisite. Preserve existing-order snapshots, cancellation and retry behavior.
2. **Complete assigned procurement work.** Job creation, assignment and immutable multi-supplier purchase evidence are implemented. Add bounded staff reads and customer-visible progress only after exceptions are complete. Keep each order's collected goods separate and preserve historical pickup snapshots.
3. **Exceptions with customer consent.** Keep customer-approved replacement/removal and fixed-price basket constraints. Supplier cost changes must not silently change the customer's agreed retail price. No cost-plus margin, purchasing fee or delivery pricing rule is invented.
4. **Handover, delivery and finance.** Only confirmed collected quantities pass to courier custody. Separate supplier payable/purchase cost, employee purchasing advance/settlement and customer COD collection/refund. A receipt is not a payment; a supplier credit note is not a bank settlement. Keep cancellation after purchase and supplier returns explicit and auditable.
5. **Web/native acceptance and launch.** Update catalog availability, carts, quote recovery, staff/customer labels and native models together. Test zero-warehouse journeys, multiple suppliers, concurrent staff actions, partial collection, refusal, cancellation and response loss in disposable environments. Only then replace commercial readiness and obtain actual owner operating acceptance. Signed stores and physical devices remain separate requirements.

## Owner inputs

Real supplier/shop names and pickup contacts/addresses, approved catalog and retail prices, actual delivery geography/capacity and staff responsibilities can be prepared now. Merchant identity/policies/tax status and approved provider accounts remain required. No warehouse address or stock count is an owner prerequisite. Payment timing with suppliers, advances and any variable-pricing policy need explicit operating rules before enabling financial actions.

## Evidence and safety

Phase 1 adds the supplier directory through schema/RPC, Edge routing and web forms. Phase 2 adds a deliberately ungranted database admission/assignment core only. Refer to [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md) for actual CI/application/publication results; source alone is not deployment. The disposable suite verifies retries, races, roles, immutable requests and unchanged warehouse/stock/order/cash/slot fingerprints. Existing legacy tests remain regression protection and are not acceptance of the new business flow.

Custom-session authentication and intentional `verify_jwt:false` are preserved. Do not create commercial fixtures in production or erase historical records to make a check pass.
