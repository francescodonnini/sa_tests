#!/usr/bin/env bash
# Compila memcached per uno stage.   Uso: ./build-memcached.sh <stage 0-4>
#
# Dal repository git serve autogen.sh (autoconf, automake) e libevent:
#   dnf install autoconf automake libevent-devel
# libevent è di sistema, non strumentata. configure gira senza i flag dello
# stage; i flag si aggiungono a make insieme ai CFLAGS/LDFLAGS di configure.
# Si compilano anche memcached-debug, testapp e sizes, usati da make test.
# Risultato: $SS_ROOT/memcached/sN/memcached
set -euo pipefail
. "$(dirname "$0")/../common.sh"

MC_REF=1.6.45
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/memcached
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/memcached/memcached "$MC_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

echo "== autogen + configure (stage $STAGE)"
# --disable-coverage: senza, configure attiva gcov per memcached-debug se trova
# gcov nel sistema, e il link richiede libclang_rt.profile.a (compiler-rt),
# che la build di LLVM non ha.
(cd "$BUILD" && GIT_DIR="$DIR/src/.git" ./autogen.sh && ./configure CC="$CLANG" --disable-coverage) > "$BUILD/configure.log" 2>&1 ||
	die "configure fallito: vedi $BUILD/configure.log"

CF="$(sed -n 's/^CFLAGS = //p' "$BUILD/Makefile") $COPT"
CF="$(sed -n 's/^CFLAGS = //p' "$BUILD/Makefile") $COPT"
LF="$(sed -n 's/^LDFLAGS = //p' "$BUILD/Makefile") $LDOPT"
printf 'CF=%q\nLF=%q\n' "$CF" "$LF" > "$BUILD/ss-flags.sh"
REPORT=$BUILD/ss-report.csv
echo "== make"
SS_REPORT_DEST=$REPORT make -C "$BUILD" -j"$(nproc)" CFLAGS="$CF" LDFLAGS="$LF" \
	memcached memcached-debug testapp sizes timedrun > "$BUILD/make.log" 2>&1 ||
	die "compilazione fallita: vedi $BUILD/make.log"

mkdir -p "$DIR/s$STAGE"
cp "$BUILD/memcached" "$DIR/s$STAGE/memcached"
verify_bin "$DIR/s$STAGE/memcached" "$STAGE"
verify_bin "$BUILD/memcached-debug" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/memcached"
