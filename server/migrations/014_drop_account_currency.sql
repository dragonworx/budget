-- Accounts no longer have a currency: all money shows a plain "$" symbol.
-- (The currency *scale*, accounts.currency_scale, is a separate setting and
-- stays.) Older clients may still send a currency field; the API ignores it.
ALTER TABLE accounts DROP COLUMN IF EXISTS currency;
