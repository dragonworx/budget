-- Categories: every event belongs to exactly one category of its stream.
-- A category has a unique name in its stream (case-insensitive, trimmed),
-- a colour (the timeline lane / line colour of its events, replacing the
-- per-event colour) and a shared "hidden" flag (hidden = its events are left
-- out of the timeline and the balance, like an event's own enabled flag).
--
-- Scope: per stream, like events, so the existing stream roles and sharing
-- apply unchanged (viewers read, editors write) and deleting a category only
-- touches one stream's events (plus their transfer counterparts, done by the
-- API). The two sides of a transfer each use the same-named category of
-- their own stream.
--
-- Backfill: one category per distinct (stream, trimmed lower-case event
-- name), named after the first such event in the stream's list order
-- ("Untitled" for blank names), coloured with that event's colour, or the
-- positional palette colour the client draws for it when it has none, so
-- nothing changes on screen. events.name stays (legacy, import, old
-- clients) and is kept equal to the category name by triggers; events.color
-- stays but is no longer read.
CREATE TABLE IF NOT EXISTS categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stream_id UUID NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  color TEXT NOT NULL,
  hidden BOOLEAN NOT NULL DEFAULT false,
  version INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT categories_name_ck CHECK (name = btrim(name) AND name <> ''),
  CONSTRAINT categories_color_ck CHECK (color ~ '^#[0-9A-F]{6}$')
);
CREATE UNIQUE INDEX IF NOT EXISTS categories_stream_name_uq
  ON categories (stream_id, lower(name));

DROP TRIGGER IF EXISTS categories_bump_version ON categories;
CREATE TRIGGER categories_bump_version BEFORE UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION budget_bump_version();

-- The client's positional lane palette (stack_lanes.dart laneColors).
CREATE OR REPLACE FUNCTION budget_lane_color(slot INTEGER) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY['#3D6FD8', '#9250C8', '#B36A12', '#2B8AA8', '#B8488E',
                '#5B7A2A', '#6A62D6', '#A0602C', '#3C8A6E', '#8E5A9E',
                '#4A78A8', '#9C7A1E'])[(slot % 12) + 1]
$$;

ALTER TABLE events ADD COLUMN IF NOT EXISTS category_id UUID
  REFERENCES categories(id) ON DELETE CASCADE;

-- Backfill without touching versions or the frequency trigger.
ALTER TABLE events DISABLE TRIGGER USER;

WITH ordered AS (
  SELECT e.id, e.stream_id, e.color,
         COALESCE(NULLIF(btrim(e.name), ''), 'Untitled') AS nm,
         (row_number() OVER (
            PARTITION BY e.stream_id
            ORDER BY COALESCE(array_position(s.event_order, e.id), 2147483647),
                     e.created_at, e.id) - 1)::int AS slot
  FROM events e JOIN streams s ON s.id = e.stream_id
  WHERE e.category_id IS NULL
), firsts AS (
  SELECT DISTINCT ON (stream_id, lower(nm)) stream_id, nm, color, slot
  FROM ordered
  ORDER BY stream_id, lower(nm), slot
)
INSERT INTO categories (stream_id, name, color)
SELECT stream_id, nm, COALESCE(upper(color), budget_lane_color(slot))
FROM firsts
ON CONFLICT DO NOTHING;

UPDATE events e SET category_id = c.id
FROM categories c
WHERE e.category_id IS NULL
  AND c.stream_id = e.stream_id
  AND lower(c.name) = lower(COALESCE(NULLIF(btrim(e.name), ''), 'Untitled'));

UPDATE events e SET name = c.name
FROM categories c
WHERE c.id = e.category_id AND e.name IS DISTINCT FROM c.name;

ALTER TABLE events ENABLE TRIGGER USER;

DO $$
DECLARE missing BIGINT;
BEGIN
  SELECT count(*) INTO missing FROM events WHERE category_id IS NULL;
  IF missing > 0 THEN
    RAISE EXCEPTION 'categories backfill left % events without a category', missing;
  END IF;
END $$;

ALTER TABLE events ALTER COLUMN category_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS events_category_idx ON events (category_id);

-- Keeps events.name == its category's name. A write that sets category_id
-- takes the category's name (the category must be in the event's stream);
-- a write that only sets name (legacy clients, import, transfer mirroring)
-- maps it to the stream's category of that name, creating it when missing
-- (colour: the row's legacy colour, else the next palette colour).
CREATE OR REPLACE FUNCTION events_category_sync() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  nm TEXT;
  cid UUID;
  cname TEXT;
  cstream UUID;
  n INTEGER;
BEGIN
  IF NEW.category_id IS NOT NULL AND (TG_OP = 'INSERT'
      OR NEW.category_id IS DISTINCT FROM OLD.category_id) THEN
    SELECT stream_id, name INTO cstream, cname
      FROM categories WHERE id = NEW.category_id;
    IF cstream IS NULL OR cstream <> NEW.stream_id THEN
      RAISE EXCEPTION 'category % is not in stream %', NEW.category_id, NEW.stream_id
        USING ERRCODE = '23503';
    END IF;
    NEW.name := cname;
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' OR NEW.category_id IS NULL
      OR NEW.name IS DISTINCT FROM OLD.name THEN
    nm := COALESCE(NULLIF(btrim(NEW.name), ''), 'Untitled');
    SELECT id, name INTO cid, cname FROM categories
      WHERE stream_id = NEW.stream_id AND lower(name) = lower(nm);
    IF cid IS NULL THEN
      SELECT count(*) INTO n FROM categories WHERE stream_id = NEW.stream_id;
      INSERT INTO categories (stream_id, name, color)
        VALUES (NEW.stream_id, nm,
                COALESCE(upper(NEW.color), budget_lane_color(n)))
        RETURNING id, name INTO cid, cname;
    END IF;
    NEW.category_id := cid;
    NEW.name := cname;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS events_category_sync ON events;
CREATE TRIGGER events_category_sync
  BEFORE INSERT OR UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION events_category_sync();

-- Renaming a category renames its events (names everywhere follow).
CREATE OR REPLACE FUNCTION categories_name_sync() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE events SET name = NEW.name
    WHERE category_id = NEW.id AND name IS DISTINCT FROM NEW.name;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS categories_name_sync ON categories;
CREATE TRIGGER categories_name_sync
  AFTER UPDATE OF name ON categories
  FOR EACH ROW WHEN (NEW.name IS DISTINCT FROM OLD.name)
  EXECUTE FUNCTION categories_name_sync();
