-- 030: sync events (spec 015). A sync pins the stream's closing balance
-- on its day to `amount` (signed: zero and negative allowed). It is a
-- once-off "credit" with no transfer, loan, offsets or end. Idempotent.
ALTER TABLE events DROP CONSTRAINT IF EXISTS events_kind_check;
ALTER TABLE events ADD CONSTRAINT events_kind_check
  CHECK (kind IN ('standard', 'loan', 'sync'));

-- 001's anonymous `amount >= 0` check: found by definition (its name
-- differs between databases), replaced by one that lets a sync be signed.
DO $$
DECLARE
  c TEXT;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'events'::regclass AND contype = 'c'
       AND conname <> 'events_amount_nonneg'
       AND pg_get_constraintdef(oid) ~ '^CHECK \(\(amount >= \(?0'
  LOOP
    EXECUTE format('ALTER TABLE events DROP CONSTRAINT %I', c);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'events_amount_nonneg') THEN
    ALTER TABLE events ADD CONSTRAINT events_amount_nonneg
      CHECK (amount >= 0 OR kind = 'sync');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'events_sync_rules') THEN
    ALTER TABLE events ADD CONSTRAINT events_sync_rules
      CHECK (kind <> 'sync' OR (
        transfer_id IS NULL AND freq_rule = 'once' AND direction = 'credit'
        AND loan IS NULL AND cardinality(offset_stream_ids) = 0
        AND end_mode = 'never' AND end_date IS NULL
        AND occurrence_count IS NULL));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS events_sync_by_stream
  ON events (stream_id, start_date) WHERE kind = 'sync';
