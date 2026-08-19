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

# Härlett, inte hårdkodat: run.sh:s guard lovar att OUT_DIR är enda ratten, och
# ett test som duplicerar sökvägen gör tre falska diagnoser av en korrekt
# omkonfiguration — i just den fil vars syfte är att inget ska rapportera fel sak.
OUT_REL=$(sed -n 's|^OUT_DIR="\$ROOT/\(.*\)"$|\1|p' pipeline/run.sh)
SRC_JSON="$ROOT/$OUT_REL"

die() { echo "FEL: $*" >&2; exit 2; }

# Varje förutsättning kontrolleras med egen diagnos. Utan detta blir ett saknat
# python3 tio rader "did not fail at all" — alltså exakt den falskt gröna
# rapporten filen finns för att omöjliggöra.
[ -n "$OUT_REL" ]              || die "kunde inte läsa OUT_DIR ur pipeline/run.sh"
[ -f "$SRC_DB" ]               || die "$SRC_DB saknas — kör pipeline/run.sh --fixtures först"
[ -f "$SRC_JSON/cracks.json" ] || die "$SRC_JSON/cracks.json saknas — kör pipeline/run.sh --fixtures först"
[ -f "$SRC_JSON/retail.json" ] || die "$SRC_JSON/retail.json saknas"
[ -f "$SRC_JSON/fx.json" ]     || die "$SRC_JSON/fx.json saknas"
[ -f "$SRC_JSON/cracks_daily.json" ] || die "$SRC_JSON/cracks_daily.json saknas"
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
SET VARIABLE min_week_obs = 3;
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

# format() ger NULL om något argument är NULL, och error(NULL) kastar inte. En
# HELT tom crack_weekly gör max(week_start) NULL, och före härdningen rapporterade
# check 7 då grönt på den värsta tänkbara datan. Provet ovan tömmer bara delvis
# och kunde därför inte se det.
expect_fail "crack_weekly emptied entirely (error(NULL))" "verify 7" \
  "UPDATE stg.build_meta SET strict = true;
   DELETE FROM stg.crack_weekly;" verify

# 7b:s NULL-gren har medvetet inget prov: den enda datan som gör
# max(week_start) NULL är en tom retail_eu_weekly, och då fäller check 3 först
# och med rätta. Härdningen av 7b står kvar ändå — den kostar ingenting och
# check 3 kan komma att flyttas.

# --- täckning, linjal och dagsaxel -------------------------------------------
#
# Check 13 räknar om täckningen ur stg.spot_daily i stället för ur den GROUP BY
# som byggde stg.legs_weekly. Korruptionen nedan utnyttjar precis det: den tar
# bort handelsdagar UNDER en publicerad vecka och lämnar veckovärdet kvar. Hade
# kontrollen läst samma aggregat som produktionen hade den inte kunnat fälla —
# vilket är hela skälet till att den inte gör det.
expect_fail "a published week loses its trading days" "verify 13" \
  "DELETE FROM stg.spot_daily
    WHERE date_trunc('week', obs_date) = DATE '2023-06-05'
      AND obs_date > DATE '2023-06-06';" verify

# Linjalen måste vara det den utger sig för. Två felriktningar, båda prövade:
expect_fail "MA7 no longer equals its window" "verify 14" \
  "UPDATE stg.crack_daily_ma SET usd_per_bbl = usd_per_bbl + 5
    WHERE obs_date = DATE '2023-06-07';" verify

# ... och en punkt som borde SAKNAS men finns: de första dagarna har för få
# observationer i fönstret, och ett medelvärde av en enda punkt vore bara
# dagslinjen ritad med tjockare penna.
expect_fail "MA7 emitted where the window is too thin" "verify 14" \
  "UPDATE stg.crack_daily_ma SET usd_per_bbl = 50.0
    WHERE obs_date = (SELECT min(obs_date) FROM stg.crack_daily_ma);" verify

expect_fail "a day appears twice on the daily axis" "verify 15" \
  "INSERT INTO stg.day_axis SELECT min(obs_date) FROM stg.day_axis;" verify

# Dagsserien är där färskhet faktiskt mäts — veckoserien slutar regelmässigt en
# vecka tidigt av konstruktion, så check 7 kan inte göra det jobbet.
expect_fail "daily data gone stale (strict build)" "verify 16" \
  "UPDATE stg.build_meta SET strict = true;
   DELETE FROM stg.crack_daily    WHERE obs_date > DATE '2024-01-01';
   DELETE FROM stg.crack_daily_ma WHERE obs_date > DATE '2024-01-01';" verify

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

