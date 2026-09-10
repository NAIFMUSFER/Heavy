# COD and refund correction — implementation in progress

The deployed legacy settlement subtracts every completed refund from courier liability. That is incorrect when JANA finance paid the refund from company funds. The old admin refund also records completion without a real payment reference. Customer refund requests currently depend on component identifiers that order snapshots do not contain. These flows are not launch approved.

The next forward migration will enforce:

- Customer requests reserve refundable money and do not claim a payment occurred.
- Completed refunds require an authorized finance/admin actor, reason, explicit payment source, and the actual payment reference.
- A courier-funded refund reduces that courier's recorded cash liability. A finance-funded refund leaves courier liability unchanged.
- Liability equals collected cash minus finance settlements minus refunds paid from courier cash.
- Settlement can be partial; each amount and reference is retained in an append-only cash ledger.
- One order row serializes collection, refund completion, and settlement. Deferred ledger checks reconcile account totals before commit.
- Replayed idempotency keys return the recorded original result. A reference cannot be counted twice for the same order/event type.
- No money is transferred by these COD recordkeeping APIs. Staff must confirm a payment actually occurred before recording it. Online payment and refund adapters remain configuration work.

Production pre-migration evidence, 10 September 2026: one existing order; zero collected orders, zero courier-held cash orders, zero refund records. No historical refund source needs to be invented. This document describes the pending correction, not deployed behavior.

The first disposable PostgreSQL financial run (34431555191) passed sixteen financial groups, then failed on an ambiguous SQL alias in the overview report. The alias is corrected; the migration is still unapplied and the complete gate must pass before release.
