#!/usr/bin/env bash
# Benchmark di memcached con memtier_benchmark (protocollo text).
#   Uso: ./bench.sh [-r ripetizioni] [-d secondi] <stage>[,<stage>...]
#
#   set       solo scritture
#   get       solo letture (chiavi già caricate)
#   mixed     1 scrittura ogni 10 letture
#   get-P16   letture in pipeline da 16 richieste
# Valori da 100 byte su 100000 chiavi. memcached ha un solo thread di lavoro
# (-t 1) sul core 1; memtier (2 thread, 25 connessioni ciascuno) sui core 2 e 3,
# che devono esistere. Per ogni misura memcached viene riavviato e ricaricato;
# gli stage si alternano. Valori in operazioni al secondo: più alto è meglio.
#
# memtier_benchmark viene compilato una volta, non strumentato. Servono:
#   dnf install autoconf automake gcc-c++ libevent-devel openssl-devel zlib-devel
set -uo pipefail
. "$(dirname "$0")/../common.sh"

MEMTIER_REF=2.5.2
RUNS=5
DUR=10
while getopts "r:d:" opt; do
	case $opt in
		r) RUNS=$OPTARG ;;
		d) DUR=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-r ripetizioni] [-d secondi] <stage>[,<stage>...]"
parse_stages "$1"
[ "$(nproc)" -ge 4 ] || die "servono almeno 4 CPU (memcached sul core 1, memtier sui core 2-3)"

DIR=$SS_ROOT/memcached
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/memcached" ] || die "stage $s: lancia build.sh $s"
done

MT=$SS_ROOT/tools/memtier_benchmark
if [ ! -x "$MT/memtier_benchmark" ]; then
	fetch_src https://github.com/RedisLabs/memtier_benchmark "$MEMTIER_REF" "$MT"
	echo "== compilo memtier_benchmark"
	(cd "$MT" && autoreconf -ivf && ./configure && make -j"$(nproc)") > "$MT/build.log" 2>&1 ||
		die "compilazione di memtier fallita: vedi $MT/build.log"
fi

PORT=21211
if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
	die "la porta $PORT è già in uso"
fi
PID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null' EXIT

COMMON=(-s 127.0.0.1 -p "$PORT" -P memcache_text --hide-histogram -t 2 -c 25
	--data-size=100 --key-maximum=100000 --key-prefix=k)
# memtier [opzioni]: stampa le operazioni al secondo della riga "Totals"
memtier() {
	taskset -c 2,3 "$MT/memtier_benchmark" "${COMMON[@]}" "$@" 2>/dev/null |
		awk '$1 == "Totals" {print $2}'
}

# nome|opzioni di memtier
CASES="set|--ratio=1:0 --test-time=$DUR
get|--ratio=0:1 --test-time=$DUR
mixed|--ratio=1:10 --test-time=$DUR
get-P16|--ratio=0:1 --pipeline=16 --test-time=$DUR"

OUT=$(result_path bench memcached).csv
echo "stage,test,run,ops/s" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	while IFS='|' read -r name opts; do
		for s in "${STAGES[@]}"; do
			taskset -c 1 "$DIR/s$s/memcached" -U 0 -t 1 -m 1024 -l 127.0.0.1 -p "$PORT" &
			PID=$!
			for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
			# carica tutte le chiavi, così le letture non vanno a vuoto
			memtier --ratio=1:0 --key-pattern=P:P --requests=allkeys -t 1 -c 1 > /dev/null
			# shellcheck disable=SC2086
			ops=$(memtier $opts)
			kill "$PID"; wait "$PID" 2>/dev/null; PID=
			[ -n "$ops" ] || die "s$s $name: output di memtier inatteso (o memcached terminato)"
			echo "s$s,$name,$run,$ops" >> "$OUT"
		done
	done <<< "$CASES"
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in operazioni/s; percentuale rispetto a s${STAGES[0]}, negativa = più lento)"
