-- Per-user home-list order for every stream the user can open (owned
-- and shared). Each viewer's order is independent; reordering a shared
-- stream does not change the owner's list. New streams are appended
-- (owned: on create; shared: when the share is granted). Deleted
-- streams and revoked shares are pruned. Ids missing from the array
-- sort after, using the previous default (owned first by display_order,
-- then shared by name).

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS stream_order uuid[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION users_stream_order_append() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE users
     SET stream_order = stream_order || NEW.id
   WHERE id = NEW.owner_id
     AND NOT (stream_order @> ARRAY[NEW.id]);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_stream_order_append ON streams;
CREATE TRIGGER users_stream_order_append
  AFTER INSERT ON streams
  FOR EACH ROW EXECUTE FUNCTION users_stream_order_append();

CREATE OR REPLACE FUNCTION users_stream_order_append_share() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE users
     SET stream_order = stream_order || NEW.stream_id
   WHERE id = NEW.user_id
     AND NOT (stream_order @> ARRAY[NEW.stream_id]);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_stream_order_append_share ON stream_shares;
CREATE TRIGGER users_stream_order_append_share
  AFTER INSERT ON stream_shares
  FOR EACH ROW EXECUTE FUNCTION users_stream_order_append_share();

CREATE OR REPLACE FUNCTION users_stream_order_prune_stream() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE users
     SET stream_order = array_remove(stream_order, OLD.id)
   WHERE stream_order @> ARRAY[OLD.id];
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS users_stream_order_prune_stream ON streams;
CREATE TRIGGER users_stream_order_prune_stream
  AFTER DELETE ON streams
  FOR EACH ROW EXECUTE FUNCTION users_stream_order_prune_stream();

CREATE OR REPLACE FUNCTION users_stream_order_prune_share() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE users
     SET stream_order = array_remove(stream_order, OLD.stream_id)
   WHERE id = OLD.user_id;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS users_stream_order_prune_share ON stream_shares;
CREATE TRIGGER users_stream_order_prune_share
  AFTER DELETE ON stream_shares
  FOR EACH ROW EXECUTE FUNCTION users_stream_order_prune_share();

-- Existing lists: the previous default (mine first by display_order,
-- then shared by name). Skip users who already have an order so a
-- second run is a no-op.
UPDATE users u
   SET stream_order = (
     SELECT coalesce(array_agg(s.id ORDER BY
              (s.owner_id = u.id) DESC,
              CASE WHEN s.owner_id = u.id THEN s.display_order ELSE 0 END,
              lower(s.name), s.id), '{}'::uuid[])
       FROM streams s
       LEFT JOIN stream_shares sh
         ON sh.stream_id = s.id AND sh.user_id = u.id
      WHERE s.owner_id = u.id OR sh.user_id IS NOT NULL
   )
 WHERE u.stream_order = '{}';
