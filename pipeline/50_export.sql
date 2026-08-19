-- 50_export.sql — staging -> the three published JSON files.
--
-- Contract: specs/001-crack-and-retail-fuel-site/contracts/chart-json.md.
-- Wide form: one `weeks` axis shared by every series in a file, each series a
-- positionally aligned `values` array. Nulls are preserved in place, which is why
-- every series is built by left-joining the full week calendar rather than by
-- aggregating whatever rows happen to exist.
--
-- Rounding happens here, not in the browser: it keeps the files small and makes
-- the displayed number identical for every visitor.
--
-- The COPY targets below are string LITERALS because DuckDB's parser accepts
-- nothing else there — not getvariable(), not concatenation. 60_verify_export.sql
-- reads through getvariable('out_dir') instead, so the two agree only because
-- run.sh cd's to the repo root and points out_dir at this same directory. run.sh
-- asserts that before building rather than leaving it to convention.

-- ---------------------------------------------------------------------------
-- cracks.json
-- ---------------------------------------------------------------------------

-- Spreads and the underlying levels in one long table. The levels are published
-- so the dual-axis chart needs no fourth file, and they share the crude
-- provenance block with the spreads that are derived from them.
CREATE OR REPLACE TABLE stg.crack_points AS
SELECT series_key, week_start, usd_per_bbl AS value FROM stg.crack_weekly
UNION ALL SELECT 'brent', week_start, brent_usd_per_bbl FROM stg.legs_weekly
UNION ALL SELECT 'wti',   week_start, wti_usd_per_bbl   FROM stg.legs_weekly
UNION ALL SELECT 'ulsd',  week_start, ulsd_usd_per_gal  FROM stg.legs_weekly;

-- Declared rather than derived, so nwe_gasoil_brent is emitted even when the
-- manual CSV is empty. The frontend needs "present but empty" (the documented
-- ICE limitation) to be distinguishable from "absent" (a bug).
CREATE OR REPLACE TABLE stg.crack_series_def (
  series_key VARCHAR, label VARCHAR, kind VARCHAR,
  region VARCHAR, unit VARCHAR, ord INTEGER
);
INSERT INTO stg.crack_series_def VALUES
  ('us_ulsd_brent',    'NYH ULSD – Brent',   'spread', 'US',  'USD/bbl', 1),
  ('us_ulsd_wti',      'NYH ULSD – WTI',     'spread', 'US',  'USD/bbl', 2),
  ('nwe_gasoil_brent', 'ICE gasoil – Brent', 'spread', 'NWE', 'USD/bbl', 3),
  ('brent',            'Brent',              'level',  'US',  'USD/bbl', 4),
  ('wti',              'WTI',                'level',  'US',  'USD/bbl', 5),
  ('ulsd',             'NYH ULSD',           'level',  'US',  'USD/gal', 6);

COPY (
  WITH aligned AS (
    SELECT d.*, c.week_start, p.value
    FROM stg.crack_series_def d
    CROSS JOIN stg.week_calendar c
    LEFT JOIN stg.crack_points p
      ON p.series_key = d.series_key AND p.week_start = c.week_start
  ),
  series AS (
    SELECT ord, {
      'key':    any_value(series_key),
      'label':  any_value(label),
      'kind':   any_value(kind),
      'region': any_value(region),
      'unit':   any_value(unit),
      -- An all-null series is published as [] rather than as a column of nulls:
      -- the chart's empty state keys off length, not off content.
      'values': CASE WHEN count(value) = 0 THEN []::DOUBLE[]
                     ELSE list(round(value, 2) ORDER BY week_start) END
    } AS s
    FROM aligned GROUP BY ord
  )
  SELECT
    {
      'generated': getvariable('generated'),
      'synthetic': NOT getvariable('strict')::BOOLEAN,
      'sources': [
        {'name':    'EIA Open Data v2',
         'url':     'https://www.eia.gov/opendata/',
         'licence': 'US Government work, public domain',
         'series':  ['RBRTE', 'RWTC', 'EER_EPD2DXL0_PF4_Y35NY_DPG']},
        {'name':    'ICE Low Sulphur Gasoil (manual)',
         'url':     'https://www.ice.com/products/34361119/Low-Sulphur-Gasoil-Futures',
         'licence': 'Not redistributable; user-supplied via data/manual/ice_gasoil.csv',
         'series':  ['ICE gasoil settlement']}
      ],
      'formulae': {
        'us_ulsd_brent':    'ULSD USD/gal x 42 - Brent USD/bbl',
        'us_ulsd_wti':      'ULSD USD/gal x 42 - WTI USD/bbl',
        'nwe_gasoil_brent': 'ICE gasoil USD/t / 7.45 - Brent USD/bbl'
      }
    } AS meta,
    (SELECT list(week_start ORDER BY week_start) FROM stg.week_calendar) AS weeks,
    (SELECT list(s ORDER BY ord) FROM series)                            AS series
) TO 'site/public/data/cracks.json' (FORMAT json, ARRAY false);

