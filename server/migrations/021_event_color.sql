-- Per-event colour: the event's lane / line colour on the timeline (and the
-- header of its editor and action menu), as "#RRGGBB". Null (every existing
-- row) = the positional palette colour the client has always drawn, so
-- nothing changes on screen until a colour is picked. Both sides of a
-- transfer share it (mirrored like the name). Additive and idempotent: no
-- backfill, no recolouring.
ALTER TABLE events ADD COLUMN IF NOT EXISTS color TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'events_color_ck'
  ) THEN
    ALTER TABLE events ADD CONSTRAINT events_color_ck
      CHECK (color IS NULL OR color ~ '^#[0-9A-F]{6}$');
  END IF;
END $$;
