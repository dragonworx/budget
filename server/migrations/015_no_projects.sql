-- Projects are gone: accounts are top level, owned directly by a user, and
-- shared per account (account_shares). All budget data was test data, so it
-- is wiped once here rather than converted.
--
-- Kept: users (incl. is_admin), sessions, allowed_emails.
-- Wiped: projects, project_members, accounts, transactions, skipped dates,
-- once-off overrides, scenarios, account shares, invites, audit_log.
--
-- Runs once (recorded in schema_migrations). The wipe is additionally
-- guarded on the projects table still existing, so a re-run never wipes.
DO $$
BEGIN
  IF to_regclass('public.projects') IS NOT NULL THEN
    TRUNCATE occurrence_overrides, skipped_occurrences, scenarios,
      transactions, account_shares, invites, audit_log, accounts,
      project_members, projects;
  END IF;
END $$;

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS owner_id UUID
  REFERENCES users (id) ON DELETE CASCADE;
-- Safe: accounts is empty here on an upgraded database, and on a fresh one.
DELETE FROM accounts WHERE owner_id IS NULL;
ALTER TABLE accounts ALTER COLUMN owner_id SET NOT NULL;
ALTER TABLE accounts DROP COLUMN IF EXISTS project_id;
CREATE INDEX IF NOT EXISTS accounts_owner_idx ON accounts (owner_id);
CREATE UNIQUE INDEX IF NOT EXISTS accounts_owner_name_uidx
  ON accounts (owner_id, lower(name));

-- Invites are per account only.
DELETE FROM invites WHERE account_id IS NULL;
ALTER TABLE invites DROP COLUMN IF EXISTS project_id;
ALTER TABLE invites ALTER COLUMN account_id SET NOT NULL;

-- Events are keyed by account.
DROP INDEX IF EXISTS audit_log_project_idx;
ALTER TABLE audit_log DROP COLUMN IF EXISTS project_id;
CREATE INDEX IF NOT EXISTS audit_log_account_idx ON audit_log (account_id, id);

DROP TABLE IF EXISTS project_members;
DROP TABLE IF EXISTS projects;

