-- "Pools" are now "streams" and "transactions" are now "events" everywhere
-- (UI, API, code, schema). A pure rename: every row is kept (users,
-- sessions, allow list, admin flags, shares, invites, views, audit log).
-- Runs once (schema_migrations) inside one DB transaction, and is guarded on
-- the old table still existing, so a re-run is a no-op. On a fresh database
-- 001-019 create the old names and this renames them.
DO $$
DECLARE
  r record;
  new_name text;
BEGIN
  IF to_regclass('public.pools') IS NULL THEN
    RETURN;
  END IF;

  -- Tables.
  ALTER TABLE pools RENAME TO streams;
  ALTER TABLE transactions RENAME TO events;
  ALTER TABLE pool_shares RENAME TO stream_shares;
  ALTER TABLE pool_views RENAME TO stream_views;

  -- Columns.
  ALTER TABLE events RENAME COLUMN pool_id TO stream_id;
  ALTER TABLE stream_shares RENAME COLUMN pool_id TO stream_id;
  ALTER TABLE stream_views RENAME COLUMN pool_id TO stream_id;
  ALTER TABLE scenarios RENAME COLUMN pool_id TO stream_id;
  ALTER TABLE invites RENAME COLUMN pool_id TO stream_id;
  ALTER TABLE audit_log RENAME COLUMN pool_id TO stream_id;
  ALTER TABLE users RENAME COLUMN last_pool_id TO last_stream_id;
  ALTER TABLE streams RENAME COLUMN transaction_order TO event_order;
  ALTER TABLE skipped_occurrences RENAME COLUMN transaction_id TO event_id;
  ALTER TABLE occurrence_overrides RENAME COLUMN transaction_id TO event_id;

  -- Constraints (renaming a PK/unique constraint renames its index too),
  -- including names left over from the accounts era.
  FOR r IN
    SELECT c.conname, t.relname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public' AND c.conname ~ '(pool|transaction|account)'
  LOOP
    new_name := replace(replace(replace(r.conname,
      'account', 'stream'), 'pool', 'stream'), 'transaction', 'event');
    EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
      r.relname, r.conname, new_name);
  END LOOP;

  -- Remaining indexes and sequences.
  FOR r IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('i', 'S')
      AND c.relname ~ '(pool|transaction|account)'
  LOOP
    new_name := replace(replace(replace(r.relname,
      'account', 'stream'), 'pool', 'stream'), 'transaction', 'event');
    IF r.relkind = 'i' THEN
      EXECUTE format('ALTER INDEX %I RENAME TO %I', r.relname, new_name);
    ELSE
      EXECUTE format('ALTER SEQUENCE %I RENAME TO %I', r.relname, new_name);
    END IF;
  END LOOP;

  -- Triggers (the shared budget_bump_version() function names no table).
  FOR r IN
    SELECT tg.tgname, t.relname
    FROM pg_trigger tg
    JOIN pg_class t ON t.oid = tg.tgrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public' AND NOT tg.tgisinternal
      AND tg.tgname ~ '(pool|transaction|account)'
  LOOP
    new_name := replace(replace(replace(r.tgname,
      'account', 'stream'), 'pool', 'stream'), 'transaction', 'event');
    EXECUTE format('ALTER TRIGGER %I ON %I RENAME TO %I',
      r.tgname, r.relname, new_name);
  END LOOP;

  -- Stored event names (realtime resume, audit) follow the new names:
  -- pool.* -> stream.*, pool_share.* -> stream_share.*,
  -- transaction.* -> event.*, transactions.* -> events.*.
  UPDATE audit_log SET action = 'stream' || substr(action, 5)
    WHERE action LIKE 'pool.%' OR action LIKE 'pool\_share.%';
  UPDATE audit_log SET action = 'event' || substr(action, 12)
    WHERE action LIKE 'transaction.%' OR action LIKE 'transactions.%';
  UPDATE audit_log SET entity = 'stream' || substr(entity, 5)
    WHERE entity = 'pool' OR entity = 'pool_share';
  UPDATE audit_log SET entity = 'event' || substr(entity, 12)
    WHERE entity = 'transaction' OR entity = 'transactions';
  UPDATE audit_log
    SET detail = (detail - 'deletedPoolId')
      || jsonb_build_object('deletedStreamId', detail -> 'deletedPoolId')
    WHERE detail ? 'deletedPoolId';
END $$;
