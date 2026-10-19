-- P5 realtime: audit rows double as events. Keep the originating client
-- (X-Client-Id, for echo suppression) and the user a membership change is
-- about (so a revoked user is still told).
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS client_id TEXT;
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS subject_user_id UUID;
