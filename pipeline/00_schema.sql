-- 00_schema.sql — extensions, build metadata and country reference.
--
-- The week axis is NOT here; it lives in pipeline/25_calendar.sql. See below.
--
-- Variables this file reads (set by run.sh's generated preamble):
--   strict        whether the freshness invariants are fatal for this build
--   min_week_obs  minimum daily observations behind a published week AND behind
--                 a point on the 7-day mean — run.sh sets one value for both so
--                 the two rules cannot drift apart
--
-- work_dir and start_week are absent on purpose: they belong to the scripts that
-- read the sources, not to this one. start_week in particular is the week axis's
-- lower bound, and the axis is built in 25_calendar.sql. Three attempts at a
-- fuller map of which script reads which variable were each wrong in a new way;
-- the list above is what this file reads, and a grep is a better answer than a
-- prose summary maintained by hand. It needs both spellings:
--
--   grep -rE "getvariable|build_meta" pipeline/
--
-- strict and min_week_obs are read downstream OUT OF stg.build_meta, not through
-- getvariable() — that is the whole point of recording them here — so grepping
-- for getvariable alone finds only this file and makes them look unused.

INSTALL json;   LOAD json;
INSTALL excel;  LOAD excel;

-- Everything staging lives in one schema so 50_export.sql can be read without
-- wondering which tables are inputs and which are products.
CREATE SCHEMA IF NOT EXISTS stg;

-- Strictness is recorded in the database at build time, not read from the
-- variable at check time. --verify-only re-runs the invariants against a
-- database an earlier invocation built, so deriving it from the current
-- invocation's mode would fail a fixtures build the moment it was re-verified.
CREATE OR REPLACE TABLE stg.build_meta AS
-- coalesce to true: an unset variable yields NULL, and `CASE WHEN NULL AND ...`
-- is NULL, which reports green. The default has to be "do check it" — this is
-- the same fail-open-on-NULL class the export checks close with IS DISTINCT FROM.
SELECT coalesce(getvariable('strict')::BOOLEAN, true) AS strict,
       -- min_week_obs har ingen säker default. Ett för högt värde tömmer
       -- veckoserien, ett för lågt återinför det fel hela feature 003 finns för
       -- — och NULL gör check 13 och 14 tysta, eftersom n >= NULL är NULL och
       -- CASE faller igenom till grönt. Alltså: dö högljutt i stället för att
       -- gissa. Läses härifrån och inte via getvariable() i varje fil, så att en
       -- handkörd `duckdb -f pipeline/verify.sql` utan preamble inte kan
       -- rapportera två invarianter gröna som inte kan fälla.
       CASE WHEN getvariable('min_week_obs') IS NULL
            THEN error('min_week_obs är inte satt — se preamblen i pipeline/run.sh')
            ELSE getvariable('min_week_obs')::INTEGER END AS min_week_obs,
       -- Byggdagen, fryst. 25_calendar.sql sätter axelns gräns utifrån den och
       -- verify 1e kontrollerar gränsen mot samma värde, så de två kan inte
       -- glida isär. Läses inte ur current_date vid kontrolltillfället:
       -- --verify-only kör invarianterna mot en databas som byggdes en annan
       -- dag, och då hade 1e fällt en helt korrekt axel för att kalendern hunnit
       -- vidare. Färskhet mäts av check 7/16, som är till för just det.
       current_date AS built_on;

-- Veckoaxeln byggs INTE här. Dess övre gräns beror på vad källorna faktiskt
-- publicerat, och de är inte inlästa förrän 10/15/20 har körts — se
-- pipeline/25_calendar.sql. Att den låg här och bara läste current_date var
-- skälet till att en publicerad retailvecka kunde kastas i upp till sju dagar.

-- ---------------------------------------------------------------------------
-- EU-27
--
-- Explicit membership, never inferred from whichever columns the Oil Bulletin
-- workbook happens to carry: its history also contains UK, plus EU_ and EUR_
-- aggregate columns that look exactly like country prefixes. Deriving the list
-- would silently add three "countries" to every chart.
--
-- Codes are the Bulletin's own (note GR for Greece, not the EL that Eurostat
-- uses). is_focus drives the emphasised line in the frontend — one country, and
-- not hard-coded on the far side of the JSON contract.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.eu27 (cc VARCHAR, name_en VARCHAR, is_focus BOOLEAN);
INSERT INTO stg.eu27 VALUES
  ('AT','Austria',false),        ('BE','Belgium',false),
  ('BG','Bulgaria',false),       ('HR','Croatia',false),
  ('CY','Cyprus',false),         ('CZ','Czechia',false),
  ('DK','Denmark',false),        ('EE','Estonia',false),
  ('FI','Finland',false),        ('FR','France',false),
  ('DE','Germany',false),        ('GR','Greece',false),
  ('HU','Hungary',false),        ('IE','Ireland',false),
  ('IT','Italy',false),          ('LV','Latvia',false),
  ('LT','Lithuania',false),      ('LU','Luxembourg',false),
  ('MT','Malta',false),          ('NL','Netherlands',false),
  ('PL','Poland',false),         ('PT','Portugal',false),
  ('RO','Romania',false),        ('SK','Slovakia',false),
  ('SI','Slovenia',false),       ('ES','Spain',false),
  ('SE','Sweden',true);
