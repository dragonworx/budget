-- Per-stream colour: tints the stream's wave icon and its icon tile on
-- Home. Reuses the existing 12-colour category / lane palette
-- (budget_lane_color). Additive and idempotent.
--
-- Existing streams are backfilled with distinct palette colours per
-- owner, in display_order then name, so neighbouring streams are not
-- the same colour. New streams get a colour from the application
-- (least-used palette entry for that owner) when the client does not
-- send one.

ALTER TABLE streams ADD COLUMN IF NOT EXISTS color TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'streams_color_ck'
  ) THEN
    ALTER TABLE streams ADD CONSTRAINT streams_color_ck
      CHECK (color IS NULL OR color ~ '^#[0-9A-F]{6}$');
  END IF;
END $$;

WITH ranked AS (
  SELECT id,
         (row_number() OVER (
            PARTITION BY owner_id
            ORDER BY display_order, lower(name), id
          ) - 1)::int AS slot
  FROM streams
  WHERE color IS NULL
)
UPDATE streams s
SET color = budget_lane_color(r.slot)
FROM ranked r
WHERE s.id = r.id
  AND s.color IS NULL;
