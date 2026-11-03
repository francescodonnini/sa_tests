#!/usr/bin/env bash
# Benchmark di xz: tempo di compressione (preset -1 e -6, il default) e di
# decompressione di un file, in un solo thread (-T1).
#   Uso: ./bench-xz.sh [-r ripetizioni] [-f file] <stage>[,<stage>...]
#
# Input di default: un tar dei sorgenti di xz (circa 8 MB, testo e codice: il
# caso tipico di xz), creato con ordine e date fissi, quindi identico ad ogni
# esecuzione. Con -f si usa un altro file. Il file compresso per la
# decompressione viene da s0, uguale per tutti. Ogni misura ripete il comando
# più volte (COMP_N, DECOMP_N) per durare qualche secondo: la decompressione
# è molto più veloce. Gli stage si alternano dentro ogni ripetizione.
# Valori in secondi.
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

DIR=$SS_ROOT/xz
for s in "${STAGES[@]}" 0; do
	[ -x "$DIR/s$s/xz" ] || die "stage $s: $DIR/s$s/xz non trovato (lancia build-xz.sh $s)"
done
for s in "${STAGES[@]}"; do check_prereq "$s"; done

if [ -z "$INPUT" ]; then
	INPUT=$DIR/bench-input.tar
	if [ ! -f "$INPUT" ]; then
		tar -C "$DIR/src" --exclude=.git --sort=name --mtime=@0 --owner=0 --group=0 -cf "$INPUT" .
	fi
fi
[ -f "$INPUT" ] || die "file non trovato: $INPUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for p in 1 6; do
	"$DIR/s0/xz" -T1 -"$p" -c "$INPUT" > "$TMP/in.$p.xz" || die "compressione di riferimento fallita"
done
echo "input: $INPUT ($(du -h "$INPUT" | cut -f1))"

COMP_N=3
DECOMP_N=20

OUT=$PWD/bench-xz-$(date +%Y%m%d-%H%M%S).csv
echo "stage,test,run,secondi" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	for p in 1 6; do
		for s in "${STAGES[@]}"; do
			t0=$(now)
			for _ in $(seq "$COMP_N"); do
				taskset -c 1 "$DIR/s$s/xz" -T1 -"$p" -c "$INPUT" > "$TMP/out.xz" || die "s$s -$p: compressione fallita"
			done
			echo "s$s,compress-$p,$run,$(seconds "$t0")" >> "$OUT"
			# xz è deterministico: un risultato diverso da s0 è un errore
			cmp -s "$TMP/out.xz" "$TMP/in.$p.xz" || die "s$s -$p: output diverso da s0"
			t0=$(now)
			for _ in $(seq "$DECOMP_N"); do
				taskset -c 1 "$DIR/s$s/xz" -T1 -dc "$TMP/in.$p.xz" > /dev/null || die "s$s -$p: decompressione fallita"
			done
			echo "s$s,decompress-$p,$run,$(seconds "$t0")" >> "$OUT"
		done
	done
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in secondi; percentuale rispetto a s${STAGES[0]})"
