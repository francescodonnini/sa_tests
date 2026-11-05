#!/usr/bin/env bash
# Compila speedtest1 (il benchmark ufficiale di SQLite) per uno stage.
#   Uso: ./build.sh <stage 0-4>
#
# Sorgenti: l'amalgamation (sqlite3.c, un solo file con tutta la libreria) e
# speedtest1.c della stessa versione, scaricati una volta in $SS_ROOT/sqlite/src.
# Tutti gli stage si compilano allo stesso modo, cambiano solo i flag dello stage.
# Risultato: $SS_ROOT/sqlite/sN/speedtest1
set -euo pipefail
. "$(dirname "$0")/../common.sh"

SQLITE_VER=3500400          # 3.50.4
SQLITE_YEAR=2025
SQLITE_TAG=version-3.50.4
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/sqlite
SRC=$DIR/src
if [ ! -f "$SRC/sqlite3.c" ] || [ ! -f "$SRC/speedtest1.c" ]; then
	echo "== download di SQLite $SQLITE_TAG"
	mkdir -p "$SRC"
	curl -fsSL -o "$SRC/sqlite.zip" \
		"https://www.sqlite.org/$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_VER.zip" ||
		die "download dell'amalgamation fallito"
	unzip -j -o -q "$SRC/sqlite.zip" '*/sqlite3.c' '*/sqlite3.h' -d "$SRC"
	rm -f "$SRC/sqlite.zip"
	curl -fsSL -o "$SRC/speedtest1.c" \
		"https://raw.githubusercontent.com/sqlite/sqlite/$SQLITE_TAG/test/speedtest1.c" ||
		die "download di speedtest1.c fallito"
fi

BUILD=$DIR/build-s$STAGE
rm -rf "$BUILD"
mkdir -p "$BUILD"
REPORT=$BUILD/ss-report.csv
CFLAGS="-O2 -fPIE -I$SRC -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_ENABLE_RTREE $COPT"

echo "== compilazione (stage $STAGE)"
# i due file in parallelo: sqlite3.c da solo richiede circa un minuto
pids=()
for f in sqlite3 speedtest1; do
	# shellcheck disable=SC2086
	SS_REPORT_DEST=$REPORT "$CLANG" $CFLAGS -c "$SRC/$f.c" -o "$BUILD/$f.o" 2> "$BUILD/$f.log" &
	pids+=($!)
done
for p in "${pids[@]}"; do
	wait "$p" || die "compilazione fallita: vedi $BUILD/*.log"
done
# shellcheck disable=SC2086
"$CLANG" "$BUILD/sqlite3.o" "$BUILD/speedtest1.o" $LDOPT -lm -lpthread -o "$BUILD/speedtest1"

mkdir -p "$DIR/s$STAGE"
cp "$BUILD/speedtest1" "$DIR/s$STAGE/speedtest1"
verify_bin "$DIR/s$STAGE/speedtest1" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/speedtest1"
