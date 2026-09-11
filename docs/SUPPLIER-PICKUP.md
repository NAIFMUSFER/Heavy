# Supplier pickup operating model — JANA

## Owner decision — 12 September 2026 (Saudi Arabia)

**No warehouses.** Staff collect/purchase the customer's requested goods from suppliers, shops and other approved sources, then hand them over for delivery. This explicit clarification supersedes warehouse, shelf and inventory-count launch requirements in earlier plans. Do not ask the owner to create a warehouse, bin or fictitious opening balance. Legacy data and endpoints are retained for compatibility and audit, not as the target business model.

The commercial intake remains closed during this transition. Do not bypass the current stock/route guards or open sales merely because pickup addresses have been entered. A location directory does not implement order procurement.

## Implemented candidate: supplier locations

- Existing supplier IDs remain authoritative; each supplier/retailer can have multiple pickup locations. No suppliers, locations or balances are seeded.
- Admin and the existing `inventory` operations role maintain draft/active locations with an explicit reason, optimistic revision, durable idempotency and an audit trail. Technical role identifiers remain unchanged to preserve sessions and permissions.
- An active location needs a real city, address, valid coordinate pair and an active supplier. Deactivating the supplier removes its sites from picker reads immediately. A site cannot be reassigned to another supplier.
- The picker has a read-only, paged directory of active locations. Navigation and phone links require an explicit tap; no tracking or message is sent automatically. Supplier email/financial notes are not exposed by this endpoint.
- The directory has no quantity, item-availability, order assignment, purchase, receipt, stock movement or payment side effects. The response explicitly reports `order_flow_ready:false`.
- Web operations and owner handoff point to suppliers, not warehouse setup. Historical stock screens remain labelled as legacy. Native application source is not changed by this phase.

`GET /api/ops/pickup-sites?limit=50&after_id=...` returns bounded sites, a continuation ID, at most 250 supplier choices for maintainers, and an explicit truncation flag. `POST /api/ops/pickup-sites` and `PATCH /api/ops/pickup-sites/:id` require the current custom session, CSRF for cookie writes, an idempotency key, reason, and current revision for updates. Location activation means a reviewed address, not a promise of stock or commercial supplier approval.

## Next engineering gates — not complete

1. **Order admission without warehouse stock.** Introduce an explicit fulfillment model on new quotes/orders. Snapshot retail terms and delivery capacity; reserve neither warehouse lots nor fictitious supplier stock. Define bounded supplier availability/confirmation separately from actual purchased quantities. Preserve existing-order snapshots, cancellation and retry behavior. Retire the one-warehouse route prerequisite for the new mode only once its replacement is tested.
2. **Assigned procurement work.** Freeze the requested lines/components, assign a purchasing employee, record chosen supplier/site per pickup, and keep each order's collected goods separate. One order may require several shops; one shop may supply several lines. Site changes must not rewrite a historical pickup snapshot. Quantities, quality checks, missing items, actual cost and document reference need atomic, idempotent writes.
3. **Exceptions with customer consent.** Keep customer-approved replacement/removal and fixed-price basket constraints. Supplier cost changes must not silently change the customer's agreed retail price. No cost-plus margin, purchasing fee or delivery pricing rule is invented.
4. **Handover, delivery and finance.** Only confirmed collected quantities pass to courier custody. Separate supplier payable/purchase cost, employee purchasing advance/settlement and customer COD collection/refund. A receipt is not a payment; a supplier credit note is not a bank settlement. Keep cancellation after purchase and supplier returns explicit and auditable.
5. **Web/native acceptance and launch.** Update catalog availability, carts, quote recovery, staff/customer labels and native models together. Test zero-warehouse journeys, multiple suppliers, concurrent staff actions, partial collection, refusal, cancellation and response loss in disposable environments. Only then replace commercial readiness and obtain actual owner operating acceptance. Signed stores and physical devices remain separate requirements.

## Owner inputs

Real supplier/shop names and pickup contacts/addresses, approved catalog and retail prices, actual delivery geography/capacity and staff responsibilities can be prepared now. Merchant identity/policies/tax status and approved provider accounts remain required. No warehouse address or stock count is an owner prerequisite. Payment timing with suppliers, advances and any variable-pricing policy need explicit operating rules before enabling financial actions.

## Evidence and safety

The candidate adds schema/RPC, Edge routing, web forms and regression tests. Refer to [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md) for actual CI/application/publication results; source alone is not deployment. The disposable database suite verifies revision races, active/draft filtering, paging, role scope and unchanged warehouse/stock/order/cash/slot fingerprints. Existing legacy tests remain regression protection and are not acceptance of the new business flow.

Custom-session authentication and intentional `verify_jwt:false` are preserved. Do not create commercial fixtures in production or erase historical records to make a check pass.
