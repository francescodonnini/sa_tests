#!/usr/bin/env bash
# Compila e installa Redis per uno stage della pipeline dello shadow stack.
#
# Uso:   ./build-redis.sh <stage>      stage = 0, 1, 2, 3 o 4
#
#   0  baseline: nessuna protezione
#   1  solo runtime (relocate_stack + libruntime), nessun pass
#   2  runtime + pass IR (mascheramento store)
#   3  runtime + pass x86 (shadow stack)
#   4  runtime + pass IR + pass x86 (protezione completa)
#
# Risultato: binari in $HOME/redis-s<stage>/bin, build in $BUILD_ROOT/build-s<stage>.
#
# Redis non ha configure e compila dentro la cartella dei sorgenti, quindi ogni
# stage lavora su una copia propria di $SRC. Le opzioni dei pass vanno in
# REDIS_CFLAGS/REDIS_LDFLAGS, che il Makefile di Redis usa SOLO per i file di
# src/: le dipendenze in deps/ (jemalloc, lua, hiredis, ...) restano non
# strumentate, come la libc.
set -euo pipefail

# ---- da adattare alla macchina ------------------------------------------
SRC=$HOME/redis                                     # git clone di redis
BUILD_ROOT=$HOME/redis-build                        # copie per stage, fuori da $SRC
CLANG=$HOME/llvm-project/build/bin/clang            # clang con il pass x86 integrato
RT=$HOME/runtime/build                              # stckcpy.o e libruntime.so
IR_PASS=$HOME/shadow_stack/build/ShadowStack.so     # pass IR
# -O2 come Postgres e SQLite. Con il default -O3 il Makefile di Redis aggiunge
# -flto: il codice verrebbe generato al link, dove i pass passati a clang -c
# non arrivano.
OPTIMIZATION=-O2
# -------------------------------------------------------------------------

die() { echo "build-redis: $*" >&2; exit 1; }

STAGE=${1:-}
case "$STAGE" in
	0|1|2|3|4) ;;
	*) die "uso: $0 <stage 0-4>" ;;
esac

BUILD=$BUILD_ROOT/build-s$STAGE
PREFIX=$HOME/redis-s$STAGE

# ---- opzioni del compilatore e del linker per lo stage --------------------
COPT=""
LDOPT=""
case "$STAGE" in
	2) COPT="-fpass-plugin=$IR_PASS" ;;
	3) COPT="-mllvm -x86-shadow-stack-pass" ;;
	4) COPT="-fpass-plugin=$IR_PASS -mllvm -x86-shadow-stack-pass" ;;
esac
if [ "$STAGE" -ge 1 ]; then
	# --no-as-needed: senza, il linker può scartare libruntime.so se il
	# programma non ne usa simboli, e il suo costruttore non verrebbe eseguito
	LDOPT="$RT/stckcpy.o -Wl,-e,relocate_stack -L$RT -Wl,-rpath,$RT \
-Wl,--push-state,--no-as-needed -lruntime -Wl,--pop-state"
fi

