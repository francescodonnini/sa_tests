#!/usr/bin/env bash
# Suite di test di Redis (./runtest) sugli stage indicati.
#   Uso: ./test.sh [-j client] [-a "argomenti di runtest"] <stage>[,<stage>...]
#
#   ./test.sh 0,4                          suite completa
#   ./test.sh -a "--tags -slow" 0,1,4      senza i test lenti
#   ./test.sh -a "--single unit/type/list" 4
# runtest avvia il redis-server della build dello stage e lo fa lavorare con
# fork (BGSAVE, BGREWRITEAOF, replica) e thread (bio, I/O). Serve tclsh.
# Si confrontano i test falliti con quelli di s0.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

CLIENTS=$(nproc)
EXTRA=
while getopts "j:a:" opt; do
	case $opt in
		j) CLIENTS=$OPTARG ;;
		a) EXTRA=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-j client] [-a \"argomenti\"] <stage>[,<stage>...]"
parse_stages "$1"
command -v tclsh > /dev/null || die "tclsh non trovato (lancia deps-fedora.sh redis)"

DIR=$SS_ROOT/redis
OUT=$(result_path test redis)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -x "$B/src/redis-server" ] || die "stage $s: lancia build.sh $s"
	log=$OUT/s$s.log
	t0=$(now)
	# shellcheck disable=SC2086
	(cd "$B" && ./runtest --clients "$CLIENTS" --dump-logs $EXTRA) > "$log" 2>&1
	rc=$?
	# "[err]: nome del test in tests/unit/..." e "[exception]: ..."
	grep -E '^\[(err|exception)\]' "$log" | sed -E 's/^\[(err|exception)\]: //' | sort -u > "$OUT/s$s.failed"
	echo "s$s: $(grep -c '^\[ok\]' "$log") ok, $(wc -l < "$OUT/s$s.failed") falliti (exit $rc, $(seconds "$t0") s)"
	# server morti con un segnale (per esempio un crash dello shadow stack)
	n=$(grep -cE 'crashed by signal|Redis .* crashed|SIGSEGV|SIGILL' "$log" || true)
	[ "$n" -eq 0 ] || echo "   ATTENZIONE: $n righe di crash del server nel log"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"
