# Browser acceptance against real PostgreSQL

Source `3d0d74504cc0b0ffe6bee0620dc0e2b768994045` passed [browser run 34456468946](https://github.com/NAIFMUSFER/Heavy/actions/runs/34456468946). Fourteen assertions passed through actual customer and staff interfaces, with no browser JavaScript error or gateway 5xx during the journey.

The job replays the complete recovered schema plus forward migrations into an isolated PostgreSQL 17/PostGIS/pg_cron database. PostgREST executes actual SQL RPCs. The real Node gateway and the three canonical Edge handler sources serve Chromium requests. Browser transport is intercepted only to loopback, retaining the canonical HTTPS origin to exercise Secure/HttpOnly/SameSite cookies and CSRF. All other destinations are blocked. This tests source integration, not Supabase's production transport or a physical mobile device. The separate live smoke verifies deployment identity and dependencies.

| Journey | Verified behavior |
|---|---|
| Warehouse receiving | Pending receipt does not increase usable stock; accepted inspection increases it exactly once |
| Customer identity | Registration, real login cookies, reload restoration and profile update work |
| Address and quote | PostGIS coverage finds the slot; quote reserves stock and capacity before any permanent order exists |
| Confirmation | Reviewed COD quote creates the order and exposes its delivery code to the customer |
| Assignment and picking | Admin assigns picker; picker records 900 g against 1 kg and finalizes FEFO consumption with the adjusted price |
| Delivery | Assigned courier dispatches and verifies the customer code; delivered state leaves collected and settled amounts zero |
| Collection and settlement | Explicit collection creates liability; finance records a deposit reference and clears liability |
| Support | Customer opens an order-linked ticket; support replies/closes without mandatory assignment; customer reads the actual reply |
| Refund | Customer request does not count as payment; finance records a company-funded refund without changing settled courier liability |
| Saved customer data | Saved list and explicitly consented reminder can be created; pause works without adding orders or reservations |

Screenshots of confirmation, finance and reminders, plus machine-readable results, are retained as fixture-only Actions artifacts for fourteen days. The test uses synthetic accounts only inside the disposable database. It does not change production records or send messages to real recipients.

The first three runs identified concrete gaps that unit/database tests alone had missed:

1. `34455369503`: inventory supplier form called an admin-only RPC. The forward repair allows the required inventory/admin roles, preserves validation/audit and adds persisted supplier-create idempotency. Eight concurrent retries and disallowed customer/courier roles are checked in the warehouse database suite.
2. `34455786633`: the active-only courier task query hid delivered orders before collection. The forward repair keeps only the proper courier's uncollected or cash-liability tasks visible until reconciliation. Financial regression tests cover each stage and exclude other couriers.
3. `34456089554`: native HTML required-select validation blocked a support reply when optional assignment was blank. Optional support assignment and receipt supplier are now explicitly optional; payment source remains required. The harness also observes action/response promises together to preserve timeout diagnostics.

Separate SQL suites cover stronger concurrency, quote/confirmation retries, cancellation, substitutions, refunds, counts and role changes. This browser journey does not yet cover every failed-delivery branch, custom basket construction, physical device operation, real operator acceptance, load/performance or restoration of production data.
