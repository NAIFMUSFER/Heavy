# Operational health observations

The admin dashboard and health page read the existing `GET /api/ops/deep-health` endpoint. Existing database-invariant fields keep their meanings. A versioned `operations` object adds server observation time, two scheduled-job observations and three overdue queue counts. The endpoint remains admin-only through the current custom session and service-only RPC boundary. Its private aggregation function has no anon, authenticated or service-role execute grant.

The observer reads metadata and business rows. It never runs a worker, expires a quote, decides a substitution, edits an order or sends a notification. It is usable inside a PostgreSQL read-only transaction. Public readiness and commercial admission do not silently acquire new behavior from this admin view.

| Observation | Alert condition | Operator response |
|---|---|---|
| Quote/substitution expiry worker | Global scheduler disabled/unknown, missing/disabled job, wrong cadence/command/database, missing/invalid heartbeat, or last successful cycle over 180 seconds old | Review scheduler configuration and job logs; correct the verified cause and confirm a new successful cycle |
| Recurring reminder worker | Same conditions; normal cadence is once a minute | Review the worker and active plan errors; confirm a new success without creating duplicate reminders |
| Active expired quotes | Still active at least 120 seconds after expiry | Inspect the expiry worker and blocked transactions; require normal release to clear the backlog |
| Pending expired substitutions | Still pending at least 120 seconds after expiry | Inspect the expiry worker and affected picking flow; never infer customer consent |
| Active overdue reminders | Active recipient and plan still due after 120 seconds | Inspect the reminder worker; do not enable an external channel merely to clear the alert |

Three minutes for heartbeat age and two minutes for queue grace are initial engineering observation thresholds for the existing one-minute jobs, not a commercial SLA. Counts are exact through 1,000; above that the response returns 1,000 with `capped:true` and the oldest due timestamp. Expiry scans use partial indexes, and reminder scans reuse the existing active-plan index. No identity, address, recipient, job command, token or free-text database error is returned.

A recent heartbeat does not suppress a backlog alert. A stopped job does not become healthy merely because a previous heartbeat is recent. A future or invalid success timestamp does not count as recovery. Every refresh clears the prior success while loading; failed, malformed or superseded responses cannot restore a green status. Results from a previous session or page are ignored. Failure to load health does not prevent the admin's financial reports from loading, and finance users do not request the admin-only observation.

These are observations when the dashboard/page is opened or refreshed. There is no unattended polling or external delivery in this release. Independent uptime checks, an owner-approved destination/provider, escalation ownership and an end-to-end alert delivery exercise remain launch work.

`tests/operational-health.py` exercises healthy, disabled/missing/misconfigured jobs, heartbeat boundaries, scheduling grace, bounded backlogs, inactive recipients, role isolation and concurrent read-only access. It uses disposable loopback PostgreSQL only and restores its temporary scheduler setting in `finally`. Real worker recovery is checked against a reserved fixture quote. Browser coverage verifies the phone alert page, a failed refresh, recovery and customer denial through the real local gateway/Edge/database chain. Production fixture creation is not used.

The observation model uses the official [pg_cron job and configuration contract](https://github.com/citusdata/pg_cron) and [Supabase Cron](https://supabase.com/docs/guides/cron), checked 11 September 2026. Exact tested and published states belong in RELEASE-EVIDENCE.md.
