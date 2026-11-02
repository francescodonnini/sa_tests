#!/usr/bin/env bash
# Esegue la suite di regressione di Postgres sui build dei vari stage e
# confronta i test falliti con quelli dello stage 0.
#
# Uso: ./check.sh [-i] [-c] <stage>[,<stage>...]      (con il modulo caricato)
#
#   ./check.sh 0,4          regressione principale (make check) su s0 e s4
#   ./check.sh -i 0,1,4     anche i test di isolamento (transazioni concorrenti)
#
# Opzioni:
#   -i   anche src/test/isolation (make check)
#   -c   anche i test dei moduli in contrib/ (make -C contrib check), più lunghi
#
# Usa le cartelle di build lasciate da build-pg.sh ($BUILD_ROOT/build-s<N>).
# make check crea un'istanza temporanea con i binari di quel build, quindi
# esegue proprio il codice strumentato, fork comprese (una per connessione).
# Log e diff in test-pg-<data>/. Lo stage 0 serve da riferimento: un test che
# fallisce anche lì dipende dall'ambiente, non dallo shadow stack.
set -uo pipefail

# ---- come in build-pg.sh -----------------------------------------------------
BUILD_ROOT=$HOME/pg-build
RT=$HOME/runtime/build
IR_PASS=$HOME/shadow_stack/build/ShadowStack.so
# -------------------------------------------------------------------------

die() { echo "test-pg: $*" >&2; exit 1; }

usage() {
	sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

ISOLATION=0
CONTRIB=0
while getopts "ich" opt; do
	case $opt in
		i) ISOLATION=1 ;;
		c) CONTRIB=1 ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
IFS=, read -r -a STAGES <<< "$1"

[ "$(id -u)" -ne 0 ] || die "initdb non gira come root: lancia lo script come utente normale"

for s in "${STAGES[@]}"; do
	case $s in 0|1|2|3|4) ;; *) die "stage non valido: $s (0-4)" ;; esac
	[ -f "$BUILD_ROOT/build-s$s/GNUmakefile" ] || die "stage $s: build non trovato (lancia build-pg.sh $s)"
	[ "$s" -eq 0 ] || [ -e /dev/shdwstck ] || die "/dev/shdwstck non esiste: carica il modulo"
done

OUT=test-pg-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

# stesse opzioni del build: se make check ricompila qualcosa (per esempio i
# moduli dei test), lo fa come il resto dello stage
stage_flags() {
	COPT=""
	LDFLAGS_EX=""
	case $1 in
		2) COPT="-fpass-plugin=$IR_PASS" ;;
		3) COPT="-mllvm -x86-shadow-stack-pass" ;;
		4) COPT="-fpass-plugin=$IR_PASS -mllvm -x86-shadow-stack-pass" ;;
	esac
	if [ "$1" -ge 1 ]; then
		LDFLAGS_EX="$RT/stckcpy.o -Wl,-e,relocate_stack -L$RT -Wl,-rpath,$RT \
-Wl,--push-state,--no-as-needed -lruntime -Wl,--pop-state"
	fi
}

# failed_tests <log>: nomi dei test falliti, uno per riga
# (pg_regress recente: "not ok 12 - nome ..."; più vecchio: "test nome ... FAILED")
failed_tests() {
	grep -E '^not ok|\.\.\. FAILED|FAILED \(' "$1" |
		sed -E 's/^not ok +[0-9]+ +[-+] +//; s/^(test +)?//; s/[ .]+FAILED.*//; s/ +[0-9]+ ms$//' |
		awk '{print $1}' | sort -u
}

# run <stage> <nome> <cartella relativa al build>
run() {
	local s=$1 name=$2 dir=$3
	local B=$BUILD_ROOT/build-s$s
	local log=$OUT/s$s-$name.log

	printf "   %-10s " "$name"
	stage_flags "$s"
	make -C "$B/$dir" check COPT="$COPT" LDFLAGS_EX="$LDFLAGS_EX" > "$log" 2>&1
	local rc=$?

	failed_tests "$log" > "$OUT/s$s-$name.failed"
	# diff dei risultati, per ogni cartella di test che ne ha prodotto uno
	find "$B/$dir" -name regression.diffs -newer "$log.start" 2> /dev/null |
		while read -r d; do
			cp "$d" "$OUT/s$s-$name-$(echo "${d#$B/}" | tr / _)"
		done

	local nfail
	nfail=$(wc -l < "$OUT/s$s-$name.failed")
	if [ $rc -eq 0 ]; then
		echo "ok"
	elif [ "$nfail" -gt 0 ]; then
		echo "FALLITO: $nfail test ($(paste -sd' ' "$OUT/s$s-$name.failed"))"
	else
		echo "FALLITO senza test identificati (exit $rc): vedi $log"
	fi
}

SUITES=("regress:.")
[ $ISOLATION -eq 1 ] && SUITES+=("isolation:src/test/isolation")
[ $CONTRIB -eq 1 ] && SUITES+=("contrib:contrib")

for s in "${STAGES[@]}"; do
	echo "== s$s"
	for suite in "${SUITES[@]}"; do
		name=${suite%%:*}
		dir=${suite#*:}
		touch "$OUT/s$s-$name.log.start"
		run "$s" "$name" "$dir"
		rm -f "$OUT/s$s-$name.log.start"
	done
done

# ---- confronto con lo stage 0 ------------------------------------------------
if [ -d "$OUT" ] && ls "$OUT"/s0-*.failed > /dev/null 2>&1; then
	echo
	echo "== confronto con s0 (test che falliscono solo nello stage)"
	for s in "${STAGES[@]}"; do
		[ "$s" -eq 0 ] && continue
		for suite in "${SUITES[@]}"; do
			name=${suite%%:*}
			extra=$(comm -13 "$OUT/s0-$name.failed" "$OUT/s$s-$name.failed" | paste -sd' ')
			printf "   s%s %-10s %s\n" "$s" "$name" "${extra:-nessuno}"
		done
	done
fi

echo
echo "Log, elenchi dei test falliti e diff in $OUT/"