#!/usr/bin/env bash
# Verifica che speedtest1 dia gli stessi risultati in tutti gli stage.
#   Uso: ./test.sh [-s size] <stage>[,<stage>...]      es. ./test.sh 0,4
#
# speedtest1 --verify calcola un hash di tutti i risultati delle query: gli
# sviluppatori di SQLite lo usano per accorgersi di una compilazione che
# produce risultati sbagliati. L'hash non dipende da ottimizzazioni, thread o
# tipo di database, quindi ogni stage deve dare lo stesso hash dello stage 0
# in ogni configurazione:
#   memdb     database in memoria
#   file      database su file (pager, journal, syscall)
#   threads   database su file, ordinamenti con 4 thread
# Lo stage 0 viene sempre eseguito come riferimento. -s: dimensione (default 50).
set -uo pipefail
. "$(dirname "$0")/../common.sh"

SIZE=50
while getopts "s:" opt; do
	case $opt in s) SIZE=$OPTARG ;; *) die "opzione non valida" ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-s size] <stage>[,<stage>...]"
parse_stages "0,$1"
# lo stage 0 una volta sola, per primo
mapfile -t STAGES < <(printf '%s\n' "${STAGES[@]}" | awk '!seen[$0]++')

DIR=$SS_ROOT/sqlite
OUT=$PWD/test-sqlite-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/speedtest1" ] || die "stage $s: lancia build.sh $s"
done

CONFIGS="memdb file threads"
declare -A REF
for s in "${STAGES[@]}"; do
	: > "$OUT/s$s.failed"
	for c in $CONFIGS; do
		db=$OUT/s$s-$c.db
		rm -f "$db"*
		case $c in
			memdb)   args=(--memdb) ;;
			file)    args=("$db") ;;
			threads) args=(--threads 4 "$db") ;;
		esac
		"$DIR/s$s/speedtest1" --verify --size "$SIZE" "${args[@]}" > "$OUT/s$s-$c.log" 2>&1
		rc=$?
		rm -f "$db"*
		h=$(sed -n 's/^Verification Hash: //p' "$OUT/s$s-$c.log")
		[ $rc -eq 0 ] && [ -n "$h" ] || h="ERRORE(exit $rc)"
		if [ "$s" -eq 0 ]; then
			REF[$c]=$h
			mark="(riferimento)"
			case $h in ERRORE*) echo "$c" >> "$OUT/s$s.failed" ;; esac
		elif [ "$h" = "${REF[$c]}" ]; then
			mark="ok"
		else
			mark="DIVERSO"
			echo "$c" >> "$OUT/s$s.failed"
		fi
		printf "s%s %-8s %s %s\n" "$s" "$c" "$h" "$mark"
	done
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/"
