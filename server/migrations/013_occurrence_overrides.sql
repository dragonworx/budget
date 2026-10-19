-- Once-off overrides: one occurrence of a series takes a different amount
-- (and direction) than the series. Attached to the series row, so it
-- follows the series (cascade delete, transfers mirror it, seed shifts move
-- it) and is cleared to restore the natural value.
CREATE TABLE IF NOT EXISTS occurrence_overrides (
  transaction_id UUID NOT NULL REFERENCES transactions (id) ON DELETE CASCADE,
  date DATE NOT NULL,
  amount NUMERIC NOT NULL CHECK (amount >= 0),
  direction TEXT NOT NULL CHECK (direction IN ('credit', 'debit')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (transaction_id, date)
);
