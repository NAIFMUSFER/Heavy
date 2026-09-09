CREATE TABLE favorites (
  user_id varchar(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  offering_family_id varchar(36) NOT NULL,
  created_at bigint NOT NULL,
  PRIMARY KEY (user_id, offering_family_id)
);
CREATE INDEX ix_favorites_user_created ON favorites(user_id, created_at DESC);
CREATE TABLE shopping_lists (
  id varchar(36) PRIMARY KEY,
  user_id varchar(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name varchar(100) NOT NULL,
  items jsonb NOT NULL,
  created_at bigint NOT NULL,
  updated_at bigint NOT NULL
);
CREATE INDEX ix_shopping_lists_user_updated ON shopping_lists(user_id, updated_at DESC);