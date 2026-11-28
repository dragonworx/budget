-- Categories become per-stream again: every stream gets a full copy of its
-- owner's current tree (new ids; parent_id remapped inside the copy).
-- Events (and favourites) are repointed at the copy in that event's own
-- stream. Transfer legs that shared one row each get their stream's copy
-- of the same path. Names, colours, hidden, sort_order and created_at are
-- preserved. There is no icon column.
--
-- Unique names and sibling sort order are scoped to the stream. The
-- events_category_sync trigger again requires the category to belong to
-- the event's stream (a name-only write maps or creates in that stream).
-- The parent guard uses stream_id. Idempotent: a second run is a no-op
-- once stream_id is populated and owner_id is gone.

ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS stream_id uuid REFERENCES streams(id) ON DELETE CASCADE;

-- Copies would collide on the owner-scoped uniques (same name / sort in
-- two streams of one owner). Drop them before inserting.
DROP INDEX IF EXISTS categories_owner_name_uq;
ALTER TABLE categories DROP CONSTRAINT IF EXISTS categories_sibling_sort_uq;

ALTER TABLE events DISABLE TRIGGER USER;
ALTER TABLE categories DISABLE TRIGGER USER;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'categories'
       AND column_name = 'owner_id'
  ) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM categories WHERE stream_id IS NULL) THEN
    RETURN;
  END IF;

  CREATE TEMP TABLE _035_tree ON COMMIT DROP AS
  SELECT c.owner_id,
         c.name,
         c.color,
         c.hidden,
         c.sort_order,
         p.name AS parent_name
    FROM categories c
    LEFT JOIN categories p ON p.id = c.parent_id
   WHERE c.stream_id IS NULL;

  CREATE TEMP TABLE _035_expect ON COMMIT DROP AS
  SELECT c.owner_id,
         count(*) AS cats,
         (SELECT count(*) FROM streams s WHERE s.owner_id = c.owner_id) AS streams,
         count(*) * (SELECT count(*) FROM streams s WHERE s.owner_id = c.owner_id)
           AS expect
    FROM categories c
   WHERE c.stream_id IS NULL
   GROUP BY c.owner_id;

  CREATE TEMP TABLE _035_map ON COMMIT DROP AS
  SELECT c.id AS old_id,
         s.id AS stream_id,
         gen_random_uuid() AS new_id,
         c.parent_id AS old_parent_id,
         c.owner_id,
         c.name,
         c.color,
         c.hidden,
         c.sort_order,
         c.version,
         c.created_at,
         c.updated_at
    FROM categories c
    JOIN streams s ON s.owner_id = c.owner_id
   WHERE c.stream_id IS NULL;

  INSERT INTO categories (
      id, stream_id, owner_id, name, color, hidden,
      parent_id, sort_order, version, created_at, updated_at)
  SELECT m.new_id, m.stream_id, m.owner_id, m.name, m.color, m.hidden,
         NULL, m.sort_order, m.version, m.created_at, m.updated_at
    FROM _035_map m
   WHERE m.old_parent_id IS NULL;

  INSERT INTO categories (
      id, stream_id, owner_id, name, color, hidden,
      parent_id, sort_order, version, created_at, updated_at)
  SELECT m.new_id, m.stream_id, m.owner_id, m.name, m.color, m.hidden,
         p.new_id, m.sort_order, m.version, m.created_at, m.updated_at
    FROM _035_map m
    JOIN _035_map p ON p.old_id = m.old_parent_id AND p.stream_id = m.stream_id
   WHERE m.old_parent_id IS NOT NULL;

  UPDATE events e
     SET category_id = m.new_id
    FROM _035_map m
   WHERE e.category_id = m.old_id
     AND e.stream_id = m.stream_id;

  INSERT INTO category_favorites (user_id, category_id, sort_order, created_at)
  SELECT f.user_id, m.new_id, f.sort_order, f.created_at
    FROM category_favorites f
    JOIN _035_map m ON m.old_id = f.category_id
  ON CONFLICT (user_id, category_id) DO NOTHING;

  DELETE FROM category_favorites f
   USING categories c
   WHERE f.category_id = c.id AND c.stream_id IS NULL;

  -- Children first: parent_id is ON DELETE RESTRICT.
  DELETE FROM categories WHERE stream_id IS NULL AND parent_id IS NOT NULL;
  DELETE FROM categories WHERE stream_id IS NULL;

  -- Owner had categories but no streams: unused leftovers, no events.
  DELETE FROM category_favorites f
   USING categories c
   WHERE f.category_id = c.id
     AND c.stream_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM streams s WHERE s.owner_id = c.owner_id);

  DELETE FROM categories c
   WHERE c.stream_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM streams s WHERE s.owner_id = c.owner_id)
     AND NOT EXISTS (SELECT 1 FROM events e WHERE e.category_id = c.id);
