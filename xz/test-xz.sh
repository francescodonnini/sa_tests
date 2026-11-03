#!/usr/bin/env bash
# Suite di test di xz (ctest) sugli stage indicati.
#   Uso: ./test-xz.sh <stage>[,<stage>...]      es. ./test-xz.sh 0,4
#
# Comprende i test unitari di liblzma (filtri, check, index, block, stream, ...),
# test_files.sh (decodifica dei file di prova, anche corrotti di proposito),
# test_compress_* (compressione e decompressione con filtri diversi) e i test
# degli script. Pochi secondi per stage.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

[ $# -eq 1 ] || die "uso: $0 <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/xz
OUT=$PWD/test-xz-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s/build
	[ -x "$B/xz" ] || die "stage $s: $B/xz non trovato (lancia build-xz.sh $s)"
	log=$OUT/s$s.log
	rm -f "$B/Testing/Temporary/LastTestsFailed.log"
	ctest --test-dir "$B" -j"$(nproc)" --output-on-failure > "$log" 2>&1
	rc=$?
	# LastTestsFailed.log: una riga "numero:nome" per test fallito
	cut -d: -f2- "$B/Testing/Temporary/LastTestsFailed.log" > "$OUT/s$s.failed" 2>/dev/null ||
		: > "$OUT/s$s.failed"
	echo "s$s: $(grep -o '[0-9]*% tests passed.*' "$log" || echo "ctest exit $rc, vedi $log")"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"
