#!/usr/bin/env bash
# Verifica che speedtest1 dia gli stessi risultati in tutti gli stage.
#
# Uso: ./test-sqlite.sh [-s <size>] <stage>[,<stage>...]      (nella cartella del benchmark)
#
#   ./test-sqlite.sh 1,2,3,4
#
# Opzioni:
#   -s <numero>   dimensione del test (--size di speedtest1)   (default 50)
#
# speedtest1 --verify calcola un hash di tutti i risultati delle query: gli
# sviluppatori di SQLite lo usano proprio per accorgersi di una compilazione
# che produce risultati sbagliati. L'hash non dipende da ottimizzazioni,
# thread o tipo di database, quindi ogni stage deve dare lo stesso hash dello
# stage 0 in ogni configurazione:
#   memdb     database in memoria
#   file      database su file (pager, journal, syscall)
#   threads   database su file, ordinamenti con 4 thread (slot dei thread)
# Lo stage 0 viene sempre eseguito come riferimento.
set -uo pipefail

SIZE=50

die() { echo "test-sqlite: $*" >&2; exit 1; }

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

while getopts "s:h" opt; do
	case $opt in
		s) SIZE=$OPTARG ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
IFS=, read -r -a ARGS <<< "$1"

# lo stage 0 per primo, una volta sola
STAGES=(0)
for s in "${ARGS[@]}"; do
	case $s in 0|1|2|3|4) ;; *) die "stage non valido: $s (0-4)" ;; esac
	[ "$s" -eq 0 ] || STAGES+=("$s")
done

for s in "${STAGES[@]}"; do
	[ -x "build/stage$s/speedtest1" ] || die "manca build/stage$s/speedtest1 (make STAGE=$s all)"
	[ "$s" -eq 0 ] || [ -e /dev/shdwstck ] || die "/dev/shdwstck non esiste: carica il modulo"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM

CONFIGS=(memdb file threads)

# run <stage> <config>: stampa l'hash, o ERRORE con il codice di uscita
run() {
	local bin=build/stage$1/speedtest1 out=$TMP/out rc
	rm -f "$TMP/db"*
	case $2 in
		memdb)   "$bin" --verify --size "$SIZE" --memdb > "$out" 2>&1 ;;
		file)    "$bin" --verify --size "$SIZE" "$TMP/db" > "$out" 2>&1 ;;
		threads) "$bin" --verify --size "$SIZE" --threads 4 "$TMP/db" > "$out" 2>&1 ;;
	esac
	rc=$?
	if [ $rc -ne 0 ]; then
		cp "$out" "speedtest1-s$1-$2.err"
		echo "ERRORE(exit $rc)"
		return
	fi
	sed -n 's/^Verification Hash: //p' "$out"
}

declare -A REF
FAIL=0
printf "%-7s %-8s %s\n" stage config hash
for s in "${STAGES[@]}"; do
	for c in "${CONFIGS[@]}"; do
		h=$(run "$s" "$c")
		if [ "$s" -eq 0 ]; then
			REF[$c]=$h
			mark="(riferimento)"
		elif [ "$h" = "${REF[$c]}" ]; then
			mark="ok"
		else
			mark="DIVERSO"
			FAIL=1
		fi
		printf "%-7s %-8s %s %s\n" "s$s" "$c" "$h" "$mark"
	done
done

echo
if [ $FAIL -eq 0 ]; then
	echo "Tutti gli stage danno gli stessi risultati dello stage 0."
else
	echo "Almeno uno stage dà risultati diversi o termina con errore (output in speedtest1-s*.err)."
	exit 1
fi