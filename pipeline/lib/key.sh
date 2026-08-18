# key.sh — upplösning av EIA_API_KEY. Sourcas av run.sh.
#
# Egen sourcebar fil av samma skäl som lib/fetch.sh: run.sh utför allt vid
# inläsning, så logik som ligger inline där kan inte drivas av ett prov. En
# företrädesordning som bara påstås i README är en regel som tyst kan kastas om
# utan att något blir rött — se proven i pipeline/test/negative.sh.

# resolve_eia_key <nyckel_från_miljön> <nyckel_från_.env>
#
# Ordning: miljön, login-nyckelringen, .env. Skriver nyckeln på stdout, tom
# sträng om ingen finns.
resolve_eia_key() {
  local env_key="${1:-}" file_key="${2:-}" kc_key=""

  [ -n "$env_key" ] && { printf '%s' "$env_key"; return 0; }

  if command -v security >/dev/null 2>&1; then
    # -a "$USER" och inte bara -s: med flera poster för samma tjänst — ett andra
    # konto, en post synkad från en annan Mac, en post i en annan nyckelring —
    # returnerar security den första i sökordningen, som inte behöver vara den
    # instruktionerna bad användaren skapa. Symtomet blir 403 från EIA mot en
    # nyckel som ser korrekt ut i Keychain Access.
    kc_key=$(security find-generic-password -a "${USER:-}" -s EIA_API_KEY -w 2>/dev/null) || kc_key=""
  fi
  [ -n "$kc_key" ] && { printf '%s' "$kc_key"; return 0; }

  printf '%s' "$file_key"
}
