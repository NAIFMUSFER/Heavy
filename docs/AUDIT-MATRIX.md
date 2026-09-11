# JANA implementation and launch gaps

This matrix describes implemented source. Exact release/deployment/build evidence and historical failures are retained in RELEASE-EVIDENCE.md and the release handoff. A passing build is not physical operating acceptance or a signed store release.

**Commercial launch is not complete.** Store admission remains closed until actual merchant information, policies, inventory, geography and operating acceptance pass the existing readiness gate. No invented percentage represents readiness.

| Area | Implemented and covered by automated gates | Still required |
|---|---|---|
| Isolation/backend | Dedicated JANA Supabase/Render/branches; Node → custom authenticated Edge → transactional PostgreSQL/PostGIS | Dedicated JANA staging and actual operating acceptance |
| Identity/staff | Email or Saudi phone sign-in; hashed sessions, CSRF/SecureStore; password change/all-session revocation; audited roles, assignment and cash/task safeguards | Verified recipient/recovery flow; actual staff acceptance |
| Commercial storefront | Private versioned draft, immutable published policies, reviewed intake open/close, frozen seller terms | Actual merchant identity/contacts/tax status and approved policies |
| Catalog | Families, versions, offerings, units, fixed/custom baskets, paginated catalog, images | Actual approved products, prices, photographs; replace preview catalog |
| Customer web/mobile | Catalog/cart/quote/COD, resumed checkout/uncertain-confirmation recovery, server-clock expiry, account, frozen order details, dated history, older-order pages, recorded-location tracking | Real customer/device acceptance; signed mobile distribution |
| Saved data | Profiles, address/default management, favorites, lists, synced cart, recurring reminders with revision/consent | External reminder channels disabled |
| Addresses/maps | Arabic/Persian normalization, strict phone/coordinates, foreground GPS, supported pin import, keyless Google links, PostGIS coverage | Approved real geography; embedded Google API not enabled |
| Delivery administration | Polygons/exclusions, fees, minimums, cutoff/slot capacity, revision checks | Actual capacity; warehouse routing before multiple hubs |
| Quotes/orders | Atomic stock/slot reservation, expiration, persistent idempotency, frozen terms and cancellation gates | Tax/invoicing integration before enabling a VAT-registered seller |
| Order experience | Frozen address/appointment, line/cash details, public timeline, cursor paging, cancellation/code renewal/refresh | No automatic background courier publishing or ETA |
| Warehouse/counts | Suppliers, pending inspection, accepted FEFO stock, lot costs/metadata, reorder levels, reviewed counts | Actual inspected/received/count-verified stock; canonical warehouse/bin segregation for multiple hubs |
| Disposal/returns | Waste, damage, supplier outbound return, customer quarantine/inspection, rejected-return custody/disposition | Supplier credit reconciliation and approved physical procedures |
| Picker/substitutions | Assignment, FEFO, weight tolerance, fixed-basket measurements, explicit customer-approved substitutions | Component-level basket substitution/variance/tolerance/pricing rules and field acceptance |
| Courier | Paged tasks retain outstanding collection/cash liability; assignment, dispatch, delivery code, failure/retry, destination navigation, recipient call link and explicit foreground GPS sharing | Physical devices/procedure; continuous location publishing absent |
| Finance/COD | Delivery separated from cash collection, liability, partial settlement and source-aware completed refunds | Actual cash handover/accounting acceptance |
| Support/reporting | Threads, order links, priority/assignment; real sales/cash/stock reports and explicit unknown/estimated costs | Staff acceptance, actual costs; tax/operating expenses not full accounting |
| Notifications | Transactional in-app notifications; guarded outbox/leases/retries/uncertainty, Resend adapter and monitoring | Dedicated worker, verified destinations/consent/domain and approved channel activation |
| Providers/analytics | Server-only provider boundaries, privacy-minimized events, fail-closed flags | Concrete SMS/push/payment/media integrations as selected; dedicated PostHog ingestion verification |
| Database assurance | Recovered replay, populated fixture backup/restore gate, disposable concurrency tests, immutable ledgers, service-only application RPCs | Real backup restore/recovery timing; supported PostGIS platform-advisor remediation |
| CI/operations | Node/PostgreSQL/recovery/browser/Expo/Android/iOS simulator gates, exact-commit smoke, recovery/rotation runbooks | Capacity/load, dedicated staging, alerts, measured backup/restore and signed releases |

## Work order before commercial sales

