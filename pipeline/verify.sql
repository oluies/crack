-- verify.sql — invariants over the built staging tables.
--
-- These are the real test. They target the failures that produce a plausible
-- but wrong chart — a missing x42 on the crack, an exchange rate applied to
-- prices that are already in EUR — because those do not announce themselves.
--
-- Each check raises with a message naming what broke. .bail on (set by run.sh)
-- stops at the first failure, so the message you see is the one that matters.

-- ---------------------------------------------------------------------------
-- VARNING, gäller varje kontroll i den här filen och i 60_verify_export.sql.
--
-- format() ger NULL om NÅGOT argument är NULL, och error(NULL) KASTAR INTE —
-- den returnerar NULL och körningen fortsätter grön. En kontroll vars
-- meddelande interpolerar ett värde som kan vara NULL är alltså tyst i precis
-- det värsta fallet: en tom tabell. Upptäckt när check 14 vägrade fälla på en
-- serie utan observationer i fönstret, där expected var NULL.
--
-- Samma sak gäller VILLKORET, inte bara meddelandet: NULL > 21 är NULL, och
-- CASE faller igenom till grönt. Därför kommer check 1b först av allt.
--
-- Kontroll 1–6 interpolerar avsiktligt utan coalesce. Deras uttryck kan inte
-- vara NULL när count(*) > 0: nycklarna kommer från kolumner som filtreras
-- non-null redan i staging (10_eia.sql och 20_oilbulletin.sql), och min/max
-- över en icke-tom mängd är non-null. Det är ett antagande om de filtren, inte
-- en egenskap hos format() — flyttas ett filter måste de coalesce:as.
-- ---------------------------------------------------------------------------

-- 1b. Veckoaxeln finns över huvud taget.
--
--     Först, för att allt nedanför vilar på den. En tom stg.week_calendar gör
--     inte bara meddelanden NULL utan villkoren också: check 1 räknar luckor
--     över noll rader, check 6 kryssjoinar en tom kalender till noll rader, och
--     staleness-uttrycket blir NULL - DATE '1900-01-01' > 21, alltså NULL. Ett
--     DELETE FROM stg.week_calendar passerade hela verify.sql grönt — ett värre
--     tillstånd än den tomma crack_weekly som redan har ett prov.
SELECT CASE WHEN (SELECT count(*) FROM stg.week_calendar) = 0
  THEN error('verify 1b: stg.week_calendar is empty - every check below it is vacuous')
END AS "1b week calendar is not empty";

-- 1c. Samma sak för dagsaxeln.
--
--     En tom stg.day_axis gör check 15 tom (noll grupper har count > 1) och
--     check 14 tom (recomputed har noll rader), och check 16 är grindad på
--     strict — ett fixtures-bygge med tom dagsaxel passerade alltså hela
--     verify.sql. Export-check 8/18a tar den, men först efter att filen
--     skrivits.
SELECT CASE WHEN (SELECT count(*) FROM stg.day_axis) = 0
  THEN error('verify 1c: stg.day_axis is empty - checks 14, 15 and 16 are vacuous')
END AS "1c daily axis is not empty";

-- 1d. build_meta har en användbar min_week_obs.
--
--     Guarden i 00_schema.sql stänger "variabeln var inte satt vid bygget", inte
--     "NULL vid kontrolltillfället". Varje läsare gör numera
--     (SELECT min_week_obs FROM stg.build_meta), en okorrelerad skalär delfråga
--     som ger NULL om tabellen är tom — och då är felläget exakt det som skulle
--     tas bort: n >= NULL är NULL, check 13 och 14 får tomma mängder och
--     rapporterar grönt. strict är av samma skäl coalesce:ad på sina två
--     läsplatser; det här är den andra kolumnen i samma tabell.
SELECT CASE WHEN (SELECT count(*) FROM stg.build_meta
                   WHERE min_week_obs IS NOT NULL AND built_on IS NOT NULL) <> 1
  THEN error('verify 1d: stg.build_meta has no usable min_week_obs/built_on - checks 1e, 13 and 14 are vacuous')
END AS "1d build_meta usable";

