-- Structured frequency: a rule (once, daily, weekly, every_n_weeks,
-- monthly, every_n_months), its interval N and an optional list of days
-- (weekdays 1 = Mon … 7 = Sun for the week rules, month days 1-31 for the
-- month rules). Additive only: the legacy recurrence_mode / interval /
-- unit columns stay and the server keeps them in step, so an older server
-- still reads every row (days aside) during a rollout.

ALTER TABLE events
  ADD COLUMN IF NOT EXISTS freq_rule TEXT,
  ADD COLUMN IF NOT EXISTS freq_interval INT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS freq_days SMALLINT[] NOT NULL DEFAULT '{}';

-- Legacy cadence to rule, losslessly: weeks/months keep N (N = 1 is the
-- plain weekly / monthly rule), years N become every 12N months (the
-- engine already stepped years as 12 months, rolled from the start day).
CREATE OR REPLACE FUNCTION events_legacy_freq_rule(mode TEXT, n INT, u TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN mode = 'once' THEN 'once'
    WHEN u = 'days' THEN 'daily'
    WHEN u = 'weeks' AND n = 1 THEN 'weekly'
    WHEN u = 'weeks' THEN 'every_n_weeks'
    WHEN u = 'months' AND n = 1 THEN 'monthly'
    WHEN u IN ('months', 'years') THEN 'every_n_months'
  END
$$;

CREATE OR REPLACE FUNCTION events_legacy_freq_interval(mode TEXT, n INT, u TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN mode = 'once' THEN 1
    WHEN u = 'years' THEN n * 12
    ELSE n
  END
$$;

-- (The backfill is not an edit: it must not bump the optimistic
-- concurrency version, or every open editor would get a 409.)
ALTER TABLE events DISABLE TRIGGER events_bump_version;

UPDATE events SET
  freq_rule = events_legacy_freq_rule(recurrence_mode, interval, unit),
  freq_interval = events_legacy_freq_interval(recurrence_mode, interval, unit),
  freq_days = '{}'
WHERE freq_rule IS NULL;

ALTER TABLE events ENABLE TRIGGER events_bump_version;

-- A writer that only knows the legacy columns (the previous server during
-- a deploy) still leaves a consistent rule: an insert without freq_rule,
-- or an update that changes the legacy cadence but not the rule, derives
-- the rule from the legacy columns (its days kept while the family
-- stays week or month).
CREATE OR REPLACE FUNCTION events_freq_from_legacy() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.freq_rule IS NULL THEN
      NEW.freq_rule := events_legacy_freq_rule(NEW.recurrence_mode, NEW.interval, NEW.unit);
      NEW.freq_interval := events_legacy_freq_interval(NEW.recurrence_mode, NEW.interval, NEW.unit);
      NEW.freq_days := '{}';
    END IF;
  ELSIF NEW.freq_rule IS NOT DISTINCT FROM OLD.freq_rule
    AND NEW.freq_interval IS NOT DISTINCT FROM OLD.freq_interval
    AND NEW.freq_days IS NOT DISTINCT FROM OLD.freq_days
    AND (NEW.recurrence_mode, NEW.interval, NEW.unit)
        IS DISTINCT FROM (OLD.recurrence_mode, OLD.interval, OLD.unit) THEN
    NEW.freq_rule := events_legacy_freq_rule(NEW.recurrence_mode, NEW.interval, NEW.unit);
    NEW.freq_interval := events_legacy_freq_interval(NEW.recurrence_mode, NEW.interval, NEW.unit);
    -- Days survive a change of N within the week or month family only.
    IF NEW.freq_rule IN ('once', 'daily')
      OR (NEW.freq_rule IN ('weekly', 'every_n_weeks'))
         IS DISTINCT FROM (OLD.freq_rule IN ('weekly', 'every_n_weeks')) THEN
      NEW.freq_days := '{}';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS events_freq_from_legacy ON events;
CREATE TRIGGER events_freq_from_legacy
  BEFORE INSERT OR UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION events_freq_from_legacy();

ALTER TABLE events ALTER COLUMN freq_rule SET NOT NULL;

ALTER TABLE events ADD CONSTRAINT events_freq_rule_check CHECK (
  freq_rule IN ('once', 'daily', 'weekly', 'every_n_weeks', 'monthly', 'every_n_months')
);

ALTER TABLE events ADD CONSTRAINT events_freq_interval_check CHECK (
  CASE
    WHEN freq_rule IN ('once', 'weekly', 'monthly') THEN freq_interval = 1
    WHEN freq_rule IN ('every_n_weeks', 'every_n_months') THEN freq_interval >= 2
    ELSE freq_interval >= 1
  END
);

-- Days: none for once / daily, 1-7 for the week rules, 1-31 for the month
-- rules (the server stores them sorted and without duplicates).
ALTER TABLE events ADD CONSTRAINT events_freq_days_check CHECK (
  array_position(freq_days, NULL) IS NULL
  AND CASE
    WHEN freq_rule IN ('once', 'daily') THEN cardinality(freq_days) = 0
    WHEN freq_rule IN ('weekly', 'every_n_weeks') THEN 1 <= ALL (freq_days) AND 7 >= ALL (freq_days)
    ELSE 1 <= ALL (freq_days) AND 31 >= ALL (freq_days)
  END
);
