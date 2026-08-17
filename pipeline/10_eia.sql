-- 10_eia.sql — EIA Open Data v2 JSON -> staging.
--
-- run.sh has already paged the API into work_dir as eia_spot_NNN.json and
-- eia_retail_NNN.json (shell moves bytes, SQL does the work). Both are read with
-- read_json_auto over a glob, so adding a page adds no SQL.
--
-- Envelope: {"response":{"total":..,"data":[{period,series,value,units,..}]}}.
-- The document root is one object, so the rows live behind an UNNEST of
-- response.data rather than at the top level.

-- ---------------------------------------------------------------------------
-- Daily spot prices: NYH ULSD (USD/gal), Brent and WTI (USD/bbl).
--
-- Units differ per series and stay native here; 40_cracks.sql converts. Value is
-- TRY_CAST because EIA occasionally serialises a number as a string, and a hard
-- cast would fail the whole run over one such row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.spot_daily AS
WITH raw AS (
  SELECT UNNEST(response.data) AS d
  FROM read_json_auto(getvariable('work_dir') || '/eia_spot_*.json')
)
SELECT
  d.period::DATE                 AS obs_date,
  d.series::VARCHAR              AS series_id,
  TRY_CAST(d.value AS DOUBLE)    AS value
FROM raw
WHERE d.period::DATE >= getvariable('start_week')::DATE
  AND TRY_CAST(d.value AS DOUBLE) IS NOT NULL;

-- ---------------------------------------------------------------------------
-- US weekly retail, already published Monday-weekly by EIA.
--
-- Kept as raw rows first, and aggregated in a second step. The duplicate check
-- in verify.sql has to run against THIS table: asserting uniqueness on the
-- aggregate below would be tautological — the GROUP BY guarantees it — and
-- would report green on exactly the upstream double-publication it claims to
-- catch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.retail_us_raw AS
WITH raw AS (
  SELECT UNNEST(response.data) AS d
  FROM read_json_auto(getvariable('work_dir') || '/eia_retail_*.json')
)
SELECT
  d.period::DATE    AS obs_date,
  d.series::VARCHAR AS series_id,
  CASE d.series::VARCHAR
    WHEN 'EMM_EPMR_PTE_NUS_DPG' THEN 'gasoline'
    WHEN 'EMD_EPD2D_PTE_NUS_DPG' THEN 'diesel'
  END               AS fuel,
  TRY_CAST(d.value AS DOUBLE) AS usd_per_gal
FROM raw
WHERE d.period::DATE >= getvariable('start_week')::DATE
  AND TRY_CAST(d.value AS DOUBLE) IS NOT NULL
  AND d.series::VARCHAR IN ('EMM_EPMR_PTE_NUS_DPG', 'EMD_EPD2D_PTE_NUS_DPG');

-- date_trunc is a key derivation here, not an aggregation: EIA already
-- publishes these on Mondays.
CREATE OR REPLACE TABLE stg.retail_us_weekly AS
SELECT
  date_trunc('week', obs_date)::DATE AS week_start,
  fuel,
  AVG(usd_per_gal)                   AS usd_per_gal
FROM stg.retail_us_raw
GROUP BY 1, 2;
