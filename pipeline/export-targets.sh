#!/usr/bin/env bash
#
# export-targets.sh — print the paths 50_export.sql's COPY statements write to,
# one per line.
#
# One copy, two callers: check-export-paths.sh asserts they agree with OUT_DIR,
# and refresh.yml's deploy gate asserts the files exist before publishing. Those
# two had drifted apart as hand-maintained lists — the gate was still naming
# three files after two more had been added — so the list is derived, and derived
# in exactly one place. negative.sh exercises this script through
# check-export-paths.sh, which means the tested copy is the shipped one.
#
#   export-targets.sh <export_sql>

set -euo pipefail

EXPORT_SQL="${1:?usage: export-targets.sh <export_sql>}"

[ -f "$EXPORT_SQL" ] || { echo "FEL: $EXPORT_SQL finns inte" >&2; exit 1; }

# || true är inte kosmetik: under set -e (och pipefail) fäller grep:s exitkod 1
# — "inga träffar" — hela skriptet på tilldelningsraden, och diagnosen nedan blir
# oåtkomlig. Felet rapporteras då som tom utdata i stället för som ett
# meddelande. Det hände en gång i den här filens föregångare.
TARGETS=$(grep -oE "TO '[^']*\.json'" "$EXPORT_SQL" | sed "s/^TO '//; s/'$//" || true)

if [ -z "$TARGETS" ]; then
  echo "FEL: hittade inga COPY ... TO '...json'-mål i $EXPORT_SQL" >&2
  echo "     Antingen har exporten slutat skriva JSON, eller så har formen ändrats" >&2
  echo "     så att den här kontrollen inte längre ser målen — båda måste åtgärdas." >&2
  exit 1
fi

printf '%s\n' "$TARGETS"
