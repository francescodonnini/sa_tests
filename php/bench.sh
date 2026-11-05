#!/usr/bin/env bash
# Benchmark di PHP: Zend/bench.php e Zend/micro_bench.php, i benchmark del
# motore distribuiti con PHP (bench.php: mandel, ackermann, fibo, hash,
# heapsort, matrix, sieve, strcat...; micro_bench.php: chiamate, proprietà,
# accessi statici, array, ...). Ogni sotto-test stampa il suo tempo.
#   Uso: ./bench.sh [-r ripetizioni] <stage>[,<stage>...]
#
# Per micro_bench si registra il tempo lordo (senza sottrarre il ciclo vuoto).
# opcache è disattivato per la CLI (default), quindi si misura l'interprete.
# Gli stage si alternano dentro ogni ripetizione. Valori in secondi.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

RUNS=5
while getopts "r:" opt; do
	case $opt in r) RUNS=$OPTARG ;; *) die "opzione non valida" ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-r ripetizioni] <stage>[,<stage>...]"
parse_stages "$1"

DIR=$SS_ROOT/php
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/php" ] || die "stage $s: $DIR/s$s/php non trovato (lancia build.sh $s)"
done

OUT=$(result_path bench php).csv
echo "stage,test,run,secondi" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	for b in bench micro_bench; do
		for s in "${STAGES[@]}"; do
			# -n: nessun php.ini
			res=$(taskset -c 1 "$DIR/s$s/php" -n "$DIR/src/Zend/$b.php") || die "s$s $b.php: terminato con errore"
			# righe "nome<spazi>tempo[<spazi>tempo netto]"; i nomi possono contenere spazi
			echo "$res" | awk -v pre="s$s,$b:" -v run="$run" '
				function num(x) { return x ~ /^-?[0-9][0-9.,]*$/ }
				NF >= 2 && num($NF) {
					k = (NF >= 3 && num($(NF - 1))) ? NF - 1 : NF   # colonna del tempo lordo
					t = $k; gsub(",", "", t)
					name = $1; for (i = 2; i < k; i++) name = name " " $i
					gsub(",", ";", name)
					print pre name "," run "," t
				}' >> "$OUT"
		done
	done
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in secondi; percentuale rispetto a s${STAGES[0]})"
