-- Categories become global per owner: one shared set for every stream a
-- user owns (unique name in the set, case-insensitive), usable by events in
-- any of those streams. A shared stream's events use its OWNER's set:
-- editors pick from it (and may add to it), viewers read it; renaming,
-- recolouring, hiding and deleting are the owner's (they reach every one
-- of the owner's streams).
--
-- Merge: the per-stream categories of an owner with the same name
-- (case-insensitive, trimmed) become one, the earliest made (then lowest
-- id) wins and keeps its name, colour and hidden flag; events are
-- repointed to it and the rest are dropped. Names are unique per stream
-- already, so after the merge there is exactly one category per
-- (owner, lower(name)): no other collisions are possible.
ALTER TABLE categories ADD COLUMN IF NOT EXISTS owner_id UUID
  REFERENCES users(id) ON DELETE CASCADE;

UPDATE categories c SET owner_id = s.owner_id
FROM streams s WHERE s.id = c.stream_id AND c.owner_id IS NULL;

ALTER TABLE events DISABLE TRIGGER USER;
ALTER TABLE categories DISABLE TRIGGER USER;

CREATE TEMP TABLE category_merge ON COMMIT DROP AS
SELECT c.id AS old_id,
       first_value(c.id) OVER (
         PARTITION BY c.owner_id, lower(btrim(c.name))
         ORDER BY c.created_at, c.id) AS new_id
FROM categories c;

UPDATE events e SET category_id = m.new_id
FROM category_merge m
WHERE e.category_id = m.old_id AND m.old_id <> m.new_id;

DELETE FROM categories c USING category_merge m
WHERE c.id = m.old_id AND m.old_id <> m.new_id;

UPDATE events e SET name = c.name
FROM categories c
WHERE c.id = e.category_id AND e.name IS DISTINCT FROM c.name;

ALTER TABLE categories ENABLE TRIGGER USER;
ALTER TABLE events ENABLE TRIGGER USER;

DO $$
DECLARE missing BIGINT; dups BIGINT;
BEGIN
  SELECT count(*) INTO missing FROM events e
    WHERE NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = e.category_id);
  IF missing > 0 THEN
    RAISE EXCEPTION 'global categories left % events without a category', missing;
  END IF;
  SELECT count(*) INTO dups FROM events e
    JOIN streams s ON s.id = e.stream_id
    JOIN categories c ON c.id = e.category_id
    WHERE c.owner_id <> s.owner_id;
  IF dups > 0 THEN
    RAISE EXCEPTION '% events use another owner''s category', dups;
  END IF;
END $$;

ALTER TABLE categories ALTER COLUMN owner_id SET NOT NULL;
DROP INDEX IF EXISTS categories_stream_name_uq;
ALTER TABLE categories DROP COLUMN IF EXISTS stream_id;
CREATE UNIQUE INDEX IF NOT EXISTS categories_owner_name_uq
  ON categories (owner_id, lower(name));

-- An event's category belongs to its stream's owner; a write naming only
-- a name (legacy clients, import, transfer mirroring) maps to the owner's
-- category of that name, creating it when missing.
CREATE OR REPLACE FUNCTION events_category_sync() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  nm TEXT;
  cid UUID;
  cname TEXT;
  cowner UUID;
  sowner UUID;
  n INTEGER;
BEGIN
  SELECT owner_id INTO sowner FROM streams WHERE id = NEW.stream_id;
  IF NEW.category_id IS NOT NULL AND (TG_OP = 'INSERT'
      OR NEW.category_id IS DISTINCT FROM OLD.category_id
      OR NEW.stream_id IS DISTINCT FROM OLD.stream_id) THEN
    SELECT owner_id, name INTO cowner, cname
      FROM categories WHERE id = NEW.category_id;
    IF cowner IS NULL OR cowner <> sowner THEN
      RAISE EXCEPTION 'category % is not one of the stream owner''s', NEW.category_id
        USING ERRCODE = '23503';
    END IF;
    NEW.name := cname;
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' OR NEW.category_id IS NULL
      OR NEW.name IS DISTINCT FROM OLD.name THEN
    nm := COALESCE(NULLIF(btrim(NEW.name), ''), 'Untitled');
    SELECT id, name INTO cid, cname FROM categories
      WHERE owner_id = sowner AND lower(name) = lower(nm);
    IF cid IS NULL THEN
      SELECT count(*) INTO n FROM categories WHERE owner_id = sowner;
      INSERT INTO categories (owner_id, name, color)
        VALUES (sowner, nm, COALESCE(upper(NEW.color), budget_lane_color(n)))
        RETURNING id, name INTO cid, cname;
    END IF;
    NEW.category_id := cid;
    NEW.name := cname;
  END IF;
  RETURN NEW;
END $$;
