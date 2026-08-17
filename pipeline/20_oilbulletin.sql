-- 20_oilbulletin.sql — EU Weekly Oil Bulletin workbook -> tidy weekly prices.
--
-- The workbook is 226 columns wide with a three-row header, so it cannot be read
-- with a normal header=true. The shape (verified in research.md):
--
--   row 1   machine names: SE_price_with_tax_diesel, SE_exchange_rate, CTR, ...
--   row 2   human labels    (ignored)
--   row 3   units           (ignored; liquids are all "1000 l")
--   row 4+  data, column A an Excel date serial, rows DESCENDING by date
--
-- read_xlsx with header=false names columns by spreadsheet letter, which turns
-- the problem into a join: unpivot row 1 to (letter -> name), unpivot the data to
-- (date, letter, value), join on the letter. 226 columns become tidy rows without
-- a line of DDL naming any of them.
--
-- all_varchar is required: the sheet interleaves "CTR" text markers among the
-- numeric columns, and letting DuckDB sniff types nulls out real values.
--
-- The two sheets are read identically because the row-1 names carry the tax
-- treatment themselves (price_with_tax / price_wo_tax) — only the sheet name
-- differs. The sheet is still carried through the join key, because a given
-- column letter means different things in the two sheets.

CREATE OR REPLACE TABLE stg.retail_eu_weekly AS
WITH hdr AS (
  SELECT 'with' AS sheet_tax, col, label
  FROM (UNPIVOT (SELECT * FROM read_xlsx(getvariable('ob_path'),
                   sheet = 'Prices with taxes',
                   header = false, all_varchar = true, range = 'A1:AMJ1'))
        ON COLUMNS(*) INTO NAME col VALUE label)
  UNION ALL
  SELECT 'without', col, label
  FROM (UNPIVOT (SELECT * FROM read_xlsx(getvariable('ob_path'),
                   sheet = 'Prices wo taxes',
                   header = false, all_varchar = true, range = 'A1:AMJ1'))
        ON COLUMNS(*) INTO NAME col VALUE label)
),
dat AS (
  SELECT 'with' AS sheet_tax, A AS date_serial, col, val
  FROM (UNPIVOT (SELECT * FROM read_xlsx(getvariable('ob_path'),
                   sheet = 'Prices with taxes',
                   header = false, all_varchar = true, range = 'A4:AMJ3000'))
        ON COLUMNS(* EXCLUDE (A)) INTO NAME col VALUE val)
  UNION ALL
  SELECT 'without', A, col, val
  FROM (UNPIVOT (SELECT * FROM read_xlsx(getvariable('ob_path'),
                   sheet = 'Prices wo taxes',
                   header = false, all_varchar = true, range = 'A4:AMJ3000'))
        ON COLUMNS(* EXCLUDE (A)) INTO NAME col VALUE val)
),
parsed AS (
  SELECT
    -- Excel 1900-system serial. Verified: 46244 -> 2026-08-10.
    (DATE '1899-12-30' + INTERVAL (d.date_serial::INT) DAY)::DATE AS obs_date,
    regexp_extract(h.label, '^([A-Z]{2})_price_(with|wo)_tax_(euro95|diesel)$', 1) AS cc,
    h.sheet_tax                                                                    AS tax,
    CASE regexp_extract(h.label, '^([A-Z]{2})_price_(with|wo)_tax_(euro95|diesel)$', 3)
      WHEN 'euro95' THEN 'gasoline' ELSE 'diesel'
    END                                                                            AS fuel,
    -- Source publishes EUR per 1000 litres, for every country, already converted.
    -- The workbook's {CC}_exchange_rate columns are deliberately NOT read: they
    -- are EUR-per-national-unit and applying one would divide Swedish prices by
    -- eleven. verify.sql asserts a plausible EUR/L range to catch a regression.
    TRY_CAST(d.val AS DOUBLE) / 1000.0                                             AS eur_per_l
  FROM dat d
  JOIN hdr h ON h.sheet_tax = d.sheet_tax AND h.col = d.col
  -- SIMILAR TO matches the whole string, so this admits only country price
  -- columns — not the CTR separators, the _exchange_rate columns, or the other
  -- four products.
  WHERE h.label SIMILAR TO '[A-Z]{2}_price_(with|wo)_tax_(euro95|diesel)'
    AND TRY_CAST(d.val AS DOUBLE) IS NOT NULL
)
SELECT
  date_trunc('week', p.obs_date)::DATE AS week_start,
  p.cc,
  p.fuel,
  p.tax,
  AVG(p.eur_per_l)                     AS eur_per_l
FROM parsed p
-- The join is the country filter. 'EU_' also matches [A-Z]{2} and would
-- otherwise ride along as a 28th country; UK is in the history but not the EU-27.
JOIN stg.eu27 c ON c.cc = p.cc
WHERE p.obs_date >= getvariable('start_week')::DATE
GROUP BY 1, 2, 3, 4;