expect_fail "a cracks_daily series truncated" "verify 17" \
  '!python3 -c "import json;d=json.load(open(\"cracks_daily.json\"));d[\"series\"][0][\"values\"]=d[\"series\"][0][\"values\"][:100];json.dump(d,open(\"cracks_daily.json\",\"w\"))"' export

# En verklig serie tömd är inte ICE-stubben och får inte omfattas av undantaget.
expect_fail "daily brent emptied (not the ICE stub)" "verify 17" \
  '!python3 -c "import json;d=json.load(open(\"cracks_daily.json\"));[s.update(values=[]) for s in d[\"series\"] if s[\"key\"]==\"brent\"];json.dump(d,open(\"cracks_daily.json\",\"w\"))"' export

# En omkastad dag ändrar ingen arraylängd — bara vilket datum varje värde hör
# till. Utan check 18 ritas fel år utan att något ser tomt ut.
expect_fail "the daily axis goes backwards" "verify 18" \
  '!python3 -c "import json;d=json.load(open(\"cracks_daily.json\"));d[\"days\"][5],d[\"days\"][6]=d[\"days\"][6],d[\"days\"][5];json.dump(d,open(\"cracks_daily.json\",\"w\"))"' export

# Dagsfilen får inte bära en veckoaxel: check 12 jämför weeks[] mellan filerna,
# och en dagsfil med weeks[] hade antingen fällt den eller, värre, passerat och
# fått frontend att indexera dagsvärden mot veckor.
expect_fail "daily file grows a weeks axis" "verify 8" \
  '!python3 -c "import json;d=json.load(open(\"cracks_daily.json\"));d[\"weeks\"]=d[\"days\"];json.dump(d,open(\"cracks_daily.json\",\"w\"))"' export

expect_fail "week axes disagree" "verify 12" \
  '!python3 -c "import json;d=json.load(open(\"fx.json\"));d[\"weeks\"]=[\"1999-01-04\"]+d[\"weeks\"][1:];json.dump(d,open(\"fx.json\",\"w\"))"' export

# --- the export/verify coupling guard ----------------------------------------
#
# check-export-paths.sh is shell, not SQL, so it needs its own cases — and it
# needs them for the same reason as everything above: it replaced an invariant
# that was reverted, and an untested guard is how the inert checks got in.

# $5 = förväntat textfragment i felet. Utan det är guardens två felgrenar
# omöjliga att skilja åt, och en ny gren kan passera på en annans exitkod —
# vilket är precis den förväxling grenen lades till för att ta bort.
guard() {  # $1 = namn, $2 = "fail"|"pass", $3 = out_dir, $4 = export-sql, $5 = text
  local name="$1" want="$2" want_msg="${5:-}" out
  # Ett tomt mönster matchar all utdata, vilket tyst degraderar provet till en
  # ren exitkodskontroll — samma tysta no-op som cmp- och korruptionsvakterna
  # ovan finns för att stänga.
  [ "$want" != "fail" ] || [ -n "$want_msg" ] \
    || die "guard '$name': förväntat felmeddelande saknas"
  if out=$(pipeline/check-export-paths.sh "$ROOT" "$3" "$4" 2>&1); then
    if [ "$want" = "pass" ]; then
      printf 'ok    %-44s -> stays green\n' "$name"; pass=$((pass+1))
    else
      printf 'FAIL  %-44s did not fail at all\n' "$name"; fail=$((fail+1))
    fi
  elif [ "$want" != "fail" ]; then
    printf 'FAIL  %-44s should have stayed green\n' "$name"; fail=$((fail+1))
  elif ! printf '%s' "$out" | grep -qF "$want_msg"; then
    printf 'FAIL  %-44s failed, but not with "%s"\n      got: %s\n' \
      "$name" "$want_msg" "$(printf '%s' "$out" | head -1)"; fail=$((fail+1))
  else
    printf 'ok    %-44s -> %s\n' "$name" "$want_msg"; pass=$((pass+1))
  fi
}

sed "s|TO '$OUT_REL/retail.json'|TO 'nagon/annan/retail.json'|" \
  pipeline/50_export.sql > "$TMP/export_moved.sql"
# Samma krav som på korruptionerna ovan: en sed som slutat matcha gör provet
# till en kopia, och "did not fail at all" skulle då skyllas på guarden i
# stället för på en förlegad testfixtur.
[ -s "$TMP/export_moved.sql" ] \
  || die "sed gav en tom export_moved.sql — kontrollera OUT_REL och sed-uttrycket"
