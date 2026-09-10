# JANA Fresh — جَنى

Arabic RTL produce commerce and operations. **Commercial launch is not yet verified.** Current catalog and inventory include explicitly marked preview records. See [audit matrix](docs/AUDIT-MATRIX.md) for evidence and remaining work.

## Canonical deployment

- Source: `NAIFMUSFER/Heavy`, branch `jana-live` only.
- Web gateway: https://jana-fresh-app.onrender.com (`srv-dagnferl550s73cbivhg`).
- Supabase: dedicated JANA project `jjdsajiwoqanefmnikls`.
- Browser/mobile → same-origin Node gateway → JANA Edge functions → service-only transactional PostgreSQL RPCs.
- No service role key exists in the web gateway, browser or mobile source. Supabase Edge receives its server-side key from the platform.

## Local verification

Use Node 24. The gateway has no npm dependencies.

```sh
node scripts/check.cjs
node --test tests/*.test.cjs tests/*.test.mjs
node server.js
```

The server fails startup on missing public assets or invalid project/origin configuration. Local browsing still uses real JANA APIs: do not create test orders in production. Unit tests inject responses in memory. The isolated browser gate instead uses actual Edge handlers and a disposable PostgreSQL/PostgREST service; production has no fake backend fallback.

## Configuration

`PORT` defaults to 10000. `JANA_SUPABASE_URL` defaults to the verified JANA project and rejects unrelated projects. `JANA_PUBLIC_ORIGIN` defaults to the verified Render URL and requires an HTTPS origin. `RENDER_GIT_COMMIT` is supplied by Render and exposed at `/version`. `JANA_POSTHOG_PROJECT_ID` together with `JANA_POSTHOG_PROJECT_KEY` enables optional server-side capture; generic analytics keys are ignored. `JANA_POSTHOG_HOST` is restricted to the US/EU PostHog ingestion endpoints. Configure only a dedicated approved JANA project. No emails, SMS, online payments or feature rollout changes are enabled by this release.

`/health` is gateway liveness. `/ready` checks all three Edge services including the main API's database invariant health. `/version` reports the deployed commit. Public source access is allowlisted: backend files and mobile source are not web assets.

## Database and Edge source

`supabase/migrations` contains the reviewed repairs already applied to the existing JANA database on 9–10 September 2026. The original schema history is recovered verbatim under `tests/database-history`, with preview credentials and sample stock seed excluded. GitHub Actions successfully replays that history and the subsequent repairs into an empty PostgreSQL 17/PostGIS database. This verifies schema recovery, not recovery of production data backups. Source guards prevent blind reapplication of earlier repairs.

`supabase/functions` contains the current reviewed Edge source. Custom opaque session authentication is enforced by JANA PostgreSQL RPCs; the deployed functions intentionally keep the existing `verify_jwt=false` because they do not use Supabase Auth JWT sessions. Function grants must remain service-only. Do not enable anonymous table access.

`tests/database-invariants.sql` is a rollback-fixture test suite used through an authorized PostgreSQL connection. It must never be edited to retain fixtures on production. It does not prove concurrent behavior.

## Mobile and CI

`mobile/` is the existing Expo 54 / React Native app. SecureStore stores tokens and uncertain critical-write retry keys; cart preferences use AsyncStorage. Network outages do not delete sessions. GET requests retry once; financial/checkout writes never automatically retry and preserve their idempotency key when the result is uncertain.

Existing GitHub Actions compile Android debug APK and iOS simulator app and export Expo web. EAS development/preview/production profiles exist. Apple/Google distribution requires owner credentials and identifier ownership confirmation. The established code identifier `com.jana.fresh` is preserved.

Critical order confirmation, delivery completion, COD collection and settlement use a persisted PostgreSQL idempotency dispatcher with role checks and transaction-scoped locks. The extended real-database gate contains 34 checks (33 behavior checks and one SQL type diagnostic), with all fixtures rolled back.