-- 1e. Axelns övre gräns ligger i rätt intervall.
--
--     Sedan 25_calendar.sql låter en publicerad enkätvecka dra ut axeln beror
--     gränsen på uppströmsdata, inte bara på klockan. Två fel blir då möjliga
--     som inte var det förut: ett trasigt datum uppströms kan skjuta axeln in i
--     framtiden, och en tom enkättabell kan låta den falla under den sista
--     avslutade veckan. Båda ger en axel som ser normal ut.
--     Gränserna prövas mot stg.build_meta.built_on, inte mot current_date:
--     --verify-only kör de här invarianterna mot en databas som byggdes en
--     annan dag, och mot dagens datum hade en helt korrekt axel fällts så fort
--     kalendern hunnit vidare en vecka. Att datan är gammal är en annan fråga
--     och har egna kontroller (7, 7b, 16).
SELECT CASE
  WHEN (SELECT max(week_start) FROM stg.week_calendar)
       > date_trunc('week', (SELECT built_on FROM stg.build_meta))::DATE
    THEN error(format('verify 1e: the week axis runs into the future - ends {}, build week {}',
                      coalesce((SELECT max(week_start) FROM stg.week_calendar)::VARCHAR, 'none'),
                      coalesce(date_trunc('week', (SELECT built_on FROM stg.build_meta))::DATE::VARCHAR, 'none')))
  WHEN (SELECT max(week_start) FROM stg.week_calendar)
       < (date_trunc('week', (SELECT built_on FROM stg.build_meta)) - INTERVAL 7 DAY)::DATE
    THEN error(format('verify 1e: the week axis stops before the last complete week - ends {}, expected at least {}',
                      coalesce((SELECT max(week_start) FROM stg.week_calendar)::VARCHAR, 'none'),
                      coalesce((date_trunc('week', (SELECT built_on FROM stg.build_meta)) - INTERVAL 7 DAY)::DATE::VARCHAR, 'none')))
END AS "1e week axis ends in range";

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
--    Two things have to line up here, and both were wrong at some point: the
--    check runs against the RAW table (asserting uniqueness on a table whose own
--    GROUP BY produces the key is tautological), AND it groups by the key that
--    table is later aggregated on. Checking (obs_date, series_id) passes happily
--    while two publications in the same week — different dates, same week — get
--    silently averaged by the downstream GROUP BY.
--    2a is the exception: spot_daily is genuinely daily and its weekly mean in
--    40_cracks.sql is deliberate, so the daily key is the right one there.
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2a: {} (date, series) group(s) have duplicate EIA spot rows', count(*)))
END AS "2a EIA spot rows unique"
FROM (SELECT 1 FROM stg.spot_daily GROUP BY obs_date, series_id HAVING count(*) > 1);

-- Namngivna vyer så att felmeddelandet kan peka ut vilka grupper som brast;
-- ett antal utan nycklar ger operatören ingenting att titta på.
CREATE OR REPLACE TEMP VIEW dup2b AS
SELECT date_trunc('week', obs_date)::DATE || '/' || cc || '/' || fuel || '/' || tax AS k
FROM stg.ob_parsed
GROUP BY date_trunc('week', obs_date), cc, fuel, tax HAVING count(*) > 1;

CREATE OR REPLACE TEMP VIEW dup2c AS
SELECT date_trunc('week', obs_date)::DATE || '/' || fuel AS k
FROM stg.retail_us_raw
GROUP BY date_trunc('week', obs_date), fuel HAVING count(*) > 1;

SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2b: {} (week, cc, fuel, tax) group(s) have more than one '
                    'Oil Bulletin observation; first: {}',
                    count(*), (SELECT string_agg(k, ', ') FROM (SELECT k FROM dup2b LIMIT 5))))
END AS "2b Oil Bulletin one row per week"
FROM dup2b;

SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 2c: {} (week, fuel) group(s) have more than one EIA retail '
                    'publication; first: {}',
                    count(*), (SELECT string_agg(k, ', ') FROM (SELECT k FROM dup2c LIMIT 5))))
END AS "2c EIA retail one row per week"
FROM dup2c;

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

-- 7. No long trailing run of empty weeks. The calendar ends at the last complete
--    week, but if a source has stalled we would publish a flat blank tail and
--    call it data. Two weeks of slack absorbs normal publication lag.
--
--    Check 7 (crack) is gated on strict: under --fixtures the EIA half is a
--    frozen synthetic snapshot while week_calendar tracks current_date, so it
--    would start failing every CI run weeks after the fixtures were generated.
--    Check 7b (EU retail) is NOT gated — the Oil Bulletin is fetched live in
--    every mode, so a workbook that still parses but has stopped being updated
--    must fail CI rather than sail through it.
--
--    Slacken för crack är 21 dagar, inte 14 som för retail, och det är en följd
--    av coverage-regeln nedan: EIA ligger ~8 dagar efter, så den sista
--    kalenderveckan har regelmässigt för få handelsdagar och publiceras som
--    NULL. Ett normalläge är alltså redan en veckas glapp, och 14 dagar hade
--    fällt bygget på en enda sen EIA-publicering. Dagsserien är stället där
--    färskhet faktiskt mäts — se verify 16.
SELECT CASE WHEN coalesce((SELECT strict FROM stg.build_meta), true) AND (SELECT max(week_start) FROM stg.week_calendar)
                 - coalesce((SELECT max(week_start) FROM stg.crack_weekly
                             WHERE usd_per_bbl IS NOT NULL), DATE '1900-01-01') > 21
  THEN error(format('verify 7: crack data stale - calendar ends {}, last observation {}',
                    coalesce((SELECT max(week_start) FROM stg.week_calendar)::VARCHAR, 'none'),
                    coalesce((SELECT max(week_start) FROM stg.crack_weekly
                              WHERE usd_per_bbl IS NOT NULL)::VARCHAR, 'none')))
