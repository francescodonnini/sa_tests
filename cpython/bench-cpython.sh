#!/usr/bin/env bash
# Benchmark di CPython: pyperformance, la suite ufficiale di benchmark di Python
# (circa 80 benchmark: interprete, json, regex, pickle, asyncio, template...).
#   Uso: ./bench-cpython.sh [-b benchmark] [-f] <stage>[,<stage>...]
#
#   -b   benchmark da eseguire (sintassi di pyperformance, default "default")
#   -f   modalità --fast di pyperformance (meno processi e valori, circa 4 volte
#        più veloce, meno preciso)
# pyperformance viene installato una volta in un venv separato. Per ogni stage
# crea da sé un venv con le dipendenze dei benchmark (serve la rete la prima volta)
# e gestisce da solo ripetizioni, processi e riscaldamento; per questo gli stage
# girano uno dopo l'altro e non alternati. Senza -f l'intera suite richiede
# circa un'ora per stage. Il confronto finale è di pyperf (compare_to), rispetto
# al primo stage; per un sistema più stabile si può usare "pyperf system tune".
set -uo pipefail
. "$(dirname "$0")/common.sh"

: "${PYPERFORMANCE_VERSION:=1.14.0}"
BENCH=default
FAST=
while getopts "b:f" opt; do
	case $opt in
		b) BENCH=$OPTARG ;;
		f) FAST=--fast ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-b benchmark] [-f] <stage>[,<stage>...]"
parse_stages "$1"

DIR=$SS_ROOT/cpython
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/bin/python3" ] || die "stage $s: lancia build-cpython.sh $s"
done

# pyperformance gira con il python di sistema e lancia i benchmark con --python
PP=$DIR/pyperformance-venv
if [ ! -x "$PP/bin/pyperformance" ]; then
	echo "== installo pyperformance $PYPERFORMANCE_VERSION in $PP"
	python3 -m venv "$PP" && "$PP/bin/pip" install -q "pyperformance==$PYPERFORMANCE_VERSION" ||
		die "installazione di pyperformance fallita"
fi

OUT=$PWD/bench-cpython-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
for s in "${STAGES[@]}"; do
	echo "== stage $s"
	t0=$(now)
	# --affinity: i processi dei benchmark su un solo core, come negli altri script
	"$PP/bin/pyperformance" run $FAST -b "$BENCH" --affinity 1 \
		--python "$DIR/s$s/bin/python3" \
		-o "$OUT/s$s.json" > "$OUT/s$s.log" 2>&1 || die "s$s: pyperformance fallito, vedi $OUT/s$s.log"
	echo "   $(seconds "$t0") s"
done

echo
ref=${STAGES[0]}
others=()
for s in "${STAGES[@]:1}"; do others+=("$OUT/s$s.json"); done
if [ ${#others[@]} -gt 0 ]; then
	"$PP/bin/python3" -m pyperf compare_to --table -G "$OUT/s$ref.json" "${others[@]}" | tee "$OUT/confronto.txt"
fi
echo
echo "Risultati in $OUT/ (JSON di pyperf; confronto rispetto a s$ref in confronto.txt)"
