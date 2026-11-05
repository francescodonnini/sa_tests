#!/usr/bin/env bash
# Compila PHP (solo la CLI) per uno stage.   Uso: ./build.sh <stage 0-4>
#
# Dal repository git servono buildconf (autoconf) e i generatori del parser
# (bison, re2c): su Fedora  dnf install autoconf bison re2c
# --disable-all: solo il motore Zend e le estensioni sempre presenti (standard,
# date, pcre con PCRE incluso nei sorgenti, spl, json, hash, random, ...), così
# non servono librerie di sistema e quasi tutto il codice eseguito è strumentato.
# --disable-opcache-jit: il JIT genererebbe codice macchina non strumentato.
#
# configure gira senza i flag dello stage (i suoi programmi di prova non vanno
# strumentati); i flag si aggiungono a make con EXTRA_CFLAGS (compilazione) e
# EXTRA_LDFLAGS_PROGRAM (link dei programmi, cioè sapi/cli/php).
# Risultato: $SS_ROOT/php/sN/php
set -euo pipefail
. "$(dirname "$0")/../common.sh"

PHP_REF=php-8.5.12
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/php
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/php/php-src "$PHP_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

echo "== buildconf + configure (stage $STAGE)"
(cd "$BUILD" && ./buildconf --force &&
	./configure CC="$CLANG" CFLAGS="-O2" --disable-all --enable-cli --disable-cgi \
		--disable-phpdbg --disable-opcache-jit --without-pear) > "$BUILD/configure.log" 2>&1 ||
	die "configure fallito: vedi $BUILD/configure.log"

# il valore di configure (pagine da 2 MB, LDFLAGS) più il runtime
LDPROG="$(sed -n 's/^EXTRA_LDFLAGS_PROGRAM = //p' "$BUILD/Makefile") $LDOPT"
REPORT=$BUILD/ss-report.csv
echo "== make"
SS_REPORT_DEST=$REPORT make -C "$BUILD" -j"$(nproc)" \
	EXTRA_CFLAGS="$COPT" EXTRA_LDFLAGS_PROGRAM="$LDPROG" > "$BUILD/make.log" 2>&1 ||
	die "compilazione fallita: vedi $BUILD/make.log"

mkdir -p "$DIR/s$STAGE"
cp "$BUILD/sapi/cli/php" "$DIR/s$STAGE/php"
verify_bin "$DIR/s$STAGE/php" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/php"
