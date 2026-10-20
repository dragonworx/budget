-- Indexes on foreign keys that cascade or SET NULL when a pool or user is
-- deleted (each delete otherwise scans the whole referencing table), and
-- that the invite list filters on. Idempotent.
CREATE INDEX IF NOT EXISTS invites_pool_idx ON invites (pool_id);
CREATE INDEX IF NOT EXISTS invites_invited_by_idx ON invites (invited_by);
CREATE INDEX IF NOT EXISTS users_last_pool_idx ON users (last_pool_id)
  WHERE last_pool_id IS NOT NULL;
