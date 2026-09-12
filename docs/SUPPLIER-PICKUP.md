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

## Implemented phase 10: read-only staff web workspace

- Admin and finance can page every procurement job and inspect its reconciled lines, supplier visits, actual cost, funding, shortage and handover evidence. Only those roles receive settlement entries, payment references and financial totals.
- A purchasing employee starts on `picker.html#procurement`, sees assigned jobs only and receives no customer contact or finance settlement detail. The previous preparation screen remains at `#orders` for compatibility.
- Filtering refreshes from the first bounded page; continuation uses the paired keyset cursor and deduplicates overlap. Refresh, logout and session replacement invalidate prior responses so stale private data cannot repaint.
- Supplier, receipt and note fields are escaped before rendering. The workspace has no transaction buttons and cannot create/assign work, record a purchase, decide a shortage, fund/settle, hand over or cancel.
- Release `df9ed7a1` publishes the workspace. Exact CI passed 359 Node tests, 30 production checks and 87 disposable-browser checks; publication details are recorded in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 11: read-only native staff workspace

- Shared Expo source now routes admin, finance and purchasing-employee sessions directly to procurement instead of initializing customer addresses, favorites and checkout state. Customer sessions retain their existing flow.
- Staff can refresh, continue bounded pages and inspect requested/collected/remaining quantities, supplier visits, receipt references, actual cost, shortage and courier handover. The purchasing employee remains limited to assigned jobs and receives no customer contact.
- Settlement evidence is rendered only when the local role is admin/finance and the server confirms financial detail. Request generations prevent a stale response from repainting after refresh, logout or session replacement.
- The native workspace is read-only and contains no create, assign, purchase, funding, settlement, shortage, handover or cancellation request. Legacy screens and data remain intact.
- Release `f5522603` publishes the source and server version. Exact CI passed 363 Node tests, 30 production checks, Expo export, Android debug and iOS simulator builds. These builds are not signed store releases or physical-device acceptance; exact evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 12: read-only customer collection progress

- The existing authenticated order-detail endpoint now adds procurement progress only when the customer's owned order has a procurement job. Legacy orders keep the prior response and display.
- Web and shared Expo order details show the collection state and requested, collected and remaining quantity for every frozen customer line. A pending shortage shows the exact proposed reduction from the frozen displayed price and states that no change occurs before explicit consent.
- The customer object deliberately excludes supplier/shop identity, staff and courier identity, receipt references, quality notes, actual supplier cost, funding and settlement evidence. Invalid or arithmetically inconsistent progress is rejected by the shared client formatter instead of being presented as fact.
- The prior order-detail function still enforces authentication and ownership before procurement is read. Its renamed helper is private even to `service_role`; the public function remains service-only. No write route, supplier contact, automatic notification, inventory reservation, fee or new pricing rule is introduced.
- Release `611b28e6` publishes the database wrapper and both clients. Exact CI passed 364 Node tests, 22 procurement database groups, 87 browser checks, recovery, capacity, Expo, Android debug and iOS simulator gates. Supabase is at 108 migrations and production procurement tables remain empty; exact evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 13: explicit customer shortage decision

- When the owned order has one pending whole-shortage request, web and shared Expo order details now offer explicit approval or rejection. Both require a customer note and a separate confirmation; the clients send the exact request ID and current procurement revision with durable idempotency.
- Approval records consent for the exact reduction already derived from frozen displayed prices. It does not change the total immediately: the existing separate admin/finance adjustment remains required. Rejection resumes collection without changing the customer price.
- The service-only database wrapper reuses the ownership-checked custom session and private decision primitive, then verifies the result belongs to the order in the route inside the same transaction. Any mismatch rolls back. Direct execution of the inner write remains unavailable to clients and `service_role`.
- Cookie writes retain CSRF, bearer sessions retain their existing boundary, and malformed request IDs, revisions, decisions or notes fail before database access. The action never exposes supplier, employee, receipt, actual-cost, funding or settlement detail.
- Release `7a90c538` publishes the route and both clients. Exact CI passed 369 Node tests, 22 procurement database groups, 87 browser checks, recovery, capacity, Expo, Android debug and iOS simulator gates. Supabase is at 109 migrations with `jana-api v35`; production procurement tables remain empty and intake remains closed. Exact evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 14: staff application of the approved reduction

