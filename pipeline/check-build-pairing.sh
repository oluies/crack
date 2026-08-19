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
# Exit codes: 0 = they agree (or there is nothing to compare), 1 = they disagree,
# 2 = this script was called wrongly. run.sh dispatches on them, so 1 must mean
# one thing only.
#
# Silent (exit 0) when either side is missing or unstamped: an absent cracks.json
# is export check 8's business, and this guard reporting it would be a second
# diagnosis for one fault.
#
#   check-build-pairing.sh <db> <out_dir>

set -euo pipefail

# Exitkod 1 är reserverad för ETT utfall: paret är i otakt. ${1:?} avslutar med
# just 1, så ett saknat argument hade lästs av run.sh som en obalans och tyst
# degraderat i stället för att säga att anropet är fel. Användningsfel är 2.
if [ $# -ne 2 ]; then
  echo "usage: check-build-pairing.sh <db> <out_dir>" >&2
  exit 2
fi

DB="$1"
OUT_DIR="$2"
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

# Ingen FEL:-prefix och inget botemedel här. Anroparen avgör om fyndet är
# fatalt — run.sh --verify-only degraderar numera i stället för att dö — och en
# hård felmärkning på en körning som slutar grönt är vad både en människa och en
# loggsökning fastnar på. Exitkoden bär informationen; texten beskriver bara vad
# som gäller. Exit 1 betyder ENBART "paret är i otakt": allt annat är ett fel i
# den här kontrollen, och anroparen skiljer på dem.
if [ "$db_synth" != "$file_synth" ]; then
  echo "databasen och de publicerade filerna kommer inte ur samma körning" >&2
  echo "  (databasen: synthetic=$db_synth, $FILE: synthetic=$file_synth)." >&2
  echo "  Det inträffar efter 'pipeline/run.sh --fixtures', som återställer" >&2
  echo "  site/public/data ur git men lämnar den syntetiska databasen kvar." >&2
  exit 1
fi
