#!/usr/bin/env bash
# Confronta con redis-benchmark le build di Redis dei vari stage.
# Risultati in redis-bench-<data>.csv, una riga per misura: stage,test,run,valore
#   test = comando di redis-benchmark (SET, GET, ...): valore in richieste/s
#   test = fork_usec: durata della fork di BGSAVE in microsecondi (latest_fork_usec)
#
# Uso: ./bench-redis.sh [opzioni] <stage>[,<stage>...]      (con il modulo caricato)
#
#   ./bench-redis.sh 0,1,4
#   ./bench-redis.sh -P 16 -r 3 0,4        pipeline da 16 comandi, 3 ripetizioni
#
# Opzioni:
#   -n <numero>    richieste per esecuzione              (default 1000000)
#   -r <numero>    ripetizioni                           (default 5)
#   -c <numero>    client paralleli                      (default 50)
#   -P <numero>    comandi in pipeline per client        (default 1)
#   -t <test,...>  comandi di redis-benchmark            (default set,get,incr,lpush,rpop,sadd,hset,zadd,lrange_100)
#   -k <numero>    chiavi caricate per il test di fork   (default 1000000, 0 = niente test di fork)
#   -f <numero>    BGSAVE per esecuzione nel test di fork (default 10)
#
# Il server di ogni stage usa i binari in $HOME/redis-s<N>/bin. Il client
# (redis-benchmark, redis-cli) è sempre quello dello stage 0, così misura solo
# il server e non anche il costo della strumentazione nel client.
set -e

PORT=6380
REQUESTS=1000000
RUNS=5
CLIENTS=50
PIPELINE=1
TESTS=set,get,incr,lpush,rpop,sadd,hset,zadd,lrange_100
KEYS=1000000
FORKS=10

die() { echo "bench-redis: $*" >&2; exit 1; }

usage() {
	sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

while getopts "n:r:c:P:t:k:f:h" opt; do
	case $opt in
		n) REQUESTS=$OPTARG ;;
		r) RUNS=$OPTARG ;;
		c) CLIENTS=$OPTARG ;;
		P) PIPELINE=$OPTARG ;;
		t) TESTS=$OPTARG ;;
		k) KEYS=$OPTARG ;;
		f) FORKS=$OPTARG ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
IFS=, read -r -a STAGES <<< "$1"

for n in REQUESTS RUNS CLIENTS PIPELINE KEYS FORKS; do
	[[ ${!n} =~ ^[0-9]+$ ]] || die "$n deve essere un numero: ${!n}"
done

# ---- client e CPU ---------------------------------------------------------------
CLIENT=$HOME/redis-s0/bin
[ -x "$CLIENT/redis-benchmark" ] || die "manca $CLIENT/redis-benchmark (lancia build-redis.sh 0)"
# server sulla CPU 0, client sulle altre: non si contendono la stessa CPU
NCPU=$(nproc)
SERVER_CPU=0
CLIENT_CPUS=$([ "$NCPU" -gt 1 ] && echo "1-$((NCPU - 1))" || echo 0)

# ---- controlli sui binari, prima di partire -----------------------------------
for s in "${STAGES[@]}"; do
	case $s in 0|1|2|3|4) ;; *) die "stage non valido: $s (0-4)" ;; esac
	bin=$HOME/redis-s$s/bin/redis-server
	[ -x "$bin" ] || die "stage $s: $bin non trovato (lancia build-redis.sh $s)"
	refs=$(objdump -d "$bin" | grep -c '__ss_shadow_offset' || true)
	case $s in
		3|4) [ "$refs" -ge 1000 ] || die "stage $s: binario NON strumentato ($refs riferimenti)" ;;
		1|2) [ "$refs" -lt 100 ]  || die "stage $s: binario strumentato ma non dovrebbe ($refs riferimenti)" ;;
		0)   [ "$refs" -eq 0 ]    || die "stage 0: binario con riferimenti allo shadow stack ($refs)" ;;
	esac
	[ "$s" -eq 0 ] || [ -e /dev/shdwstck ] || die "/dev/shdwstck non esiste: carica il modulo"
	echo "stage $s: $bin ($refs riferimenti a __ss_shadow_offset)"
