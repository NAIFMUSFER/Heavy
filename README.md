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

The server fails startup on missing public assets or invalid project/origin configuration. Local browsing still uses real JANA APIs: do not create test orders in production. Test suites inject stub responses in memory; production has no fake backend fallback.

## Configuration

`PORT` defaults to 10000. `JANA_SUPABASE_URL` defaults to the verified JANA project and rejects unrelated projects. `JANA_PUBLIC_ORIGIN` defaults to the verified Render URL and requires an HTTPS origin. `RENDER_GIT_COMMIT` is supplied by Render and exposed at `/version`. `POSTHOG_PROJECT_KEY` enables optional server-side capture; `POSTHOG_HOST` is restricted to the US/EU PostHog ingestion endpoints. Configure only a dedicated approved JANA project. No emails, SMS, online payments or feature rollout changes are enabled by this release.

`/health` is gateway liveness. `/ready` checks all three Edge services including the main API's database invariant health. `/version` reports the deployed commit. Public source access is allowlisted: backend files and mobile source are not web assets.

## Database and Edge source

`supabase/migrations` contains the three repairs already applied to the existing JANA database on 9 September 2026. They are **not a complete empty-database bootstrap**. Their pre-change source guards intentionally prevent blind reapplication. The historical migrations must be recovered and validated in an isolated database before a disaster-recovery claim is possible.

`supabase/functions` contains the current reviewed Edge source. Custom opaque session authentication is enforced by JANA PostgreSQL RPCs; the deployed functions intentionally keep the existing `verify_jwt=false` because they do not use Supabase Auth JWT sessions. Function grants must remain service-only. Do not enable anonymous table access.

`tests/database-invariants.sql` is a rollback-fixture test suite used through an authorized PostgreSQL connection. It must never be edited to retain fixtures on production. It does not prove concurrent behavior.

## Mobile and CI

`mobile/` is the existing Expo 54 / React Native app. SecureStore stores tokens and uncertain critical-write retry keys; cart preferences use AsyncStorage. Network outages do not delete sessions. GET requests retry once; financial/checkout writes never automatically retry and preserve their idempotency key when the result is uncertain.

Existing GitHub Actions compile Android debug APK and iOS simulator app and export Expo web. EAS development/preview/production profiles exist. Apple/Google distribution requires owner credentials and identifier ownership confirmation. The established code identifier `com.jana.fresh` is preserved.

Critical order confirmation, delivery completion, COD collection and settlement use a persisted PostgreSQL idempotency dispatcher with role checks and transaction-scoped locks. The extended real-database gate contains 34 checks (33 behavior checks and one SQL type diagnostic), with all fixtures rolled back.

The verification workflow runs syntax and executable tests, then checks the actual Render commit before public smoke tests. An older deployment passing health is insufficient. Current native CI results must be reviewed before release.

## Recovery and limitations

Revert application changes through a new commit on `jana-live`; allow Render to deploy and verify `/version`, `/ready` and smoke. Database rollback requires a reviewed forward corrective migration, never editing applied history. Before commercial launch, establish backup retention, restore into an isolated JANA project, verify constraints and RBAC, and measure recovery time. Rotate Supabase server keys only in JANA Edge configuration and validate all dependencies after rotation. PostGIS grants owned by Supabase administrators remain a documented unresolved security finding.

The full product definition is not complete. Outstanding commercial transactions, provider interfaces, full restore, concurrency and browser/device journeys are listed in the matrix; passing transport tests is not a production-readiness certification.
