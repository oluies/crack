#!/usr/bin/env bash
#
# check-export-paths.sh — assert the export writes where the verifier reads.
#
# 50_export.sql's COPY targets are string literals, because DuckDB's parser
# accepts nothing else there: not getvariable(), not concatenation. So the
# coupling to 60_verify_export.sql, which reads through out_dir, cannot be made
# structural. It is asserted here instead, before any download or DuckDB work.
#
# Its own script rather than a few lines inline in run.sh so that
# pipeline/test/negative.sh can point it at a doctored copy and prove it fires —
# the whole point of that harness is that no check goes untested.
#
#   check-export-paths.sh <repo_root> <out_dir> <export_sql>

set -euo pipefail

ROOT="$1"; OUT_DIR="$2"; EXPORT_SQL="$3"

# Egen diagnos: utan detta blir en felstavad sökväg tre misslyckade grep och
# meddelandet "skriver inte till ..." — vilket pekar på filens innehåll i
# stället för på att filen inte finns.
[ -f "$EXPORT_SQL" ] || { echo "FEL: $EXPORT_SQL finns inte" >&2; exit 1; }

# COPY ... TO paths are relative to the process CWD, which run.sh sets to the
# repo root; out_dir is absolute. Compare them in the same terms.
REL="${OUT_DIR#"$ROOT"/}"

# Målen läses UR filen i stället för ur en lista här. En hårdkodad lista är
# tyst för precis det fel som är lättast att göra — en ny COPY som skriver
# någon annanstans — och den listan har redan hunnit bli inaktuell en gång.
TARGETS=$(grep -oE "TO '[^']*\.json'" "$EXPORT_SQL" | sed "s/^TO '//; s/'$//")

[ -n "$TARGETS" ] || {
  echo "FEL: hittade inga COPY ... TO '...json'-mål i $EXPORT_SQL" >&2
  echo "     Antingen har exporten slutat skriva JSON, eller så har formen ändrats" >&2
  echo "     så att den här kontrollen inte längre ser målen — båda måste åtgärdas." >&2
  exit 1
}

wrong=""
for t in $TARGETS; do
  case "$t" in
    "$REL"/*) ;;
    *) wrong="$wrong $t" ;;
  esac
done

if [ -n "$wrong" ]; then
  echo "FEL: $(basename "$EXPORT_SQL") skriver utanför '$REL/':$wrong" >&2
  echo "     Verifieringen läser ur $OUT_DIR, så exporten skulle kontrolleras mot" >&2
  echo "     filer den inte skrev. Ändra COPY-målen, eller OUT_DIR i run.sh, så att" >&2
  echo "     filerna skrivs och läses på samma plats." >&2
  exit 1
fi
