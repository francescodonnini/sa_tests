#!/usr/bin/env bash
# Compila e installa CPython per uno stage.   Uso: ./build-cpython.sh <stage 0-4>
#
# configure senza i flag dello stage (i suoi programmi di prova non vanno
# strumentati) e con le opzioni di default: -O3, niente PGO/LTO, niente JIT;
# ensurepip resta attivo perché pyperformance crea dei venv con pip.
# I flag dello stage si aggiungono a make:
#   CFLAGS_NODIST  compilazione dell'interprete e dei moduli C della stdlib
#   LIBS           link degli eseguibili (python, _freeze_module,
#                  _bootstrap_python, _testembed), che girano anche durante la
#                  build. I moduli C condivisi (.so) non hanno LIBS: i loro
#                  riferimenti al runtime si risolvono nel processo python.
# Su Fedora per i moduli più comuni servono (facoltativi):
#   dnf install openssl-devel libffi-devel zlib-devel bzip2-devel xz-devel sqlite-devel
# Risultato: $SS_ROOT/cpython/sN/bin/python3
set -euo pipefail
. "$(dirname "$0")/../common.sh"

PY_REF=v3.14.10
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/cpython
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/python/cpython "$PY_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

echo "== configure (stage $STAGE)"
(cd "$BUILD" && ./configure CC="$CLANG" --prefix="$DIR/s$STAGE") \
	> "$BUILD/configure.log" 2>&1 || die "configure fallito: vedi $BUILD/configure.log"

LIBS_ALL="$(sed -n 's/^LIBS=[[:space:]]*//p' "$BUILD/Makefile") $LDOPT"
REPORT=$BUILD/ss-report.csv
echo "== make"
rm -rf "$DIR/s$STAGE"
SS_REPORT_DEST=$REPORT make -C "$BUILD" -j"$(nproc)" CFLAGS_NODIST="$COPT" LIBS="$LIBS_ALL" \
	> "$BUILD/make.log" 2>&1 || die "compilazione fallita: vedi $BUILD/make.log"
# moduli che non si sono compilati (librerie di sistema mancanti): uguali in ogni stage
grep -A3 'necessary bits to build these optional modules' "$BUILD/make.log" | sed 's/^/   /' || true
echo "== make install"
make -C "$BUILD" CFLAGS_NODIST="$COPT" LIBS="$LIBS_ALL" install > "$BUILD/install.log" 2>&1 ||
	die "installazione fallita: vedi $BUILD/install.log"

verify_bin "$DIR/s$STAGE/bin/python3" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/bin/python3"
