#!/usr/bin/env bash
# Suite di test di memcached (make test) sugli stage indicati.
#   Uso: ./test-memcached.sh [-j job] <stage>[,<stage>...]      es. ./test-memcached.sh 0,4
#
# make test esegue sizes, testapp (test in C del protocollo binario e del
# server) e i circa 100 script Perl in t/ (protocolli text/meta/binary, LRU,
# slab rebalance, extstore, ...) contro memcached-debug. Servono perl e prove.
# Si confrontano i test falliti con quelli di s0.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

JOBS=$(nproc)
while getopts "j:" opt; do
	case $opt in j) JOBS=$OPTARG ;; *) die "opzione non valida" ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-j job] <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/memcached
OUT=$PWD/test-memcached-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -f "$B/ss-flags.sh" ] || die "stage $s: lancia build-memcached.sh $s"
	# shellcheck disable=SC1091
	. "$B/ss-flags.sh"
	t0=$(now)
	# stessi flag della build, altrimenti make ricompilerebbe senza strumentazione
	make -C "$B" CFLAGS="$CF" LDFLAGS="$LF" PARALLEL="$JOBS" test > "$OUT/s$s.log" 2>&1
	rc=$?
	grep -oE '^[^ ]+\.t +\(Wstat' "$OUT/s$s.log" | sed 's/ *(Wstat//; s|.*/t/|t/|' | sort -u > "$OUT/s$s.failed"
	if ! grep -q '^Result: ' "$OUT/s$s.log"; then
		# make test si ferma prima di prove se sizes o testapp falliscono
		echo "make test (exit $rc, prima di prove)" >> "$OUT/s$s.failed"
	fi
	echo "s$s: $(grep -E '^Result: ' "$OUT/s$s.log" | tail -1 || echo "non completato"), $(wc -l < "$OUT/s$s.failed") falliti ($(seconds "$t0") s)"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"
