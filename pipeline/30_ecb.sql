-- 30_ecb.sql — ECB daily reference rates -> one rate per ISO week.
--
-- run.sh downloads ecb_USD.csv and ecb_SEK.csv from the SDMX service, starting
-- two weeks before start_week so the first published week already has a rate
-- behind it. The CSV carries 32 SDMX columns; three matter.
--
-- Values are units of the named currency per 1 EUR (USD 1.1593, SEK 11.001 on
-- 2026-08-17), matching ECB's own orientation and the JSON contract's.

CREATE OR REPLACE TABLE stg.fx_weekly AS
WITH rates AS (
  SELECT
    TIME_PERIOD::DATE      AS obs_date,
    CURRENCY::VARCHAR      AS ccy,
    OBS_VALUE::DOUBLE      AS per_eur
  FROM read_csv(getvariable('work_dir') || '/ecb_*.csv', union_by_name = true)
  WHERE TRY_CAST(OBS_VALUE AS DOUBLE) IS NOT NULL
),
grid AS (
  SELECT w.week_start, c.ccy
  FROM stg.week_calendar w
  CROSS JOIN (SELECT DISTINCT ccy FROM rates) c
)
-- ASOF: take the most recent rate on or before the week's Monday. ECB publishes
-- business days only, so a TARGET holiday leaves that Monday without its own
-- observation. Carrying the previous rate forward is correct here and only here:
-- an exchange rate is a level that persists until it is restated, unlike a price
-- observation that was simply never taken.
SELECT g.week_start, g.ccy, r.per_eur
FROM grid g
ASOF JOIN rates r
  ON g.ccy = r.ccy AND g.week_start >= r.obs_date;
