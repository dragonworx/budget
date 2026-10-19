-- P3 audit log: one row per successful mutation. `id` is the global event
-- sequence used by P5 real-time resync (SSE Last-Event-ID replay).
CREATE TABLE IF NOT EXISTS audit_log (
  id BIGSERIAL PRIMARY KEY,
  at TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_id UUID REFERENCES users (id) ON DELETE SET NULL,
  project_id UUID,
  account_id UUID,
  action TEXT NOT NULL,
  entity TEXT NOT NULL,
  entity_id TEXT,
  detail JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS audit_log_project_idx ON audit_log (project_id, id);
CREATE INDEX IF NOT EXISTS audit_log_user_idx ON audit_log (user_id, id);
CREATE INDEX IF NOT EXISTS audit_log_at_idx ON audit_log (at);
