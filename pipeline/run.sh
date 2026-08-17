#!/usr/bin/env bash
#
# run.sh — the single entry point for the data pipeline.
#
# Downloads the upstream files, then hands them to DuckDB. Shell moves bytes and
# sequences scripts; every transformation lives in the SQL beside this file.
#
#   pipeline/run.sh                 fetch everything, build, verify, export
#   pipeline/run.sh --offline       reuse data/work/, no network
#   pipeline/run.sh --fixtures      build from data/fixtures/, no API key needed
#   pipeline/run.sh --verify-only   re-run the invariants against the existing db
#
# Requires: duckdb 1.5+, curl. EIA_API_KEY from the environment or .env.

set -euo pipefail

cd "$(dirname "$0")/.."          # repo root; the SQL writes to relative paths
ROOT="$PWD"
. pipeline/sources.env
# shellcheck source=/dev/null
if [ -f .env ]; then . ./.env; fi   # gitignored; convenient place for EIA_API_KEY

WORK="$ROOT/data/work"
DB="$ROOT/data/work/crack.duckdb"
MODE="live"

for arg in "$@"; do
  case "$arg" in
    --offline)     MODE="offline" ;;
    --fixtures)    MODE="fixtures" ;;
    --verify-only) MODE="verify" ;;
    *) echo "okänd flagga: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "FEL: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

mkdir -p "$WORK" site/public/data data/manual

# ---------------------------------------------------------------------------
# Download
#
# Each fetch names its own source on failure (FR-006) — "the pipeline broke" is
# not a diagnosis when there are three independent upstreams.
# ---------------------------------------------------------------------------

# EIA pages at 5000 rows. Three daily series over four years is ~3600 rows, so
# this is one page today; the loop exists so a longer window does not silently
# truncate. Files are numbered and read back as a glob, so an extra page needs
# no change in the SQL.
fetch_eia() {
  local url="$1" prefix="$2" freq="$3"; shift 3
  local facets="" s
  for s in "$@"; do facets="${facets}&facets[series][]=${s}"; done

  rm -f "$WORK/${prefix}"_*.json

  local page=0 offset=0 out code n full
  while :; do
    out=$(printf '%s/%s_%03d.json' "$WORK" "$prefix" "$page")
    full="${url}?api_key=${EIA_API_KEY}&frequency=${freq}&data[0]=value${facets}"
    full="${full}&start=${START_WEEK}&length=5000&offset=${offset}"
    full="${full}&sort[0][column]=period&sort[0][direction]=asc"
    # -g is mandatory: without it curl reads EIA's data[0] and facets[series][]
    # as glob ranges and refuses the URL with "bad range in URL".
    code=$(curl -gsS -o "$out" -w '%{http_code}' "$full") \
      || die "EIA ($prefix): curl misslyckades"
    if [ "$code" != "200" ]; then
      die "EIA ($prefix): http $code — kontrollera EIA_API_KEY. Svar: $(head -c 300 "$out")"
    fi

    n=$(duckdb -noheader -list -c \
          "SELECT coalesce(len(response.data), 0) FROM read_json_auto('$out')") \
      || die "EIA ($prefix): svaret är inte den väntade {response:{data:[...]}}-formen"
    say "EIA $prefix sida $page: $n rader"
    if [ "$n" -lt 5000 ]; then break; fi
    offset=$((offset + 5000)); page=$((page + 1))
  done
}

fetch_ecb() {
  # Starta två veckor tidigare så att den första publicerade veckan redan har en
  # kurs på eller före sig för ASOF-joinen att hitta.
  #
  # Datumräkningen görs i DuckDB, inte med date(1): BSD vill ha -v -f i en viss
  # ordning och GNU vill ha -d, och en tyst felaktig flaggordning ger ett datum
  # med blanksteg som förstör URL:en i stället för att fela.
  local from ccy
  from=$(duckdb -noheader -list -c \
    "SELECT (DATE '$START_WEEK' - INTERVAL 14 DAY)::DATE") \
    || die "ECB: kunde inte räkna fram startdatum"

  for ccy in $ECB_CURRENCIES; do
    curl -sS -o "$WORK/ecb_${ccy}.csv" --fail \
      "${ECB_BASE}/D.${ccy}.EUR.SP00.A?format=csvdata&startPeriod=${from}" \
      || die "ECB ($ccy): nedladdning misslyckades"
    say "ECB $ccy: $(wc -l < "$WORK/ecb_${ccy}.csv") rader"
  done
}

