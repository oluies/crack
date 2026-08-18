-- 60_verify_export.sql — invariants over the published JSON, after export.
--
-- verify.sql runs against the staging tables and cannot see these: the whole
-- wide-form contract rests on every series' values[] being the same length as
-- weeks[], and on all three files sharing one axis. The frontend indexes by
-- position with no bounds check — Fx.convert reads usd(i) for an i that comes
-- from a retail series — so a short array throws mid-render and blanks every
-- chart, and a shifted one silently draws the wrong year.
--
-- These read through out_dir while 50_export.sql writes to a string literal —
-- DuckDB's COPY ... TO accepts nothing else there. run.sh asserts the two agree
-- before it builds; see the OUT_DIR check there. An earlier attempt to catch the
-- divergence here, by comparing meta.generated against the run's stamp, was
-- removed: it broke --verify-only (a later UTC day, or any file the idempotence
-- restore rolled back, failed a perfectly valid export) and cost more than the
-- latent risk it covered.
--
-- Contract: specs/001-crack-and-retail-fuel-site/contracts/chart-json.md

-- 8. Shape first, on the raw JSON.
--
--    Every check below reads the files through read_json, whose inferred schema
--    depends on the content: a missing "weeks" key makes the column unbindable
--    and a null rates.USD makes list_filter unbindable. Those still fail the run
--    — .bail on sees a non-zero exit — but they fail with a binder error that
--    names a column rather than the problem. Probing the raw JSON first binds
--    regardless of content, so a malformed file gets a diagnosis instead.
CREATE OR REPLACE TEMP TABLE published AS
SELECT 'cracks.json' AS f, json FROM read_json_objects(getvariable('out_dir') || '/cracks.json')
UNION ALL SELECT 'retail.json', json FROM read_json_objects(getvariable('out_dir') || '/retail.json')
UNION ALL SELECT 'fx.json',     json FROM read_json_objects(getvariable('out_dir') || '/fx.json')
UNION ALL SELECT 'usregions.json', json FROM read_json_objects(getvariable('out_dir') || '/usregions.json');

SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 8: {} published file(s) have the wrong shape: {}',
                    count(*), string_agg(f || ' (' || why || ')', '; ')))
END AS "8 published files well-formed"
FROM (
  SELECT f,
    CASE
      WHEN json_type(json->'$.weeks') IS DISTINCT FROM 'ARRAY'  THEN 'weeks is not an array'
      WHEN json_type(json->'$.meta')  IS DISTINCT FROM 'OBJECT' THEN 'meta is not an object'
      WHEN f = 'usregions.json' AND (json_type(json->'$.regions') IS DISTINCT FROM 'ARRAY'
                                  OR json_array_length(json->'$.regions') = 0
                                  OR json_type(json->'$.regions[0].values') IS DISTINCT FROM 'ARRAY')
        THEN 'regions missing or malformed'
      WHEN f NOT IN ('fx.json', 'usregions.json')
           AND json_type(json->'$.series') IS DISTINCT FROM 'ARRAY'
        THEN 'series is not an array'
      WHEN f NOT IN ('fx.json', 'usregions.json')
           AND json_array_length(json->'$.series') = 0
        THEN 'series is empty'
      -- Element keys, not just the top level. read_json unifies the struct
      -- schema across list elements, so a key absent from EVERY element leaves
      -- the inferred struct without that field and s.values fails to BIND —
      -- the binder-error-instead-of-diagnosis outcome this check exists to
      -- prevent. Probing element 0 catches it here, with a message.
      WHEN f = 'cracks.json' AND (json_type(json->'$.series[0].key')    IS DISTINCT FROM 'VARCHAR'
                               OR json_type(json->'$.series[0].values') IS DISTINCT FROM 'ARRAY')
        THEN 'series elements lack key/values'
      WHEN f = 'retail.json' AND (json_type(json->'$.series[0].cc')     IS DISTINCT FROM 'VARCHAR'
                               OR json_type(json->'$.series[0].fuel')   IS DISTINCT FROM 'VARCHAR'
                               OR json_type(json->'$.series[0].tax')    IS DISTINCT FROM 'VARCHAR'
                               OR json_type(json->'$.series[0].values') IS DISTINCT FROM 'ARRAY')
        THEN 'series elements lack cc/fuel/tax/values'
      WHEN f =  'fx.json' AND (json_type(json->'$.rates.USD') IS DISTINCT FROM 'ARRAY'
                            OR json_type(json->'$.rates.SEK') IS DISTINCT FROM 'ARRAY')
        THEN 'rates.USD/SEK is not an array'
    END AS why
  FROM published
) WHERE why IS NOT NULL;

