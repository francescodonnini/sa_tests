#!/usr/bin/env bash
# Suite di test di DuckDB sugli stage indicati.
#   Uso: ./test.sh [-j job] [-p pattern] <stage>[,<stage>...]
#
#   ./test.sh 0,4                      i test di default (senza quelli lenti)
#   ./test.sh -p 'test/sql/join/*' 0,4  solo una parte
# Si usa build/test/run, il runner di DuckDB (scripts/ci/run_tests.py): divide
# i test (circa 4000 file sqllogictest più i test C++) in gruppi eseguiti da
# più processi unittest in parallelo, così un crash ferma solo il suo gruppo.
# I test che richiedono estensioni non compilate (httpfs, icu, ...) vengono
# saltati, uguali in ogni stage. Si confrontano i test falliti con quelli di s0.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

JOBS=$(( $(nproc) * 3 / 4 ))
PATTERN=
while getopts "j:p:" opt; do
	case $opt in
		j) JOBS=$OPTARG ;;
		p) PATTERN=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-j job] [-p pattern] <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/duckdb
OUT=$(result_path test duckdb)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -x "$B/build/test/unittest" ] || die "stage $s: lancia build.sh $s"
	t0=$(now)
	# i percorsi dei test sono relativi alla radice dei sorgenti
	# shellcheck disable=SC2086
	(cd "$B" && build/test/run --workers="$JOBS" ${PATTERN:+"$PATTERN"}) > "$OUT/s$s.log" 2>&1
	# a fine run, se qualcosa fallisce, il runner stampa "reproduce all failed
	# tests:" e sotto un comando con i nomi tra virgolette separati da virgole
	python3 - "$OUT/s$s.log" > "$OUT/s$s.failed" <<'EOF'
import re, shlex, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
for i, l in enumerate(lines):
    if l.strip() == "reproduce all failed tests:" and i + 1 < len(lines):
        last = shlex.split(lines[i + 1])[-1]
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', last):
            print(m.group(1).replace('\\"', '"').replace("\\\\", "\\"))
EOF
	res=$(grep -E 'ran tests:' "$OUT/s$s.log" | tail -1 | sed 's/^[^r]*ran tests: //')
	echo "s$s: ${res:-runner non completato, vedi $OUT/s$s.log}, $(wc -l < "$OUT/s$s.failed") falliti ($(seconds "$t0") s)"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"