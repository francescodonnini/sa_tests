#!/usr/bin/env bash
# Compila OpenSSL per uno stage.   Uso: ./build.sh <stage 0-4>
#
# Opzioni di Configure (uguali per ogni stage):
#   no-asm      niente implementazioni in assembly (AES-NI, SHA, bignum...):
#               non passerebbero dal pass; resta il codice C
#   no-shared   libcrypto e libssl statiche, dentro gli eseguibili
#   no-module   provider (legacy) compilati dentro libcrypto, non come .so
# Così sono linkati solo eseguibili (apps/openssl e i test) e il runtime si
# aggiunge con LDFLAGS. Configure gira senza i flag dello stage; i flag si
# passano a make aggiungendoli ai CFLAGS e LDFLAGS scritti da Configure.
# Risultato: $SS_ROOT/openssl/sN/openssl
set -euo pipefail
. "$(dirname "$0")/../common.sh"

OSSL_REF=openssl-3.5.9
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/openssl
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/openssl/openssl "$OSSL_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

echo "== Configure (stage $STAGE)"
(cd "$BUILD" && CC="$CLANG" ./Configure linux-x86_64 no-asm no-shared no-module) \
	> "$BUILD/configure.log" 2>&1 || die "Configure fallito: vedi $BUILD/configure.log"

CF="$(sed -n 's/^CFLAGS=//p' "$BUILD/Makefile") $COPT"
LF="$(sed -n 's/^LDFLAGS=//p' "$BUILD/Makefile") $LDOPT"
REPORT=$BUILD/ss-report.csv
echo "== make"
SS_REPORT_DEST=$REPORT make -C "$BUILD" -j"$(nproc)" CFLAGS="$CF" LDFLAGS="$LF" \
	> "$BUILD/make.log" 2>&1 || die "compilazione fallita: vedi $BUILD/make.log"
# lo stesso CFLAGS/LDFLAGS serve a test-openssl.sh (make test ricompila se cambiano)
printf 'CF=%q\nLF=%q\n' "$CF" "$LF" > "$BUILD/ss-flags.sh"

mkdir -p "$DIR/s$STAGE"
cp "$BUILD/apps/openssl" "$DIR/s$STAGE/openssl"
verify_bin "$DIR/s$STAGE/openssl" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/openssl"
