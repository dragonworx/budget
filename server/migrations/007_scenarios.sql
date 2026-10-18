-- Saved what-if scenarios: a goal-planner request stored per account,
-- overlaid on the timeline as a coloured ghost line when included. They
-- never change the account's real transactions.
CREATE TABLE IF NOT EXISTS scenarios (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  color_index INTEGER NOT NULL DEFAULT 0 CHECK (color_index BETWEEN 0 AND 7),
  included BOOLEAN NOT NULL DEFAULT TRUE,
  request JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS scenarios_account_idx ON scenarios (account_id, created_at);
