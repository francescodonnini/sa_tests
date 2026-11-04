#!/usr/bin/env bash
# Suite di test di PHP (run-tests.php, i file .phpt) sugli stage indicati.
#   Uso: ./test-php.sh [-j job] <stage>[,<stage>...]      es. ./test-php.sh 0,4
#
# Con --disable-all restano circa 10000 test: motore Zend, linguaggio, standard,
# pcre, spl, date, json, hash, random, ... (qualche minuto per stage).
# Alcuni test falliscono o vengono saltati anche in s0 (rete, locale, ...):
# si confrontano i test falliti di ogni stage con quelli di s0.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

JOBS=$(nproc)
while getopts "j:" opt; do
	case $opt in j) JOBS=$OPTARG ;; *) die "opzione non valida" ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-j job] <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/php
OUT=$PWD/test-php-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -x "$B/sapi/cli/php" ] || die "stage $s: lancia build-php.sh $s"
	t0=$(now)
	# -w: elenco dei test falliti; NO_INTERACTION: niente domande a fine run
	(cd "$B" && NO_INTERACTION=1 TEST_PHP_EXECUTABLE=sapi/cli/php \
		sapi/cli/php run-tests.php -q -j"$JOBS" -w "$OUT/s$s.failed" \
		Zend tests ext sapi/cli) > "$OUT/s$s.log" 2>&1
	[ -f "$OUT/s$s.failed" ] || : > "$OUT/s$s.failed"
	# riepilogo di run-tests: righe "Tests passed : N (...)" ecc.
	sum=$(grep -E '^Tests (passed|failed|skipped) *:' "$OUT/s$s.log" | awk -F: '{split($2, a, " "); printf "%s %s, ", $1, a[1]}')
	echo "s$s: ${sum:-run-tests non completato, vedi $OUT/s$s.log }($(seconds "$t0") s)"
	sed -i "s|^$B/||" "$OUT/s$s.failed"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/ (diff dei test falliti: file .diff accanto ai .phpt nella build)"