# ---- controlli prima di partire --------------------------------------------
[ -f "$SRC/src/server.c" ] || die "sorgenti di Redis non trovati in $SRC"
[ -x "$CLANG" ] || die "clang non trovato: $CLANG"
case "$(realpath -m "$BUILD_ROOT")/" in
	"$(realpath -m "$SRC")"/*) die "BUILD_ROOT ($BUILD_ROOT) non può stare dentro SRC ($SRC)" ;;
esac
if [ "$STAGE" -ge 1 ]; then
	[ -f "$RT/stckcpy.o" ] || die "manca $RT/stckcpy.o (compila il runtime)"
	[ -f "$RT/libruntime.so" ] || die "manca $RT/libruntime.so (compila il runtime)"
	n=$(objdump -d "$RT/stckcpy.o" | grep -c '0x100002' || true)
	[ "$n" -ge 1 ] ||
		die "$RT/stckcpy.o è la versione vecchia (stack anonimo): ricompila il runtime"
fi
if [ "$STAGE" = 2 ] || [ "$STAGE" = 4 ]; then
	[ -f "$IR_PASS" ] || die "pass IR non trovato: $IR_PASS"
fi

echo "== stage $STAGE"
echo "   build:  $BUILD"
echo "   prefix: $PREFIX"
echo "   COPT:   ${COPT:-(vuoto)}"
echo "   LDOPT:  ${LDOPT:-(vuoto)}"

# ---- copia pulita dei sorgenti -------------------------------------------------
# Si riparte sempre da zero: il build corrisponde sempre a quello scritto qui
echo "== copia dei sorgenti"
rm -rf "$BUILD"
mkdir -p "$BUILD"
tar -C "$SRC" --exclude=.git -cf - . | tar -C "$BUILD" -xf -

# report del pass IR (stage 2 e 4): una riga CSV per file compilato
# file,funzioni,store,mascherati,constaddr,knownbits,domtree
REPORT=$BUILD/ss-report.csv
rm -f "$REPORT"

# ---- build e install -----------------------------------------------------------
echo "== make"
SS_REPORT_DEST="$REPORT" make -s -C "$BUILD" -j"$(nproc)" \
	CC="$CLANG" OPTIMIZATION="$OPTIMIZATION" \
	REDIS_CFLAGS="$COPT" REDIS_LDFLAGS="$LDOPT"

echo "== make install"
rm -rf "$PREFIX"
make -s -C "$BUILD" install PREFIX="$PREFIX" \
	CC="$CLANG" OPTIMIZATION="$OPTIMIZATION" \
	REDIS_CFLAGS="$COPT" REDIS_LDFLAGS="$LDOPT" > /dev/null

# ---- verifica del risultato ------------------------------------------------
BIN=$PREFIX/bin/redis-server
echo "== verifica $BIN"

# il preambolo del pass x86 legge __ss_shadow_offset
refs=$(objdump -d "$BIN" | grep -c '__ss_shadow_offset' || true)
echo "   riferimenti a __ss_shadow_offset: $refs"
case "$STAGE" in
	3|4) [ "$refs" -ge 1000 ] || die "stage $STAGE ma il binario non è strumentato" ;;
	1|2) [ "$refs" -lt 100 ] || die "stage $STAGE ma il binario contiene la strumentazione x86" ;;
	0)   [ "$refs" -eq 0 ] || die "stage 0 ma il binario contiene riferimenti allo shadow stack" ;;
esac

# entry point: relocate_stack dallo stage 1 in su, _start nello stage 0
entry=$(readelf -h "$BIN" | awk '/Entry point/ {print $4}')
reloc=$(nm "$BIN" | awk '$3 == "relocate_stack" {print $1}')
if [ "$STAGE" -ge 1 ]; then
	[ -n "$reloc" ] || die "relocate_stack non presente nel binario"
	[ $((entry)) -eq $((16#$reloc)) ] ||
		die "entry point $entry diverso da relocate_stack 0x$reloc"
	n=$(ldd "$BIN" | grep -c "$RT/libruntime.so" || true)
	[ "$n" -ge 1 ] || die "libruntime.so non risolta da $RT"
	echo "   entry point = relocate_stack, libruntime.so da $RT"
else
	[ -z "$reloc" ] || die "stage 0 ma il binario contiene relocate_stack"
	echo "   entry point standard, nessun runtime"
fi

if [ -f "$REPORT" ]; then
	awk -F, '{for (i = 2; i <= 7; i++) t[i] += $i}
	END {printf "   pass IR: %d file, %d funzioni, %d store, %d mascherati (%.1f%%), saltati: constaddr %d, knownbits %d, domtree %d\n",
		NR, t[2], t[3], t[4], t[3] ? 100 * t[4] / t[3] : 0, t[5], t[6], t[7]}' "$REPORT"
	echo "   dettaglio per file: $REPORT"
fi

echo "== stage $STAGE pronto in $PREFIX"