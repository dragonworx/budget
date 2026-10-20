-- Each member's own saved timeline view of a pool (what they were looking
-- at last), so reopening the pool — on any device — restores it. Per user
-- per pool: people sharing a pool keep their own views. A preference, not
-- shared data: never audited or broadcast. Additive and idempotent.
CREATE TABLE IF NOT EXISTS pool_views (
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  pool_id      UUID NOT NULL REFERENCES pools(id) ON DELETE CASCADE,
  -- Left edge as a calendar day coordinate (days since 1970-01-01, plus
  -- the fraction of the day), so it means the same date in any timezone.
  start_day    DOUBLE PRECISION NOT NULL,
  visible_days DOUBLE PRECISION NOT NULL,
  unit         TEXT,
  -- Visible balance range; null = the default fit.
  y_min        DOUBLE PRECISION,
  y_max        DOUBLE PRECISION,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, pool_id),
  CONSTRAINT pool_views_days_ck CHECK (visible_days > 0),
  CONSTRAINT pool_views_y_ck CHECK (
    (y_min IS NULL AND y_max IS NULL) OR (y_min < y_max))
);

CREATE INDEX IF NOT EXISTS pool_views_pool_idx ON pool_views (pool_id);
