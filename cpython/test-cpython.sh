#!/usr/bin/env bash
# Suite di test di CPython (python -m test, circa 500 moduli di test) sugli stage indicati.
#   Uso: ./test-cpython.sh [-j job] [-u risorse] <stage>[,<stage>...]
#
#   ./test-cpython.sh 0,4              tutta la suite (10-20 minuti per stage)
#   ./test-cpython.sh -u cpu 0,4       anche i test che usano molta CPU
# I test girano nella cartella di build con ./python. Per default regrtest
# ripete una volta i test falliti (rerun): sono "falliti" quelli che falliscono
# anche la seconda volta. Si confrontano i test falliti con quelli di s0.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

JOBS=$(nproc)
RES=
while getopts "j:u:" opt; do
	case $opt in
		j) JOBS=$OPTARG ;;
		u) RES="-u $OPTARG" ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-j job] [-u risorse] <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/cpython
OUT=$PWD/test-cpython-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -x "$B/python" ] || die "stage $s: lancia build-cpython.sh $s"
	t0=$(now)
	# shellcheck disable=SC2086
	(cd "$B" && ./python -m test -j"$JOBS" $RES --timeout 1800) > "$OUT/s$s.log" 2>&1
	# blocchi "N tests failed again:" (dopo il rerun) o "N tests failed:", nomi
	# indentati sulle righe successive; si prende l'ultimo blocco
	awk '/tests? failed( again)?:$/ {f = 1; delete l; n = 0; next}
		f && /^    / {for (i = 1; i <= NF; i++) l[++n] = $i; next}
		f {f = 0}
		END {for (i = 1; i <= n; i++) print l[i]}' "$OUT/s$s.log" > "$OUT/s$s.failed"
	echo "s$s: $(grep -E '^Result: ' "$OUT/s$s.log" | tail -1 || echo "regrtest non completato"), $(wc -l < "$OUT/s$s.failed") test falliti ($(seconds "$t0") s)"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"