done

OUT=redis-bench-$(date +%Y%m%d-%H%M%S).csv
echo "stage,test,run,valore" > "$OUT"
echo "$REQUESTS richieste, $RUNS ripetizioni, $CLIENTS client, pipeline $PIPELINE, test: $TESTS"

cli() { "$CLIENT/redis-cli" -p $PORT "$@"; }

bench() {
	taskset -c "$CLIENT_CPUS" "$CLIENT/redis-benchmark" -p $PORT -q "$@"
}

stop_server() {
	cli shutdown nosave > /dev/null 2>&1 || true
	wait "$SERVER_PID" 2> /dev/null || true
}

# run_stage <stage>
run_stage() {
	NAME=s$1
	DATA=$(mktemp -d)

	echo "== $NAME"
	taskset -c $SERVER_CPU "$HOME/redis-s$1/bin/redis-server" --port $PORT \
		--save "" --appendonly no --dir "$DATA" --logfile "$HOME/redis-$NAME.log" &
	SERVER_PID=$!
	trap 'stop_server; rm -rf "$DATA"' EXIT

	for i in $(seq 50); do
		cli ping > /dev/null 2>&1 && break
		kill -0 "$SERVER_PID" 2> /dev/null || die "$NAME: il server è terminato (vedi $HOME/redis-$NAME.log)"
		sleep 0.1
	done
	cli ping > /dev/null 2>&1 || die "$NAME: il server non risponde (vedi $HOME/redis-$NAME.log)"

	echo "   riscaldamento (scartato)"
	bench -n 200000 -c "$CLIENTS" -P "$PIPELINE" -t "$TESTS" > /dev/null

	for run in $(seq 1 "$RUNS"); do
		# --csv: "SET","123456.78",... (dopo una riga di intestazione)
		bench -n "$REQUESTS" -c "$CLIENTS" -P "$PIPELINE" -t "$TESTS" --csv |
			awk -F'"' -v n="$NAME" -v r="$run" 'NR > 1 && $2 != "" {
				t = $2   # "LPUSH (needed to benchmark LRANGE)" -> LPUSH_for_lrange
				sub(/ \(needed to benchmark LRANGE\)/, "_for_lrange", t)
				sub(/ \(.*\)$/, "", t)
				print n "," t "," r "," $4
			}' \
			> "$DATA/run.csv"
		[ -s "$DATA/run.csv" ] || die "$NAME #$run: redis-benchmark non ha restituito risultati"
		cat "$DATA/run.csv" >> "$OUT"
		echo "   #$run: $(awk -F, '{printf "%s %.0f  ", $2, $4}' "$DATA/run.csv")"
	done

	# fork: BGSAVE fa fork() del server con tutto il dataset caricato.
	# latest_fork_usec è la durata della fork misurata da Redis nel processo padre.
	if [ "$KEYS" -gt 0 ]; then
		echo "   test di fork: carico $KEYS chiavi"
		cli flushall > /dev/null
		bench -t set -n "$KEYS" -r "$KEYS" -d 100 -P 64 > /dev/null
		for run in $(seq 1 "$RUNS"); do
			for f in $(seq 1 "$FORKS"); do
				cli bgsave > /dev/null
				while cli info persistence | grep -q '^rdb_bgsave_in_progress:1'; do
					sleep 0.05
				done
				usec=$(cli info stats | awk -F: '/^latest_fork_usec/ {print $2+0}')
				echo "$NAME,fork_usec,$run,$usec" >> "$OUT"
			done
		done
		echo "   fork: $(grep "^$NAME,fork_usec," "$OUT" |
			awk -F, '{s += $4; n++} END {printf "%.0f us in media su %d fork", s / n, n}')"
	fi

	stop_server
	trap - EXIT
	rm -rf "$DATA"
}

for s in "${STAGES[@]}"; do
	run_stage "$s"
done

echo
echo "Risultati in $OUT"