# Physical customer and courier returns

Published baseline: source 0b1c63e passed 190 JavaScript tests, 22 PostgreSQL return groups and 33 browser checks. Render dep-dahf7teq1p3s73em6eag became live at 18:16:50 UTC; exact-commit smoke 34513034338 passed. Migration 20260910170206 is applied; customer API v25 and operations Edge v20 are active.

The custody extension in this commit passes local syntax and 197 JavaScript tests. Expanded PostgreSQL and browser gates and production deployment are pending.

Admin/inventory staff look up the exact order number and select an actual shipped stock/lot allocation. Only delivered shipments or failed deliveries after completed picking are eligible. The operator records the quantity physically received, a real receipt reference and the reason. The canonical stock, unit, lot, order and actor are resolved by PostgreSQL; they cannot be selected through arbitrary client names or prices.

The receipt is quarantined outside usable on-hand and reserved balances. Its immutable original source and quantity are recorded, with an audit and a zero-usable-delta stock movement. A source/document uniqueness rule and persisted request idempotency prevent repeat receipt. Concurrent receipts serialize against the original order and movement, and all received quantities, including rejected and pending returns, count against the quantity actually shipped.

A separate irreversible quality inspection records accepted and rejected quantities plus the observation/reason. The accepted amount starts blank in the UI. Staff explicitly confirm the real decision. PostgreSQL locks the stock balance, source movement and original lot, permits one immutable decision, and checks current expiry. Only the accepted quantity re-enters the original accepted, unexpired lot; expiry is never renewed. Rejected returned goods remain physically segregated and unavailable for sale. The custody extension records subsequent actual disposal or supplier handover separately; rejection itself does not claim destruction or decrement usable stock a second time.

Accepted stock restores its original shipment cost with cumulative rounding capped at the original consumption value. Known zero, recorded, estimated and unknown source costs remain distinct. Missing source cost is never replaced with the current retail price. Mixing unknown returned cost into existing stock conservatively marks the pooled lot cost unknown; immutable individual cost events remain available. The positive cost entry references the original order so operational net COGS reflects the return. Order prices, COD collection, courier liability, settlements and refunds are unchanged. A financial refund is a separate reviewed workflow.

The original failed order cannot be redispatched once its physical goods have been received back, even while inspection is pending. Receipt and redispatch serialize on the order. A new approved replacement order requires a new quote/reservation; returned goods cannot silently be delivered twice. There is no automatic replacement or customer charge.

Admin/inventory can receive and inspect; finance reads cost evidence; support reads return status with purchase cost redacted. No customer/courier write API is exposed. History uses 50-row stable keyset pages and displays pending/inspected/rejected receipt counts without summing grams and pieces together. The general movement ledger resolves actual return document references.

API:

- `GET /api/ops/customer-returns/context?number=...` — exact original shipment allocations; admin/inventory.
- `POST /api/ops/customer-returns` — physical receipt; requires Idempotency-Key.
- `POST /api/ops/customer-returns/:id/inspection` — accepted quantity and quality observation; requires Idempotency-Key.
- `GET /api/ops/customer-returns?before_at=...&before_id=...` — paginated history; role-filtered cost evidence.

Migration: `20260910170206_jana_customer_return_inspection.sql` (applied; unchanged SQL renamed to the actual migration version). The two new application tables have RLS and no client-role grants. Application RPCs are service-only with server-side JANA session/role checks. The order redispatch trigger helper is not callable by API roles. This migration does not modify PostGIS objects or backfill historical order/inventory values.

Remaining operations: owner-approved quality/food-handling and return policies, actual warehouse acceptance, a dedicated canonical warehouse/location model, and supplier financial credits. The return UI does not certify a food safety policy or invent observed quality.

## Rejected-return custody extension

`POST /api/ops/customer-returns/:id/dispositions` records a completed physical action against an inspected rejected quantity. It requires a document reference, integer base-unit quantity, observation and durable idempotency key. Allowed actions are recorded destruction and supplier handover; a handover also requires the named supplier/recipient. These documents record staff attestations, not verified provider delivery or permission to perform the action.

Only admin/inventory may write. Partial actions keep the remaining quantity in custody. An inspection row lock serializes distinct submissions, total disposition cannot exceed its rejected quantity, and duplicate reference/retry checks prevent double recording. Documents and their audit events are immutable. Closing custody does not mutate sellable stock, reservations, lots, cost entries, orders, refunds, or the cash ledger. There is no automatic supplier credit or customer payment.

`GET /api/ops/customer-returns/:id/dispositions` exposes 50-row keyset history to admin/inventory/finance/support, including actor, recording time, recipient and evidence reference. It does not expose purchase cost. Return history includes disposed/remaining quantities per receipt and counts of open/closed rejected receipts, without aggregating grams and pieces together. The UI starts quantity blank, requires an explicit completed-action checkbox and confirmation, shows supplier recipient only for handover, and removes the form when nothing remains.

Storage is a new service-only RLS table with the existing JANA session/role checks. No historical returns are backfilled or closed automatically. Applicable quality, food-handling, disposal and supplier-credit procedures still require owner approval and actual operating acceptance. Erroneous recorded evidence cannot be silently edited or deleted.
