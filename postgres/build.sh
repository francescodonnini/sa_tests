#!/usr/bin/env bash
# Compila e installa Postgres per uno stage della pipeline dello shadow stack.
#
# Uso:   ./build-pg.sh <stage>      stage = 0, 1, 2, 3 o 4
#
#   0  baseline: nessuna protezione
#   1  solo runtime (relocate_stack + libruntime), nessun pass
#   2  runtime + pass IR (store masking)
#   3  runtime + pass x86 (shadow stack)
#   4  runtime + pass IR + pass x86 (protezione completa)
#
# Risultato: binari in $HOME/pg-s<stage>, build in $BUILD_ROOT/build-s<stage>.
# Ogni esecuzione riesegue configure e ricompila da zero (make clean): make non
# si accorge se cambiano COPT o LDFLAGS_EX, quindi senza clean si rischia un
# build misto, con oggetti protetti e non protetti.
set -euo pipefail

# ---- da adattare alla macchina ------------------------------------------
SRC=$HOME/postgres                                  # sorgenti di Postgres
# qui vanno le build-s<N>: deve stare FUORI da $SRC, altrimenti configure
# ricopia le cartelle di build dentro se stesse a ogni esecuzione
BUILD_ROOT=$HOME/pg-build
CLANG=$HOME/llvm-project/build/bin/clang            # clang con il pass x86 integrato
RT=$HOME/runtime/build                              # stckcpy.o e libruntime.so
IR_PASS=$HOME/shadow_stack/build/ShadowStack.so     # pass IR
# opzioni comuni a tutti gli stage (le stesse dei build originali)
CONFIGURE_FLAGS="--without-icu --without-readline --without-zlib"
BASE_CFLAGS="-O2"
# -------------------------------------------------------------------------

die() { echo "build-pg: $*" >&2; exit 1; }

STAGE=${1:-}
case "$STAGE" in
	0|1|2|3|4) ;;
	*) die "uso: $0 <stage 0-4>" ;;
esac

BUILD=$BUILD_ROOT/build-s$STAGE
PREFIX=$HOME/pg-s$STAGE

# ---- opzioni del compilatore e del linker per lo stage --------------------
COPT=""
LDFLAGS_EX=""
case "$STAGE" in
	2) COPT="-fpass-plugin=$IR_PASS" ;;
	3) COPT="-mllvm -x86-shadow-stack-pass" ;;
	4) COPT="-fpass-plugin=$IR_PASS -mllvm -x86-shadow-stack-pass" ;;
esac
if [ "$STAGE" -ge 1 ]; then
	# --no-as-needed: senza, il linker può scartare libruntime.so se il
	# programma non ne usa simboli, e il suo costruttore non verrebbe eseguito
	LDFLAGS_EX="$RT/stckcpy.o -Wl,-e,relocate_stack -L$RT -Wl,-rpath,$RT \
-Wl,--push-state,--no-as-needed -lruntime -Wl,--pop-state"
fi

# ---- controlli prima di partire --------------------------------------------
[ -f "$SRC/configure" ] || die "sorgenti di Postgres non trovati in $SRC"
[ -x "$CLANG" ] || die "clang non trovato: $CLANG"
case "$(realpath -m "$BUILD_ROOT")/" in
	"$(realpath -m "$SRC")"/*) die "BUILD_ROOT ($BUILD_ROOT) non può stare dentro SRC ($SRC)" ;;
esac
if [ "$STAGE" -ge 1 ]; then
	[ -f "$RT/stckcpy.o" ] || die "manca $RT/stckcpy.o (compila il runtime)"
	[ -f "$RT/libruntime.so" ] || die "manca $RT/libruntime.so (compila il runtime)"
	# 0x100002 = MAP_PRIVATE | MAP_FIXED_NOREPLACE: stack mappato dal device
	# grep -c e non grep -q: con pipefail, grep -q che esce al primo match
	# fa terminare objdump con SIGPIPE e la pipeline risulta fallita
	# make install esegue programmi appena compilati (per esempio zic), che
	# con il runtime collegato aprono il device: senza modulo falliscono
	[ -e /dev/shdwstck ] ||
		die "/dev/shdwstck non esiste: carica il modulo prima di compilare lo stage $STAGE"
	n=$(objdump -d "$RT/stckcpy.o" | grep -c '0x100002' || true)
	[ "$n" -ge 1 ] ||
		die "$RT/stckcpy.o è la versione vecchia (stack anonimo): ricompila il runtime"
fi
if [ "$STAGE" = 2 ] || [ "$STAGE" = 4 ]; then
	[ -f "$IR_PASS" ] || die "pass IR non trovato: $IR_PASS"
fi

echo "== stage $STAGE"
echo "   build:      $BUILD"
echo "   prefix:     $PREFIX"
echo "   CFLAGS:     $BASE_CFLAGS"
echo "   COPT:       ${COPT:-(vuoto)}"
echo "   LDFLAGS_EX: ${LDFLAGS_EX:-(vuoto)}"

# ---- configure ---------------------------------------------------------------
# configure riceve SOLO le opzioni comuni, uguali per tutti gli stage.
# Le opzioni dello stage non possono andare qui: configure compila ed ESEGUE
# programmi di prova, che con il pass x86 sarebbero strumentati ma senza
# runtime (niente relocate_stack, niente shadow stack) e andrebbero in crash
# ("cannot run C compiled programs"). Si passano a make con COPT e LDFLAGS_EX.
# Si riesegue sempre: il build corrisponde sempre a quello scritto qui.
mkdir -p "$BUILD"
cd "$BUILD"
echo "== configure (1-2 minuti; avanzamento: tail -f $BUILD/configure.out)"
# shellcheck disable=SC2086
"$SRC/configure" --prefix="$PREFIX" $CONFIGURE_FLAGS \
	CC="$CLANG" CFLAGS="$BASE_CFLAGS" > configure.out ||
	die "configure fallito: vedi $BUILD/config.log"

# ---- build e install ---------------------------------------------------------
# ATTENZIONE: anche un make lanciato a mano in questa cartella deve ricevere
# COPT e LDFLAGS_EX, altrimenti produce binari NON protetti.
echo "== make clean"
make -s clean

# report del pass IR (stage 2 e 4): una riga CSV per file compilato
# file,funzioni,store,mascherati,constaddr,knownbits,domtree
REPORT=$BUILD/ss-report.csv
rm -f "$REPORT"

echo "== make"
SS_REPORT_DEST="$REPORT" make -s -j"$(nproc)" COPT="$COPT" LDFLAGS_EX="$LDFLAGS_EX"

# stesse variabili anche qui: se install ricostruisce qualcosa, deve farlo
# con le stesse opzioni
echo "== make install"
make -s install COPT="$COPT" LDFLAGS_EX="$LDFLAGS_EX"

# ---- verifica del risultato ------------------------------------------------
BIN=$PREFIX/bin/postgres
echo "== verifica $BIN"

# il preambolo del pass x86 legge __ss_shadow_offset
refs=$(objdump -d "$BIN" | grep -c '__ss_shadow_offset' || true)
echo "   riferimenti a __ss_shadow_offset: $refs"
case "$STAGE" in
	3|4) [ "$refs" -ge 1000 ] || die "stage $STAGE ma il binario non è strumentato" ;;
	# stage 1-2: solo i pochi riferimenti di relocate_stack (che scrive la
	# variabile e la rende read-only), nessun preambolo strumentato
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
	[ "$n" -ge 1 ] ||
		die "libruntime.so non risolta da $RT"
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