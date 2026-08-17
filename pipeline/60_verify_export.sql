-- 60_verify_export.sql — invariants over the published JSON, after export.
--
-- verify.sql runs against the staging tables and cannot see these: the whole
-- wide-form contract rests on every series' values[] being the same length as
-- weeks[], and on all three files sharing one axis. The frontend indexes by
-- position with no bounds check — Fx.convert reads usd(i) for an i that comes
-- from a retail series — so a short array throws mid-render and blanks every
-- chart, and a shifted one silently draws the wrong year.
--
-- Contract: specs/001-crack-and-retail-fuel-site/contracts/chart-json.md

-- 8. Every series in cracks.json and retail.json is either aligned to weeks[]
--    or deliberately empty (the ICE gasoil stub).
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 8: {} series in cracks.json are misaligned: {}',
                    count(*), string_agg(key || '=' || n, ', ')))
END AS "8 cracks.json series aligned"
FROM (
  SELECT s.key AS key, len(s.values) AS n, len(weeks) AS w
  FROM (SELECT weeks, unnest(series) AS s FROM read_json('site/public/data/cracks.json'))
) WHERE n <> w AND n <> 0;

-- Exemplen kapas: en misslyckad axel gör alla 110 serier felaktiga, och en
-- CI-logg med 110 namn i döljer felet i stället för att visa det.
CREATE OR REPLACE TEMP VIEW allser AS
SELECT s.cc || '/' || s.fuel || '/' || s.tax AS label,
       len(s.values) AS n, len(weeks) AS w
FROM (SELECT weeks, unnest(series) AS s FROM read_json('site/public/data/retail.json'));

CREATE OR REPLACE TEMP VIEW bad AS SELECT * FROM allser WHERE n <> w;

SELECT CASE WHEN (SELECT count(*) FROM bad) > 0
  THEN error(format('verify 9: {} of {} series in retail.json are misaligned (weeks={}); first: {}',
                    (SELECT count(*) FROM bad),
                    (SELECT count(*) FROM allser),
                    (SELECT any_value(w) FROM bad),
                    (SELECT string_agg(label || '=' || n, ', ') FROM (SELECT * FROM bad LIMIT 5))))
END AS "9 retail.json series aligned"
FROM (SELECT 1);

-- 10. FX must be complete, not merely aligned: a null or a short array here
--     drops every series the moment a visitor switches currency.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 10: fx.json rates are not aligned to weeks ({} problems)', count(*)))
END AS "10 fx.json rates aligned"
FROM (SELECT * FROM read_json('site/public/data/fx.json'))
WHERE len(rates.USD) <> len(weeks)
   OR len(rates.SEK) <> len(weeks)
   OR len(list_filter(rates.USD, x -> x IS NULL)) > 0
   OR len(list_filter(rates.SEK, x -> x IS NULL)) > 0;

-- 11. One axis across all three files. The frontend indexes retail values into
--     the FX arrays by position, which is only valid if these are identical.
SELECT CASE WHEN (SELECT weeks FROM read_json('site/public/data/cracks.json'))
                 <> (SELECT weeks FROM read_json('site/public/data/retail.json'))
             OR (SELECT weeks FROM read_json('site/public/data/cracks.json'))
                 <> (SELECT weeks FROM read_json('site/public/data/fx.json'))
  THEN error('verify 11: the three JSON files do not share one week axis')
END AS "11 shared week axis";

SELECT 'export-invarianter gröna' AS verify;
