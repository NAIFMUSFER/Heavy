# Warehouse receipt, counts and stock policy

Status: migration `20260910035511` and warehouse UI are deployed. The expanded seventeen-group warehouse suite and actual browser receiving/inspection journey pass; current evidence is in RELEASE-EVIDENCE.md. This document does not certify a completed physical warehouse acceptance test.

Receiving creates a pending lot with its supplier, quantity, optional recorded cost, expiry and receipt reference. Pending and rejected stock never increases usable balances. Receipt and rejection generate explicit zero-quantity movements; accepted inspection adds stock once and recognizes recorded cost. External invoice references are supplied by operators, never fabricated. Unknown costs remain null. Warehouse writes persist idempotency keys to protect network retries.

Inventory balance and lot mutations acquire stock-balance locks before lot locks. Accepted lot quantities retain a monotonic physical revision that changes whenever on-hand quantity or inspection state changes. Reservation changes do not increment this physical revision; current reservations are checked independently before any adjustment.

A count session records a physical location description and selected accepted lot IDs. The server captures each lot's system quantity and revision. Staff enter the quantity actually counted and a reason; blank inputs do not default to the system quantity. Submission preserves both quantities and does not change stock. Admin explicitly approves or rejects each difference. Approval checks the original revision and current reserved quantity, then atomically posts the adjustment, cost effect and audit record. A matching count closes without inventing a stock movement. Repeated approval with the same key replays one result.

Any physical movement after the count starts makes the count stale, including a quantity decrease followed by an increase back to its original value. A stale count must be rejected/cancelled and counted again. An approval cannot reduce on-hand below existing reservations. Cancelling a session retains its historical lines and does not erase already approved adjustments. Partial approval is visible per line; sessions close when every submitted line has a decision. This is an optimistic count workflow, not a warehouse-wide physical stock freeze.

Stock master includes optional English name, category and per-item reorder quantity in its canonical gram/piece unit. Existing units are immutable. An unset reorder threshold is explicitly unconfigured. Reports identify out-of-stock or stock at/below a configured threshold; they do not label arbitrary lowest-stock items as low. Unreserved physical balance and currently sellable quantity are separate: sellable quantity excludes expired/unaccepted lots, and actual checkout additionally checks expiry against its delivery window.

Supplier email, phone, notes and active state are validated and audited. Deactivation prevents new receipts linked to that supplier and preserves old lots. Existing creation timestamps not previously recorded remain unknown; only new supplier records receive a creation timestamp.

Remaining: modeled warehouse/location ownership and multi-city stock pools, purchase orders, barcode workflows and authorized physical operator acceptance. Supplier-return credit notes can be recorded and compared with inventory cost evidence; actual bank settlement, accounting/tax treatment and approval policy still require owner/finance acceptance. A free-text count-location description does not implement multi-warehouse stock segregation.

Typed waste, damage and accepted-stock supplier returns are deployed with immutable movements, cost recognition and guarded idempotency; see INVENTORY-DISPOSALS.md. General paginated movement history is live (see STOCK-MOVEMENTS.md).

Customer/courier return quarantine, inspection and rejected-custody disposition are implemented separately; see [CUSTOMER-RETURNS.md](CUSTOMER-RETURNS.md). Physical procedures and supplier credit agreement remain owner/operator acceptance work.
