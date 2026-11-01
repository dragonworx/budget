-- 028: variables (spec 010). An owner's named values ($rent) that event,
-- override and stream number fields may reference in formulas. The
-- resolved number stays in the existing numeric column (the engine and
-- read routes are unchanged); the formula text sits beside it in a
-- nullable *_expr column and *expr_error(s) holds a still-valid value's
-- last resolution problem. variable_refs indexes who uses what (by id, so
-- a rename rewrites only the texts it lists). Existing rows are untouched.
-- Idempotent.
CREATE TABLE IF NOT EXISTS variables (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  unit TEXT NOT NULL DEFAULT 'number',
  expr TEXT NOT NULL,
  value NUMERIC NOT NULL,
  description TEXT,
  display_decimals SMALLINT,
  problem JSONB,
  version INT NOT NULL DEFAULT 1,
  created_by UUID REFERENCES users (id) ON DELETE SET NULL,
  updated_by UUID REFERENCES users (id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'variables_name_check') THEN
    ALTER TABLE variables ADD CONSTRAINT variables_name_check
      CHECK (name ~ '^[A-Za-z_][A-Za-z0-9_]{0,39}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'variables_unit_check') THEN
    ALTER TABLE variables ADD CONSTRAINT variables_unit_check
      CHECK (unit IN ('money', 'percent', 'number'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'variables_expr_len') THEN
    ALTER TABLE variables ADD CONSTRAINT variables_expr_len
      CHECK (char_length(expr) BETWEEN 1 AND 500);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'variables_desc_len') THEN
    ALTER TABLE variables ADD CONSTRAINT variables_desc_len
      CHECK (description IS NULL OR char_length(description) <= 200);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'variables_decimals') THEN
    ALTER TABLE variables ADD CONSTRAINT variables_decimals
      CHECK (display_decimals IS NULL OR display_decimals BETWEEN 0 AND 6);
  END IF;
END $$;

-- Names are unique per owner, case-insensitively ($Rent and $rent clash).
CREATE UNIQUE INDEX IF NOT EXISTS variables_owner_name_uq
  ON variables (owner_id, lower(name));

DROP TRIGGER IF EXISTS variables_bump_version ON variables;
CREATE TRIGGER variables_bump_version BEFORE UPDATE ON variables
  FOR EACH ROW EXECUTE FUNCTION budget_bump_version();

-- Formula texts beside the resolved numbers.
ALTER TABLE events ADD COLUMN IF NOT EXISTS amount_expr TEXT;
ALTER TABLE events ADD COLUMN IF NOT EXISTS interval_expr TEXT;
ALTER TABLE events ADD COLUMN IF NOT EXISTS count_expr TEXT;
ALTER TABLE events ADD COLUMN IF NOT EXISTS expr_errors JSONB;
ALTER TABLE occurrence_overrides ADD COLUMN IF NOT EXISTS amount_expr TEXT;
ALTER TABLE occurrence_overrides ADD COLUMN IF NOT EXISTS expr_error JSONB;
ALTER TABLE streams ADD COLUMN IF NOT EXISTS seed_balance_expr TEXT;
ALTER TABLE streams ADD COLUMN IF NOT EXISTS loss_threshold_expr TEXT;
ALTER TABLE streams ADD COLUMN IF NOT EXISTS expr_errors JSONB;

DO $$
DECLARE
  c RECORD;
BEGIN
  FOR c IN SELECT * FROM (VALUES
      ('events', 'amount_expr'), ('events', 'interval_expr'),
      ('events', 'count_expr'), ('occurrence_overrides', 'amount_expr'),
      ('streams', 'seed_balance_expr'), ('streams', 'loss_threshold_expr')
    ) v(t, col) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conname = c.t || '_' || c.col || '_len') THEN
      EXECUTE format(
        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IS NULL OR char_length(%I) <= 500)',
        c.t, c.t || '_' || c.col || '_len', c.col, c.col);
    END IF;
  END LOOP;
END $$;

-- Who references which variable. Exactly one of from_variable_id (a
-- variable's own formula) or stream_id (a stream field, an event field
-- with event_id, or an override with event_id + override_date). A
-- transfer is indexed on its debit row only. variable_id has no cascade:
-- a variable in use cannot be deleted (the API answers 409 first). The
-- check is deferred to commit: a user deletion cascades variables and
-- (via streams -> events) their refs in nested statements whose order
-- Postgres doesn't guarantee, and a NO ACTION check runs after each
-- nested statement, not after the outer one.
CREATE TABLE IF NOT EXISTS variable_refs (
  id BIGSERIAL PRIMARY KEY,
  variable_id UUID NOT NULL REFERENCES variables (id)
    DEFERRABLE INITIALLY DEFERRED,
  from_variable_id UUID REFERENCES variables (id) ON DELETE CASCADE,
  stream_id UUID REFERENCES streams (id) ON DELETE CASCADE,
  event_id UUID REFERENCES events (id) ON DELETE CASCADE,
  override_date DATE,
  field TEXT NOT NULL,
  FOREIGN KEY (event_id, override_date)
    REFERENCES occurrence_overrides (event_id, date)
    ON DELETE CASCADE ON UPDATE CASCADE,
  CHECK ((from_variable_id IS NOT NULL) <> (stream_id IS NOT NULL)),
  CHECK (event_id IS NULL OR stream_id IS NOT NULL),
  CHECK (override_date IS NULL OR event_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS variable_refs_uq ON variable_refs
  (variable_id, from_variable_id, stream_id, event_id, override_date, field)
  NULLS NOT DISTINCT;
CREATE INDEX IF NOT EXISTS variable_refs_event_idx ON variable_refs (event_id);
CREATE INDEX IF NOT EXISTS variable_refs_stream_idx ON variable_refs (stream_id);
CREATE INDEX IF NOT EXISTS variable_refs_from_idx
  ON variable_refs (from_variable_id);
