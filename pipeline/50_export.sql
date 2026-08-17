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
-- reads through getvariable('out_dir') instead, so the two can only agree because
-- run.sh cd's to the repo root and points out_dir here. That coupling is checked
-- rather than assumed: check 8 rejects any file whose meta.generated is not this
-- run's stamp.

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