- Admin and finance can now apply the exact currently approved shortage reduction from the web or shared Expo procurement detail. The action is shown only when the complete approved evidence, revision and before/reduction/after totals reconcile; malformed or empty-order results fail closed.
- A separate confirmation shows the exact customer total before and after, requires an operational reason, and sends the request ID plus current job revision with durable idempotency. The purchasing employee has no access to this financial action.
- The service-only wrapper executes the existing private adjustment primitive and verifies that its returned job and shortage request match the URL/body inside the same transaction. Any mismatch rolls back. Direct execution of the inner primitive remains unavailable to `service_role` and clients.
- The action changes only the active customer snapshot by the already approved reduction, retains `original_snapshot`, and moves a non-empty job to `ready` for handover. It does not change inventory, supplier cost, funding, settlement, customer cash, margin or fees.
- Release `a1ba81ec` publishes the database boundary, `jana-api v36`, and both clients. Exact CI passed 374 Node tests, 22 procurement database groups, 87 browser checks, recovery, capacity, Expo, Android debug and iOS simulator gates. Supabase is at 110 migrations; production procurement tables remain empty and intake remains closed. Exact evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 15: assignment and purchase recording

- Admin can assign or reassign an active purchasing employee from the current job revision, with an explicit reason and confirmation. Finance and purchasing employees cannot assign work.
- Only the employee currently assigned to an `assigned` or `collecting` job can append a real supplier visit. The record includes the active supplier and pickup site, receipt/invoice reference, visit note, exact collected quantities, per-line quality note and actual supplier cost. A line cannot exceed the remaining customer quantity.
- The web and shared Expo interfaces page the actual supplier directory, reconcile quantities before enabling submission, show the actual-cost total at confirmation and preserve the submitted action through response loss with durable idempotency.
- Each Edge route binds the procurement job from the URL. Its service-only wrapper derives the canonical order internally and verifies the inner transaction returned the same job, order, employee, supplier and site; a mismatch rolls every write back. Broader order-based primitives remain unavailable to `service_role` and clients.
- These two actions do not create inventory, recalculate the customer's displayed price, classify funding, settle a supplier/employee, hand custody to a courier or open intake. Database CI, production application and publication status must be taken only from [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).
- Release `ee872e8e` publishes both actions on web and shared Expo with Supabase at 111 migrations and ACTIVE `jana-api v37`. Exact CI passed 383 Node tests, 22 procurement database groups, 87 browser checks, recovery, capacity, Expo, Android debug and iOS simulator gates; production procurement tables remain empty and intake remains closed. Exact evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 16: explicit funding and settlement controls

- Admin and finance can attribute each unfunded purchase explicitly to company-paid, employee-paid or supplier credit from the web and shared Expo workspaces. No source is selected by default; the actor must provide evidence reference, note and a separate confirmation.
- Only actual-cost principal copied from the immutable purchase is used. Employee and supplier beneficiaries remain canonical; a cross-job purchase/funding identifier is rejected by a path-bound service wrapper in the same transaction.
- Admin and finance can append a partial or full payment only to an employee or supplier liability. The amount is capped by the current outstanding balance, company-paid purchases are not payable, and durable idempotency prevents duplicate payment evidence after response loss.
- These controls do not move inventory, alter the customer's displayed or original terms, add margin or fees, collect customer cash, or assume a payment channel or due date. Handover and post-purchase cancellation remain separate and private.
- Release `2cb5dfc` publishes the controls with Supabase at 112 migrations and ACTIVE `jana-api v38`. Exact CI and production safety evidence are in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md); procurement tables remain empty and intake remains closed.

## Implemented phase 17: two-party courier custody controls

- Admin or the currently assigned purchasing employee can prepare custody only after collection is ready and every purchase has explicit funding evidence. The actor must select an active courier, enter a handover note and confirm separately; no courier is selected by default.
- The request freezes the exact retained customer lines and collected quantities. Only the selected active courier can see that custody, count it and accept it explicitly at the current revision. Acceptance alone moves the existing order into its delivery-ready assignment state.
- Courier list/detail responses omit supplier/shop identity, receipt references, purchase identifiers, actual supplier cost, customer totals, per-line retail prices, funding and settlements. Other couriers cannot read or accept the request.
- Path-bound service wrappers verify the job, order, purchasing employee, courier and handover request inside the same transaction. Durable idempotency returns the original result after response loss, and a courier with pending unaccepted custody cannot be disabled or moved to another role.
- The web and shared Expo workspaces expose preparation and acceptance with role-specific controls; the retained courier delivery screen remains a separate destination. Neither action creates inventory, changes customer price, records supplier/employee payment, collects customer cash or opens intake.
- Release `720e98b0` publishes this boundary with Supabase at 113 migrations and ACTIVE `jana-api v39`. Exact CI passed 397 Node tests, 22 procurement database groups, 87 browser checks, recovery, capacity, Expo, Android debug and iOS simulator gates; production procurement tables remain empty and intake remains closed. Exact evidence is in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md).

## Implemented phase 18: customer admission boundary and procurement catalog

