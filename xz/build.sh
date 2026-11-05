#!/usr/bin/env bash
# Compila xz (liblzma + strumenti) per uno stage.   Uso: ./build.sh <stage 0-4>
#
# Si usa CMake invece di autotools: dal repository git autotools richiede
# autogen.sh (autoconf, automake, libtool, po4a), CMake no.
# liblzma è statica (default di CMake), quindi è dentro xz e viene strumentata.
# I test (ctest) usano gli stessi flag e linkano la stessa liblzma.
# Risultato: $SS_ROOT/xz/sN/xz
set -euo pipefail
. "$(dirname "$0")/../common.sh"

XZ_REF=v5.8.4
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/xz
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/tukaani-project/xz "$XZ_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

echo "== cmake (stage $STAGE)"
# il report si attiva solo per la compilazione: i test di configurazione di
# CMake compilano anche loro con il pass e sporcherebbero il csv
cmake -S "$BUILD" -B "$BUILD/build" -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_COMPILER="$CLANG" -DCMAKE_C_FLAGS="$COPT" \
	-DCMAKE_EXE_LINKER_FLAGS="$LDOPT" \
	-DBUILD_TESTING=ON -DXZ_NLS=OFF -DXZ_DOC=OFF > "$BUILD/cmake.log" 2>&1 ||
	die "cmake fallito: vedi $BUILD/cmake.log"

REPORT=$BUILD/ss-report.csv
echo "== make"
SS_REPORT_DEST=$REPORT cmake --build "$BUILD/build" -j"$(nproc)" > "$BUILD/make.log" 2>&1 ||
	die "compilazione fallita: vedi $BUILD/make.log"

mkdir -p "$DIR/s$STAGE"
cp "$BUILD/build/xz" "$DIR/s$STAGE/xz"
verify_bin "$DIR/s$STAGE/xz" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/xz"