END $$;

ALTER TABLE categories ENABLE TRIGGER USER;
ALTER TABLE events ENABLE TRIGGER USER;

DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM events e
   WHERE NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = e.category_id);
  IF n > 0 THEN
    RAISE EXCEPTION '035: % events lost their category', n;
  END IF;

  SELECT count(*) INTO n FROM events e
    JOIN categories c ON c.id = e.category_id
   WHERE c.stream_id IS DISTINCT FROM e.stream_id
      OR c.stream_id IS NULL;
  IF n > 0 THEN
    RAISE EXCEPTION '035: % events point at a category in another stream', n;
  END IF;

  SELECT count(*) INTO n FROM categories WHERE stream_id IS NULL;
  IF n > 0 THEN
    RAISE EXCEPTION '035: % categories still have no stream_id', n;
  END IF;

  IF to_regclass('_035_expect') IS NOT NULL THEN
    SELECT count(*) INTO n
      FROM _035_expect x
     WHERE x.expect IS DISTINCT FROM (
       SELECT count(*)
         FROM categories c
         JOIN streams s ON s.id = c.stream_id
        WHERE s.owner_id = x.owner_id
     );
    IF n > 0 THEN
      RAISE EXCEPTION
        '035: % owners do not have categories = original set x streams', n;
    END IF;
  END IF;

  IF to_regclass('_035_tree') IS NOT NULL THEN
    SELECT count(*) INTO n
      FROM streams s
      JOIN _035_tree t ON t.owner_id = s.owner_id
     WHERE NOT EXISTS (
       SELECT 1
         FROM categories c
         LEFT JOIN categories p ON p.id = c.parent_id
        WHERE c.stream_id = s.id
          AND c.name = t.name
          AND c.color = t.color
          AND c.hidden = t.hidden
          AND c.sort_order = t.sort_order
          AND p.name IS NOT DISTINCT FROM t.parent_name
     );
    IF n > 0 THEN
      RAISE EXCEPTION
        '035: % stream/category rows missing from an owner tree copy', n;
    END IF;
  END IF;

  SELECT count(*) INTO n
    FROM events a
    JOIN events b ON b.transfer_id = a.transfer_id AND a.id < b.id
    JOIN categories ca ON ca.id = a.category_id
    JOIN categories cb ON cb.id = b.category_id
    LEFT JOIN categories pa ON pa.id = ca.parent_id
    LEFT JOIN categories pb ON pb.id = cb.parent_id
   WHERE a.transfer_id IS NOT NULL
     AND (ca.id = cb.id
          OR ca.stream_id IS DISTINCT FROM a.stream_id
          OR cb.stream_id IS DISTINCT FROM b.stream_id
          OR lower(ca.name) IS DISTINCT FROM lower(cb.name)
          OR pa.name IS DISTINCT FROM pb.name);
  IF n > 0 THEN
    RAISE EXCEPTION
      '035: % transfer pairs do not each have their stream copy of the same path',
      n;
  END IF;
END $$;

ALTER TABLE categories ALTER COLUMN stream_id SET NOT NULL;

-- Recreate triggers that still mention owner_id before dropping the column.
CREATE OR REPLACE FUNCTION categories_parent_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  parent_stream uuid;
  parent_parent uuid;
  parent_name text;
  has_children boolean;