1. Owner provides actual merchant identity, contacts, registrations/tax status, policies, catalog/prices and intended Jazan geography. Publish reviewed terms without inferring these values.
2. Operations records actual inspected stock and capacity, creates real staff accounts and accepts the customer → warehouse → courier → cash/refund journey.
3. Engineering connects the approved verification/recovery and communication providers, provisions the worker, verifies approved destinations, and establishes isolated staging/capacity/backup recovery evidence. Add VAT/invoicing if the confirmed tax status requires it.
4. Owner provides Apple/Google distribution accounts; complete physical-device acceptance, signing and store review.
5. Before Riyadh/Jeddah or another warehouse: implement warehouse/location ownership, routing and stock segregation, approved basket component variance/substitution rules and supplier credit accounting.

Supabase-owned PostGIS advisor findings remain documented platform limitations. Do not alter system-object ownership or invent policies to silence advisors. Service-only JANA application permissions are checked separately. Historical failed runs and recoveries stay in RELEASE-EVIDENCE.md.

## Recovery regression extension — 11 September 2026

The review-branch populated-fixture backup/restore workflow passed run 34548982939 on 278d1326673b87813696304989d808049b9d840c: 12 guard/normalization tests, 11 integration groups and identical data across 52 public tables (24 nonempty). Production application/schema were not changed. See [RECOVERY-REHEARSAL.md](RECOVERY-REHEARSAL.md). Do not mark actual production backup recovery or RPO/RTO complete from this regression gate.

## Staff list continuation — 11 September 2026

Operations order pagination is implemented: indexed database selection, older-page controls, retry preservation, refresh/session guards and the existing courier cash-task lifecycle. Candidate 40e0780 passed 245 Node tests, 56 browser checks, full disposable database integrity and recovery. Migration 20260911015144 and jana-api v30 are applied; the initial web release ca1f650 passed 23 post-deployment checks through dep-dahm129594qs73fj9h70. The current release below includes this work. Full evidence is in RELEASE-EVIDENCE.md. This removes the first-100-orders UI ceiling; it does not complete field acceptance, a signed mobile release or any commercial activation prerequisite.

## Checkout continuity — 11 September 2026

Checkout recovery is implemented for web and native: account-scoped quote references restore the review, server-clock expiry prevents stale confirmation, explicit release handles reservations, and read-only recovery displays an order whose confirmation response was lost. The cart preserves later edits and native retry cleanup preserves newer sessions. Candidate 98eb36f passed 266 Node tests, 59 browser checks and full database/recovery gates. Its identical mobile source passed Expo, Android debug and iOS simulator builds. See RELEASE-EVIDENCE.md for the exact source, runs and artifact expiration.

The additive checkout recovery migration **20260911024522** is applied (84 migrations), with unchanged production order/stock/lot/slot hashes at application. Edge remains jana-api v30 / jana-critical v6 / jana-ops-extra v21; custom-session authentication is preserved.

**Current web release:** **07125e5cbcf1f383c9535fc940b74b506f081b1e**, Render **dep-dahmvfid0e5s7382utpg**, live at **2026-09-11 03:05 UTC**. After the owner's payment update, fresh service reads confirmed the billing suspension was cleared. The production smoke [34556999274](https://github.com/NAIFMUSFER/Heavy/actions/runs/34556999274) passed 23 checks against the exact deployed commit. This release has the same application source as the tested candidate, plus documentation. The hosting blocker is resolved; no additional schema or Edge deployment was needed.

Commercial admission remains closed. Actual merchant/catalog/prices/inspected stock/geography/capacity and operating approval, verified providers, staging/load/real-backup recovery, physical-device acceptance and signed store distribution remain outstanding. Native build success does not establish store publication. Warehouse routing/segregation, approved basket component rules and supplier credit reconciliation remain explicit work items.

## Cross-application resilience review — 11 September 2026

The review candidate validates and serializes local cart persistence across web/native, preserves stored selections on failures, adds retry/explicit reset, normalizes monetary entry without rounding extra decimal places, repairs staff workspace links and exposes native account restoration retry. Updated API/architecture/mobile documents distinguish current implementation from historical evidence and owner configuration. See [REVIEW-2026-09-11.md](REVIEW-2026-09-11.md) for coverage and limits. Relevant local tests passed; exact candidate CI and deployment results follow in RELEASE-EVIDENCE.md. The current deployed commit remains the preceding release until those gates and promotion complete.
