CREATE TABLE IF NOT EXISTS schema_migrations (
  id TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS projects (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS projects_name_lower_uidx
  ON projects (lower(name));

CREATE TABLE IF NOT EXISTS accounts (
  id UUID PRIMARY KEY,
  project_id UUID NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  currency CHAR(3) NOT NULL,
  seed_balance NUMERIC NOT NULL,
  seed_date DATE NOT NULL,
  display_order INT NOT NULL DEFAULT 0,
  stream_order UUID[] NOT NULL DEFAULT '{}',
  UNIQUE (project_id, name)
);

CREATE TABLE IF NOT EXISTS streams (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  name TEXT NOT NULL DEFAULT '',
  direction TEXT NOT NULL CHECK (direction IN ('credit', 'debit')),
  amount NUMERIC NOT NULL CHECK (amount >= 0),
  start_date DATE NOT NULL,
  recurrence_mode TEXT NOT NULL CHECK (recurrence_mode IN ('once', 'every')),
  interval INT CHECK (interval IS NULL OR interval >= 1),
  unit TEXT CHECK (unit IS NULL OR unit IN ('days', 'weeks', 'months', 'years')),
  end_mode TEXT NOT NULL CHECK (end_mode IN ('never', 'until_date', 'count')),
  end_date DATE,
  occurrence_count INT CHECK (occurrence_count IS NULL OR occurrence_count >= 1),
  enabled BOOL NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT streams_once_or_every CHECK (
    (recurrence_mode = 'once' AND interval IS NULL AND unit IS NULL)
    OR (recurrence_mode = 'every' AND interval IS NOT NULL AND unit IS NOT NULL)
  ),
  CONSTRAINT streams_end_fields CHECK (
    (end_mode = 'never' AND end_date IS NULL AND occurrence_count IS NULL)
    OR (end_mode = 'until_date' AND end_date IS NOT NULL AND occurrence_count IS NULL)
    OR (end_mode = 'count' AND occurrence_count IS NOT NULL AND end_date IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS streams_account_id_idx ON streams (account_id);

CREATE TABLE IF NOT EXISTS skipped_occurrences (
  stream_id UUID NOT NULL REFERENCES streams (id) ON DELETE CASCADE,
  date DATE NOT NULL,
  PRIMARY KEY (stream_id, date)
);