END AS "7 crack data fresh"
;

SELECT CASE WHEN (SELECT max(week_start) FROM stg.week_calendar)
                 - coalesce((SELECT max(week_start) FROM stg.retail_eu_weekly), DATE '1900-01-01') > 14
  THEN error(format('verify 7b: EU retail data stale - calendar ends {}, last observation {}',
                    coalesce((SELECT max(week_start) FROM stg.week_calendar)::VARCHAR, 'none'),
                    coalesce((SELECT max(week_start) FROM stg.retail_eu_weekly)::VARCHAR, 'none')))
END AS "7b EU retail data fresh"
;

-- ---------------------------------------------------------------------------
-- 13. Ingen publicerad veckopunkt får vila på för få handelsdagar.
--
--     Räknas om ur stg.spot_daily, inte ur den GROUP BY som byggde raden. Det
--     är hela skillnaden mellan en kontroll och en tautologi: filtrerar man i
--     40_cracks.sql OCH kontrollerar samma filter här kan kontrollen aldrig
--     fälla, vilket den här pipelinen redan råkat ut för tre gånger.
--
--     Bakgrund: veckan 2026-08-10 publicerades som 86,28 = (84,16 + 88,39) / 2,
--     två av fem handelsdagar, mitt under en brant uppgång.
-- ---------------------------------------------------------------------------
WITH published AS (
  SELECT week_start, 'EER_EPD2DXL0_PF4_Y35NY_DPG' AS series_id, ulsd_usd_per_gal AS value
  FROM stg.legs_weekly
  UNION ALL SELECT week_start, 'RBRTE', brent_usd_per_bbl FROM stg.legs_weekly
  UNION ALL SELECT week_start, 'RWTC',  wti_usd_per_bbl   FROM stg.legs_weekly
),
coverage AS (
  SELECT date_trunc('week', obs_date)::DATE AS week_start, series_id, count(value) AS n
  FROM stg.spot_daily GROUP BY 1, 2
),
thin AS (
  SELECT p.week_start, p.series_id, coalesce(c.n, 0) AS n
  FROM published p
  LEFT JOIN coverage c USING (week_start, series_id)
  WHERE p.value IS NOT NULL
    AND coalesce(c.n, 0) < (SELECT min_week_obs FROM stg.build_meta)
)
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 13: {} published weekly leg(s) rest on fewer than {} daily '
                    'observations (first: {} {}, {} obs) - a partial week must publish as NULL',
                    count(*), coalesce((SELECT min_week_obs FROM stg.build_meta)::VARCHAR, 'unset'),
                    coalesce(min(week_start)::VARCHAR, 'none'),
                    coalesce((SELECT series_id FROM thin ORDER BY week_start, series_id LIMIT 1), 'none'),
                    coalesce((SELECT n FROM thin ORDER BY week_start, series_id LIMIT 1)::VARCHAR, 'none')))
END AS "13 weekly legs have enough daily coverage"
FROM thin;

