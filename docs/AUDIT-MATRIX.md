# JANA implementation and launch gaps

This matrix describes implemented source. Exact release/deployment/build evidence and historical failures are retained in RELEASE-EVIDENCE.md and the release handoff. A passing build is not physical operating acceptance or a signed store release.

Latest verified web release: **e101198c40cb26e9f441c316eb948ee328c51d74**, LIVE **11 September 2026 at 13:12:06 UTC** via Render **dep-dahvs3nqj5pc73aopsig**. Exact-commit [verification and public smoke](https://github.com/NAIFMUSFER/Heavy/actions/runs/34602325362) passed **27 production checks** on the second attempt; the first attempt exhausted its readiness wait before Render started, then the identical source passed immediately after the single deployment. This release passed **315 Node tests** and **77 browser checks**, including concurrent real clicks in two storefront tabs, plus Expo, Android debug and iOS simulator builds. Supabase is unchanged at **90 migrations**, with ACTIVE **jana-api v32**, jana-critical v6 and jana-ops-extra v23; custom-session authentication and intentional `verify_jwt:false` are unchanged. The prior release's atomic inactive-draft catalog import remains available. No database, Edge, provider, commercial data or admission setting changed in this web/cart release. Older dated checkpoints below retain historical states.

**Commercial launch is not complete.** Store admission remains closed until actual merchant information, policies, inventory, geography and operating acceptance pass the existing readiness gate. No invented percentage represents readiness.

| Area | Implemented and covered by automated gates | Still required |
|---|---|---|
| Isolation/backend | Dedicated JANA Supabase/Render/branches; Node → custom authenticated Edge → transactional PostgreSQL/PostGIS | Dedicated JANA staging and actual operating acceptance |
| Identity/staff | Email or Saudi phone sign-in; hashed sessions, CSRF/SecureStore; password change/all-session revocation; audited roles, assignment and cash/task safeguards | Verified recipient/recovery flow; actual staff acceptance |
| Commercial storefront | Private versioned draft, immutable published policies, reviewed intake open/close, frozen seller terms | Actual merchant identity/contacts/tax status and approved policies |
| Owner handoff | Public team-link portal; role-scoped bookmarked setup sections; privacy-minimized downloadable launch observation; unsaved merchant draft protection | Owner completes and accepts the [handoff steps](OWNER-HANDOFF-ar.md); current publication evidence below |
| Catalog | Families, versions, offerings, units, fixed/custom baskets, paginated catalog, images; owner-file validation and atomic inactive-draft import | Actual approved products, prices, photographs; replace preview catalog and review/activate each imported draft |
| Customer web/mobile | Catalog/cart/quote/COD, durable local cart and recovery, exact localized amounts, native account retry, resumed checkout/uncertain-confirmation recovery, server-clock expiry, frozen order details/history/paging, recorded-location tracking | Real customer/device acceptance; signed mobile distribution |
| Saved data | Profiles, address/default management, favorites, lists, explicit account-saved cart, validated serialized device persistence with retry/reset, same-origin web-tab synchronization with Web Locks and storage events, recurring reminders with revision/consent | External reminder channels disabled; cross-device/account-cart merge remains explicit |
| Addresses/maps | Arabic/Persian normalization, strict phone/coordinates, foreground GPS, supported pin import, keyless Google links, PostGIS coverage | Approved real geography; embedded Google API not enabled |
| Delivery administration | Polygons/exclusions, fees, minimums, cutoff/slot capacity, revision checks | Actual capacity; warehouse routing before multiple hubs |
| Quotes/orders | Atomic stock/slot reservation, expiration, persistent idempotency, frozen terms and cancellation gates | Tax/invoicing integration before enabling a VAT-registered seller |
| Order experience | Frozen address/appointment, line/cash details, public timeline, cursor paging, cancellation/code renewal/refresh | No automatic background courier publishing or ETA |
| Warehouse/counts | Suppliers, pending inspection, accepted FEFO stock, lot costs/metadata, reorder levels, reviewed counts | Actual inspected/received/count-verified stock; canonical warehouse/bin segregation for multiple hubs |
| Disposal/returns | Waste, damage, supplier outbound return, immutable supplier credit-note evidence/reference-cost comparison, customer quarantine/inspection, rejected-return custody/disposition | Actual bank settlement/accounting/tax treatment, approval policy and approved physical procedures |
| Picker/substitutions | Assignment, FEFO, weight tolerance, fixed-basket measurements, explicit customer-approved line replacement/removal, and same-unit/exact-quantity component replacement at unchanged basket price | Omitted-component discount and basket variance/tolerance/pricing policy; field acceptance |
| Courier | Paged tasks retain outstanding collection/cash liability; assignment, dispatch, delivery code, failure/retry, destination navigation, recipient call link and explicit foreground GPS sharing | Physical devices/procedure; continuous location publishing absent |
| Finance/COD | Delivery separated from cash collection, liability, partial settlement and source-aware completed refunds | Actual cash handover/accounting acceptance |
| Support/reporting | Threads, order links, priority/assignment; real sales/cash/stock reports and explicit unknown/estimated costs | Staff acceptance, actual costs; tax/operating expenses not full accounting |
| Notifications | Transactional in-app notifications; guarded outbox/leases/retries/uncertainty, Resend adapter and monitoring | Dedicated worker, verified destinations/consent/domain and approved channel activation |
| Providers/analytics | Server-only provider boundaries, privacy-minimized events, fail-closed flags | Concrete SMS/push/payment/media integrations as selected; dedicated PostHog ingestion verification |
| Database assurance | Recovered replay, populated fixture backup/restore gate, disposable concurrency tests, immutable ledgers, service-only application RPCs | Real backup restore/recovery timing; supported PostGIS platform-advisor remediation |
| CI/operations | Node/PostgreSQL/recovery/browser/Expo/Android/iOS simulator gates, exact-commit smoke, fixture-only capacity/overload regression, recovery/rotation runbooks; [admin observations](OPERATIONAL-HEALTH.md) for stopped/stale scheduled jobs and overdue queues | Owner-approved staging load, dedicated staging, unattended monitoring/external alert delivery, measured production-backup restore and signed releases |

## Work order before commercial sales

Start with the [Arabic owner handoff guide and exact role links](OWNER-HANDOFF-ar.md). The setup center preserves actual admission state and separates recorded observations from manual operating acceptance; it neither declares commercial completion nor changes admission.

1. Owner provides actual merchant identity, contacts, registrations/tax status, policies, catalog/prices and intended Jazan geography. Publish reviewed terms without inferring these values.
2. Operations records actual inspected stock and capacity, creates real staff accounts and accepts the customer → warehouse → courier → cash/refund journey.
3. Engineering connects the approved verification/recovery and communication providers, provisions the worker, verifies approved destinations, and establishes isolated staging/capacity/backup recovery evidence. Add VAT/invoicing if the confirmed tax status requires it.
4. Owner provides Apple/Google distribution accounts; complete physical-device acceptance, signing and store review.
5. Before Riyadh/Jeddah or another warehouse: implement warehouse/location ownership, routing and stock segregation, approve any basket variance/tolerance/omitted-component pricing beyond the bounded exact replacement, and approve accounting treatment for recorded supplier credits.

Supabase-owned PostGIS advisor findings remain documented platform limitations. Do not alter system-object ownership or invent policies to silence advisors. Service-only JANA application permissions are checked separately. Historical failed runs and recoveries stay in RELEASE-EVIDENCE.md.

## Recovery regression extension — 11 September 2026

The review-branch populated-fixture backup/restore workflow passed run 34548982939 on 278d1326673b87813696304989d808049b9d840c: 12 guard/normalization tests, 11 integration groups and identical data across 52 public tables (24 nonempty). Production application/schema were not changed. See [RECOVERY-REHEARSAL.md](RECOVERY-REHEARSAL.md). Do not mark actual production backup recovery or RPO/RTO complete from this regression gate.

## Staff list continuation — 11 September 2026

Operations order pagination is implemented: indexed database selection, older-page controls, retry preservation, refresh/session guards and the existing courier cash-task lifecycle. Candidate 40e0780 passed 245 Node tests, 56 browser checks, full disposable database integrity and recovery. Migration 20260911015144 and jana-api v30 are applied; the initial web release ca1f650 passed 23 post-deployment checks through dep-dahm129594qs73fj9h70. The current release below includes this work. Full evidence is in RELEASE-EVIDENCE.md. This removes the first-100-orders UI ceiling; it does not complete field acceptance, a signed mobile release or any commercial activation prerequisite.

## Checkout continuity — 11 September 2026

Checkout recovery is implemented for web and native: account-scoped quote references restore the review, server-clock expiry prevents stale confirmation, explicit release handles reservations, and read-only recovery displays an order whose confirmation response was lost. The cart preserves later edits and native retry cleanup preserves newer sessions. Candidate 98eb36f passed 266 Node tests, 59 browser checks and full database/recovery gates. Its identical mobile source passed Expo, Android debug and iOS simulator builds. See RELEASE-EVIDENCE.md for the exact source, runs and artifact expiration.

The additive checkout recovery migration **20260911024522** is applied (84 migrations), with unchanged production order/stock/lot/slot hashes at application. Edge remains jana-api v30 / jana-critical v6 / jana-ops-extra v21; custom-session authentication is preserved.

The initial checkout recovery web release was **07125e5cbcf1f383c9535fc940b74b506f081b1e**, Render **dep-dahmvfid0e5s7382utpg**, live at **2026-09-11 03:05 UTC**. After the owner's payment update, fresh service reads confirmed the billing suspension was cleared; production smoke [34556999274](https://github.com/NAIFMUSFER/Heavy/actions/runs/34556999274) passed 23 checks. The current release below retains this work. The hosting blocker is resolved; no additional schema or Edge deployment was needed.

Commercial admission remains closed. Actual merchant/catalog/prices/inspected stock/geography/capacity and operating approval, verified providers, staging/load/real-backup recovery, physical-device acceptance and signed store distribution remain outstanding. Native build success does not establish store publication. Warehouse routing/segregation, approved basket component rules and supplier credit reconciliation remain explicit work items.

## Cross-application resilience review — 11 September 2026

The implemented release validates and serializes local cart persistence across web/native, preserves stored selections on failures, adds retry/explicit reset, normalizes monetary entry without rounding extra decimal places, repairs staff workspace links and exposes native account restoration retry. Updated API/architecture/mobile documents distinguish current implementation from historical evidence and owner configuration. See [REVIEW-2026-09-11.md](REVIEW-2026-09-11.md) for coverage and limits.

**Current web release: 0a4f992e845275523d2973f49480c7620066a0f4**, Render **dep-dahniorm8hqs73cji0cg**, LIVE at **2026-09-11T03:46:16.549455Z**. This exact source passed **284 Node tests**, **63 disposable browser checks**, Expo export, Android debug and iOS simulator compilation before promotion. Public smoke [34559615482](https://github.com/NAIFMUSFER/Heavy/actions/runs/34559615482) then passed **26 checks** with the exact deployed commit at **03:46:28 UTC**. No migration or Edge runtime changed. Read-only production health remains true, with admission closed and no published merchant profile. Exact runs, artifact digests and remaining launch inputs are retained in RELEASE-EVIDENCE.md; successful native builds are not signed store releases or real-device acceptance.

## Supplier credit reconciliation release — 11 September 2026

**Current web release: 67d03047b191bf8edc8cdee24be5c038ed87166c**, Render **dep-dahp529594qs7380058g**, LIVE at **2026-09-11T05:33:23.737690Z**. The exact aligned source passed **288 Node tests**, **64 disposable browser checks**, full database integrity and populated recovery before promotion. Public smoke [34566340605](https://github.com/NAIFMUSFER/Heavy/actions/runs/34566340605) passed **26 checks** against the deployed commit. Supabase is at **86 migrations** with ACTIVE jana-api v30, jana-critical v6 and jana-ops-extra v22, preserving `verify_jwt:false` custom-session authentication.

The software now records immutable supplier credit-note evidence against a completed physical supplier return, prevents duplicate supplier documents, separates reference inventory cost from financial claims and gives finance/admin write access with inventory read-only review. Production contains zero such records after release; no fixture was created. Actual settlement/accounting/VAT treatment, approval thresholds and operating acceptance remain owner inputs and are not inferred by the application.

## Isolated capacity gate — 11 September 2026

The review branch adds a disposable gateway/Edge/PostgreSQL capacity regression: bounded concurrent catalog reads, explicit latency/throughput thresholds, deterministic overload shedding at the existing gateway admission limit and a recovery read. Candidate 530c045 passed [capacity run 34568077986](https://github.com/NAIFMUSFER/Heavy/actions/runs/34568077986), 288 Node tests and 64 browser checks. It writes only aggregate fixture evidence and cannot target production. This does not establish a production SLA or replace owner-approved staging load acceptance. See [CAPACITY-REHEARSAL.md](CAPACITY-REHEARSAL.md).

## Customer-approved unavailable-line removal release — 11 September 2026

**Current web release: 85a4511d1ee40b9b4d38f014f00b5e45f1277cc7**, Render **dep-dahqq4h594qs73870gs0**, LIVE at **2026-09-11T07:26:38.521573Z**. A picker can now request removal of an unavailable line from a multi-line order; the original item and reservations remain unchanged until explicit customer approval, the lower total is frozen for review, the final line cannot be removed, and accepted reallocation is atomic. Web and native customer review, picker controls and public history are implemented.

Review passed 290 Node tests, the complete PostgreSQL gate with 21 substitution/removal groups, 64 browser checks, recovery, capacity, Expo, Android debug and iOS simulator builds. Exact production smoke [34574309224](https://github.com/NAIFMUSFER/Heavy/actions/runs/34574309224) passed 26 checks; production browser and database gates also passed. Supabase is at **87 migrations** and ACTIVE `jana-api` **v31**, with custom-session authentication unchanged. Production business fingerprints are unchanged and no removal proposal or fixture was created. At that release, component-level basket replacement/variance pricing remained open; the following candidate addresses only exact same-unit replacement at unchanged price.

## Exact basket component replacement candidate — 11 September 2026

Starting from published `85a4511`, this candidate implements the bounded component rule that does not require an invented pricing policy: only a physically recorded shortage may be replaced, the replacement must be active and use the same base unit and exact sold quantity, and the fixed basket price/coupon/total remain unchanged. No reservation changes before explicit customer consent. Approval atomically reallocates stock and clears the old measurements; the newly approved component set must be measured before finishing. Rejection or expiry retains the unresolved original shortage. Web and native customer review, picker selection, public history, durable idempotency and service-only database permissions are included.

Local syntax, gateway bundle checks and **293 Node tests** pass. New disposable PostgreSQL coverage checks proposal immutability, sixteen concurrent approval retries, atomic reservation movement, fresh measurement and consumption, rejection, expiry, validation and grants. CI database/browser/native results, Supabase application, Edge deployment and public release are not yet claimed at this checkpoint.

Verified checkpoint: **581c4f6** passed 293 Node tests, the complete database gate (18 basket groups with sixteen concurrent decisions) and 68 browser checks including picker-to-customer component consent. Recovery/capacity and native build evidence is tied to identical relevant source trees in RELEASE-EVIDENCE.md. Supabase now has **88 migrations** and ACTIVE **jana-api v32**; 19 business-table fingerprints and all deep-health invariants are unchanged. The migration filename matches its actual applied version **20260911083950**. Web promotion remains pending at this checkpoint. Unimplemented basket pricing/tolerance policies, multiple-warehouse segregation/routing, actual operations/device acceptance and owner launch inputs remain open.