-- ---------------------------------------------------------------------------
-- cracks_daily.json
--
-- Egen fil, och egen axel. `days` är observationsdatum — inte kalenderdagar —
-- och kan därför INTE indexeras mot `weeks` i de andra filerna. Det är hela
-- skälet till att den ligger för sig: en delad axel som bara ibland stämmer är
-- värre än två som aldrig påstår att de gör det.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.crack_daily_points AS
SELECT series_key, obs_date, usd_per_bbl AS value FROM stg.crack_daily
UNION ALL
SELECT series_key || '_ma7', obs_date, usd_per_bbl FROM stg.crack_daily_ma
UNION ALL SELECT 'brent', obs_date, brent_usd_per_bbl FROM stg.legs_daily
UNION ALL SELECT 'wti',   obs_date, wti_usd_per_bbl   FROM stg.legs_daily
UNION ALL SELECT 'ulsd',  obs_date, ulsd_usd_per_gal  FROM stg.legs_daily;

-- Deklarerad, inte härledd — av samma skäl som veckofilen: en serie som saknas
-- ska betyda en bugg, inte en tom källa. 'of' binder linjalen till serien den
-- jämnar ut, så frontend slipper gissa ur namnet.
CREATE OR REPLACE TABLE stg.crack_daily_series_def (
  series_key VARCHAR, label VARCHAR, kind VARCHAR,
  region VARCHAR, unit VARCHAR, of VARCHAR, ord INTEGER
);
INSERT INTO stg.crack_daily_series_def VALUES
  ('us_ulsd_brent',        'NYH ULSD – Brent',   'spread', 'US',  'USD/bbl', NULL,              1),
  ('us_ulsd_wti',          'NYH ULSD – WTI',     'spread', 'US',  'USD/bbl', NULL,              2),
  ('nwe_gasoil_brent',     'ICE gasoil – Brent', 'spread', 'NWE', 'USD/bbl', NULL,              3),
  ('us_ulsd_brent_ma7',    'NYH ULSD – Brent, 7d', 'ma',   'US',  'USD/bbl', 'us_ulsd_brent',   4),
  ('us_ulsd_wti_ma7',      'NYH ULSD – WTI, 7d',   'ma',   'US',  'USD/bbl', 'us_ulsd_wti',     5),
  ('nwe_gasoil_brent_ma7', 'ICE gasoil – Brent, 7d','ma',  'NWE', 'USD/bbl', 'nwe_gasoil_brent',6),
  ('brent',                'Brent',              'level',  'US',  'USD/bbl', NULL,              7),
  ('wti',                  'WTI',                'level',  'US',  'USD/bbl', NULL,              8),
  ('ulsd',                 'NYH ULSD',           'level',  'US',  'USD/gal', NULL,              9);

