-- Optional per-event label: extra context under the category name, shown
-- on the timeline as "<category>: <label>" when set. Null means none
-- (every existing row stays unchanged). Additive and idempotent: no
-- backfill, no rewrite of names. Empty strings are rejected so the
-- application stores absence as NULL.
ALTER TABLE events ADD COLUMN IF NOT EXISTS label TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'events_label_ck'
  ) THEN
    ALTER TABLE events ADD CONSTRAINT events_label_ck
      CHECK (label IS NULL OR (char_length(label) BETWEEN 1 AND 60));
  END IF;
END $$;
