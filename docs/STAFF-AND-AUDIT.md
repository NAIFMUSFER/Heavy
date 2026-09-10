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

Production inspection on 10 September 2026 found one inactive legacy administrator and no active administrator. No account was activated, assigned a guessed identity or given a fabricated password. An owner must establish the first active administrator through their dedicated JANA database administration access, selecting an account they control. Register and verify access to that customer account first; review its exact id/email in the JANA project, then perform a documented role change under the `jana-staff-membership` transaction lock, insert an audit event and revoke its sessions. Do not use unrelated project credentials or activate an unknown preview account. Further staff creation belongs in the authenticated staff page.

Disposable PostgreSQL tests cover retry behavior, byte limits, session revocation, safe responses, active assignments, cash, final-admin concurrency, self-claim/deactivation races, support assignments and audit pagination. Production account identities and passwords are never test fixtures. Authenticated operator acceptance awaits owner initialization.
