-- Folders (categories with children) cannot hold events. Favourites are
-- leaves only. Events still on a folder would be a 031 leftover; abort
-- rather than drop them.

DELETE FROM category_favorites f
 WHERE EXISTS (
   SELECT 1 FROM categories ch WHERE ch.parent_id = f.category_id
 );

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM events e
     WHERE e.category_id IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM categories ch WHERE ch.parent_id = e.category_id
       )
  ) THEN
    RAISE EXCEPTION
      '032: events are still filed on a category that has children';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION events_category_must_be_leaf()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.category_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM categories ch WHERE ch.parent_id = NEW.category_id
  ) THEN
    RAISE EXCEPTION
      'events cannot be filed on a category that has children'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS events_category_must_be_leaf ON events;
CREATE TRIGGER events_category_must_be_leaf
  BEFORE INSERT OR UPDATE OF category_id ON events
  FOR EACH ROW
  WHEN (NEW.category_id IS NOT NULL)
  EXECUTE FUNCTION events_category_must_be_leaf();

-- A parent must have its events moved before it can gain a child.
CREATE OR REPLACE FUNCTION categories_parent_must_be_empty()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM events e WHERE e.category_id = NEW.parent_id
  ) THEN
    RAISE EXCEPTION
      'cannot add a child to a category that still has events'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS categories_parent_must_be_empty ON categories;
CREATE TRIGGER categories_parent_must_be_empty
  BEFORE INSERT OR UPDATE OF parent_id ON categories
  FOR EACH ROW
  WHEN (NEW.parent_id IS NOT NULL)
  EXECUTE FUNCTION categories_parent_must_be_empty();
