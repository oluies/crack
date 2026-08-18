# fetch.sh — nedladdningshjälpare. Sourcas av run.sh.
#
# Egen fil för att den ska gå att source:a från pipeline/test/negative.sh utan
# att köra hela pipelinen: run.sh utför allt vid inläsning. Argumentet i det här
# projektet är att en okontrollerad kontroll är hur de verkningslösa
# invarianterna slank in — det gäller lika mycket för omförsökslogiken.
#
# Använder globalerna WORK, START_WEEK, EIA_API_KEY, OB_*, ECB_* från run.sh.
# Funktioner slår upp globaler vid anrop, så ordningen spelar ingen roll.

die() { echo "FEL: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# Alla tre uppströmskällorna tappar en förfrågan då och då — kommissionens
# server observerad mitt i en serie lyckade hämtningar. Utan omförsök fäller ett
# enstaka nätverksglapp hela veckojobbet, och nästa körning är en vecka bort.
#
# Den anropade funktionen kan sätta RETRY_FATAL=1 för att avbryta direkt: en
# återkallad API-nyckel blir inte giltig av att fråga fyra gånger.
retry() {  # $1 = beskrivning, resten = kommandot
  local what="$1"; shift
  local try wait=4
  RETRY_FATAL=0
  for try in 1 2 3 4; do
    if "$@"; then return 0; fi
    if [ "${RETRY_FATAL:-0}" = 1 ]; then return 1; fi
    if [ "$try" -lt 4 ]; then
      say "$what: försök $try misslyckades — väntar ${wait}s"
      sleep "$wait"; wait=$((wait * 2))
    fi
  done
  return 1
}

# Statuskoden måste testas INNE i den omförsökta enheten. Utan --fail avslutar
# curl med 0 på 429/500/503, så ett omförsök på exitkod ensamt skulle bara täcka
# nätverksfel — och det är just rate-limit och 5xx som är "servern tappade en
# förfrågan" för ett nyckelskyddat JSON-API.
#
# Koden får inte heller fångas ur retry: curl skriver sin -w-sträng vid varje
# försök, så ett misslyckat följt av ett lyckat gav "000200" och en die() som
# skyllde på API-nyckeln.
# Gemensam för alla tre källorna. --fail duger inte: curl ger exitkod 22 för
# varje HTTP >= 400, så retry kan inte skilja en tillfällig 503 från ett
# permanent 404 — och ett roterat Oil-Bulletin-UUID, som är just den väntade
# felkällan där, kostade fyra förfrågningar och 28 s backoff mot en server som
# svarade 404 direkt, fyra gånger.
LAST_CODE=""
http_get() {  # $1 = url, $2 = utfil, resten = extra curl-flaggor
  local url="$1" out="$2"; shift 2
  local code
  code=$(curl -sS "$@" -o "$out" -w '%{http_code}' "$url") || { LAST_CODE=""; return 1; }
  LAST_CODE="$code"
  case "$code" in
    200)             return 0 ;;
    # Permanent: fel eller återkallad nyckel, flyttad rutt, roterat UUID. Fyra
    # identiska förfrågningar gör ingen av dem giltig och fördröjer bara den
    # diagnos som faktiskt hjälper.
    401|403|404|410) RETRY_FATAL=1; return 1 ;;
    *)               return 1 ;;
  esac
}

# -g är nödvändigt för EIA: utan det läser curl data[0] och facets[series][]
# som globb-intervall och vägrar URL:en med "bad range in URL".
eia_get() { http_get "$1" "$2" -g; }

# EIA sidindelar vid 5000 rader. Tre dagliga serier över fyra år är ~3600, så
# det är en sida idag; loopen finns för att ett längre fönster inte ska tystna
# trunkerat. Filerna numreras och läses tillbaka som ett glob, så en extra sida
# kräver ingen SQL-ändring.
fetch_eia() {
  local url="$1" prefix="$2" freq="$3"; shift 3
  local facets="" s
  for s in "$@"; do facets="${facets}&facets[series][]=${s}"; done

  rm -f "$WORK/${prefix}"_*.json

  local page=0 offset=0 out n full
  while :; do
    out=$(printf '%s/%s_%03d.json' "$WORK" "$prefix" "$page")
    full="${url}?api_key=${EIA_API_KEY}&frequency=${freq}&data[0]=value${facets}"
    full="${full}&start=${START_WEEK}&length=5000&offset=${offset}"
    full="${full}&sort[0][column]=period&sort[0][direction]=asc"

    retry "EIA $prefix" eia_get "$full" "$out" \
      || die "EIA ($prefix): svar ${LAST_CODE:-nätverksfel}$(
                [ "${RETRY_FATAL:-0}" = 1 ] && printf ' (permanent, inga omförsök)' || printf ' efter 4 försök'
              ). Vid 401/403 — kontrollera EIA_API_KEY. Svar: $(head -c 300 "$out" 2>/dev/null)"

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
    retry "ECB $ccy" http_get \
      "${ECB_BASE}/D.${ccy}.EUR.SP00.A?format=csvdata&startPeriod=${from}" \
      "$WORK/ecb_${ccy}.csv" \
      || die "ECB ($ccy): svar ${LAST_CODE:-nätverksfel}$(
                [ "${RETRY_FATAL:-0}" = 1 ] && printf ' (permanent)' || printf ' efter 4 försök')"
    say "ECB $ccy: $(wc -l < "$WORK/ecb_${ccy}.csv") rader"
  done
}

fetch_oilbulletin() {
  retry "Oil Bulletin" http_get "$OB_URL" "$WORK/$OB_FILE" -L \
    || die "Oil Bulletin: svar ${LAST_CODE:-nätverksfel}$(
              [ "${RETRY_FATAL:-0}" = 1 ] && printf ' (permanent)' || printf ' efter 4 försök').
     Vid 404: UUID:t roteras när kommissionen republicerar — hämta det aktuella
     från $OB_PAGE och uppdatera OB_UUID i pipeline/sources.env."
  # Ett omutfärdat UUID serveras ofta som en HTML-felsida med HTTP 200, vilket
  # annars når read_xlsx som ett obegripligt parse-fel.
  case "$(file -b --mime-type "$WORK/$OB_FILE")" in
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet|application/zip) ;;
    *) die "Oil Bulletin: nedladdningen är inte en xlsx (fick $(file -b "$WORK/$OB_FILE")).
     UUID:t har troligen roterats — se $OB_PAGE." ;;
  esac
  say "Oil Bulletin: $(wc -c < "$WORK/$OB_FILE") byte"
}
