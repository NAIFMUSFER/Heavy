ALTER TABLE addresses ADD COLUMN is_default boolean NOT NULL DEFAULT false;
CREATE INDEX ix_addresses_user_default ON addresses(user_id, is_default DESC);
WITH ranked AS (
  SELECT id, row_number() OVER (PARTITION BY user_id ORDER BY id) AS rn
  FROM addresses
)
UPDATE addresses a SET is_default = true FROM ranked r WHERE a.id = r.id AND r.rn = 1;
CREATE UNIQUE INDEX uq_addresses_one_default_per_user ON addresses(user_id) WHERE is_default = true;