The verification workflow runs syntax and executable tests, then checks the actual Render commit before public smoke tests. An older deployment passing health is insufficient. Current native CI results must be reviewed before release.

Detailed [architecture](docs/ARCHITECTURE.md), [deployment and recovery](docs/OPERATIONS-RUNBOOK.md), [financial integrity](docs/FINANCIAL-INTEGRITY.md), [picking/substitution](docs/PICKING-SUBSTITUTIONS.md), and [warehouse counts](docs/WAREHOUSE-COUNTS.md) documents describe current behavior and explicit gaps.

## Recovery and limitations

Revert application changes through a new commit on `jana-live`; allow Render to deploy and verify `/version`, `/ready` and smoke. Database rollback requires a reviewed forward corrective migration, never editing applied history. Before commercial launch, establish backup retention, restore into an isolated JANA project, verify constraints and RBAC, and measure recovery time. Rotate Supabase server keys only in JANA Edge configuration and validate all dependencies after rotation. PostGIS grants owned by Supabase administrators remain a documented unresolved security finding.

The full product definition is not complete. Outstanding commercial acceptance, external provider workers/configuration, production-data restore and device journeys are listed in the matrix; passing transport tests is not a production-readiness certification.

## Transaction and release verification

The isolated PostgreSQL CI gate runs 34 regression checks, ten groups of 16-client concurrency checks, and ten coupon lifecycle/pricing groups. Address ownership/default and actual pg_cron execution tests also pass. Successful database run: 34400862608. The JavaScript suite now has 163 passing tests. See [release evidence](docs/RELEASE-EVIDENCE.md) for current deployment, database, browser and mobile results.

Coupons support fixed amounts and percentage basis points. Their usage is reserved with stock and delivery capacity, released on quote cancellation/expiry, and redeemed once on confirmation. Confirmed-order cancellation does not restore a redeemed usage. Immutable sold coupon terms govern weight adjustments. A coupon may expire sooner than the usual fifteen-minute quote window. VAT configuration remains outstanding.

Coupon entry is gated by the server-side `jana-checkout-coupons` PostHog flag. Configure `JANA_POSTHOG_PROJECT_ID`, `JANA_POSTHOG_PROJECT_KEY`, and `JANA_POSTHOG_HOST` only for a dedicated JANA project in Supabase Edge secrets. Create the flag at 0% and test internally before requesting rollout approval. Missing configuration, flag outages, partial evaluation errors, and quota limits keep this feature disabled; ordinary COD checkout remains available. No production rollout percentage has been changed. Flags use a hashed high-entropy session identifier and never send tokens or customer details. API reference: https://posthog.com/docs/api/flags .

Run the database scripts only with `JANA_TEST_DATABASE=disposable`, `PGHOST=127.0.0.1` and `PGDATABASE=jana_test`. They refuse non-local database targets. The Actions service is destroyed after the job; no preview accounts or inventory are copied into production.

The migration `20260909202730_jana_scheduled_quote_expiry.sql` installs pg_cron and schedules `jana-quote-expiry` every minute. It releases up to 200 expired quote reservations per run without swallowing transaction errors. Inspect `cron.job_run_details` for failures and `worker_runs` for the last successful run. The isolated Docker test uses PostgreSQL 17 Bookworm with genuine PostGIS and pg_cron; it verifies a scheduled release rather than invoking a fake timer. Scheduling reference: https://supabase.com/docs/guides/cron/quickstart .

Canonical product families now contain immutable versions with multiple sellable sizes. Admin saves a draft and explicitly activates it; original offerings and old order snapshots remain intact. Support conversations include customer/staff replies, assignment, priority, closing and reopening. COD/refund ledger details and the latest release gate are in [financial integrity](docs/FINANCIAL-INTEGRITY.md).

The isolated browser journey is defined in `.github/workflows/jana-browser-e2e.yml`. It uses pinned Playwright dependencies in `tests/e2e`, actual gateway/Edge code, and a fresh migrated local database. There is no production-network fallback. Its current run status and gaps are recorded in the audit matrix.
