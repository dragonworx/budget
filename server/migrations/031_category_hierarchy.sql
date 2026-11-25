-- Hierarchical categories (parent/child, max depth 2) and per-user
-- favourites. Additive and keep-all: existing category ids, names and
-- event links are unchanged. New parent rows are inserted only for an
-- owner who has at least one mapped child; a same-named existing row is
-- reused as the parent. Sync is never nested.

ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS parent_id uuid REFERENCES categories(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS categories_parent_idx ON categories (parent_id);

CREATE OR REPLACE FUNCTION categories_parent_guard() RETURNS trigger AS $$
DECLARE
  parent_owner uuid;
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
  SELECT c.owner_id, c.parent_id, c.name
    INTO parent_owner, parent_parent, parent_name
    FROM categories c WHERE c.id = NEW.parent_id;
  IF parent_owner IS NULL THEN
    RAISE EXCEPTION 'parent category not found'
      USING ERRCODE = '23503', CONSTRAINT = 'categories_parent_id_fkey';
  END IF;
  IF parent_owner IS DISTINCT FROM NEW.owner_id THEN
    RAISE EXCEPTION 'parent category must belong to the same owner'
      USING ERRCODE = '23514', CONSTRAINT = 'categories_parent_owner_ck';
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS categories_parent_guard ON categories;
CREATE TRIGGER categories_parent_guard
  BEFORE INSERT OR UPDATE OF parent_id, name, owner_id ON categories
  FOR EACH ROW EXECUTE FUNCTION categories_parent_guard();

CREATE TABLE IF NOT EXISTS category_favorites (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, category_id)
);

CREATE INDEX IF NOT EXISTS category_favorites_user_idx
  ON category_favorites (user_id, sort_order, created_at);

-- Name-based nesting for every owner. Keep-all: no renames, merges or
-- deletes; only insert parents and set parent_id.
DO $$
DECLARE
  own uuid;
  pname text;
  pid uuid;
  used_colors text[];
  color text;
  palette text[] := ARRAY[
    '#3D6FD8','#9250C8','#B36A12','#2B8AA8','#B8488E','#5B7A2A',
    '#6A62D6','#A0602C','#3C8A6E','#8E5A9E','#4A78A8','#9C7A1E'
  ];
  i int;
BEGIN
  CREATE TEMP TABLE cat_map (
    parent text NOT NULL,
    child text NOT NULL
  ) ON COMMIT DROP;
  INSERT INTO cat_map(parent, child) VALUES
    ('Housing', 'Council rates'),
    ('Housing', 'Mortgage'),
    ('Housing', 'Mortgage repayment'),
    ('Housing', 'Rent'),
    ('Housing', 'Home loan'),
    ('Utilities', 'Gas'),
    ('Utilities', 'Internet'),
    ('Utilities', 'Phone'),
    ('Utilities', 'Power'),
    ('Utilities', 'Water'),
    ('Shopping', 'Coffee'),
    ('Shopping', 'Groceries'),
    ('Shopping', 'Pet food'),
    ('Transport', 'Car loan'),
    ('Transport', 'Car service'),
    ('Transport', 'Fuel'),
    ('Transport', 'Parking'),
    ('Income', 'Bonus'),
    ('Income', 'Salary'),
    ('Income', 'Wages'),
    ('Income', 'Pocket money'),
    ('Health', 'Dentist'),
    ('Health', 'Gym'),
    ('Giving', 'Charity'),
    ('Giving', 'Gifts'),
    ('Savings', 'Top up savings');

  FOR own IN SELECT DISTINCT owner_id FROM categories
  LOOP
    FOR pname IN
      SELECT DISTINCT m.parent
      FROM cat_map m
      WHERE EXISTS (
        SELECT 1 FROM categories c
        WHERE c.owner_id = own AND lower(c.name) = lower(m.child)
      )
    LOOP
      SELECT c.id INTO pid
      FROM categories c
      WHERE c.owner_id = own AND lower(c.name) = lower(pname);
      IF pid IS NULL THEN
        SELECT array_agg(c.color) INTO used_colors
        FROM categories c WHERE c.owner_id = own;
        color := palette[1];
        FOR i IN 1 .. array_length(palette, 1) LOOP
          IF used_colors IS NULL OR NOT (palette[i] = ANY (used_colors)) THEN
            color := palette[i];
            EXIT;
          END IF;
        END LOOP;
        INSERT INTO categories (owner_id, name, color, hidden, sort_order)
        VALUES (own, pname, color, false, -1000000)
        RETURNING id INTO pid;
      END IF;

      UPDATE categories c
         SET parent_id = pid
        FROM cat_map m
       WHERE c.owner_id = own
         AND lower(c.name) = lower(m.child)
         AND lower(m.parent) = lower(pname)
         AND c.id <> pid
         AND c.parent_id IS NULL
         AND lower(c.name) <> 'sync';
    END LOOP;
  END LOOP;

  WITH n AS (
    SELECT c.id,
           row_number() OVER (
             PARTITION BY c.owner_id, c.parent_id
             ORDER BY c.id
           ) AS rn
    FROM categories c
  )
  UPDATE categories c SET sort_order = -n.rn FROM n WHERE c.id = n.id;

  WITH ranked AS (
    SELECT c.id,
           row_number() OVER (
             PARTITION BY c.owner_id, c.parent_id
             ORDER BY
               CASE WHEN c.parent_id IS NULL THEN
                 CASE lower(c.name)
                   WHEN 'income' THEN 0
                   WHEN 'housing' THEN 1
                   WHEN 'utilities' THEN 2
                   WHEN 'insurance' THEN 3
                   WHEN 'transport' THEN 4
                   WHEN 'shopping' THEN 5
                   WHEN 'health' THEN 6
                   WHEN 'giving' THEN 7
                   WHEN 'savings' THEN 8
                   ELSE 100
                 END
               ELSE 0 END,
               lower(c.name),
               c.id
           ) - 1 AS ord
    FROM categories c
  )
  UPDATE categories c SET sort_order = ranked.ord FROM ranked WHERE c.id = ranked.id;
END $$;

-- Unique among siblings (null parent_id = one top-level group). Added
-- after the data rewrite so mid-update collisions cannot fire.
ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS parent_key uuid
    GENERATED ALWAYS AS (
      COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) STORED;

ALTER TABLE categories
  DROP CONSTRAINT IF EXISTS categories_sibling_sort_uq;
ALTER TABLE categories
  ADD CONSTRAINT categories_sibling_sort_uq
  UNIQUE (owner_id, parent_key, sort_order);


-- Implicit inserts (event-name mapping, import) default sort_order to 0,
-- which would collide at the top level. Bump to the next free sibling
-- slot when the chosen order is already taken.
CREATE OR REPLACE FUNCTION categories_default_sort() RETURNS trigger AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM categories
     WHERE owner_id = NEW.owner_id
       AND parent_id IS NOT DISTINCT FROM NEW.parent_id
       AND sort_order = NEW.sort_order
       AND id IS DISTINCT FROM NEW.id
  ) THEN
    SELECT coalesce(max(sort_order), -1) + 1
      INTO NEW.sort_order
      FROM categories
     WHERE owner_id = NEW.owner_id
       AND parent_id IS NOT DISTINCT FROM NEW.parent_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS categories_default_sort ON categories;
CREATE TRIGGER categories_default_sort
  BEFORE INSERT OR UPDATE OF parent_id, sort_order ON categories
  FOR EACH ROW EXECUTE FUNCTION categories_default_sort();
