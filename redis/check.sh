#!/usr/bin/env bash
# Esegue la suite di test di Redis (./runtest) sui build dei vari stage e
# confronta i test falliti con quelli dello stage 0.
#
# Uso: ./test-redis.sh [-j <client>] [-a "<argomenti di runtest>"] <stage>[,<stage>...]
#
#   ./test-redis.sh 0,4                         suite completa su s0 e s4
#   ./test-redis.sh -a "--tags -slow" 0,1,4     senza i test lenti
#   ./test-redis.sh -a "--single unit/type/list" 4
#
# Opzioni:
#   -j <numero>   test eseguiti in parallelo da runtest   (default: numero di CPU)
#   -a "<arg>"    argomenti aggiuntivi per runtest
#
# Usa le cartelle lasciate da build-redis.sh ($BUILD_ROOT/build-s<N>): runtest
# avvia il redis-server di src/, cioè proprio quello strumentato, e lo fa
# lavorare con fork (BGSAVE, BGREWRITEAOF, replica) e thread (bio, I/O).
# Richiede tclsh (Fedora: sudo dnf install tcl).
# Log in test-redis-<data>/. Lo stage 0 serve da riferimento: un test che
# fallisce anche lì dipende dall'ambiente, non dallo shadow stack.
set -uo pipefail

BUILD_ROOT=$HOME/redis-build

die() { echo "test-redis: $*" >&2; exit 1; }

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

CLIENTS=$(nproc)
EXTRA=""
while getopts "j:a:h" opt; do
	case $opt in
		j) CLIENTS=$OPTARG ;;
		a) EXTRA=$OPTARG ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
IFS=, read -r -a STAGES <<< "$1"

command -v tclsh > /dev/null || die "tclsh non trovato (Fedora: sudo dnf install tcl)"
for s in "${STAGES[@]}"; do
	case $s in 0|1|2|3|4) ;; *) die "stage non valido: $s (0-4)" ;; esac
	[ -x "$BUILD_ROOT/build-s$s/src/redis-server" ] ||
		die "stage $s: $BUILD_ROOT/build-s$s/src/redis-server non trovato (lancia build-redis.sh $s)"
	[ "$s" -eq 0 ] || [ -e /dev/shdwstck ] || die "/dev/shdwstck non esiste: carica il modulo"
done

OUT=$PWD/test-redis-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

# Ctrl+C: runtest termina i suoi server, lo script si ferma subito
trap 'exit 130' INT TERM

for s in "${STAGES[@]}"; do
	log=$OUT/s$s.log
	echo "== s$s (log: $log)"
	# shellcheck disable=SC2086
	(cd "$BUILD_ROOT/build-s$s" && ./runtest --clients "$CLIENTS" --dump-logs $EXTRA) > "$log" 2>&1
	rc=$?

	# "[err]: nome del test in tests/unit/..." e "[exception]: ..."
	grep -E '^\[(err|exception)\]' "$log" | sed -E 's/^\[(err|exception)\]: //' | sort -u > "$OUT/s$s.failed"
	nfail=$(wc -l < "$OUT/s$s.failed")
	if [ $rc -eq 0 ] && [ "$nfail" -eq 0 ]; then
		echo "   ok: $(grep -c '^\[ok\]' "$log") test superati"
	else
		echo "   FALLITO (exit $rc): $nfail test, $(grep -c '^\[ok\]' "$log") superati"
		sed 's/^/     /' "$OUT/s$s.failed" | head -20
	fi
	# server morti con un segnale (per esempio SIGSEGV dello shadow stack)
	n=$(grep -cE 'crashed by signal|Redis .* crashed|SIGSEGV|SIGILL' "$log" || true)
	[ "$n" -eq 0 ] || echo "   ATTENZIONE: $n righe di crash del server nel log"
done

if [ -f "$OUT/s0.failed" ]; then
	echo
	echo "== confronto con s0 (test che falliscono solo nello stage)"
	for s in "${STAGES[@]}"; do
		[ "$s" -eq 0 ] && continue
		extra=$(comm -13 "$OUT/s0.failed" "$OUT/s$s.failed")
		if [ -z "$extra" ]; then
			echo "   s$s: nessuno"
		else
			echo "   s$s:"
			echo "$extra" | sed 's/^/     /'
		fi
	done
fi

echo
echo "Log ed elenchi dei test falliti in $OUT/"