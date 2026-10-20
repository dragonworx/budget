-- Landing: the account each user opened last (cleared if it is deleted).
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_account_id UUID
  REFERENCES accounts (id) ON DELETE SET NULL;