-- ---------------------------------------------------------------------------
-- 14. 7-dagarslinjalen är vad den utger sig för.
--
--     Räknas om med en korrelerad delfråga i stället för med samma fönster som
--     byggde tabellen — annars vore det samma uttryck jämfört med sig självt.
--     Både värdet och tröskeln prövas: en punkt som borde saknas men finns är
--     lika fel som en som finns men är fel.
-- ---------------------------------------------------------------------------
--     FULL OUTER JOIN, inte FROM crack_daily_ma: drevs jämförelsen från
--     ma-tabellen kunde en rad som saknas DÄR aldrig jämföras mot något, och
--     exporten kryssjoinar ändå dagsaxeln så att den blir en null vid oförändrad
--     arraylängd — check 17 ser den alltså inte heller. Nu fälls både en punkt
--     som saknas och en föräldralös punkt utan motsvarande dag.
WITH recomputed AS (
  SELECT
    coalesce(d.obs_date, m.obs_date)     AS obs_date,
    coalesce(d.series_key, m.series_key) AS series_key,
    m.usd_per_bbl                        AS published,
    d.obs_date IS NULL                   AS orphan,
    (SELECT AVG(x.usd_per_bbl) FROM stg.crack_daily x
      WHERE x.series_key = coalesce(d.series_key, m.series_key)
        AND x.obs_date > coalesce(d.obs_date, m.obs_date) - INTERVAL 7 DAY
        AND x.obs_date <= coalesce(d.obs_date, m.obs_date))  AS expected,
    (SELECT count(x.usd_per_bbl) FROM stg.crack_daily x
      WHERE x.series_key = coalesce(d.series_key, m.series_key)
        AND x.obs_date > coalesce(d.obs_date, m.obs_date) - INTERVAL 7 DAY
        AND x.obs_date <= coalesce(d.obs_date, m.obs_date))  AS n
  FROM stg.crack_daily d
  FULL OUTER JOIN stg.crack_daily_ma m USING (obs_date, series_key)
),
bad AS (
  SELECT * FROM recomputed
  WHERE orphan
     OR (n >= (SELECT min_week_obs FROM stg.build_meta)
         AND (published IS NULL OR abs(published - expected) > 1e-9))
     OR (n <  (SELECT min_week_obs FROM stg.build_meta) AND published IS NOT NULL)
)
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 14: {} of {} MA7 point(s) do not equal the trailing 7-day mean '
                    '(first: {} {}, published {}, expected {}, {} obs in window)',
                    count(*), (SELECT count(*) FROM recomputed),
                    coalesce((SELECT obs_date   FROM bad ORDER BY obs_date, series_key LIMIT 1)::VARCHAR, 'none'),
                    coalesce((SELECT series_key FROM bad ORDER BY obs_date, series_key LIMIT 1), 'none'),
                    -- published och expected är NULL i just de fall kontrollen
                    -- finns för: en punkt som inte borde finnas, och en serie
                    -- utan observationer i fönstret.
                    coalesce((SELECT round(published, 4) FROM bad ORDER BY obs_date, series_key LIMIT 1)::VARCHAR, 'null'),
                    coalesce((SELECT round(expected, 4)  FROM bad ORDER BY obs_date, series_key LIMIT 1)::VARCHAR, 'null'),
                    coalesce((SELECT n FROM bad ORDER BY obs_date, series_key LIMIT 1)::VARCHAR, 'none')))
END AS "14 MA7 equals the trailing 7-day mean"
FROM bad;

-- ---------------------------------------------------------------------------
-- 15. Dagsaxeln är strikt stigande och utan dubbletter.
--
--     Den är inte en kalender utan en lista över observerade datum, så check 1:s
--     kontinuitetsresonemang gäller inte. Det som däremot måste hålla är att en
--     dag förekommer en gång: en dubblett skulle förskjuta varje values[] mot
--     axeln och rita hela diagrammet fel utan att något ser tomt ut.
-- ---------------------------------------------------------------------------
SELECT CASE WHEN count(*) > 0
  THEN error(format('verify 15: {} duplicate date(s) on the daily axis', count(*)))
END AS "15 daily axis is unique"
FROM (SELECT 1 FROM stg.day_axis GROUP BY obs_date HAVING count(*) > 1);

-- ---------------------------------------------------------------------------
-- 16. Dagsdatan är färsk.
--
--     Här, inte i check 7, är färskheten meningsfull: dagsserien slutar på EIA:s
--     sista publicerade dag utan utjämning emellan. EIA ligger normalt ~8 dagar
--     efter, så 20 dagar ger gott om marginal för en helg plus en sen
--     publicering, men fäller en källa som slutat leverera.
--
--     Grindad på strict av samma skäl som check 7: fixtures är en fryst
--     ögonblicksbild.
-- ---------------------------------------------------------------------------
SELECT CASE WHEN coalesce((SELECT strict FROM stg.build_meta), true)
                 AND current_date - coalesce((SELECT max(obs_date) FROM stg.crack_daily
                                              WHERE usd_per_bbl IS NOT NULL),
                                             DATE '1900-01-01') > 20
  THEN error(format('verify 16: daily crack data stale - today {}, last observation {}',
                    current_date::VARCHAR,
                    coalesce((SELECT max(obs_date) FROM stg.crack_daily
                              WHERE usd_per_bbl IS NOT NULL)::VARCHAR, 'none')))
END AS "16 daily crack data fresh"
;

SELECT 'alla invarianter gröna' AS verify;
