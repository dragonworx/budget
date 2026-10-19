-- P3 tenancy: project membership, account-level shares, invites, and
-- automatic version/updated_at bumps for optimistic concurrency.
DO $$ BEGIN
  CREATE TYPE member_role AS ENUM ('viewer', 'editor', 'owner');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS project_members (
  project_id UUID NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  role member_role NOT NULL,
  added_by UUID REFERENCES users (id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, user_id)
);
CREATE INDEX IF NOT EXISTS project_members_user_idx ON project_members (user_id);

-- Owners are members too (uniform joins); exactly one owner row per project.
INSERT INTO project_members (project_id, user_id, role, added_by)
SELECT id, owner_id, 'owner', owner_id FROM projects
ON CONFLICT (project_id, user_id) DO UPDATE SET role = 'owner';
CREATE UNIQUE INDEX IF NOT EXISTS project_members_one_owner_uidx
  ON project_members (project_id) WHERE role = 'owner';

CREATE TABLE IF NOT EXISTS account_shares (
  account_id UUID NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  role member_role NOT NULL CHECK (role <> 'owner'),
  added_by UUID REFERENCES users (id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, user_id)
);
CREATE INDEX IF NOT EXISTS account_shares_user_idx ON account_shares (user_id);

CREATE TABLE IF NOT EXISTS invites (
  id UUID PRIMARY KEY,
  token_hash BYTEA NOT NULL UNIQUE,
  email TEXT NOT NULL CHECK (email = lower(email)),
  project_id UUID REFERENCES projects (id) ON DELETE CASCADE,
  account_id UUID REFERENCES accounts (id) ON DELETE CASCADE,
  role member_role NOT NULL CHECK (role <> 'owner'),
  invited_by UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  accepted_at TIMESTAMPTZ,
  accepted_by UUID REFERENCES users (id) ON DELETE SET NULL,
  revoked_at TIMESTAMPTZ,
  CHECK ((project_id IS NULL) <> (account_id IS NULL))
);
CREATE INDEX IF NOT EXISTS invites_pending_email_idx ON invites (email)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- Optimistic concurrency: any real change bumps version and updated_at.
-- Changes to only the audit columns (updated_by/created_by) do not.
CREATE OR REPLACE FUNCTION budget_bump_version() RETURNS trigger AS $$
BEGIN
  IF (to_jsonb(NEW) - 'version' - 'updated_at' - 'updated_by' - 'created_by')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'version' - 'updated_at' - 'updated_by' - 'created_by') THEN
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS projects_bump_version ON projects;
CREATE TRIGGER projects_bump_version BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION budget_bump_version();
DROP TRIGGER IF EXISTS accounts_bump_version ON accounts;
CREATE TRIGGER accounts_bump_version BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION budget_bump_version();
DROP TRIGGER IF EXISTS transactions_bump_version ON transactions;
CREATE TRIGGER transactions_bump_version BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION budget_bump_version();
DROP TRIGGER IF EXISTS scenarios_bump_version ON scenarios;
CREATE TRIGGER scenarios_bump_version BEFORE UPDATE ON scenarios
  FOR EACH ROW EXECUTE FUNCTION budget_bump_version();

-- Audit columns are informational: no FKs (they conflicted with cascading
-- deletes when a user's projects are removed).
ALTER TABLE projects DROP CONSTRAINT IF EXISTS projects_created_by_fkey;
ALTER TABLE projects DROP CONSTRAINT IF EXISTS projects_updated_by_fkey;
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_created_by_fkey;
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_updated_by_fkey;
ALTER TABLE transactions DROP CONSTRAINT IF EXISTS transactions_created_by_fkey;
ALTER TABLE transactions DROP CONSTRAINT IF EXISTS transactions_updated_by_fkey;
ALTER TABLE scenarios DROP CONSTRAINT IF EXISTS scenarios_created_by_fkey;
ALTER TABLE scenarios DROP CONSTRAINT IF EXISTS scenarios_updated_by_fkey;
