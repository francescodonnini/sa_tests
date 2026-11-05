#!/usr/bin/env bash
# Compila e installa Postgres per uno stage.   Uso: ./build.sh <stage 0-4>
#
# Build fuori dai sorgenti (VPATH): configure gira in build-sN e i sorgenti in
# src/ restano intatti. Dal repository git servono bison e flex (i tarball
# contengono i file generati, git no).
#
# configure riceve SOLO le opzioni comuni a tutti gli stage: compila ed esegue
# programmi di prova, che con il pass x86 ma senza runtime andrebbero in crash.
# I flag dello stage passano a make con COPT (compilazione) e LDFLAGS_EX (link
# degli eseguibili), le variabili previste da Postgres per questo.
# Risultato: $SS_ROOT/postgres/sN/bin/postgres (e pg_ctl, initdb, pgbench, ...)
set -euo pipefail
. "$(dirname "$0")/../common.sh"

PG_REF=REL_18_6
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/postgres
BUILD=$DIR/build-s$STAGE
PREFIX=$DIR/s$STAGE
fetch_src https://github.com/postgres/postgres "$PG_REF" "$DIR/src"
rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD"

echo "== configure (stage $STAGE)"
(cd "$BUILD" && "$DIR/src/configure" --prefix="$PREFIX" \
	--without-icu --without-readline --without-zlib CC="$CLANG" CFLAGS="-O2") \
	> "$BUILD/configure.log" 2>&1 || die "configure fallito: vedi $BUILD/config.log"

# ATTENZIONE: anche un make lanciato a mano in build-sN deve ricevere COPT e
# LDFLAGS_EX, altrimenti produce binari NON protetti (test.sh li passa)
REPORT=$BUILD/ss-report.csv
echo "== make"
SS_REPORT_DEST=$REPORT make -C "$BUILD" -s -j"$(nproc)" COPT="$COPT" LDFLAGS_EX="$LDOPT" \
	> "$BUILD/make.log" 2>&1 || die "compilazione fallita: vedi $BUILD/make.log"
# make install esegue programmi appena compilati (per esempio zic): servono
# gli stessi flag e il modulo caricato
echo "== make install"
make -C "$BUILD" -s install COPT="$COPT" LDFLAGS_EX="$LDOPT" > "$BUILD/install.log" 2>&1 ||
	die "installazione fallita: vedi $BUILD/install.log"

verify_bin "$PREFIX/bin/postgres" "$STAGE" 1000
ir_report "$REPORT"
echo "== stage $STAGE pronto: $PREFIX/bin/postgres"
