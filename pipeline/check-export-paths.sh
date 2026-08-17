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

# COPY ... TO paths are relative to the process CWD, which run.sh sets to the
# repo root; out_dir is absolute. Compare them in the same terms.
REL="${OUT_DIR#"$ROOT"/}"

missing=""
for f in cracks retail fx; do
  grep -q "TO '$REL/$f.json'" "$EXPORT_SQL" || missing="$missing $f.json"
done

if [ -n "$missing" ]; then
  echo "FEL: $(basename "$EXPORT_SQL") skriver inte till '$REL/' för:$missing" >&2
  echo "     Verifieringen läser ur $OUT_DIR, så exporten skulle kontrolleras mot" >&2
  echo "     filer den inte skrev. Ändra COPY-målen, eller OUT_DIR i run.sh, så att" >&2
  echo "     de tre filerna skrivs och läses på samma plats." >&2
  exit 1
fi