BEGIN
  IF NEW.parent_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.parent_id = NEW.id THEN
    RAISE EXCEPTION 'category cannot be its own parent'
      USING ERRCODE = '23514', CONSTRAINT = 'categories_parent_ck';
  END IF;
  IF lower(NEW.name) = 'sync' THEN
    RAISE EXCEPTION 'Sync cannot be nested'
      USING ERRCODE = '23514', CONSTRAINT = 'categories_sync_top_level';
  END IF;
  SELECT c.stream_id, c.parent_id, c.name
    INTO parent_stream, parent_parent, parent_name
    FROM categories c WHERE c.id = NEW.parent_id;
  IF parent_stream IS NULL THEN
    RAISE EXCEPTION 'parent category not found'
      USING ERRCODE = '23503', CONSTRAINT = 'categories_parent_id_fkey';
  END IF;
  IF parent_stream IS DISTINCT FROM NEW.stream_id THEN
    RAISE EXCEPTION 'parent category must belong to the same stream'
      USING ERRCODE = '23514', CONSTRAINT = 'categories_parent_stream_ck';
  END IF;
  IF parent_parent IS NOT NULL THEN
    RAISE EXCEPTION 'categories can only nest one level deep'
      USING ERRCODE = '23514', CONSTRAINT = 'categories_max_depth';
  END IF;
  IF lower(parent_name) = 'sync' THEN
    RAISE EXCEPTION 'Sync cannot have children'
      USING ERRCODE = '23514', CONSTRAINT = 'categories_sync_top_level';
  END IF;
  SELECT EXISTS(SELECT 1 FROM categories c WHERE c.parent_id = NEW.id)
    INTO has_children;
  IF has_children THEN
    RAISE EXCEPTION 'a category with children must stay top-level'
      USING ERRCODE = '23514', CONSTRAINT = 'categories_max_depth';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS categories_parent_guard ON categories;
CREATE TRIGGER categories_parent_guard
  BEFORE INSERT OR UPDATE OF parent_id, name, stream_id ON categories
  FOR EACH ROW EXECUTE FUNCTION categories_parent_guard();

CREATE OR REPLACE FUNCTION categories_default_sort() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM categories
     WHERE stream_id = NEW.stream_id
       AND parent_id IS NOT DISTINCT FROM NEW.parent_id
       AND sort_order = NEW.sort_order
       AND id IS DISTINCT FROM NEW.id
  ) THEN
    SELECT coalesce(max(sort_order), -1) + 1
      INTO NEW.sort_order
      FROM categories
     WHERE stream_id = NEW.stream_id
       AND parent_id IS NOT DISTINCT FROM NEW.parent_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS categories_default_sort ON categories;
CREATE TRIGGER categories_default_sort
  BEFORE INSERT OR UPDATE OF parent_id, sort_order ON categories
  FOR EACH ROW EXECUTE FUNCTION categories_default_sort();

-- An event's category belongs to its stream; a write that only sets name
-- (legacy clients, import, transfer mirroring) maps to the stream's
-- category of that name, creating it when missing.
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
      OR NEW.category_id IS DISTINCT FROM OLD.category_id
      OR NEW.stream_id IS DISTINCT FROM OLD.stream_id) THEN
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
END;
$$;

DROP TRIGGER IF EXISTS events_category_sync ON events;
CREATE TRIGGER events_category_sync
  BEFORE INSERT OR UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION events_category_sync();

ALTER TABLE categories DROP COLUMN IF EXISTS owner_id;

CREATE UNIQUE INDEX IF NOT EXISTS categories_stream_name_uq
  ON categories (stream_id, lower(name));

ALTER TABLE categories DROP CONSTRAINT IF EXISTS categories_sibling_sort_uq;
ALTER TABLE categories
  ADD CONSTRAINT categories_sibling_sort_uq
  UNIQUE (stream_id, parent_key, sort_order);

-- Stream delete cascades to every category in the tree. parent_id is
-- RESTRICT so a folder with children cannot be deleted on its own;
-- delete children first so the cascade does not trip that restrict.
CREATE OR REPLACE FUNCTION streams_delete_categories() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM categories WHERE stream_id = OLD.id AND parent_id IS NOT NULL;
  DELETE FROM categories WHERE stream_id = OLD.id;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS streams_delete_categories ON streams;
CREATE TRIGGER streams_delete_categories
  BEFORE DELETE ON streams
  FOR EACH ROW EXECUTE FUNCTION streams_delete_categories();
