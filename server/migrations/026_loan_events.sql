-- 026: loan events (spec 002). A stream may hold one loan event: a once-off
-- debit (the drawdown) whose `loan` JSONB (schema v1, validated by the API)
-- holds the terms the balance walk accrues interest from. Idempotent.
ALTER TABLE events ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'standard';
ALTER TABLE events ADD COLUMN IF NOT EXISTS loan JSONB;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'events_kind_check') THEN
    ALTER TABLE events ADD CONSTRAINT events_kind_check
      CHECK (kind IN ('standard', 'loan'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'events_loan_shape') THEN
    ALTER TABLE events ADD CONSTRAINT events_loan_shape
      CHECK ((kind = 'loan') = (loan IS NOT NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'events_loan_rules') THEN
    ALTER TABLE events ADD CONSTRAINT events_loan_rules
      CHECK (kind <> 'loan' OR (
        transfer_id IS NULL AND direction = 'debit' AND freq_rule = 'once'
        AND amount > 0 AND (loan->>'v') = '1'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS events_one_loan_per_stream
  ON events (stream_id) WHERE kind = 'loan';