cmp -s pipeline/50_export.sql "$TMP/export_moved.sql" \
  && die "sed-mönstret matchade inte längre — COPY-målet i 50_export.sql har bytt form"

guard "export paths as shipped"         pass "$SRC_JSON"         pipeline/50_export.sql
guard "one COPY target redirected"      fail "$SRC_JSON"         "$TMP/export_moved.sql"      "utanför"
guard "out_dir moved, export unchanged" fail "$ROOT/nagon/annan" pipeline/50_export.sql       "nagon/annan/"
guard "export sql does not exist"       fail "$SRC_JSON"         "$TMP/ingen_sadan_fil.sql"   "finns inte"

# Målen läses numera UR filen. En fil utan COPY-mål får då inte passera tyst —
# det vore en guard som godkänner allt, vilket är värre än ingen guard.
printf -- "-- inga COPY-mål alls\n" > "$TMP/export_tom.sql"
guard "export sql has no COPY targets" fail "$SRC_JSON"         "$TMP/export_tom.sql"        "inga COPY"

# --- the fetch retry logic ---------------------------------------------------
#
# The argument for the guard above applies to the retry too: the properties this
# repo just restored — the status comes from LAST_CODE rather than accumulated
# -w output, and a 429/5xx re-runs while a 403 does not — were asserted only by
# a commit message. A stub curl earlier on PATH makes them cheap to check.

