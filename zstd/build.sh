#!/usr/bin/env bash
# Compila zstd per uno stage.   Uso: ./build.sh <stage 0-4>
#
# Si compilano:
#   programs/zstd                 la CLI (benchmark e playTests.sh)
#   tests/fuzzer, zstreamtest     test della libreria (API a blocchi e streaming)
#   tests/datagen                 generatore di dati dei test
# I flag dello stage passano per MOREFLAGS (compilazione) e LDFLAGS (link):
# libzstd.mk li aggiunge con +=, quindi le opzioni del progetto restano intatte.
# ZSTD_NO_ASM=1 esclude huf_decompress_amd64.S: in assembly non sarebbe strumentato.
# Risultato: $SS_ROOT/zstd/sN/zstd
set -euo pipefail
. "$(dirname "$0")/../common.sh"

ZSTD_REF=v1.5.7
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/zstd
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/facebook/zstd "$ZSTD_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

REPORT=$BUILD/ss-report.csv
export SS_REPORT_DEST=$REPORT MOREFLAGS="$COPT" LDFLAGS="$LDOPT" ZSTD_NO_ASM=1
echo "== make zstd (stage $STAGE)"
make -s -C "$BUILD/programs" -j"$(nproc)" CC="$CLANG" zstd > /dev/null
echo "== make fuzzer zstreamtest datagen"
make -s -C "$BUILD/tests" -j"$(nproc)" CC="$CLANG" fuzzer zstreamtest datagen > /dev/null

mkdir -p "$DIR/s$STAGE"
cp "$BUILD/programs/zstd" "$DIR/s$STAGE/zstd"
for b in "$DIR/s$STAGE/zstd" "$BUILD/tests/fuzzer" "$BUILD/tests/zstreamtest"; do
	verify_bin "$b" "$STAGE"
done
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/zstd"
