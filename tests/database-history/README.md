# Recovered applied migration history

These 49 SQL files were recovered from the dedicated JANA Supabase migration history without editing their statements. `manifest.json` records source hashes and the one excluded preview seed. That excluded migration inserts preview users, supplier/stock/catalog records and delivery fixtures; it contains no schema definitions and is deliberately not republished as application seed data.

This is not a production dump or authorization to replay migrations on a populated database. The test bootstrap refuses non-loopback targets and requires a disposable `jana_test` database. It creates test-only role names and the pgcrypto extension schema to reproduce Supabase's function resolution, then replays these historical migrations and the later forward repairs.

A successful CI replay validates schema reconstruction in PostgreSQL/PostGIS. It does not establish a full production backup restore, Supabase-managed extension ownership equivalence, production credentials, or a retention policy.