COPY (
  WITH aligned AS (
    SELECT d.*, a.obs_date, p.value
    FROM stg.crack_daily_series_def d
    CROSS JOIN stg.day_axis a
    LEFT JOIN stg.crack_daily_points p
      ON p.series_key = d.series_key AND p.obs_date = a.obs_date
  ),
  series AS (
    SELECT ord, {
      'key':    any_value(series_key),
      'label':  any_value(label),
      'kind':   any_value(kind),
      'region': any_value(region),
      'unit':   any_value(unit),
      'of':     any_value(of),
      'values': CASE WHEN count(value) = 0 THEN []::DOUBLE[]
                     ELSE list(round(value, 2) ORDER BY obs_date) END
    } AS s
    FROM aligned GROUP BY ord
  )
  SELECT
    {
      'generated': getvariable('generated'),
      'synthetic': NOT getvariable('strict')::BOOLEAN,
      'sources': [
        {'name':    'EIA Open Data v2',
         'url':     'https://www.eia.gov/opendata/',
         'licence': 'US Government work, public domain',
         'series':  ['RBRTE', 'RWTC', 'EER_EPD2DXL0_PF4_Y35NY_DPG']},
        {'name':    'ICE Low Sulphur Gasoil (manual)',
         'url':     'https://www.ice.com/products/34361119/Low-Sulphur-Gasoil-Futures',
         'licence': 'Not redistributable; user-supplied via data/manual/ice_gasoil.csv',
         'series':  ['ICE gasoil settlement']}
      ],
      'formulae': {
        'us_ulsd_brent':    'ULSD USD/gal x 42 - Brent USD/bbl',
        'us_ulsd_wti':      'ULSD USD/gal x 42 - WTI USD/bbl',
        'nwe_gasoil_brent': 'ICE gasoil USD/t / 7.45 - Brent USD/bbl',
        'ma7':              'Unweighted mean of the daily values over the trailing 7 '
                            'calendar days, inclusive. Emitted only where the window holds '
                            'at least ' || (SELECT min_week_obs FROM stg.build_meta)::VARCHAR || ' observations.'
      },
      'note': 'One point per EIA observation date, so weekends are absent rather than null. '
              'This axis is NOT positionally comparable with the weekly files. EIA publishes '
              'spot prices with a lag of roughly a week; the last date here is the last one '
              'EIA had published when the pipeline ran, not today.'
    } AS meta,
    (SELECT list(obs_date ORDER BY obs_date) FROM stg.day_axis) AS days,
    (SELECT list(s ORDER BY ord) FROM series)                   AS series
) TO 'site/public/data/cracks_daily.json' (FORMAT json, ARRAY false);

-- ---------------------------------------------------------------------------
-- retail.json
--
-- EU prices are EUR/L from the Oil Bulletin; the US series is USD/gal from EIA,
-- converted to USD/L but left in USD. Series stay in their native currency and
-- the frontend converts against fx.json — one source of truth beats three
-- separately rounded pipelines that drift apart.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.retail_points AS
SELECT week_start, cc, fuel, tax, eur_per_l AS value, 'EUR' AS currency, 'EU' AS region
FROM stg.retail_eu_weekly
UNION ALL
-- EIA publishes the pump price, which includes tax; there is no pre-tax series,
-- so the US contributes no 'without' rows and is simply absent from that view.
SELECT week_start, 'US', fuel, 'with', usd_per_gal / 3.785411784, 'USD', 'US'
FROM stg.retail_us_weekly;

COPY (
  WITH defs AS (
    -- Only combinations the source actually publishes. A (cc, fuel, tax) that
    -- does not exist upstream is omitted from the file entirely, never emitted
    -- as an all-null series — the without-tax view counts the omissions.
    SELECT DISTINCT cc, fuel, tax, currency, region FROM stg.retail_points
  ),
  aligned AS (
    SELECT d.*, c.week_start, p.value
    FROM defs d
    CROSS JOIN stg.week_calendar c
    LEFT JOIN stg.retail_points p
      ON p.cc = d.cc AND p.fuel = d.fuel AND p.tax = d.tax AND p.week_start = c.week_start
  ),
  series AS (
    SELECT
      any_value(a.cc) AS cc, any_value(a.fuel) AS fuel, any_value(a.tax) AS tax,
      {
        'cc':       any_value(a.cc),
        'label':    coalesce(any_value(e.name_en), 'United States'),
        'region':   any_value(a.region),
        -- Sweden's emphasis travels with the data, so the frontend never
        -- hard-codes a country code.
        'focus':    coalesce(any_value(e.is_focus), false),
        'fuel':     any_value(a.fuel),
        'tax':      any_value(a.tax),
        'currency': any_value(a.currency),
        'values':   list(round(a.value, 4) ORDER BY a.week_start)
      } AS s
    FROM aligned a
    LEFT JOIN stg.eu27 e ON e.cc = a.cc
    GROUP BY a.cc, a.fuel, a.tax
  )
  SELECT
    {
      'generated': getvariable('generated'),
      'synthetic': NOT getvariable('strict')::BOOLEAN,
      'sources': [
        {'name':    'EU Weekly Oil Bulletin',
         'url':     'https://energy.ec.europa.eu/data-and-analysis/weekly-oil-bulletin_en',
         'licence': 'European Commission open data (CC BY 4.0)',
         'series':  ['Euro-super 95', 'Gas oil automobile']},
        {'name':    'EIA Open Data v2',
         'url':     'https://www.eia.gov/opendata/',
         'licence': 'US Government work, public domain',
         'series':  ['EMM_EPMR_PTE_NUS_DPG', 'EMD_EPD2D_PTE_NUS_DPG']}
      ],
      'note': 'EU prices EUR/L; US prices USD/L converted from USD/gal at 3.785411784 L/gal. '
              'US retail is a pump price and has no pre-tax series.'
    } AS meta,
    (SELECT list(week_start ORDER BY week_start) FROM stg.week_calendar) AS weeks,
    (SELECT list(s ORDER BY cc, fuel, tax) FROM series)                  AS series
) TO 'site/public/data/retail.json' (FORMAT json, ARRAY false);

