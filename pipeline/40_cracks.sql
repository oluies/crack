-- 40_cracks.sql — weekly price levels and the derived crack spreads.

-- ---------------------------------------------------------------------------
-- Daily spot -> weekly mean, then one column per leg.
--
-- Left-joined onto the calendar so a week with no observations exists as a row
-- of nulls rather than vanishing; the crack below then falls out as null on its
-- own, with no special case.
-- ---------------------------------------------------------------------------
-- Täckningen bärs med, den härleds inte bort. En kontroll som läser samma
-- GROUP BY som producerade raden kan inte fälla — det misstaget har den här
-- pipelinen redan gjort tre gånger — så verify.sql räknar om täckningen ur
-- stg.spot_daily och jämför mot den här tabellen i stället.
CREATE OR REPLACE TABLE stg.legs_weekly_cov AS
SELECT date_trunc('week', obs_date)::DATE AS week_start,
       series_id,
       AVG(value)   AS value,
       count(value) AS n_obs
FROM stg.spot_daily
GROUP BY 1, 2;

-- ---------------------------------------------------------------------------
-- Ofullständiga veckor publiceras inte.
--
-- EIA ligger ~8 dagar efter, så den sista kalenderveckan innehåller ofta bara
-- en eller två handelsdagar. Ett medelvärde över dem såg på diagrammet exakt ut
-- som ett medelvärde över fem, och veckan 2026-08-10 publicerades som 86,28 —
-- (84,16 + 88,39) / 2 — mitt under en brant uppgång. Läsaren jämförde med
-- marknaden och hade rätt att undra.
--
-- Tre är golvet, inte fem: en helgstängd handelsvecka har fyra dagar och ska
-- inte försvinna varje påsk. Under golvet blir benet NULL och spreaden faller
-- ut som NULL av sig själv — ingen CASE, ingen specialfall.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.legs_weekly AS
WITH weekly AS (
  SELECT week_start, series_id, value
  FROM stg.legs_weekly_cov
  WHERE n_obs >= getvariable('min_week_obs')
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
CREATE OR REPLACE TABLE stg.gasoil_daily AS
SELECT obs_date, usd_per_tonne
FROM read_csv(
       getvariable('manual_dir') || '/ice_gasoil.csv',
       -- auto_detect=false är nödvändigt, inte bara städning: stubben har noll
       -- datarader och bara kommentarer före rubriken, och sniffern kan då inte
       -- gissa dialekten och fäller körningen. Allt den skulle ha gissat står
       -- redan här, så det finns inget att upptäcka.
       header = true, comment = '#', delim = ',', auto_detect = false,
       columns = {'obs_date': 'DATE', 'usd_per_tonne': 'DOUBLE'})
WHERE usd_per_tonne IS NOT NULL;

-- Veckan reduceras ur dagsserien i stället för ur filen igen: dag- och
-- veckodiagrammet ska aldrig kunna läsa olika rader ur samma stub.
CREATE OR REPLACE TABLE stg.gasoil_weekly AS
SELECT date_trunc('week', obs_date)::DATE AS week_start,
       AVG(usd_per_tonne)                 AS usd_per_tonne
FROM stg.gasoil_daily
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

-- ---------------------------------------------------------------------------
-- Dagsupplösning.
--
-- Veckomedelvärdet är ett utjämningsval, och vid fyra dollars dagsrörelse döljer
-- det mer än det klarnar. Här ligger varje observation EIA publicerat, utan
-- mellanhand mellan läsaren och källan.
--
-- Axeln är observationsdatum, inte en kalender: en helg är inte data som saknas
-- och ska inte ritas som ett hål. Därför byggs day_axis ur de datum som faktiskt
-- förekommer, medan veckoserien tvärtom vilar på en tät kalender där ett hål
-- ÄR ett hål. De två axlarna är alltså inte positionellt jämförbara, och
-- kontraktet säger det uttryckligen.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.day_axis AS
SELECT DISTINCT obs_date
FROM (
  SELECT obs_date FROM stg.spot_daily
  UNION
  SELECT obs_date FROM stg.gasoil_daily
)
WHERE obs_date >= getvariable('start_week')::DATE;

CREATE OR REPLACE TABLE stg.legs_daily AS
SELECT
  a.obs_date,
  MAX(s.value) FILTER (WHERE s.series_id = 'EER_EPD2DXL0_PF4_Y35NY_DPG') AS ulsd_usd_per_gal,
  MAX(s.value) FILTER (WHERE s.series_id = 'RBRTE')                      AS brent_usd_per_bbl,
  MAX(s.value) FILTER (WHERE s.series_id = 'RWTC')                       AS wti_usd_per_bbl,
  MAX(g.usd_per_tonne)                                                   AS gasoil_usd_per_tonne
FROM stg.day_axis a
LEFT JOIN stg.spot_daily   s USING (obs_date)
LEFT JOIN stg.gasoil_daily g USING (obs_date)
GROUP BY 1;

-- Samma formler som veckoserien, samma nollpropagering. Inner join mot gasoil
-- finns inte här: legs_daily är redan vänsterjoinad, så en tom stub ger en
-- kolumn av NULL, och exporten skiljer "tom" från "saknas" på antalet
-- icke-null-värden i stället.
CREATE OR REPLACE TABLE stg.crack_daily AS
SELECT obs_date, 'us_ulsd_brent' AS series_key,
       ulsd_usd_per_gal * 42 - brent_usd_per_bbl AS usd_per_bbl
FROM stg.legs_daily
UNION ALL
SELECT obs_date, 'us_ulsd_wti',
       ulsd_usd_per_gal * 42 - wti_usd_per_bbl
FROM stg.legs_daily
UNION ALL
SELECT obs_date, 'nwe_gasoil_brent',
       gasoil_usd_per_tonne / 7.45 - brent_usd_per_bbl
FROM stg.legs_daily;

-- ---------------------------------------------------------------------------
-- 7-dagarslinjalen.
--
-- Fönstret är sju KALENDERdagar (RANGE), inte sju observationer (ROWS). I
-- normalläge rymmer det fem handelsdagar — precis en handelsvecka — och över en
-- helgdag krymper det ärligt i stället för att tyst sträcka sig nio
-- kalenderdagar bakåt, vilket ett observationsfönster hade gjort utan att säga
-- det. Läsaren ser "7-day" och får sju dagar.
--
-- Samma golv som veckoserien: färre än tre observationer i fönstret ger inget
-- värde. Det tar bort seriens första dagar, där ett "medelvärde" av en enda
-- observation bara hade upprepat dagslinjen med tjockare penna.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.crack_daily_ma AS
SELECT
  obs_date,
  series_key,
  CASE WHEN count(usd_per_bbl) OVER w >= getvariable('min_week_obs')
       THEN AVG(usd_per_bbl) OVER w END AS usd_per_bbl
FROM stg.crack_daily
WINDOW w AS (
  PARTITION BY series_key
  ORDER BY obs_date
  RANGE BETWEEN INTERVAL 6 DAY PRECEDING AND CURRENT ROW
);
