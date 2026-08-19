-- 25_calendar.sql — the shared week axis.
--
-- Lives here rather than in 00_schema.sql because its upper bound depends on what
-- the sources actually published, and they are not parsed until 10/15/20. Runs
-- before 30_ecb.sql, which is the first script to join against it.
--
-- ---------------------------------------------------------------------------
-- Why the bound is not simply "the last complete week"
--
-- It was, and that was right for one kind of source and wrong for the other.
--
--   Daily-sampled (EIA spot): a week is a mean of its trading days, so an
--   unfinished week is a partial mean. Publishing it read a two-day average as
--   a dip. That is handled where it belongs — min_week_obs in 40_cracks.sql —
--   and not by truncating the axis.
--
--   Weekly point-in-time (EU Oil Bulletin, EIA pri/gnd): the survey IS the week.
--   One observation is not a partial anything. Excluding the current week threw
--   away a published price for up to seven days: on 2026-08-19 the Bulletin and
--   EIA had both published the week of 08-17, and the site was still showing
--   08-10 because the axis stopped at the last complete week.
--
-- So the axis ends at the later of (a) the last complete week and (b) the most
-- recent week a weekly survey has actually published, capped at the current week
-- so a bad upstream date cannot push the axis into the future. Keeping (a) as a
-- floor matters: if a survey stalls, the axis still advances and the staleness
-- checks (verify 7, 7b) see the growing gap instead of an axis that quietly
-- shrinks to match the stalled source.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.week_calendar AS
WITH surveyed AS (
  -- Bara veckovisa punktmätningar. Spot hör inte hit: dess vecka är ett
  -- medelvärde och får inte kunna dra ut axeln till en halv vecka.
  SELECT max(week_start) AS wk FROM (
    SELECT week_start FROM stg.retail_eu_weekly
    UNION ALL SELECT week_start FROM stg.retail_us_weekly
    UNION ALL SELECT week_start FROM stg.region_weekly
  )
),
bounds AS (
  SELECT
    getvariable('start_week')::DATE AS lo,
    greatest(
      (date_trunc('week', current_date) - INTERVAL 7 DAY)::DATE,
      least(
        coalesce((SELECT wk FROM surveyed), DATE '1900-01-01'),
        date_trunc('week', current_date)::DATE
      )
    ) AS hi
)
SELECT UNNEST(generate_series(lo, hi, INTERVAL 7 DAY))::DATE AS week_start
FROM bounds;
