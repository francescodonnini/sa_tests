#!/usr/bin/env bash
# Compila e installa Redis per uno stage.   Uso: ./build.sh <stage 0-4>
#
# Redis non ha configure e compila dentro i sorgenti: ogni stage ha la sua
# copia in build-sN. I flag dello stage vanno in REDIS_CFLAGS/REDIS_LDFLAGS,
# che il Makefile usa SOLO per i file di src/: le dipendenze in deps/
# (jemalloc, lua, hiredis, ...) restano non strumentate, come la libc.
# OPTIMIZATION=-O2: con il default -O3 il Makefile aggiunge -flto, e il codice
# verrebbe generato al link, dove i pass passati a clang -c non arrivano.
# Risultato: $SS_ROOT/redis/sN/bin/redis-server (e redis-cli, redis-benchmark)
set -euo pipefail
. "$(dirname "$0")/../common.sh"

REDIS_REF=8.10.3
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/redis
BUILD=$DIR/build-s$STAGE
PREFIX=$DIR/s$STAGE
fetch_src https://github.com/redis/redis "$REDIS_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

MAKEOPTS=(CC="$CLANG" OPTIMIZATION=-O2 REDIS_CFLAGS="$COPT" REDIS_LDFLAGS="$LDOPT")
REPORT=$BUILD/ss-report.csv
echo "== make (stage $STAGE)"
SS_REPORT_DEST=$REPORT make -C "$BUILD" -s -j"$(nproc)" "${MAKEOPTS[@]}" > "$BUILD/make.log" 2>&1 ||
	die "compilazione fallita: vedi $BUILD/make.log"
echo "== make install"
rm -rf "$PREFIX"
make -C "$BUILD" -s install PREFIX="$PREFIX" "${MAKEOPTS[@]}" > "$BUILD/install.log" 2>&1 ||
	die "installazione fallita: vedi $BUILD/install.log"

verify_bin "$PREFIX/bin/redis-server" "$STAGE" 1000
ir_report "$REPORT"
echo "== stage $STAGE pronto: $PREFIX/bin/redis-server"
