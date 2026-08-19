#!/usr/bin/env bash
#
# check-build-pairing.sh — assert the database and the published files came out
# of the same run.
#
# After `run.sh --fixtures` the database is synthetic while site/public/data has
# been restored to the committed real data — run.sh does that on purpose, so a
# fixtures build cannot leave sine waves in the working tree. Verifying those
# files against that database is meaningless, and without this the answer is a
# `verify 8b` about the wrong stamp, which blames the data rather than saying the
# pair does not belong together.
#
# Its own file rather than a few lines inside run.sh so negative.sh can prove it
# both fires and stays green — an untested guard is how the inert checks got in.
#
# Silent (exit 0) when either side is missing or unstamped: an absent cracks.json
# is export check 8's business, and this guard reporting it would be a second
# diagnosis for one fault.
#
#   check-build-pairing.sh <db> <out_dir>

set -euo pipefail

DB="${1:?usage: check-build-pairing.sh <db> <out_dir>}"
OUT_DIR="${2:?usage: check-build-pairing.sh <db> <out_dir>}"
FILE="$OUT_DIR/cracks.json"

# Läses med duckdb, inte med grep: en grep efter "synthetic":[a-z]* kopplar
# guardens korrekthet till exportens blankstegsformat, och [a-z]* matchar tomma
# strängen — ett mellanslag efter kolonet hade alltså tyst stängt av kontrollen.
read_db()   { duckdb -readonly "$DB" -noheader -list \
                -c 'SELECT NOT strict FROM stg.build_meta' 2>/dev/null || true; }
read_file() { duckdb -noheader -list \
                -c "SELECT json->>'\$.meta.synthetic' FROM read_json_objects('$FILE')" \
                2>/dev/null || true; }

[ -f "$DB" ]   || exit 0
[ -f "$FILE" ] || exit 0

db_synth=$(read_db)
file_synth=$(read_file)

# Bara två giltiga värden. Allt annat — tom sträng, NULL, en omdöpt kolumn —
# betyder att jämförelsen inte kan göras, inte att den lyckades.
valid() { case "$1" in true|false) return 0 ;; *) return 1 ;; esac; }
valid "$db_synth"   || exit 0
valid "$file_synth" || exit 0

if [ "$db_synth" != "$file_synth" ]; then
  echo "FEL: databasen och de publicerade filerna kommer inte ur samma körning" >&2
  echo "     (databasen: synthetic=$db_synth, $FILE: synthetic=$file_synth)." >&2
  echo "     Det inträffar efter 'pipeline/run.sh --fixtures', som återställer" >&2
  echo "     site/public/data ur git men lämnar den syntetiska databasen kvar." >&2
  echo "     Kör om bygget — pipeline/run.sh — innan du verifierar." >&2
  exit 1
fi