fetch_oilbulletin() {
  curl -sSL -o "$WORK/$OB_FILE" --fail "$OB_URL" \
    || die "Oil Bulletin: nedladdning misslyckades. UUID:t roteras när kommissionen
     republicerar — hämta det aktuella från $OB_PAGE och uppdatera OB_UUID i
     pipeline/sources.env."
  # A UUID that has been reissued often serves an HTML error page with HTTP 200,
  # which would otherwise reach read_xlsx as a baffling parse error.
  case "$(file -b --mime-type "$WORK/$OB_FILE")" in
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet|application/zip) ;;
    *) die "Oil Bulletin: nedladdningen är inte en xlsx (fick $(file -b "$WORK/$OB_FILE")).
     UUID:t har troligen roterats — se $OB_PAGE." ;;
  esac
  say "Oil Bulletin: $(wc -c < "$WORK/$OB_FILE") byte"
}

case "$MODE" in
  live)
    [ -n "${EIA_API_KEY:-}" ] || die "EIA_API_KEY saknas. Hämta en gratis nyckel på
     https://www.eia.gov/opendata/register.php och exportera den, eller kör
     pipeline/run.sh --fixtures för att bygga utan nyckel."
    fetch_eia "$EIA_SPOT_URL"   eia_spot   daily  $EIA_SPOT_SERIES
    fetch_eia "$EIA_RETAIL_URL" eia_retail weekly $EIA_RETAIL_SERIES
    fetch_ecb
    fetch_oilbulletin
    ;;
  offline)
    say "offline — återanvänder $WORK"
    ;;
  fixtures)
    # Bara EIA är nyckelskyddat. Oil Bulletin och ECB hämtas på riktigt även
    # här, så en roterad Oil-Bulletin-UUID fälls i CI i stället för att smyga
    # igenom till veckojobbet.
    say "fixtures — SYNTETISK EIA-data från data/fixtures/, övriga källor live"
    say "VARNING: crack-serierna blir påhittade. Publicera aldrig detta bygge."
    rm -f "$WORK"/eia_*.json
    cp data/fixtures/eia_*.json "$WORK/" || die "EIA-fixtures saknas i data/fixtures/"
    fetch_ecb
    fetch_oilbulletin
    ;;
  verify)
    say "verify-only"
    ;;
esac

# ---------------------------------------------------------------------------
# Build
#
# One DuckDB session across all scripts, so SET VARIABLE carries. .bail on stops
# at the first error and the exit status propagates.
# ---------------------------------------------------------------------------

OB_PATH="$WORK/$OB_FILE"

# Fixtures är en fryst ögonblicksbild medan week_calendar följer current_date.
# Färskhetskontrollerna i verify.sql skulle därför börja fälla varje CI-körning
# några veckor efter att fixtures genererades — och blockera varje pull request
# med ett fel som inte har med ändringen att göra.
STRICT=true
if [ "$MODE" = "fixtures" ]; then STRICT=false; fi

cat > "$WORK/preamble.sql" <<SQL
.bail on
SET VARIABLE work_dir   = '$WORK';
SET VARIABLE manual_dir = '$ROOT/data/manual';
SET VARIABLE ob_path    = '$OB_PATH';
SET VARIABLE start_week = '$START_WEEK';
SET VARIABLE generated  = '$(date -u +%Y-%m-%d)';
SET VARIABLE strict     = $STRICT;
SQL

if [ "$MODE" = "verify" ]; then
  say "kör invarianter"
  duckdb "$DB" -f "$WORK/preamble.sql" \
    -f pipeline/verify.sql -f pipeline/60_verify_export.sql
  exit $?
fi

# Spara föregående utdata för jämförelsen nedan.
rm -rf "$WORK/prev"; mkdir -p "$WORK/prev"
cp site/public/data/*.json "$WORK/prev/" 2>/dev/null || true

rm -f "$DB"
say "bygger $DB"
duckdb "$DB" \
  -f "$WORK/preamble.sql" \
  -f pipeline/00_schema.sql \
  -f pipeline/10_eia.sql \
  -f pipeline/20_oilbulletin.sql \
  -f pipeline/30_ecb.sql \
  -f pipeline/40_cracks.sql \
  -f pipeline/verify.sql \
  -f pipeline/50_export.sql \
  -f pipeline/60_verify_export.sql

# ---------------------------------------------------------------------------
# Idempotens
#
# Konstitutionen kräver att två körningar mot oförändrad uppströmsdata ger
# identisk utdata — men varje fil bär ett generated-datum som ändras varje gång.
# Skiljer sig bara det fältet är observationerna oförändrade, och den gamla filen
# återställs. Utan detta skulle veckojobbet committa tre filer varje vecka även
# när ingenting nytt publicerats.
# ---------------------------------------------------------------------------
undated() { sed -E 's/"generated":"[0-9-]*"/"generated":""/' "$1"; }

for f in site/public/data/*.json; do
  prev="$WORK/prev/$(basename "$f")"
  if [ -f "$prev" ] && [ "$(undated "$f")" = "$(undated "$prev")" ]; then
    cp "$prev" "$f"
    say "$(basename "$f"): oförändrad (bara datumstämpeln rörde sig)"
  fi
done

say "klart:"
ls -l site/public/data/*.json >&2
