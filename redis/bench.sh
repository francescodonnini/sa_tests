#!/usr/bin/env bash
# Benchmark di Redis con redis-benchmark, più la durata della fork di BGSAVE.
#   Uso: ./bench.sh [opzioni] <stage>[,<stage>...]      es. ./bench.sh -P 16 0,4
#
# Opzioni:
#   -n numero     richieste per esecuzione                    (default 1000000)
#   -r numero     ripetizioni                                 (default 5)
#   -c numero     client paralleli                            (default 50)
#   -P numero     comandi in pipeline per client              (default 1)
#   -T numero     thread di redis-benchmark                   (default 1)
#   -t test,...   comandi di redis-benchmark  (default set,get,incr,lpush,rpop,sadd,hset,zadd,lrange_100)
#   -k numero     chiavi caricate per il test di fork          (default 1000000, 0 = niente fork)
#   -f numero     BGSAVE per ripetizione nel test di fork      (default 10)
# Nel CSV: per i comandi richieste al secondo (più alto è meglio); per
# fork_usec la durata della fork in microsecondi (più basso è meglio).
# Server sul core 0, client sugli altri. Client (redis-benchmark, redis-cli)
# sempre dello stage 0, così si misura solo il server. Gli stage girano uno
# dopo l'altro, con un server avviato una volta per stage.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

PORT=6380
REQUESTS=1000000
RUNS=5
CLIENTS=50
PIPELINE=1
THREADS=1
TESTS=set,get,incr,lpush,rpop,sadd,hset,zadd,lrange_100
KEYS=1000000
FORKS=10
while getopts "n:r:c:P:T:t:k:f:" opt; do
	case $opt in
		n) REQUESTS=$OPTARG ;;
		r) RUNS=$OPTARG ;;
		c) CLIENTS=$OPTARG ;;
		P) PIPELINE=$OPTARG ;;
		T) THREADS=$OPTARG ;;
		t) TESTS=$OPTARG ;;
		k) KEYS=$OPTARG ;;
		f) FORKS=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [opzioni] <stage>[,<stage>...]"
parse_stages "$1"

DIR=$SS_ROOT/redis
CLIENT=$DIR/s0/bin
[ -x "$CLIENT/redis-benchmark" ] || die "manca $CLIENT/redis-benchmark (lancia build.sh 0)"
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/bin/redis-server" ] || die "stage $s: lancia build.sh $s"
done
NCPU=$(nproc)
[ "$NCPU" -ge 2 ] || die "servono almeno 2 CPU (server sul core 0, client sugli altri)"
CLIENT_CPUS=1-$((NCPU - 1))

cli() { "$CLIENT/redis-cli" -p $PORT "$@"; }
cli ping > /dev/null 2>&1 &&
	die "c'è già un server sulla porta $PORT: fermalo con $CLIENT/redis-cli -p $PORT shutdown nosave"

# Con --threads (anche --threads 1) redis-benchmark si ferma solo al tick
# successivo del suo timer, ogni 250 ms: la durata è arrotondata a multipli
# di 250 ms. Per questo l'opzione si passa solo con -T > 1.
bench() {
	[ "$THREADS" -gt 1 ] && set -- --threads "$THREADS" "$@"
	taskset -c "$CLIENT_CPUS" "$CLIENT/redis-benchmark" -p $PORT -q "$@"
}
wait_bgsave() {
	while cli info persistence | grep -q '^rdb_bgsave_in_progress:1'; do sleep 0.05; done
}

OUT=$(result_path bench redis).csv
echo "stage,test,run,valore" > "$OUT"
echo "$REQUESTS richieste, $RUNS ripetizioni, $CLIENTS client, pipeline $PIPELINE, test: $TESTS"

for s in "${STAGES[@]}"; do
	LOG=$DIR/s$s.log
	DATA=$(mktemp -d)
	echo "== s$s"
	taskset -c 0 "$DIR/s$s/bin/redis-server" --port $PORT --save "" --appendonly no \
		--dir "$DATA" --logfile "$LOG" &
	SERVER_PID=$!
	trap 'cli shutdown nosave > /dev/null 2>&1; wait $SERVER_PID 2> /dev/null; rm -rf "$DATA"' EXIT
	for _ in $(seq 50); do
		cli ping > /dev/null 2>&1 && break
		kill -0 "$SERVER_PID" 2> /dev/null || die "s$s: il server è terminato (vedi $LOG)"
		sleep 0.1
	done
	cli ping > /dev/null 2>&1 || die "s$s: il server non risponde (vedi $LOG)"

	echo "   riscaldamento (scartato)"
	bench -n 200000 -c "$CLIENTS" -P "$PIPELINE" -t "$TESTS" > /dev/null
	for run in $(seq 1 "$RUNS"); do
		# --csv: "SET","123456.78",... dopo una riga di intestazione
		res=$(bench -n "$REQUESTS" -c "$CLIENTS" -P "$PIPELINE" -t "$TESTS" --csv |
			awk -F'"' -v p="s$s" -v r="$run" 'NR > 1 && $2 != "" {
				t = $2       # "LPUSH (needed to benchmark LRANGE)" -> LPUSH_for_lrange
				sub(/ \(needed to benchmark LRANGE\)/, "_for_lrange", t)
				sub(/ \(.*\)$/, "", t)
				print p "," t "," r "," $4
			}')
		[ -n "$res" ] || die "s$s #$run: redis-benchmark non ha restituito risultati"
		echo "$res" >> "$OUT"
		echo "   #$run: $(echo "$res" | awk -F, '{printf "%s %.0f  ", $2, $4}')"
	done

	# fork: BGSAVE fa fork() del server con tutto il dataset caricato;
	# latest_fork_usec è la durata della fork misurata da Redis nel padre
	if [ "$KEYS" -gt 0 ]; then
		echo "   test di fork: carico $KEYS chiavi"
		cli flushall > /dev/null
		bench -t set -n "$KEYS" -r "$KEYS" -d 100 -P 64 > /dev/null
		cli bgsave > /dev/null; wait_bgsave       # la prima fork è più lenta: scartata
		for run in $(seq 1 "$RUNS"); do
			for _ in $(seq 1 "$FORKS"); do
				cli bgsave > /dev/null; wait_bgsave
				echo "s$s,fork_usec,$run,$(cli info stats | awk -F: '/^latest_fork_usec/ {print $2 + 0}')" >> "$OUT"
			done
		done
	fi

	cli shutdown nosave > /dev/null 2>&1
	wait "$SERVER_PID" 2> /dev/null
	trap - EXIT
	rm -rf "$DATA"
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane: comandi in richieste/s, fork_usec in microsecondi; percentuale rispetto a s${STAGES[0]})"