-- 9. Every series in cracks.json is aligned to weeks[].
--
--    The empty exemption applies ONLY to the declared ICE gasoil stub. 50_export
--    emits [] for any series with no observations at all, so a blanket "or empty"
--    would let Brent, WTI and ULSD all come back empty — an EIA facet rename, a
--    typo in a series ID, a fetch that returned nothing — and still report green.
--    That is the exact failure this file exists to close.
--
--    n IS NULL is tested explicitly: a series with no values key at all gives
--    NULL, and NULL <> w is NULL, which would quietly not match.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 9: {} series in cracks.json are misaligned (weeks={}): {}',
                    count(*), any_value(w), string_agg(key || '=' || coalesce(n::VARCHAR, 'NULL'), ', ')))
END AS "9 cracks.json series aligned"
FROM (
  SELECT s.key AS key, len(s.values) AS n, len(weeks) AS w
  FROM (SELECT weeks, unnest(series) AS s FROM read_json(getvariable('out_dir') || '/cracks.json'))
) WHERE n IS NULL
     OR (n IS DISTINCT FROM w AND NOT (n = 0 AND key = 'nwe_gasoil_brent'));

-- Exemplen kapas: en misslyckad axel gör alla 110 serier felaktiga, och en
-- CI-logg med 110 namn i döljer felet i stället för att visa det.
CREATE OR REPLACE TEMP VIEW allser AS
SELECT s.cc || '/' || s.fuel || '/' || s.tax AS label,
       len(s.values) AS n, len(weeks) AS w
FROM (SELECT weeks, unnest(series) AS s FROM read_json(getvariable('out_dir') || '/retail.json'));

CREATE OR REPLACE TEMP VIEW bad AS
SELECT * FROM allser WHERE n IS NULL OR n IS DISTINCT FROM w;

SELECT CASE WHEN (SELECT count(*) FROM bad) > 0
  THEN error(format('verify 10: {} of {} series in retail.json are misaligned (weeks={}); first: {}',
                    (SELECT count(*) FROM bad),
                    (SELECT count(*) FROM allser),
                    (SELECT any_value(w) FROM bad),
                    (SELECT string_agg(coalesce(label, '?') || '=' || coalesce(n::VARCHAR, 'NULL'), ', ')
                     FROM (SELECT * FROM bad LIMIT 5))))
END AS "10 retail.json series aligned"
FROM (SELECT 1);

-- 11. FX must be complete, not merely aligned: a null or a short array here
--     drops every series the moment a visitor switches currency.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 11: fx.json rates are not aligned to weeks ({} problems)', count(*)))
END AS "11 fx.json rates aligned"
FROM (SELECT * FROM read_json(getvariable('out_dir') || '/fx.json'))
-- The NULL cases are tested first and explicitly. 50_export builds these with
-- list(...) FILTER (WHERE ccy = 'USD'), which yields NULL — not [] — when no row
-- survives; len(NULL) <> len(weeks) is NULL, so a fx.json with no USD rates at
-- all would otherwise pass this check green.
WHERE rates.USD IS NULL
   OR rates.SEK IS NULL
   OR len(rates.USD) IS DISTINCT FROM len(weeks)
   OR len(rates.SEK) IS DISTINCT FROM len(weeks)
   OR len(list_filter(rates.USD, x -> x IS NULL)) > 0
   OR len(list_filter(rates.SEK, x -> x IS NULL)) > 0;

-- 11b. usregions.json aligned to the same axis.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 11b: {} US region series are misaligned (weeks={}): {}',
                    count(*), any_value(w), string_agg(code || '/' || fuel || '=' || coalesce(n::VARCHAR,'NULL'), ', ')))
END AS "11b usregions.json aligned"
FROM (
  SELECT s.code AS code, s.fuel AS fuel, len(s.values) AS n, len(weeks) AS w
  FROM (SELECT weeks, unnest(regions) AS s FROM read_json(getvariable('out_dir') || '/usregions.json'))
) WHERE n IS NULL OR n IS DISTINCT FROM w;

-- 12. One axis across all files. The frontend indexes retail values into
--     the FX arrays by position, which is only valid if these are identical.
--     IS DISTINCT FROM, not <>: a missing or renamed weeks key gives NULL, and
--     NULL <> NULL is NULL, so the CASE would fall through to green on a file
--     with no axis at all.
SELECT CASE WHEN (SELECT weeks FROM read_json(getvariable('out_dir') || '/cracks.json'))
                 IS DISTINCT FROM (SELECT weeks FROM read_json(getvariable('out_dir') || '/retail.json'))
             OR (SELECT weeks FROM read_json(getvariable('out_dir') || '/cracks.json'))
                 IS DISTINCT FROM (SELECT weeks FROM read_json(getvariable('out_dir') || '/fx.json'))
             OR (SELECT weeks FROM read_json(getvariable('out_dir') || '/cracks.json'))
                 IS DISTINCT FROM (SELECT weeks FROM read_json(getvariable('out_dir') || '/usregions.json'))
             OR (SELECT weeks FROM read_json(getvariable('out_dir') || '/cracks.json')) IS NULL
  THEN error('verify 12: the three JSON files do not share one week axis')
END AS "12 shared week axis";

SELECT 'export-invarianter gröna' AS verify;
