# Staff, assignment and audit

Administrative membership changes use PostgreSQL RBAC, durable idempotency and an advisory lock shared with explicit order assignment. Account creation validates the six operational roles and bcrypt's 72-byte password limit. Only selected public staff fields leave the RPC; raw passwords are never persisted in idempotency responses or audit detail.

Changing role or active status revokes that employee's sessions. The final active administrator cannot be demoted or disabled, including concurrent attempts. Customer self-service account deletion rejects staff accounts; it cannot bypass membership safeguards. A current deployment with no active administrator still requires owner-controlled initialization; this migration does not reactivate legacy accounts.

Membership removal is refused while the employee has active assigned orders, delivered orders awaiting COD collection, courier cash liability or unresolved assigned support tickets. Admins must resolve or reassign work first. Picker assignment is allowed before picking completes; courier assignment is allowed for ready orders before dispatch or after a recorded failed attempt. Moving deliveries and collected orders cannot be reassigned. Completed order history retains original employee identifiers. The current conservative rule keeps a picker with a ready but still active order active until that order completes.

A self-claim locks the active staff row through the order transition; an administrative disable cannot concurrently strand newly claimed work. Explicit assignment is audited with previous and new employees plus mandatory reason. Administrator dispatch also requires a real active assigned courier.

The staff page confirms membership changes and administrator creation. The order assignment dialog loads the current active roster. The audit page uses 50-row keyset pagination with a timestamp/id tie-breaker; stored values are HTML-escaped and credential-like JSON fields recursively removed. Audit history remains append-only.

## API

- `GET /api/ops/staff`: minimal administrative roster.
- `POST /api/ops/staff`: create staff; `Idempotency-Key` required.
- `PATCH /api/ops/staff/:id`: documented name/email/phone/role/active changes; key required.
- `POST /api/ops/orders/:id/assignment`: picker or courier assignment with reason; key required.
- `GET /api/ops/audit`: optional `action`, paired `before_at` and `before_id` cursor.

## Owner initialization

Initial production inspection on 10 September 2026 found one inactive legacy administrator and no active administrator. At 14:19:39 UTC, the owner identified their already registered account through a signed-in account screenshot. Its exact id/email, active customer role and lack of active orders, live quotes or assigned operational obligations were checked in the dedicated JANA database.

The authorized initialization transaction took the `jana-staff-membership` advisory lock and the target row lock, rechecked that no active administrator existed, changed only the selected account's role, revoked its one stored session and inserted one `owner_initialized` audit event with before/after state and authorization context. Its operation identifier makes a repeat after success return without another change or session revocation. An independent read confirmed one active administrator, the audit event, unchanged order/stock fingerprints and zero direct client EXECUTE grants on JANA functions. The legacy administrator remains inactive. Account identifiers and credentials are kept out of source documentation.

For a new isolated environment, register and verify control of the intended customer account first, review its exact id/email, then perform the same guarded, audited initialization through dedicated database administration. Never activate a guessed identity or unknown preview account. Subsequent staff changes belong in the authenticated staff page. The owner must sign in again after initialization; a successful owner browser login is not implied by the database verification.

Disposable PostgreSQL tests cover retry behavior, byte limits, session revocation, safe responses, active assignments, cash, final-admin concurrency, self-claim/deactivation races, support assignments and audit pagination. Production account identities and passwords are never test fixtures. Authenticated operator acceptance remains pending after owner initialization.
