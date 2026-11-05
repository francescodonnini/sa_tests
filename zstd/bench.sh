#!/usr/bin/env bash
# Benchmark di zstd: velocità di compressione e decompressione in memoria
# (zstd -b, il benchmark integrato), ai livelli 1, 3 e 9.
#   Uso: ./bench.sh [-r ripetizioni] [-f file] <stage>[,<stage>...]
#
# Input di default: 100 MB generati da datagen (compressibilità circa 3x,
# riproducibile). Con -f si usa un file reale, per esempio un tar del kernel o
# il corpus Silesia. Ogni misura dura qualche secondo (-i) su un solo core;
# gli stage si alternano dentro ogni ripetizione. Valori in MB/s: più alto è
# meglio, quindi nel riepilogo una percentuale negativa è un rallentamento.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

RUNS=5
INPUT=
while getopts "r:f:" opt; do
	case $opt in
		r) RUNS=$OPTARG ;;
		f) INPUT=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-r ripetizioni] [-f file] <stage>[,<stage>...]"
parse_stages "$1"

DIR=$SS_ROOT/zstd
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/zstd" ] || die "stage $s: $DIR/s$s/zstd non trovato (lancia build.sh $s)"
done
if [ -z "$INPUT" ]; then
	INPUT=$DIR/bench-input.dat
	if [ ! -f "$INPUT" ]; then
		B=$DIR/build-s${STAGES[0]}
		"$B/tests/datagen" -g100MB -s1 > "$INPUT" || die "datagen fallito"
	fi
fi
[ -f "$INPUT" ] || die "file non trovato: $INPUT"

# livello:secondi per misura. Niente livelli alti: a 1 MB/s zstd stampa una
# sola cifra decimale e la misura perde precisione.
LEVELS="1:3 3:3 9:4"

OUT=$(result_path bench zstd).csv
echo "stage,test,run,MB/s" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	for l in $LEVELS; do
		lvl=${l%:*}
		sec=${l#*:}
		for s in "${STAGES[@]}"; do
			# -q stampa una riga sola:  -3  31252050 (3.355) 172.45 MB/s  660.1 MB/s  file
			line=$(taskset -c 1 "$DIR/s$s/zstd" -q -b"$lvl" -i"$sec" "$INPUT" 2>&1 | grep "^ *-$lvl ") ||
				die "s$s livello $lvl: benchmark fallito"
			read -r c d <<< "$(echo "$line" | awk '{print $4, $6}')"
			echo "s$s,L$lvl-compress,$run,$c" >> "$OUT"
			echo "s$s,L$lvl-decompress,$run,$d" >> "$OUT"
		done
	done
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in MB/s; percentuale rispetto a s${STAGES[0]}, negativa = più lento)"
