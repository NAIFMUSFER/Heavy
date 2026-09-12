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

## Implemented phase 4 backend: dormant customer-approved shortage consent

- The assigned purchasing employee can freeze one complete proposal containing every quantity still missing from the customer's immutable request. The proposal records requested, collected and missing quantities and derives the exact proposed reduction only from the frozen displayed unit prices.
- While the proposal is pending, the job is `awaiting_customer` and further purchase evidence is blocked. Only the customer who owns the order can explicitly approve or reject the complete removal proposal.
- Rejection returns the job to `collecting`. Approval moves it to `shortage_approved`, blocks further collection and requires a separate exact retail adjustment before courier readiness. The customer total is not changed by this phase and `ready` is never inferred from consent alone.
- Request identity and decision evidence are immutable, revisioned, idempotent and audited. Both tables have RLS; direct table access and both functions are revoked from clients and `service_role`, and no Edge route calls them.
- Release `fd65f645` publishes the dormant structure. Production contains zero shortage requests/decisions, intake remains closed, and the pre/post business-table fingerprints match.

## Implemented phase 5 backend: exact approved retail adjustment

- Admin/finance can apply an approved complete-shortage decision once at the current job revision. The reduction is copied exactly from the customer's immutable decision and never derived from supplier cost, a margin, a purchasing fee or a new pricing rule.
- The active order snapshot retains collected quantities, removes only approved missing quantities, and updates subtotal/total by the exact approved reduction. `original_snapshot` remains byte-for-byte unchanged; prior cash/refund activity or changed commercial terms fail closed.
- A non-empty adjusted order moves the procurement job to `ready` for courier handover, not delivered. If every merchandise line would disappear, the function rejects with an explicit cancellation-required state until that separate path exists.
- Adjustment evidence is append-only with before/after snapshot hashes, idempotency, revision locks, audit and customer notification. Its table has RLS; direct table access and the function are revoked from clients and `service_role`, and no Edge route calls it.
- Release `e7a2e885` publishes the dormant structure. Production contains zero procurement rows/adjustments, intake remains closed, and business fingerprints remain unchanged.

## Implemented phase 6 backend: dual-confirmed courier custody

- The assigned purchasing employee prepares one immutable handover request only after procurement is `ready`. The request freezes the retained order lines, exact collected quantities, contributing purchase records, actual-cost total and hashes of the purchase evidence and current customer snapshot.
- Preparing a handover does not assign delivery or make the order ready: it moves only the procurement job to `handover_pending` and names one active courier.
- Only that selected courier can accept at the current revision. Acceptance creates a second immutable record, moves procurement to `handed_over`, and only then sets the existing order to fulfillment `ready` and delivery `assigned`.
- The customer price and original snapshot are unchanged. No stock, payable, employee reimbursement, COD collection or settlement entry is created.
- Both functions remain deliberately unavailable to Edge, clients and `service_role` until settlement, cancellation and the complete interfaces are ready.
- Release `cf191d15` publishes this dormant handover. Production contains zero handover rows; intake remains closed and all monitored business fingerprints remain unchanged.

## Implemented phase 7 backend: explicit zero-purchase cancellation

- When the approved complete-shortage evidence says every requested quantity is unavailable and no purchase was recorded, only the owning customer can submit a second explicit cancellation confirmation at the current job revision.
- The transaction revalidates all frozen lines, zero collected quantities, the full displayed-price reduction, absence of purchase/adjustment/handover/cash/refund activity, and the booked delivery slot. It cancels the order and procurement job and releases delivery capacity exactly once.
- The active and original customer snapshots and historical order total remain unchanged. No inventory, supplier cost, payable, employee reimbursement, cash entry or new pricing policy is created.
- Cancellation evidence is append-only, revisioned, idempotent, audited and linked to the exact shortage request and decision. The table has RLS; direct table access and the function are revoked from clients and `service_role`, and no Edge route calls it.
- Release `d9c22c81` publishes this dormant primitive. Production contains zero cancellation rows, intake remains closed and twenty monitored business fingerprints remain unchanged.
- This phase deliberately does not cancel after any partial purchase. That case needs approved supplier-return/payable and employee-advance/reimbursement rules before money or custody can be reversed safely.

## Implemented phase 8 backend: purchase funding and settlement evidence

