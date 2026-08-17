#!/usr/bin/env bash
#
# negative.sh — assert that the invariants can actually fail.
#
# This exists because three consecutive commits shipped invariants that were
# structurally incapable of firing: first the uniqueness checks asserted on
# tables whose own GROUP BY produced the key, then they moved to the raw tables
# but kept the raw key (so two publications in the same week passed), then four
# export checks returned green on NULL input. Every one was caught by review,
# none by the build — because the build only ever exercised the happy path.
#
# A check that cannot fail is worse than no check: it reports green and is
# believed. So each case below corrupts one input and asserts the run exits
# non-zero AND that stderr names the expected check.
#
# Operates entirely on copies in a scratch directory; the real database and the
# published JSON are never touched.
#
# Requires a prior build:  pipeline/run.sh --fixtures
# Run:                     pipeline/test/negative.sh

set -uo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
SRC_DB="$ROOT/data/work/crack.duckdb"
SRC_JSON="$ROOT/site/public/data"

die() { echo "FEL: $*" >&2; exit 2; }

# Varje förutsättning kontrolleras med egen diagnos. Utan detta blir ett saknat
# python3 tio rader "did not fail at all" — alltså exakt den falskt gröna
# rapporten filen finns för att omöjliggöra.
[ -f "$SRC_DB" ]               || die "$SRC_DB saknas — kör pipeline/run.sh --fixtures först"
[ -f "$SRC_JSON/cracks.json" ] || die "$SRC_JSON/cracks.json saknas — kör pipeline/run.sh --fixtures först"
[ -f "$SRC_JSON/retail.json" ] || die "$SRC_JSON/retail.json saknas"
[ -f "$SRC_JSON/fx.json" ]     || die "$SRC_JSON/fx.json saknas"
command -v python3 >/dev/null  || die "python3 krävs för JSON-korruptionerna"
command -v duckdb  >/dev/null  || die "duckdb krävs"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/data"

pass=0; fail=0

# Skrivs en gång, inte per prov: ett prov som råkar köra först ska inte avgöra
# om filen finns.
cat > "$TMP/pre.sql" <<SQL
.bail on
SET VARIABLE work_dir   = '$ROOT/data/work';
SET VARIABLE manual_dir = '$ROOT/data/manual';
SET VARIABLE start_week = '2022-01-03';
SET VARIABLE generated  = '1970-01-01';
SET VARIABLE strict     = true;
SET VARIABLE out_dir    = '$TMP/data';
SQL