- New customer quotes enter the supplier-pickup transaction through a narrow service gateway. It freezes the displayed retail terms, address and delivery slot, reserves delivery capacity only, and records that no inventory was reserved.
- Order confirmation uses a durable gateway that creates exactly one procurement job. Already-issued legacy inventory quotes remain confirmable through the retained transaction; no old rows or interfaces are deleted.
- Catalog responses preserve factual legacy `available_units` for compatibility, while separately declaring `orderable`, `max_order_quantity`, `inventory_required:false`, `availability_status:to_be_purchased` and `fulfillment_model:supplier_pickup`. Web and shared Expo carts use those explicit procurement fields instead of inventing stock.
- Customer cards and basket builders state that items are collected from suppliers after confirmation. The displayed sale price is retained, shortages still require explicit consent, and no margin, purchasing fee or supplier-cost pricing policy is introduced.
- Both gateways remain protected by the closed storefront switch. This phase does not open intake or replace the legacy warehouse readiness screen; replacement readiness and full disposable browser acceptance remain separate launch gates.

## Next engineering gates — not complete

1. **Replace the legacy launch readiness prerequisite.** Customer quote/order admission now routes to supplier pickup and uses no warehouse balance. Replace the one-warehouse opening attestation with supplier/site, purchasing staff, courier and delivery-capacity evidence while preserving the explicit closed switch and immutable opening review.
2. **Complete assigned procurement work.** Job creation, role-scoped assignment, immutable multi-supplier purchase evidence, bounded staff reads, web/native staff workspaces, customer collection progress, explicit customer shortage decisions, the admin/finance approved-reduction action, explicit funding/settlement evidence and dual-confirmed courier custody are published. Keep each order's collected goods separate and preserve historical pickup snapshots while completing end-to-end exception and acceptance coverage.
3. **Exceptions with customer consent.** The complete-removal proposal, customer approve/reject interface, exact one-time reduction and second-confirmation cancellation for a zero-purchase all-unavailable order are implemented. Add replacement only under an explicit frozen proposal, and keep any post-purchase cancellation closed until its supplier-return and employee-liability rules are approved. Supplier cost changes must not silently change the customer's agreed retail price. No cost-plus margin, purchasing fee or delivery pricing rule is invented.
4. **Delivery and finance.** Only funded, dual-confirmed collected quantities pass to courier custody. Supplier payable and employee reimbursement are separately recorded from customer COD collection/refund. A receipt is not a payment; a supplier credit note is not a bank settlement. Obtain owner approval for actual payment channels/timing and implement post-purchase cancellation/return as a separate auditable action.
5. **Web/native acceptance and launch.** Catalog availability, carts, quote recovery and confirmation now use the supplier-pickup admission contract. Test zero-warehouse journeys, multiple suppliers, concurrent staff actions, partial collection, refusal, cancellation and response loss in disposable environments. Only then obtain actual owner operating acceptance. Signed stores and physical devices remain separate requirements.

## Owner inputs

Real supplier/shop names and pickup contacts/addresses, approved catalog and retail prices, actual delivery geography/capacity and staff responsibilities can be prepared now. Merchant identity/policies/tax status and approved provider accounts remain required. No warehouse address or stock count is an owner prerequisite. Payment timing/channels with suppliers and employee advance/reimbursement procedures need explicit operating rules before enabling financial actions; no variable customer pricing is assumed.

## Evidence and safety

Phase 1 adds the supplier directory through schema/RPC, Edge routing and web forms. Phases 2–8 add deliberately ungranted database admission, assignment, purchase-evidence, shortage-consent, approved-adjustment, courier-custody, zero-purchase cancellation and funding/settlement primitives only. Phase 9 grants two read-only procurement views to Edge while leaving every write private. Phases 10–11 render those reads in the web and shared Expo operations workspaces. Phase 12 adds a privacy-minimized collection view to the customer's existing order detail; phase 13 adds the explicit customer shortage decision; phase 14 grants and renders only the exact admin/finance approved-reduction operation. Phase 15 narrows and renders admin assignment plus assigned-employee purchase evidence. Phase 16 grants only path-bound admin/finance funding and settlement wrappers and renders explicit no-default controls. Phase 17 grants and renders only the path-bound two-party courier handover, with a privacy-minimized courier read. Phase 18 grants only the quote/confirmation gateways and updates web/native catalog orderability without changing legacy stock facts. Refer to [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md) for actual CI/application/publication results; source alone is not deployment. The disposable suite verifies retries, races, roles, immutable evidence, settlement caps, custody isolation and unchanged warehouse/stock/order/cash/slot fingerprints. Existing legacy tests remain regression protection and are not acceptance of the new business flow.

Custom-session authentication and intentional `verify_jwt:false` are preserved. Do not create commercial fixtures in production or erase historical records to make a check pass.
