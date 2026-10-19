-- P1 auth: Google-backed users, server-side sessions, admin-managed allowlist.
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY,
  google_sub TEXT UNIQUE,
  email TEXT NOT NULL CHECK (email = lower(email)),
  name TEXT,
  picture_url TEXT,
  is_admin BOOL NOT NULL DEFAULT false,
  disabled BOOL NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS users_email_uidx ON users (email);

CREATE TABLE IF NOT EXISTS sessions (
  id_hash BYTEA PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  user_agent TEXT,
  ip TEXT,
  is_dev BOOL NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS sessions_user_idx ON sessions (user_id);
CREATE INDEX IF NOT EXISTS sessions_expires_idx ON sessions (expires_at);

CREATE TABLE IF NOT EXISTS allowed_emails (
  pattern TEXT PRIMARY KEY CHECK (pattern = lower(pattern)),
  added_by UUID REFERENCES users (id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
