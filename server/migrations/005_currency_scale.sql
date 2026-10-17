-- Default currency scale: the y-axis unit (in currency units) the timeline
-- opens with. One of 1, 10, 100, 1000, 10000, 100000, 1000000.
ALTER TABLE accounts
  ADD COLUMN IF NOT EXISTS currency_scale INTEGER NOT NULL DEFAULT 100;
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_currency_scale_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_currency_scale_check
  CHECK (currency_scale IN (1, 10, 100, 1000, 10000, 100000, 1000000));
