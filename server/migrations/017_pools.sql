-- "Accounts" are now "pools" everywhere (UI, API, code, schema). A pure
-- rename: no data is lost. Runs once (schema_migrations) and is guarded on
-- the old table still existing, so a re-run is a no-op.
DO $$
BEGIN
  IF to_regclass('public.accounts') IS NOT NULL THEN
    ALTER TABLE accounts RENAME TO pools;
    ALTER TABLE account_shares RENAME TO pool_shares;
    ALTER TABLE pool_shares RENAME COLUMN account_id TO pool_id;
    ALTER TABLE transactions RENAME COLUMN account_id TO pool_id;
    ALTER TABLE scenarios RENAME COLUMN account_id TO pool_id;
    ALTER TABLE invites RENAME COLUMN account_id TO pool_id;
    ALTER TABLE audit_log RENAME COLUMN account_id TO pool_id;
    ALTER TABLE users RENAME COLUMN last_account_id TO last_pool_id;

    ALTER INDEX IF EXISTS accounts_pkey RENAME TO pools_pkey;
    ALTER INDEX IF EXISTS accounts_owner_idx RENAME TO pools_owner_idx;
    ALTER INDEX IF EXISTS accounts_owner_name_uidx RENAME TO pools_owner_name_uidx;
    ALTER INDEX IF EXISTS account_shares_pkey RENAME TO pool_shares_pkey;
    ALTER INDEX IF EXISTS account_shares_user_idx RENAME TO pool_shares_user_idx;
    ALTER INDEX IF EXISTS transactions_account_id_idx RENAME TO transactions_pool_id_idx;
    ALTER INDEX IF EXISTS scenarios_account_idx RENAME TO scenarios_pool_idx;
    ALTER INDEX IF EXISTS audit_log_account_idx RENAME TO audit_log_pool_idx;
    ALTER TRIGGER accounts_bump_version ON pools RENAME TO pools_bump_version;

    -- Stored event names (realtime resume) follow the new names.
    UPDATE audit_log SET action = 'pool' || substr(action, 8)
      WHERE action LIKE 'account%';
    UPDATE audit_log SET entity = 'pool' || substr(entity, 8)
      WHERE entity LIKE 'account%';
  END IF;
END $$;
