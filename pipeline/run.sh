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
# .env läses ALLTID, inte bara när nyckeln saknas: filen är ett vanligt skalskript
# och sätter ofta annat än nyckeln — ett lokalt OB_UUID medan man jagar ett
# roterat bulletin-UUID, ett START_WEEK, en proxyvariabel. Att hoppa över den så
# fort en nyckel dyker upp i miljön skulle tyst släcka de övriga inställningarna
# och se ut som ett dataproblem i stället för ett konfigurationsproblem.
ENV_KEY="${EIA_API_KEY:-}"          # miljön, innan .env kan skriva över
# shellcheck source=/dev/null
if [ -f .env ]; then . ./.env; fi
FILE_KEY="${EIA_API_KEY:-}"
EIA_API_KEY=""                      # sätts först i live-grenen nedan

# shellcheck source=lib/key.sh
. pipeline/lib/key.sh

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

# Nedladdningshjälparna ligger i en source:bar fil så att pipeline/test/negative.sh
# kan pröva omförsökslogiken utan att köra hela pipelinen.
# shellcheck source=lib/fetch.sh
. pipeline/lib/fetch.sh

# En enda plats som bestämmer var exporten hamnar. Guarden nedan lovar i sitt
# felmeddelande att OUT_DIR är ratten — då måste den faktiskt vara det, annars
# skulle ett byte lämna katalogen oskapad och idempotensjämförelsen längre ner
# tyst titta i den gamla.
OUT_DIR="$ROOT/site/public/data"

mkdir -p "$WORK" "$OUT_DIR" data/manual

# Exporten skriver till strängliteraler, verifieringen läser ur out_dir. Kollas
# före hämtningarna: ett felkonfigurerat par ska inte kosta fyra nedladdningar
# först. Egen skript-fil så att negative.sh kan bevisa att kontrollen fäller.
pipeline/check-export-paths.sh "$ROOT" "$OUT_DIR" pipeline/50_export.sql \
  || die "exporten och verifieringen pekar på olika kataloger (se ovan)"

case "$MODE" in
  live)
    # Uppslaget ligger inne i live-grenen: --fixtures, --offline och --verify-only
    # använder ingen nyckel, och den första nyckelringsläsningen kan resa en
    # macOS-dialog utan timeout. Ett fixtures-bygge från launchd eller ett
    # icke-interaktivt skal ska inte kunna blockera på en fråga om ett värde det
    # aldrig läser.
    EIA_API_KEY=$(resolve_eia_key "$ENV_KEY" "$FILE_KEY")
    [ -n "${EIA_API_KEY:-}" ] || die "EIA_API_KEY saknas. Hämta en gratis nyckel på
     https://www.eia.gov/opendata/register.php och lägg den i macOS-nyckelringen:
       security add-generic-password -a \"\$USER\" -s EIA_API_KEY -w
     OBS: Passwords-appen räcker inte. Den lagrar i data protection-nyckelringen,
     som security(1) inte kan läsa — nyckeln kan alltså synas tydligt i Passwords
     och ändå rapporteras som saknad här.
     Alternativt: exportera den i miljön, eller lägg den i .env (gitignorerad).
     Utan nyckel: pipeline/run.sh --fixtures bygger på syntetisk EIA-data."
    fetch_eia "$EIA_SPOT_URL"   eia_spot   daily  $EIA_SPOT_SERIES
    fetch_eia "$EIA_RETAIL_URL" eia_retail weekly $EIA_RETAIL_SERIES
    fetch_eia "$EIA_RETAIL_URL" eia_region weekly $EIA_REGION_SERIES
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
    # En ny EIA-hämtning utan motsvarande fixtur gav tidigare ett obegripligt
    # "No files found that match the pattern .../eia_region_*.json" från DuckDB,
    # långt från orsaken. Kontrollera prefixen här i stället.
    for pfx in eia_spot eia_retail eia_region; do
      ls "$WORK/${pfx}"_*.json >/dev/null 2>&1 \
        || die "fixtur saknas för $pfx. Lägg en data/fixtures/${pfx}_000.json med samma
     {response:{data:[...]}}-form som EIA svarar med — se data/fixtures/README.md."
    done
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

