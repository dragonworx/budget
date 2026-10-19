-- P1 tenancy: every project is owned by a user. Existing projects go to the
-- primary admin (budget.admin_email, set by applyMigrations from ADMIN_EMAILS).
INSERT INTO users (id, email, is_admin)
VALUES (gen_random_uuid(), lower(current_setting('budget.admin_email')), true)
ON CONFLICT (email) DO UPDATE SET is_admin = true;

ALTER TABLE projects ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users (id) ON DELETE CASCADE;

UPDATE projects SET owner_id = (
  SELECT id FROM users WHERE email = lower(current_setting('budget.admin_email'))
) WHERE owner_id IS NULL;

ALTER TABLE projects ALTER COLUMN owner_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS projects_owner_idx ON projects (owner_id);

-- Project names are unique per owner, no longer site-wide.
DROP INDEX IF EXISTS projects_name_lower_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS projects_owner_name_uidx ON projects (owner_id, lower(name));

-- Audit fields.
ALTER TABLE projects ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE scenarios ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE scenarios ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users (id) ON DELETE SET NULL;
ALTER TABLE scenarios ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

UPDATE projects SET created_by = owner_id WHERE created_by IS NULL;
UPDATE accounts a SET created_by = p.owner_id FROM projects p WHERE p.id = a.project_id AND a.created_by IS NULL;
UPDATE transactions t SET created_by = p.owner_id FROM accounts a JOIN projects p ON p.id = a.project_id WHERE a.id = t.account_id AND t.created_by IS NULL;
UPDATE scenarios s SET created_by = p.owner_id FROM accounts a JOIN projects p ON p.id = a.project_id WHERE a.id = s.account_id AND s.created_by IS NULL;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS version INT NOT NULL DEFAULT 1;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS version INT NOT NULL DEFAULT 1;
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS version INT NOT NULL DEFAULT 1;
ALTER TABLE scenarios ADD COLUMN IF NOT EXISTS version INT NOT NULL DEFAULT 1;
