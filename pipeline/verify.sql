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
--    These must target the raw rows, not the weekly tables: asserting
--    uniqueness on a table whose own GROUP BY produces the key is tautological
--    and reports green on precisely the upstream double-publication it claims
--    to catch. The earlier version of this file made that mistake.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2a: EIA spot has {} duplicate (date, series) rows upstream', count(*)))
END AS "2a EIA spot rows unique"
FROM (SELECT 1 FROM stg.spot_daily GROUP BY obs_date, series_id HAVING count(*) > 1);

SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2b: Oil Bulletin has {} duplicate (date, cc, fuel, tax) rows upstream', count(*)))
END AS "2b Oil Bulletin rows unique"
FROM (SELECT 1 FROM stg.ob_parsed GROUP BY obs_date, cc, fuel, tax HAVING count(*) > 1);

SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2c: EIA retail has {} duplicate (date, series) rows upstream', count(*)))
END AS "2c EIA retail rows unique"
FROM (SELECT 1 FROM stg.retail_us_raw GROUP BY obs_date, series_id HAVING count(*) > 1);

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

-- 7. No long trailing run of empty weeks. Live data only.
--
--    The fixtures are a frozen snapshot while week_calendar tracks current_date,
--    so this check would start failing every CI run some weeks after the
--    fixtures were generated — blocking every pull request with a failure that
--    has nothing to do with the change under test. run.sh sets strict=false in
--    fixtures mode for exactly this reason.
-- 7. No long trailing run of empty weeks. The calendar ends at the last complete
--    week, but if a source has stalled we would publish a flat blank tail and
--    call it data. Two weeks of slack absorbs normal publication lag.
SELECT CASE WHEN getvariable('strict') AND (SELECT max(week_start) FROM stg.week_calendar)
                 - coalesce((SELECT max(week_start) FROM stg.crack_weekly
                             WHERE usd_per_bbl IS NOT NULL), DATE '1900-01-01') > 14
  THEN error(format('verify 7: crack data stale - calendar ends {}, last observation {}',
                    (SELECT max(week_start) FROM stg.week_calendar),
                    (SELECT max(week_start) FROM stg.crack_weekly WHERE usd_per_bbl IS NOT NULL)))
END AS "7 crack data fresh"
;

SELECT CASE WHEN getvariable('strict') AND (SELECT max(week_start) FROM stg.week_calendar)
                 - coalesce((SELECT max(week_start) FROM stg.retail_eu_weekly), DATE '1900-01-01') > 14
  THEN error(format('verify 7b: EU retail data stale - calendar ends {}, last observation {}',
                    (SELECT max(week_start) FROM stg.week_calendar),
                    (SELECT max(week_start) FROM stg.retail_eu_weekly)))
END AS "7b EU retail data fresh"
;

SELECT 'alla invarianter gröna' AS verify;