fetch_case() {  # $1 = namn, $2 = koder stubben ska ge i tur och ordning,
                # $3 = förväntat "ok"/"fail", $4 = förväntad LAST_CODE,
                # $5 = förväntat antal anrop, $6 = funktion (default eia_get)
  local name="$1" codes="$2" want="$3" want_code="$4" want_calls="$5" fn="${6:-eia_get}"

  local d="$TMP/stub"; rm -rf "$d"; mkdir -p "$d"
  printf '%s\n' "$codes" > "$d/codes"
  cat > "$d/curl" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
n=$(cat "$d/calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$d/calls"
code=$(sed -n "${n}p" "$d/codes"); [ -n "$code" ] || code=$(tail -1 "$d/codes")
[ "$code" = "NET" ] && exit 7      # nätverksfel: curl misslyckas, ingen -w-utskrift
printf '%s' "$code"
STUB
  chmod +x "$d/curl"

  local out rc code calls
  out=$(
    PATH="$d:$PATH"
    RETRY_FATAL=0; LAST_CODE=""
    # sleep stubbas bort: provet ska inte kosta 28 s backoff.
    sleep() { :; }
    . pipeline/lib/fetch.sh
    retry "stub" "$fn" "http://x" "$TMP/stub_out" >/dev/null 2>&1
    printf '%s|%s' "$?" "$LAST_CODE"
  )
  rc="${out%%|*}"; code="${out##*|}"
  calls=$(cat "$d/calls" 2>/dev/null || echo 0)

  local got="fail"; [ "$rc" = "0" ] && got="ok"
  if [ "$got" = "$want" ] && [ "$code" = "$want_code" ] && [ "$calls" = "$want_calls" ]; then
    printf 'ok    %-44s -> %s, LAST_CODE=%s, %s anrop\n' "$name" "$got" "$code" "$calls"
    pass=$((pass+1))
  else
    printf 'FAIL  %-44s -> %s/%s/%s, väntade %s/%s/%s\n' \
      "$name" "$got" "$code" "$calls" "$want" "$want_code" "$want_calls"
    fail=$((fail+1))
  fi
}

#            namn                                    koder        utfall  kod  anrop
fetch_case "200 first time"                          "200"        ok   200 1
# Regressionen: koden får inte bli "503200".
fetch_case "503 then 200 (transient, retried)"       "503
200"        ok   200 2
fetch_case "429 then 200 (rate limit, retried)"      "429
200"        ok   200 2
fetch_case "network error then 200"                  "NET
200"        ok   200 2
fetch_case "403 is permanent, not retried"           "403
200"        fail 403 1
fetch_case "404 is permanent, not retried"           "404"        fail 404 1
fetch_case "503 throughout gives up after 4"         "503"        fail 503 4

# De riktiga funktionerna, inte http_get direkt: poängen är att fetch_ecb och
# fetch_oilbulletin GÅR genom http_get. Ett prov som anropar http_get självt
# förblir grönt om någon av dem återgår till curl --fail, alltså bevisar det
# ingenting om just den ändringen.
real_fetch_case() {  # $1 = namn, $2 = funktion, $3 = koder, $4 = förväntat antal anrop
  local name="$1" fn="$2" codes="$3" want_calls="$4"
  local d="$TMP/stub"; rm -rf "$d"; mkdir -p "$d"
  printf '%s\n' "$codes" > "$d/codes"
  cat > "$d/curl" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
n=$(cat "$d/calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$d/calls"
code=$(sed -n "${n}p" "$d/codes"); [ -n "$code" ] || code=$(tail -1 "$d/codes")
# --fail måste modelleras, annars är stubben inte curl: med --fail avslutar
# curl med 22 för varje HTTP >= 400 och skriver ingen -w-sträng. Utan detta
# passerar ett 404-prov mot en --fail-implementation av fel skäl.
for a in "$@"; do
  if [ "$a" = "--fail" ] && [ "$code" -ge 400 ] 2>/dev/null; then exit 22; fi
done
printf '%s' "$code"
STUB
  chmod +x "$d/curl"
  # duckdb stubbas: fetch_ecb räknar fram sitt startdatum med den.
  printf '#!/bin/sh\necho 2021-12-20\n' > "$d/duckdb"; chmod +x "$d/duckdb"

  # die() avslutar subskalet; räknaren ligger i fil och överlever.
  (
    PATH="$d:$PATH"
    WORK="$TMP/data"; START_WEEK="2022-01-03"
    ECB_BASE="http://x"; ECB_CURRENCIES="USD"
    OB_URL="http://x"; OB_FILE="ob.xlsx"; OB_PAGE="http://x"
    sleep() { :; }
    . pipeline/lib/fetch.sh
    "$fn"
  ) >/dev/null 2>&1

  local calls; calls=$(cat "$d/calls" 2>/dev/null || echo 0)
  if [ "$calls" = "$want_calls" ]; then
    printf 'ok    %-44s -> %s anrop\n' "$name" "$calls"; pass=$((pass+1))
  else
    printf 'FAIL  %-44s -> %s anrop, väntade %s\n' "$name" "$calls" "$want_calls"; fail=$((fail+1))
  fi
}

real_fetch_case "fetch_ecb: 404 is permanent"         fetch_ecb         "404" 1
real_fetch_case "fetch_ecb: 503 retried then gives up" fetch_ecb        "503" 4
real_fetch_case "fetch_oilbulletin: rotated UUID (404)" fetch_oilbulletin "404" 1

# --- key resolution ----------------------------------------------------------
#
# En företrädesordning som bara står i README är en regel som kan kastas om utan
# att något blir rött. CI kör dessutom på ubuntu, där security(1) inte finns, så
# nyckelringsgrenen är död där om den inte drivs av en stubbe.

key_case() {  # $1 = namn, $2 = env, $3 = keychain ("-" = ingen security), $4 = .env, $5 = väntat
  local name="$1" env_key="$2" kc="$3" file_key="$4" want="$5"
  local d="$TMP/keystub"; rm -rf "$d"; mkdir -p "$d"
  if [ "$kc" != "-" ]; then
    if [ -n "$kc" ]; then printf '#!/bin/sh\nprintf %s "%s"\n' '%s' "$kc" > "$d/security"
    else printf '#!/bin/sh\nexit 44\n' > "$d/security"; fi
    chmod +x "$d/security"
  fi

  local got
  got=$(
    # PATH utan systemets /usr/bin när vi vill simulera att security saknas.
    if [ "$kc" = "-" ]; then PATH="$d"; else PATH="$d:$PATH"; fi
    export PATH
    . pipeline/lib/key.sh
    resolve_eia_key "$env_key" "$file_key"
  )

  if [ "$got" = "$want" ]; then
    printf 'ok    %-44s -> %s\n' "$name" "${got:-(tom)}"; pass=$((pass+1))
  else
    printf 'FAIL  %-44s -> %s, väntade %s\n' "$name" "${got:-(tom)}" "${want:-(tom)}"; fail=$((fail+1))
  fi
}

#         namn                                      env      keychain  .env     väntat
key_case "environment wins over everything"        ENVKEY   KCKEY     FILEKEY  ENVKEY
key_case "keychain beats .env"                     ""       KCKEY     FILEKEY  KCKEY
key_case "keychain miss falls through to .env"     ""       ""        FILEKEY  FILEKEY
key_case "no security(1) at all falls to .env"     ""       "-"       FILEKEY  FILEKEY
key_case "nothing anywhere yields empty"           ""       ""        ""       ""
key_case "keychain alone"                          ""       KCKEY     ""       KCKEY

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
