#!/usr/bin/env bash
# Benchmark di Postgres con pgbench.
#   Uso: ./bench.sh [opzioni] <stage>[,<stage>...]      es. ./bench.sh 0,1,2,3,4
#
#   tpcb      TPC-B completo (pgbench default), prepared statement
#   select    solo SELECT per chiave
#   connect   una connessione nuova per transazione: ogni connessione è un
#             fork del server, quindi misura anche il costo del fork
# Opzioni:
#   -d secondi    durata di ogni esecuzione              (default 60)
#   -r numero     ripetizioni per ogni test              (default 5)
#   -t test,...   test da eseguire                       (default tpcb,select,connect)
#   -c numero     client pgbench                         (default 8)
#   -j numero     thread pgbench                         (default 4)
#   -w secondi    riscaldamento, scartato                (default 30)
# Per ogni stage: avvio del server (dati in $SS_ROOT/postgres/data-sN), tabelle
# ricreate a scala 50 (circa 750 MB), riscaldamento, misure. Gli stage girano
# uno dopo l'altro: avvio e caricamento sono troppo lunghi per alternarli.
# Commit asincrono e tabelle in memoria: si misura la CPU, non il disco.
# pgbench è sempre quello dello stage 0, così si misura solo il server.
# Valori in transazioni al secondo: più alto è meglio.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

PORT=5433
SCALE=50
DURATION=60
RUNS=5
CLIENTS=8
THREADS=4
WARMUP=30
TESTS=tpcb,select,connect
while getopts "d:r:t:c:j:w:" opt; do
	case $opt in
		d) DURATION=$OPTARG ;;
		r) RUNS=$OPTARG ;;
		t) TESTS=$OPTARG ;;
		c) CLIENTS=$OPTARG ;;
		j) THREADS=$OPTARG ;;
		w) WARMUP=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [opzioni] <stage>[,<stage>...]"
parse_stages "$1"
IFS=, read -r -a TEST_LIST <<< "$TESTS"
for t in "${TEST_LIST[@]}"; do
	case $t in tpcb|select|connect) ;; *) die "test sconosciuto: $t" ;; esac
done

DIR=$SS_ROOT/postgres
PGBENCH=$DIR/s0/bin/pgbench
[ -x "$PGBENCH" ] || die "manca $PGBENCH (lancia build.sh 0)"
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/bin/postgres" ] || die "stage $s: lancia build.sh $s"
done
if "$DIR/s0/bin/pg_isready" -q -p $PORT 2> /dev/null; then
	die "c'è già un server sulla porta $PORT (fermalo con pg_ctl -D $DIR/data-sN stop)"
fi

OUT=$PWD/bench-postgres-$(date +%Y%m%d-%H%M%S).csv
echo "stage,test,run,tps" > "$OUT"
echo "durata ${DURATION}s, $RUNS ripetizioni, test: $TESTS, client $CLIENTS, thread $THREADS"

pgb() { "$PGBENCH" -p $PORT -U postgres "$@" postgres; }

for s in "${STAGES[@]}"; do
	BIN=$DIR/s$s/bin
	DATA=$DIR/data-s$s
	LOG=$DIR/s$s.log
	echo "== s$s"
	[ -d "$DATA" ] || "$BIN/initdb" -D "$DATA" -U postgres > /dev/null ||
		die "s$s: initdb fallito"
	"$BIN/pg_ctl" -D "$DATA" -l "$LOG" -w \
		-o "-p $PORT -c synchronous_commit=off -c shared_buffers=1GB" start > /dev/null ||
		die "s$s: avvio fallito, vedi $LOG"
	# se qualcosa fallisce o si preme Ctrl+C, il server non deve restare acceso
	trap '"$BIN/pg_ctl" -D "$DATA" -m fast -w stop > /dev/null 2>&1 || true' EXIT

	pgb -i -s $SCALE -q > /dev/null 2>&1 || die "s$s: pgbench -i fallito"
	if [ "$WARMUP" -gt 0 ]; then
		echo "   riscaldamento (${WARMUP} s, scartato)"
		pgb -c "$CLIENTS" -j "$THREADS" -T "$WARMUP" > /dev/null 2>&1
	fi
	for test in "${TEST_LIST[@]}"; do
		case $test in
			tpcb)    opts=(-M prepared) ;;
			select)  opts=(-S -M prepared) ;;
			connect) opts=(-C) ;;
		esac
		for run in $(seq 1 "$RUNS"); do
			v=$(pgb -c "$CLIENTS" -j "$THREADS" -T "$DURATION" "${opts[@]}" 2> /dev/null |
				awk '/^tps/ {print $3}')
			[ -n "$v" ] || die "s$s $test #$run: pgbench non ha restituito tps (vedi $LOG)"
			echo "   $test #$run: $v tps"
			echo "s$s,$test,$run,$v" >> "$OUT"
		done
	done
	"$BIN/pg_ctl" -D "$DATA" -m fast -w stop > /dev/null
	trap - EXIT
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in tps; percentuale rispetto a s${STAGES[0]}, negativa = più lento)"