# Återställer en orörd kopia av databasen och de publicerade filerna.
reset_copy() {
  cp "$SRC_DB" "$TMP/t.duckdb"
  rm -rf "$TMP/data"; mkdir -p "$TMP/data"
  cp "$SRC_JSON"/*.json "$TMP/data/"
}

# Kör korruptionen och KRÄVER att den lyckades. En korruption som felar lämnar
# kopian orörd; expect_fail skulle då rapportera "did not fail at all" och
# expect_pass skulle rapportera grönt — av fel skäl. Det är precis det
# felläget den här filen finns för att stänga, så det kontrolleras här.
apply_corruption() {  # $1 = korruption, "!" -> skal mot JSON, annars SQL
  local corrupt="$1"
  if [ "${corrupt:0:1}" = "!" ]; then
    ( cd "$TMP/data" && eval "${corrupt:1}" )
  else
    duckdb "$TMP/t.duckdb" -c "$corrupt" >/dev/null
  fi
}

run_checks() {  # $1 = "verify" | "export"
  local script="pipeline/verify.sql"
  [ "$1" = "export" ] && script="pipeline/60_verify_export.sql"
  duckdb "$TMP/t.duckdb" -f "$TMP/pre.sql" -f "$script" 2>&1
}

# $1 = case name, $2 = expected check ("verify 7"), $3 = corruption,
# $4 = which script ("verify" | "export")
expect_fail() {
  local name="$1" want="$2" corrupt="$3" which="$4" out rc

  reset_copy
  if ! out=$(apply_corruption "$corrupt" 2>&1); then
    printf 'FAIL  %-44s corruption itself failed: %s\n' "$name" "$(printf '%s' "$out" | head -1)"
    fail=$((fail+1)); return
  fi

  out=$(run_checks "$which"); rc=$?

  if [ $rc -eq 0 ]; then
    printf 'FAIL  %-44s did not fail at all\n' "$name"; fail=$((fail+1))
  # Kolon i mönstret: annars matchar "verify 1" även verify 10/11/12 och
  # "verify 7" även 7b, och ett prov kan börja passera på fel kontroll.
  elif ! printf '%s' "$out" | grep -q "$want:"; then
    printf 'FAIL  %-44s failed, but not with "%s:"\n      got: %s\n' \
      "$name" "$want" "$(printf '%s' "$out" | grep -m1 -E 'Error|verify [0-9]' || printf '%s' "$out" | head -1)"
    fail=$((fail+1))
  else
    printf 'ok    %-44s -> %s\n' "$name" "$want"; pass=$((pass+1))
  fi
}

# Motsatsen: en korruption som med flit INTE ska fälla. Samma krav på att
# korruptionen faktiskt gick igenom — annars vore grönt meningslöst.
expect_pass() {
  local name="$1" corrupt="$2" which="$3" out

  reset_copy
  if ! out=$(apply_corruption "$corrupt" 2>&1); then
    printf 'FAIL  %-44s corruption itself failed: %s\n' "$name" "$(printf '%s' "$out" | head -1)"
    fail=$((fail+1)); return
  fi

  if run_checks "$which" >/dev/null 2>&1; then
    printf 'ok    %-44s -> stays green\n' "$name"; pass=$((pass+1))
  else
    printf 'FAIL  %-44s should have stayed green\n' "$name"; fail=$((fail+1))
  fi
}

echo "negativa prov — varje invariant måste kunna fälla:"

# --- staging -----------------------------------------------------------------

expect_fail "week calendar gap" "verify 1" \
  "DELETE FROM stg.week_calendar WHERE week_start = DATE '2023-06-05';" verify

expect_fail "EIA spot duplicated on one day" "verify 2a" \
  "INSERT INTO stg.spot_daily SELECT * FROM stg.spot_daily LIMIT 1;" verify

# Different DATES inside one ISO week — the case a (date, ...) key misses.
expect_fail "Oil Bulletin twice in one week" "verify 2b" \
  "INSERT INTO stg.ob_parsed VALUES (DATE '2026-08-12', 'SE', 'diesel', 'with', 1.70);" verify

expect_fail "EIA retail twice in one week" "verify 2c" \
  "INSERT INTO stg.retail_us_raw VALUES (DATE '2026-08-12', 'EMD_EPD2D_PTE_NUS_DPG', 'diesel', 4.1);" verify

expect_fail "an EU-27 member drops out" "verify 3" \
  "DELETE FROM stg.retail_eu_weekly WHERE cc = 'PT';" verify

# The exchange-rate trap: Oil Bulletin prices are already EUR.
expect_fail "SE prices divided by an FX rate" "verify 4" \
  "UPDATE stg.retail_eu_weekly SET eur_per_l = eur_per_l / 11.0 WHERE cc = 'SE';" verify

# The dropped x42: ULSD USD/gal minus Brent USD/bbl lands around -60.
expect_fail "crack missing the 42 gal/bbl factor" "verify 5" \
  "UPDATE stg.crack_weekly SET usd_per_bbl = usd_per_bbl - 100 WHERE region = 'US';" verify

expect_fail "FX hole in one week" "verify 6" \
  "DELETE FROM stg.fx_weekly WHERE ccy = 'SEK' AND week_start = DATE '2024-03-04';" verify

# strict lives in build_meta, not in the variable — that is the point of it,
# so a strict build has to be simulated in the copy rather than in the preamble.
expect_fail "crack data gone stale (strict build)" "verify 7" \
  "UPDATE stg.build_meta SET strict = true;
   DELETE FROM stg.crack_weekly WHERE week_start > DATE '2026-01-01';" verify

# SRC_DB kommer från --fixtures, alltså strict=false. Utan detta vore de två
# 7b-proven identiska och 7b aldrig prövad på ett strikt bygge.
expect_fail "EU retail gone stale (strict build)" "verify 7b" \
  "UPDATE stg.build_meta SET strict = true;
   DELETE FROM stg.retail_eu_weekly WHERE week_start > DATE '2026-01-01';" verify

# 7b must fire even on a non-strict build: the Oil Bulletin is live in every mode.
expect_fail "EU staleness fires on a fixtures build" "verify 7b" \
  "UPDATE stg.build_meta SET strict = false;
   DELETE FROM stg.retail_eu_weekly WHERE week_start > DATE '2026-01-01';" verify

# The gate must work in both directions: silencing check 7 on a fixtures build is
# the whole reason it exists, so assert the silence too, not just the noise.
expect_pass "crack staleness silent on a fixtures build" \
  "UPDATE stg.build_meta SET strict = false;
   DELETE FROM stg.crack_weekly WHERE week_start > DATE '2026-01-01';" verify

# --- published JSON ----------------------------------------------------------

expect_fail "cracks.json meta removed" "verify 8" \
  '!python3 -c "import json;d=json.load(open(\"cracks.json\"));del d[\"meta\"];json.dump(d,open(\"cracks.json\",\"w\"))"' export

expect_fail "fx.json rates.USD null" "verify 8" \
  '!python3 -c "import json;d=json.load(open(\"fx.json\"));d[\"rates\"][\"USD\"]=None;json.dump(d,open(\"fx.json\",\"w\"))"' export

# Every element missing the key -> read_json infers no such field -> bind error
# unless check 8 catches it first.
expect_fail "retail.json series lose values" "verify 8" \
  '!python3 -c "import json;d=json.load(open(\"retail.json\"));[s.pop(\"values\") for s in d[\"series\"]];json.dump(d,open(\"retail.json\",\"w\"))"' export

expect_fail "cracks.json series emptied" "verify 8" \
  '!python3 -c "import json;d=json.load(open(\"cracks.json\"));d[\"series\"]=[];json.dump(d,open(\"cracks.json\",\"w\"))"' export

# A real series emptied is NOT the ICE stub and must not be exempt.
expect_fail "brent emptied (not the ICE stub)" "verify 9" \
  '!python3 -c "import json;d=json.load(open(\"cracks.json\"));[s.update(values=[]) for s in d[\"series\"] if s[\"key\"]==\"brent\"];json.dump(d,open(\"cracks.json\",\"w\"))"' export

expect_fail "a cracks series truncated" "verify 9" \
  '!python3 -c "import json;d=json.load(open(\"cracks.json\"));d[\"series\"][0][\"values\"]=d[\"series\"][0][\"values\"][:100];json.dump(d,open(\"cracks.json\",\"w\"))"' export

expect_fail "a retail series truncated" "verify 10" \
  '!python3 -c "import json;d=json.load(open(\"retail.json\"));d[\"series\"][0][\"values\"]=d[\"series\"][0][\"values\"][:100];json.dump(d,open(\"retail.json\",\"w\"))"' export

expect_fail "a null inside fx rates" "verify 11" \
  '!python3 -c "import json;d=json.load(open(\"fx.json\"));d[\"rates\"][\"SEK\"][5]=None;json.dump(d,open(\"fx.json\",\"w\"))"' export

expect_fail "week axes disagree" "verify 12" \
  '!python3 -c "import json;d=json.load(open(\"fx.json\"));d[\"weeks\"]=[\"1999-01-04\"]+d[\"weeks\"][1:];json.dump(d,open(\"fx.json\",\"w\"))"' export

# --- the export/verify coupling guard ----------------------------------------
#
# check-export-paths.sh is shell, not SQL, so it needs its own cases — and it
# needs them for the same reason as everything above: it replaced an invariant
# that was reverted, and an untested guard is how the inert checks got in.

guard() {  # $1 = namn, $2 = "fail"|"pass", $3 = out_dir, $4 = export-sql
  local name="$1" want="$2" out
  if out=$(pipeline/check-export-paths.sh "$ROOT" "$3" "$4" 2>&1); then
    if [ "$want" = "pass" ]; then
      printf 'ok    %-44s -> stays green\n' "$name"; pass=$((pass+1))
    else
      printf 'FAIL  %-44s did not fail at all\n' "$name"; fail=$((fail+1))
    fi
  else
    if [ "$want" = "fail" ]; then
      printf 'ok    %-44s -> %s\n' "$name" "$(printf '%s' "$out" | head -1 | cut -c1-58)"
      pass=$((pass+1))
    else
      printf 'FAIL  %-44s should have stayed green\n' "$name"; fail=$((fail+1))
    fi
  fi
}

sed "s|TO 'site/public/data/retail.json'|TO 'nagon/annan/retail.json'|" \
  pipeline/50_export.sql > "$TMP/export_moved.sql"

guard "export paths as shipped"          pass "$ROOT/site/public/data" pipeline/50_export.sql
guard "one COPY target redirected"       fail "$ROOT/site/public/data" "$TMP/export_moved.sql"
guard "out_dir moved, export unchanged"  fail "$ROOT/nagon/annan"      pipeline/50_export.sql

# --- the happy path must still be green --------------------------------------

reset_copy
if duckdb "$TMP/t.duckdb" -f "$TMP/pre.sql" \
     -f pipeline/verify.sql -f pipeline/60_verify_export.sql >/dev/null 2>&1; then
  printf 'ok    %-44s -> green\n' "uncorrupted build passes"; pass=$((pass+1))
else
  printf 'FAIL  %-44s uncorrupted build does not pass\n' "uncorrupted build passes"; fail=$((fail+1))
fi

echo
echo "$pass gröna, $fail röda"
[ "$fail" -eq 0 ]