-- ---------------------------------------------------------------------------
-- fx.json — units of the named currency per 1 EUR, ECB orientation.
-- ---------------------------------------------------------------------------
COPY (
  SELECT
    {
      'generated': getvariable('generated'),
      'synthetic': NOT getvariable('strict')::BOOLEAN,
      'sources': [
        {'name':    'ECB SDMX reference rates',
         'url':     'https://data.ecb.europa.eu/',
         'licence': 'ECB open data, attribution required',
         'series':  ['EXR.D.USD.EUR.SP00.A', 'EXR.D.SEK.EUR.SP00.A']}
      ],
      'note': 'Units of the named currency per 1 EUR, last rate on or before each week Monday.'
    } AS meta,
    (SELECT list(week_start ORDER BY week_start) FROM stg.week_calendar) AS weeks,
    (SELECT {
       'USD': list(per_eur ORDER BY week_start) FILTER (WHERE ccy = 'USD'),
       'SEK': list(per_eur ORDER BY week_start) FILTER (WHERE ccy = 'SEK')
     } FROM (SELECT week_start, ccy, round(per_eur, 4) AS per_eur FROM stg.fx_weekly)) AS rates
) TO 'site/public/data/fx.json' (FORMAT json, ARRAY false);

-- ---------------------------------------------------------------------------
-- usregions.json — spridningen inom USA.
--
-- Egen fil, inte extra serier i retail.json: retail-diagrammet filtrerar på
-- (fuel, tax) och skulle rita in delstaterna i EU-jämförelsen. En fil per
-- diagram, som kontraktet säger.
--
-- USD/L som allt annat retail; frontend växlar. 'geo' bärs med så att
-- diagrammet kan säga att diesel är PADD-regioner och inte delstater.
-- ---------------------------------------------------------------------------
COPY (
  WITH defs AS (
    SELECT DISTINCT fuel, code, label, geo FROM stg.region_weekly
  ),
  aligned AS (
    SELECT d.*, c.week_start, p.usd_per_gal
    FROM defs d
    CROSS JOIN stg.week_calendar c
    LEFT JOIN stg.region_weekly p
      ON p.fuel = d.fuel AND p.code = d.code AND p.week_start = c.week_start
  ),
  regions AS (
    SELECT any_value(fuel) AS fuel, any_value(code) AS code, {
      'code':     any_value(code),
      'label':    any_value(label),
      'geo':      any_value(geo),
      'fuel':     any_value(fuel),
      'currency': 'USD',
      'values':   list(round(usd_per_gal / 3.785411784, 4) ORDER BY week_start)
    } AS s
    FROM aligned GROUP BY fuel, code
  )
  SELECT
    {
      'generated': getvariable('generated'),
      'synthetic': NOT getvariable('strict')::BOOLEAN,
      'sources': [
        {'name':    'EIA Open Data v2',
         'url':     'https://www.eia.gov/opendata/',
         'licence': 'US Government work, public domain',
         'series':  ['EMM_EPMR_PTE_S**_DPG (9 states)', 'EMD_EPD2D_PTE_R**_DPG (5 PADDs)']}
      ],
      'note': 'Petrol is published for nine states — EIA''s entire free state-level coverage, '
              'not a selection. Diesel is published by PADD region, plus California. '
              'The national average is volume-weighted and need not lie midway between the lines.'
    } AS meta,
    (SELECT list(week_start ORDER BY week_start) FROM stg.week_calendar) AS weeks,
    (SELECT list(s ORDER BY fuel, code) FROM regions)                    AS regions
) TO 'site/public/data/usregions.json' (FORMAT json, ARRAY false);
