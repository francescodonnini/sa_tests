#!/usr/bin/env bash
# Test di zstd sugli stage indicati.
#   Uso: ./test.sh [-i iterazioni] <stage>[,<stage>...]      es. ./test.sh 0,4
#
#   playTests.sh   test della CLI (circa 1000 casi: formati, dizionari, thread, file)
#   fuzzer         compressione/decompressione su dati casuali, API a blocchi
#   zstreamtest    lo stesso con l'API streaming (anche --newapi, multithread)
# I due fuzzer usano un seme fisso e un numero fisso di iterazioni (-i, default 1000,
# circa 1-2 minuti per fuzzer), quindi ogni stage esegue esattamente gli stessi casi.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

ITER=1000
while getopts "i:" opt; do
	case $opt in i) ITER=$OPTARG ;; *) die "opzione non valida" ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-i iterazioni] <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/zstd
OUT=$(result_path test zstd)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -x "$DIR/s$s/zstd" ] && [ -x "$B/tests/fuzzer" ] || die "stage $s: lancia build.sh $s"
	: > "$OUT/s$s.failed"
	for t in playTests fuzzer zstreamtest zstreamtest-newapi; do
		log=$OUT/s$s-$t.log
		t0=$(now)
		case $t in
			playTests)   (cd "$B/tests" && ZSTD_BIN="$DIR/s$s/zstd" DATAGEN_BIN=./datagen ./playTests.sh) ;;
			fuzzer)      "$B/tests/fuzzer" -s1234 -i"$ITER" ;;
			zstreamtest) "$B/tests/zstreamtest" -s1234 -i"$ITER" ;;
			zstreamtest-newapi) "$B/tests/zstreamtest" --newapi -t1 -s1234 -i"$ITER" ;;
		esac > "$log" 2>&1 < /dev/null
		rc=$?
		if [ $rc -eq 0 ]; then
			echo "s$s $t: ok ($(seconds "$t0") s)"
		else
			echo "$t" >> "$OUT/s$s.failed"
			echo "s$s $t: FALLITO (exit $rc): vedi $log"
		fi
	done
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"
