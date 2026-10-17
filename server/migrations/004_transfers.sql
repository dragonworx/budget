-- Transfers: two linked transaction rows (source debit / destination credit
-- or vice-versa) share one transfer_id. Exactly two rows per transfer_id.
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS transfer_id UUID;
CREATE INDEX IF NOT EXISTS transactions_transfer_id_idx ON transactions (transfer_id);
