#!/usr/bin/env bash
# Benchmark di DuckDB: le 22 query di TPC-H a scala 1 (circa 1 GB di dati),
# con il benchmark_runner di DuckDB, in un solo thread.
#   Uso: ./bench-duckdb.sh [-r ripetizioni] [-n esecuzioni] [-b pattern] <stage>[,<stage>...]
#
#   -r   ripetizioni dell'intera serie, con gli stage alternati (default 3)
#   -n   esecuzioni misurate di ogni query per ripetizione (default 3), dopo
#        una esecuzione a freddo non misurata
#   -b   benchmark da eseguire, come espressione regolare sul percorso
#        (default benchmark/tpch/sf1/.*); per esempio
#        'benchmark/micro/aggregate/.*' per i microbenchmark di aggregazione
# Il runner controlla anche il risultato di ogni query rispetto alle risposte
# ufficiali di TPC-H: un risultato sbagliato ferma lo script.
# Il database TPC-H viene generato la prima volta (dbgen dell'estensione tpch,
# circa un minuto) e tenuto in $SS_ROOT/duckdb/src/duckdb_benchmark_data, in
# comune tra gli stage: tutti leggono gli stessi dati. Valori in secondi.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

RUNS=3
NRUNS=3
PATTERN='benchmark/tpch/sf1/.*'
while getopts "r:n:b:" opt; do
	case $opt in
		r) RUNS=$OPTARG ;;
		n) NRUNS=$OPTARG ;;
		b) PATTERN=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-r ripetizioni] [-n esecuzioni] [-b pattern] <stage>[,<stage>...]"
parse_stages "$1"

DIR=$SS_ROOT/duckdb
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/build-s$s/build/benchmark/benchmark_runner" ] || die "stage $s: lancia build-duckdb.sh $s"
done
OUT=$PWD/bench-duckdb-$(date +%Y%m%d-%H%M%S).csv
echo "stage,test,run,secondi" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	for s in "${STAGES[@]}"; do
		LOG=${OUT%.csv}-s$s.log
		# --root-dir: file .benchmark e dati in comune. Il runner scrive su stderr
		# una riga "percorso<TAB>run<TAB>secondi" per ogni esecuzione misurata
		# (--out conterrebbe solo i tempi, senza il nome)
		taskset -c 1 "$DIR/build-s$s/build/benchmark/benchmark_runner" "$PATTERN" \
			--root-dir "$DIR/src" --threads=1 --timed-runs "$NRUNS" --disable-timeout \
			> /dev/null 2> "$LOG"
		bad=$(grep -E $'\t(ERROR|TIMEOUT|INCORRECT)$|INCORRECT RESULT' "$LOG" | head)
		[ -z "$bad" ] || die "s$s: risultato sbagliato o errore (log completo: $LOG)"$'\n'"$bad"
		# nome del test: q01 da benchmark/tpch/sf1/q01.benchmark; numero di run
		# progressivo su tutte le ripetizioni
		n=$(awk -F'\t' -v s="s$s" -v base=$(( (run - 1) * NRUNS )) \
			'NF == 3 && $1 ~ /\.benchmark$/ && $3 ~ /^[0-9.]+$/ {n = $1; sub(/^.*\//, "", n); sub(/\.benchmark$/, "", n);
			 print s "," n "," base + $2 "," $3}' "$LOG" | tee -a "$OUT" | wc -l)
		[ "$n" -gt 0 ] || die "s$s: nessun risultato per '$PATTERN'"$'\n'"$(tail -20 "$LOG")"
	done
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in secondi; percentuale rispetto a s${STAGES[0]})"