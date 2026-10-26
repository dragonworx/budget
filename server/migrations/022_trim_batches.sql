-- "End every event on this day" (the timeline's day pick ✂): one batch
-- trims / deletes many rows atomically; its Undo restores them all from the
-- snapshot written here by the server (the rows, their skips, overrides and
-- the affected streams' event order, before the trim). Kept a day, then
-- purged by the cleanup job. Additive and idempotent.
CREATE TABLE IF NOT EXISTS event_trim_batches (
  id         UUID PRIMARY KEY,
  stream_id  UUID NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day        DATE NOT NULL,
  snapshot   JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  undone_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS event_trim_batches_stream_idx
  ON event_trim_batches (stream_id);
CREATE INDEX IF NOT EXISTS event_trim_batches_created_idx
  ON event_trim_batches (created_at);
