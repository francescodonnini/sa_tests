#!/usr/bin/env bash
# Benchmark di SQLite con speedtest1: circa 30 prove (insert, select con e
# senza indici, update, delete, vacuum, ...) su un database in memoria.
#   Uso: ./bench.sh [-r ripetizioni] [-s size] <stage>[,<stage>...]
#
# -s scala il carico (default 100, il default di speedtest1). Ogni prova
# stampa il proprio tempo, al millisecondo: nel CSV c'è una riga per prova
# (t100, t110, ...) più TOTAL. Un solo core; gli stage si alternano dentro
# ogni ripetizione. Valori in secondi.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

RUNS=5
SIZE=100
while getopts "r:s:" opt; do
	case $opt in
		r) RUNS=$OPTARG ;;
		s) SIZE=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-r ripetizioni] [-s size] <stage>[,<stage>...]"
parse_stages "$1"

DIR=$SS_ROOT/sqlite
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/speedtest1" ] || die "stage $s: lancia build.sh $s"
done

OUT=$(result_path bench sqlite).csv
echo "stage,test,run,secondi" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	for s in "${STAGES[@]}"; do
		# righe " 100 - 50000 INSERTs into table ........   0.123s" e
		# "       TOTAL.......   1.234s"
		res=$(taskset -c 1 "$DIR/s$s/speedtest1" --size "$SIZE" --memdb 2>&1) ||
			die "s$s: speedtest1 terminato con errore"$'\n'"$(echo "$res" | tail -5)"
		echo "$res" | awk -v p="s$s" -v r="$run" '
			/^ *[0-9]+ - / {v = $NF; sub(/s$/, "", v); print p ",t" $1 "," r "," v}
			/^ *TOTAL/     {v = $NF; sub(/s$/, "", v); print p ",TOTAL," r "," v}' >> "$OUT"
	done
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in secondi; percentuale rispetto a s${STAGES[0]})"
