-- 15_eia_regions.sql — regional spridning inom USA.
--
-- Geografin skiljer sig mellan bränslena och det är inget vi kan välja bort:
-- EIA publicerar regular petrol per delstat för NIO delstater, och diesel per
-- PADD-region plus Kalifornien. Kartan är alltså olika för petrol och diesel,
-- vilket 'geo' bär vidare så att frontend kan säga det rakt ut.
--
-- Serie-id:t kodar området i sitt fjärde segment: S** = delstat, R** = PADD.

CREATE OR REPLACE TABLE stg.region_ref (series_id VARCHAR, fuel VARCHAR, code VARCHAR, label VARCHAR, geo VARCHAR);
INSERT INTO stg.region_ref VALUES
  ('EMM_EPMR_PTE_SCA_DPG','gasoline','CA','California',    'state'),
  ('EMM_EPMR_PTE_SCO_DPG','gasoline','CO','Colorado',      'state'),
  ('EMM_EPMR_PTE_SFL_DPG','gasoline','FL','Florida',       'state'),
  ('EMM_EPMR_PTE_SMA_DPG','gasoline','MA','Massachusetts', 'state'),
  ('EMM_EPMR_PTE_SMN_DPG','gasoline','MN','Minnesota',     'state'),
  ('EMM_EPMR_PTE_SNY_DPG','gasoline','NY','New York',      'state'),
  ('EMM_EPMR_PTE_SOH_DPG','gasoline','OH','Ohio',          'state'),
  ('EMM_EPMR_PTE_STX_DPG','gasoline','TX','Texas',         'state'),
  ('EMM_EPMR_PTE_SWA_DPG','gasoline','WA','Washington',    'state'),
  ('EMD_EPD2D_PTE_R10_DPG','diesel','EC','East Coast (PADD 1)',    'padd'),
  ('EMD_EPD2D_PTE_R20_DPG','diesel','MW','Midwest (PADD 2)',       'padd'),
  ('EMD_EPD2D_PTE_R30_DPG','diesel','GC','Gulf Coast (PADD 3)',    'padd'),
  ('EMD_EPD2D_PTE_R40_DPG','diesel','RM','Rocky Mountain (PADD 4)','padd'),
  ('EMD_EPD2D_PTE_R50_DPG','diesel','WC','West Coast (PADD 5)',    'padd'),
  ('EMD_EPD2D_PTE_SCA_DPG','diesel','CA','California',             'state');

-- Rå rader först, veckor sedan — samma skäl som i 10_eia.sql: dubblettkontrollen
-- måste kunna köra mot något som inte redan grupperats på veckonyckeln.
CREATE OR REPLACE TABLE stg.region_raw AS
WITH raw AS (
  SELECT UNNEST(response.data) AS d
  FROM read_json_auto(getvariable('work_dir') || '/eia_region_*.json')
)
SELECT d.period::DATE AS obs_date, d.series::VARCHAR AS series_id,
       TRY_CAST(d.value AS DOUBLE) AS usd_per_gal
FROM raw
WHERE d.period::DATE >= getvariable('start_week')::DATE
  AND TRY_CAST(d.value AS DOUBLE) IS NOT NULL
  AND d.series::VARCHAR IN (SELECT series_id FROM stg.region_ref);

CREATE OR REPLACE TABLE stg.region_weekly AS
SELECT date_trunc('week', r.obs_date)::DATE AS week_start,
       ref.fuel, ref.code, ref.label, ref.geo,
       AVG(r.usd_per_gal) AS usd_per_gal
FROM stg.region_raw r
JOIN stg.region_ref ref USING (series_id)
GROUP BY 1, 2, 3, 4, 5;
