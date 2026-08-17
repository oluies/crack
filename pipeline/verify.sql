-- verify.sql — invariants over the built staging tables.
--
-- These are the real test. They target the failures that produce a plausible
-- but wrong chart — a missing x42 on the crack, an exchange rate applied to
-- prices that are already in EUR — because those do not announce themselves.
--
-- Each check raises with a message naming what broke. .bail on (set by run.sh)
-- stops at the first failure, so the message you see is the one that matters.

-- 1. The week axis is contiguous Mondays. A hole here silently misaligns every
--    positional values[] array in the published JSON against every other.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 1: week_calendar has {} non-7-day gaps, first after {}',
                    count(*), min(prev)))
END AS "1 week calendar contiguous"
FROM (
  SELECT week_start, lag(week_start) OVER (ORDER BY week_start) AS prev
  FROM stg.week_calendar
) WHERE prev IS NOT NULL AND week_start - prev <> 7;

-- 2. One row per key in the PRE-aggregation tables.
--
--    Two things have to line up here, and both were wrong at some point: the
--    check runs against the RAW table (asserting uniqueness on a table whose own
--    GROUP BY produces the key is tautological), AND it groups by the key that
--    table is later aggregated on. Checking (obs_date, series_id) passes happily
--    while two publications in the same week — different dates, same week — get
--    silently averaged by the downstream GROUP BY.
--    2a is the exception: spot_daily is genuinely daily and its weekly mean in
--    40_cracks.sql is deliberate, so the daily key is the right one there.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2a: {} (date, series) group(s) have duplicate EIA spot rows', count(*)))
END AS "2a EIA spot rows unique"
FROM (SELECT 1 FROM stg.spot_daily GROUP BY obs_date, series_id HAVING count(*) > 1);

-- Namngivna vyer så att felmeddelandet kan peka ut vilka grupper som brast;
-- ett antal utan nycklar ger operatören ingenting att titta på.
CREATE OR REPLACE TEMP VIEW dup2b AS
SELECT date_trunc('week', obs_date)::DATE || '/' || cc || '/' || fuel || '/' || tax AS k
FROM stg.ob_parsed
GROUP BY date_trunc('week', obs_date), cc, fuel, tax HAVING count(*) > 1;

CREATE OR REPLACE TEMP VIEW dup2c AS
SELECT date_trunc('week', obs_date)::DATE || '/' || fuel AS k
FROM stg.retail_us_raw
GROUP BY date_trunc('week', obs_date), fuel HAVING count(*) > 1;

SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2b: {} (week, cc, fuel, tax) group(s) have more than one '
                    'Oil Bulletin observation; first: {}',
                    count(*), (SELECT string_agg(k, ', ') FROM (SELECT k FROM dup2b LIMIT 5))))
END AS "2b Oil Bulletin one row per week"
FROM dup2b;

SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2c: {} (week, fuel) group(s) have more than one EIA retail '
                    'publication; first: {}',
                    count(*), (SELECT string_agg(k, ', ') FROM (SELECT k FROM dup2c LIMIT 5))))
END AS "2c EIA retail one row per week"
FROM dup2c;

-- 3. All 27 members present in the most recent week that has any EU data.
--    Catches a country quietly dropping out of the workbook.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 3: {} EU-27 members missing from the latest with-tax diesel week: {}',
                    count(*), string_agg(cc, ', ' ORDER BY cc)))
END AS "3 all EU-27 present"
FROM (
  SELECT e.cc FROM stg.eu27 e
  WHERE e.cc NOT IN (
    SELECT cc FROM stg.retail_eu_weekly
    WHERE fuel = 'diesel' AND tax = 'with'
      AND week_start = (SELECT max(week_start) FROM stg.retail_eu_weekly
                        WHERE fuel = 'diesel' AND tax = 'with')
  )
);

-- 4. Swedish with-tax diesel stays in a plausible EUR/L band.
--    The Oil Bulletin's {CC}_exchange_rate columns are EUR-per-national-unit and
--    the prices are ALREADY in EUR. Anyone who "fixes" that by multiplying will
--    land Sweden near 0.15 or 18 EUR/L and trip this.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 4: {} Swedish with-tax diesel weeks outside 1.0-3.0 EUR/L '
                    '(min {}, max {}) - an exchange rate was probably applied twice',
                    count(*), round(min(eur_per_l), 3), round(max(eur_per_l), 3)))
END AS "4 SE diesel in plausible EUR/L range"
FROM stg.retail_eu_weekly
WHERE cc = 'SE' AND fuel = 'diesel' AND tax = 'with'
  AND (eur_per_l < 1.0 OR eur_per_l > 3.0);

-- 5. US crack spreads inside a band wide enough for the 2022 diesel spike but
--    tight enough to catch a dropped x42 (which would put them near -80).
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 5: {} US crack weeks outside -20..120 USD/bbl (min {}, max {}) '
                    '- check the 42 gal/bbl factor',
                    count(*), round(min(usd_per_bbl), 2), round(max(usd_per_bbl), 2)))
END AS "5 US crack in plausible range"
FROM stg.crack_weekly
WHERE region = 'US' AND usd_per_bbl IS NOT NULL
  AND (usd_per_bbl < -20 OR usd_per_bbl > 120);

-- 6. FX covers every calendar week for both currencies. A hole would silently
--    drop series from the chart the moment a visitor switches currency.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 6: {} (week, currency) FX combinations missing', count(*)))
END AS "6 FX covers every week"
FROM (
  SELECT w.week_start, c.ccy
  FROM stg.week_calendar w
  CROSS JOIN (VALUES ('USD'), ('SEK')) AS c(ccy)
  LEFT JOIN stg.fx_weekly f ON f.week_start = w.week_start AND f.ccy = c.ccy
  WHERE f.per_eur IS NULL
);

-- 7. No long trailing run of empty weeks. The calendar ends at the last complete
--    week, but if a source has stalled we would publish a flat blank tail and
--    call it data. Two weeks of slack absorbs normal publication lag.
--
--    Check 7 (crack) is gated on strict: under --fixtures the EIA half is a
--    frozen synthetic snapshot while week_calendar tracks current_date, so it
--    would start failing every CI run weeks after the fixtures were generated.
--    Check 7b (EU retail) is NOT gated — the Oil Bulletin is fetched live in
--    every mode, so a workbook that still parses but has stopped being updated
--    must fail CI rather than sail through it.
SELECT CASE WHEN coalesce((SELECT strict FROM stg.build_meta), true) AND (SELECT max(week_start) FROM stg.week_calendar)
                 - coalesce((SELECT max(week_start) FROM stg.crack_weekly
                             WHERE usd_per_bbl IS NOT NULL), DATE '1900-01-01') > 14
  THEN error(format('verify 7: crack data stale - calendar ends {}, last observation {}',
                    (SELECT max(week_start) FROM stg.week_calendar),
                    (SELECT max(week_start) FROM stg.crack_weekly WHERE usd_per_bbl IS NOT NULL)))
END AS "7 crack data fresh"
;

SELECT CASE WHEN (SELECT max(week_start) FROM stg.week_calendar)
                 - coalesce((SELECT max(week_start) FROM stg.retail_eu_weekly), DATE '1900-01-01') > 14
  THEN error(format('verify 7b: EU retail data stale - calendar ends {}, last observation {}',
                    (SELECT max(week_start) FROM stg.week_calendar),
                    (SELECT max(week_start) FROM stg.retail_eu_weekly)))
END AS "7b EU retail data fresh"
;

SELECT 'alla invarianter gröna' AS verify;
