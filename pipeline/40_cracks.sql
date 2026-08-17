-- 40_cracks.sql — weekly price levels and the derived crack spreads.

-- ---------------------------------------------------------------------------
-- Daily spot -> weekly mean, then one column per leg.
--
-- Left-joined onto the calendar so a week with no observations exists as a row
-- of nulls rather than vanishing; the crack below then falls out as null on its
-- own, with no special case.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.legs_weekly AS
WITH weekly AS (
  SELECT date_trunc('week', obs_date)::DATE AS week_start,
         series_id,
         AVG(value) AS value
  FROM stg.spot_daily
  GROUP BY 1, 2
)
SELECT
  c.week_start,
  MAX(w.value) FILTER (WHERE w.series_id = 'EER_EPD2DXL0_PF4_Y35NY_DPG') AS ulsd_usd_per_gal,
  MAX(w.value) FILTER (WHERE w.series_id = 'RBRTE')                      AS brent_usd_per_bbl,
  MAX(w.value) FILTER (WHERE w.series_id = 'RWTC')                       AS wti_usd_per_bbl
FROM stg.week_calendar c
LEFT JOIN weekly w USING (week_start)
GROUP BY 1;

-- ---------------------------------------------------------------------------
-- ICE gasoil — the documented gap.
--
-- ICE licenses its settlement data and there is no free API, so this leg comes
-- from a file the user maintains. A header-only file yields zero rows, which is
-- a valid state and not an error: the NWE crack is then published as an empty
-- series and the chart says so. See README.
--
-- comment = '#' lets the stub carry its own instructions without them parsing as
-- data. Daily or weekly rows both work — the mean below reduces either.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.gasoil_weekly AS
SELECT date_trunc('week', obs_date)::DATE AS week_start,
       AVG(usd_per_tonne)                 AS usd_per_tonne
FROM read_csv(
       getvariable('manual_dir') || '/ice_gasoil.csv',
       -- auto_detect=false är nödvändigt, inte bara städning: stubben har noll
       -- datarader och bara kommentarer före rubriken, och sniffern kan då inte
       -- gissa dialekten och fäller körningen. Allt den skulle ha gissat står
       -- redan här, så det finns inget att upptäcka.
       header = true, comment = '#', delim = ',', auto_detect = false,
       columns = {'obs_date': 'DATE', 'usd_per_tonne': 'DOUBLE'})
WHERE usd_per_tonne IS NOT NULL
GROUP BY 1;

-- ---------------------------------------------------------------------------
-- Crack spreads, long form.
--
--   42        US gallons per barrel — exact, by definition.
--   7.45      barrels of gasoil per tonne — a conventional density factor, not a
--             definition, which is why the chart states it next to the series.
--
-- Nulls propagate through the arithmetic, so a week missing either leg yields a
-- null spread with no CASE expression. Never interpolated.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.crack_weekly AS
SELECT week_start, 'us_ulsd_brent' AS series_key, 'US' AS region,
       ulsd_usd_per_gal * 42 - brent_usd_per_bbl AS usd_per_bbl
FROM stg.legs_weekly
UNION ALL
SELECT week_start, 'us_ulsd_wti', 'US',
       ulsd_usd_per_gal * 42 - wti_usd_per_bbl
FROM stg.legs_weekly
UNION ALL
SELECT c.week_start, 'nwe_gasoil_brent', 'NWE',
       g.usd_per_tonne / 7.45 - l.brent_usd_per_bbl
FROM stg.week_calendar c
JOIN stg.legs_weekly l USING (week_start)
-- Inner join: with an empty manual file this side contributes no rows at all,
-- which is exactly how the export distinguishes "no ICE data supplied" from
-- "supplied but sparse".
JOIN stg.gasoil_weekly g USING (week_start);
