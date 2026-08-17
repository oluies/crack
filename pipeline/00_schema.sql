-- 00_schema.sql — extensions, week axis and country reference.
--
-- Variables (set by run.sh's generated preamble):
--   work_dir    directory holding the downloaded upstream files
--   start_week  first ISO-week Monday to publish

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
SELECT getvariable('strict')::BOOLEAN AS strict;

-- ---------------------------------------------------------------------------
-- Week axis
--
-- Every published series is left-joined onto this, so all charts share one axis
-- and a missing observation stays visible as a gap. date_trunc('week') is ISO in
-- DuckDB — Monday-based — which is what the sources publish against.
--
-- The upper bound is the last COMPLETE week. Today's week is still accumulating;
-- including it would render a two-day average as a dip. Excluded here, once,
-- rather than in every downstream script.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.week_calendar AS
SELECT UNNEST(generate_series(
         getvariable('start_week')::DATE,
         (date_trunc('week', current_date) - INTERVAL 7 DAY)::DATE,
         INTERVAL 7 DAY
       ))::DATE AS week_start;

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
