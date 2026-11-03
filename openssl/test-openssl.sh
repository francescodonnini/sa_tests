#!/usr/bin/env bash
# Suite di test di OpenSSL (make test: circa 300 ricette in test/recipes, con
# migliaia di casi: algoritmi, vettori di test, TLS/DTLS end-to-end, X.509, ...).
#   Uso: ./test-openssl.sh [-j job] <stage>[,<stage>...]      es. ./test-openssl.sh 0,4
#
# Qualche minuto per stage. Si confrontano le ricette fallite con quelle di s0.
set -uo pipefail
. "$(dirname "$0")/common.sh"

JOBS=$(nproc)
while getopts "j:" opt; do
	case $opt in j) JOBS=$OPTARG ;; *) die "opzione non valida" ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-j job] <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/openssl
OUT=$PWD/test-openssl-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -f "$B/ss-flags.sh" ] || die "stage $s: lancia build-openssl.sh $s"
	# shellcheck disable=SC1091
	. "$B/ss-flags.sh"
	t0=$(now)
	# stessi flag della build: make test ricompila se sono diversi
	make -C "$B" CFLAGS="$CF" LDFLAGS="$LF" HARNESS_JOBS="$JOBS" test > "$OUT/s$s.log" 2>&1
	# riepilogo di TAP::Harness: "../test/recipes/xx.t (Wstat: ... Tests: ... Failed: N)"
	grep -oE '[^ ]*test/recipes/[^ ]+\.t +\(Wstat' "$OUT/s$s.log" | sed 's/ *(Wstat//; s|.*test/recipes/||' |
		sort -u > "$OUT/s$s.failed"
	echo "s$s: $(grep -E '^Result: ' "$OUT/s$s.log" | tail -1 || echo "nessun risultato"), $(wc -l < "$OUT/s$s.failed") ricette fallite ($(seconds "$t0") s)"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"