- Every immutable supplier purchase receives exactly one explicit funding attribution: company-paid, employee-paid or supplier credit. Its principal is copied from the recorded actual purchase cost; the employee claimant and supplier creditor cannot be substituted.
- Admin/finance can append partial or full settlement entries with an external payment reference. Row locks, cumulative caps and durable idempotency prevent duplicate and concurrent overpayment. Company-paid purchases create no payable settlement.
- Funding attribution is required before the purchasing employee can prepare courier handover. Repayment timing does not block handover because advance, credit and payment timing remain owner policy; the response reports employee and supplier outstanding amounts separately.
- Funding and settlement do not change the displayed customer price, original order snapshot, inventory, purchase evidence, courier cash or COD/refund ledgers. No margin, purchasing fee, payment channel or settlement schedule is inferred.
- Both tables are RLS-protected and append-only. All transaction and helper functions remain revoked from clients, Edge and `service_role`; production contains zero funding/settlement rows and intake remains closed.
- Release `676e98c3` publishes this dormant structure. Supabase is at 106 migrations and the three covering indexes return the unindexed-foreign-key advisor count to the pre-existing eight. Exact CI, deployment and safety evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 9: bounded staff procurement reads

- Admin and finance can page all procurement jobs; a purchasing employee can page and open only jobs assigned to that account. Keyset cursors are paired and every page is capped at 100 rows.
- Detail combines the frozen requested lines, collected and remaining quantities, immutable supplier visits, actual cost, funding status, the latest shortage decision and courier handover. Full settlement entries and payment references are limited to admin/finance.
- Customer names, phone numbers, email addresses and delivery addresses are excluded. These reads do not change job state, customer totals, supplier liabilities, inventory, custody or cash.
- Exactly the two read functions are granted to `service_role` and routed through `jana-api`; every procurement write remains private and unavailable through Edge. Intake remains closed.
- Release `7c879966` publishes the read boundary with Supabase at 107 migrations and `jana-api v34`. Production has zero procurement rows and unchanged monitored business fingerprints. Exact evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Next engineering gates — not complete

1. **Complete order admission without warehouse stock.** The dormant quote/order core, slot-only reservation, collection evidence, consent, exact approved retail adjustment, zero-purchase cancellation, purchase funding/settlement and dual-confirmed courier handover are implemented. Add the approved post-purchase cancellation/return boundary; only then grant the complete flow and replace the one-warehouse readiness prerequisite. Preserve existing-order snapshots, cancellation and retry behavior.
2. **Complete assigned procurement work.** Job creation, assignment, immutable multi-supplier purchase evidence, funding classification and bounded role-scoped reads are implemented. Build the staff web/native workspace and customer-visible progress only after the write and exception boundaries are complete. Keep each order's collected goods separate and preserve historical pickup snapshots.
3. **Exceptions with customer consent.** The dormant complete-removal proposal, approve/reject record, exact one-time reduction and second-confirmation cancellation for a zero-purchase all-unavailable order are implemented. Add replacement only under an explicit frozen proposal, and keep any post-purchase cancellation closed until its supplier-return and employee-liability rules are approved. Supplier cost changes must not silently change the customer's agreed retail price. No cost-plus margin, purchasing fee or delivery pricing rule is invented.
4. **Delivery and finance.** Only funded, dual-confirmed collected quantities pass to courier custody. Supplier payable and employee reimbursement are separately recorded from customer COD collection/refund. A receipt is not a payment; a supplier credit note is not a bank settlement. Obtain owner approval for actual payment channels/timing and implement post-purchase cancellation/return as a separate auditable action.
5. **Web/native acceptance and launch.** Update catalog availability, carts, quote recovery, staff/customer labels and native models together. Test zero-warehouse journeys, multiple suppliers, concurrent staff actions, partial collection, refusal, cancellation and response loss in disposable environments. Only then replace commercial readiness and obtain actual owner operating acceptance. Signed stores and physical devices remain separate requirements.

## Owner inputs

Real supplier/shop names and pickup contacts/addresses, approved catalog and retail prices, actual delivery geography/capacity and staff responsibilities can be prepared now. Merchant identity/policies/tax status and approved provider accounts remain required. No warehouse address or stock count is an owner prerequisite. Payment timing/channels with suppliers and employee advance/reimbursement procedures need explicit operating rules before enabling financial actions; no variable customer pricing is assumed.

## Evidence and safety

Phase 1 adds the supplier directory through schema/RPC, Edge routing and web forms. Phases 2–8 add deliberately ungranted database admission, assignment, purchase-evidence, shortage-consent, approved-adjustment, courier-custody, zero-purchase cancellation and funding/settlement primitives only. Phase 9 grants two read-only procurement views to Edge while leaving every write private. Refer to [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md) for actual CI/application/publication results; source alone is not deployment. The disposable suite verifies retries, races, roles, immutable evidence, settlement caps, read isolation and unchanged warehouse/stock/order/cash/slot fingerprints. Existing legacy tests remain regression protection and are not acceptance of the new business flow.

Custom-session authentication and intentional `verify_jwt:false` are preserved. Do not create commercial fixtures in production or erase historical records to make a check pass.
