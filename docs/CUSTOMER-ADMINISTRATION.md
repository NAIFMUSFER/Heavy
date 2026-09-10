# Customer operations review

The administrator directory searches real customer names, email addresses and phone numbers, shows active status and order counts, and paginates 50 accounts at a time with a `(created_at, id)` cursor. Operational accounts are excluded. Opening a customer shows contact/verification status, order count, open-ticket count and the last 20 order summaries with actual recorded totals/refunds.

Both RPCs require an authenticated administrator in PostgreSQL. The directory and detail response use explicit field allowlists; passwords, session hashes, tokens, customer preferences and saved address coordinates are absent. Order snapshots are not copied into the customer summary. Opening a record adds a `customer_record_viewed` audit with administrator ID and purpose, without duplicating the customer's private contact data. Gateway telemetry redacts record IDs and omits search values.

This is a review interface. It does not silently modify identities, reset passwords, escalate roles, deactivate customers or invent financial history. Existing staff, order and support workflows keep their separate authorizations and audit requirements.

The database tests traverse 55 same-timestamp customers, check role exclusions and selected output fields, verify real order data and unchanged reservations, and verify access auditing and privileges. Browser coverage opens the directory after a real commerce/refund journey. Eight database groups passed in run 34462706968, and the extended 19-check browser journey passed in 34463088510 after a warehouse dialog-loading defect was repaired. Migration 20260910095523 is applied and main API v22 is active. Gateway release 388b777 is verified live; see RELEASE-EVIDENCE.md.