# Fixtures är en fryst ögonblicksbild medan week_calendar följer byggdagen
# (stg.build_meta.built_on), som flyttar sig vid varje körning.
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
-- Minsta antal dagsobservationer bakom ett publicerat veckoben, och bakom
-- en punkt på 7-dagarslinjalen. Tre, inte fem: en helgstängd handelsvecka
-- har fyra dagar. Står här och inte i SQL:en för att veckoregeln och
-- linjalen ska vara omöjliga att flytta isär.
SET VARIABLE min_week_obs = 3;
SET VARIABLE out_dir    = '$OUT_DIR';
SQL

if [ "$MODE" = "verify" ]; then
  # Efter --fixtures är databasen syntetisk medan site/public/data har
  # återställts till den committade riktiga datan — run.sh gör det med flit. Att
  # då verifiera de publicerade filerna mot den databasen är meningslöst, och
  # utan den här raden är svaret ett verify 8b om fel stämpel, vilket pekar på
  # datan i stället för på att paret inte hör ihop.
  db_synth=$(duckdb -readonly "$DB" -noheader -list \
               -c 'SELECT NOT strict FROM stg.build_meta' 2>/dev/null) || db_synth=""
  file_synth=$(grep -o '"synthetic":[a-z]*' "$OUT_DIR/cracks.json" 2>/dev/null | head -1 | cut -d: -f2)
  if [ -n "$db_synth" ] && [ -n "$file_synth" ] && [ "$db_synth" != "$file_synth" ]; then
    die "databasen och de publicerade filerna kommer inte ur samma körning
     (databasen: synthetic=$db_synth, $OUT_DIR/cracks.json: synthetic=$file_synth).
     Det inträffar efter 'pipeline/run.sh --fixtures', som återställer
     site/public/data ur git men lämnar den syntetiska databasen kvar.
     Kör om bygget — pipeline/run.sh — innan du verifierar."
  fi
  say "kör invarianter"
  duckdb "$DB" -f "$WORK/preamble.sql" \
    -f pipeline/verify.sql -f pipeline/60_verify_export.sql
  exit $?
fi

# Spara föregående utdata för jämförelsen nedan.
rm -rf "$WORK/prev"; mkdir -p "$WORK/prev"
cp "$OUT_DIR"/*.json "$WORK/prev/" 2>/dev/null || true

rm -f "$DB"
say "bygger $DB"
duckdb "$DB" \
  -f "$WORK/preamble.sql" \
  -f pipeline/00_schema.sql \
  -f pipeline/10_eia.sql \
  -f pipeline/15_eia_regions.sql \
  -f pipeline/20_oilbulletin.sql \
  -f pipeline/25_calendar.sql \
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

for f in "$OUT_DIR"/*.json; do
  prev="$WORK/prev/$(basename "$f")"
  if [ -f "$prev" ] && [ "$(undated "$f")" = "$(undated "$prev")" ]; then
    cp "$prev" "$f"
    say "$(basename "$f"): oförändrad (bara datumstämpeln rörde sig)"
  fi
done

# Ett fixtures-bygge får inte lämna syntetisk data i arbetskopian. Kontrollen i
# ci.yml skyddade bara CI; en lokal körning följd av "git add -A" publicerade
# sinuskurvor till produktion. Återställ spårade filer här, där båda vägarna
# passerar, i stället för i ett arbetsflöde bara den ena kör.
if [ "$MODE" = "fixtures" ]; then
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$ROOT" checkout -- site/public/data 2>/dev/null || true
    git -C "$ROOT" clean -fdq site/public/data 2>/dev/null || true
    say "syntetisk utdata återställd — arbetskopian rörd orörd"
  else
    say "VARNING: inget git-repo; syntetisk utdata ligger kvar i $OUT_DIR"
  fi
fi

say "klart:"
ls -l "$OUT_DIR"/*.json >&2
