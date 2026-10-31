-- 027: loan offset accounts (spec 004). A loan event may link offset
-- streams whose balance above their alert threshold reduces the amount its
-- interest is charged on. An array (not a join table) so several offsets
-- can come later without a redesign and trim/undo snapshots carry it.
-- Postgres cannot FK array elements: the API, stream delete and undo keep
-- the ids valid, and the engine skips any it cannot load. Idempotent.
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS offset_stream_ids UUID[] NOT NULL DEFAULT '{}';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'events_offset_only_loans') THEN
    ALTER TABLE events ADD CONSTRAINT events_offset_only_loans
      CHECK (kind = 'loan' OR cardinality(offset_stream_ids) = 0);
  END IF;
  -- One offset in this version; drop this to allow several later.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'events_offset_max_one') THEN
    ALTER TABLE events ADD CONSTRAINT events_offset_max_one
      CHECK (cardinality(offset_stream_ids) <= 1);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS events_offset_stream_ids_gin
  ON events USING GIN (offset_stream_ids);
