#!/usr/bin/env bash
# Esegue speedtest1 per più stage, alternandoli a ogni ripetizione.
#   Uso: ./bench.sh [stage, es. 0,1,2,3,4] [ripetizioni]
#   SIZE e CPU si cambiano con variabili d'ambiente.
set -euo pipefail
. "$(dirname "$0")/../common.sh"

parse_stages "${1:-0,1,2,3,4}"
RUNS=${2:-10}
: "${SIZE:=200}" "${CPU:=2}"
DIR=$SS_ROOT/sqlite
[ -e /dev/shdwstck ] || die "/dev/shdwstck non esiste: carica il modulo"
for s in "${STAGES[@]}"; do verify_bin "$DIR/s$s/speedtest1" "$s"; done

OUT=$(result_path bench sqlite)
echo "# SIZE=$SIZE MASK_FLAGS=$MASK_FLAGS" > "$OUT.info"
echo "stage,test,run,valore" > "$OUT.csv"
for r in $(seq "$RUNS"); do
	for s in "${STAGES[@]}"; do
		perf stat -x, -e cycles:u,instructions:u -o "$OUT.perf" \
			taskset -c "$CPU" "$DIR/s$s/speedtest1" --memdb --size "$SIZE" > "$OUT.log"
		# tempi dei sotto-test: " 100 - descrizione.......   0.123s" e la riga TOTAL
		awk -v s="s$s" -v r="$r" '/\.\.\. *[0-9.]+s$/ {
		t = $1; sub(/\.+$/, "", t); v = $NF; sub(/s$/, "", v)
		printf "%s,%03d-%s,%s,%s\n", s, ++i, t, r, v }' "$OUT.log" >> "$OUT.csv"
		# contatori: "valore,,evento,..."
		awk -F, -v s="s$s" -v r="$r" '$3 ~ /^(cycles|instructions)/ {
			e = $3; sub(/:u$/, "", e); print s "," e "," r "," $1 }' "$OUT.perf" >> "$OUT.csv"
	done
done
summary "$OUT.csv" 0
echo; summary "$OUT.csv" 3