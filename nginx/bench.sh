#!/usr/bin/env bash
# Benchmark di nginx con wrk: richieste al secondo su file statici.
#   Uso: ./bench.sh [-r ripetizioni] [-d secondi] [-c connessioni] <stage>[,<stage>...]
#
#   small     file da 612 byte (la pagina di default): domina il codice di nginx
#             (parsing, header, eventi, log)
#   100k      file da 100 KB: più peso a sendfile e al kernel
#   gzip      file da 100 KB compresso al volo (gzip, zlib di sistema)
#   close     file piccolo con una connessione nuova per richiesta (accept,
#             pool di connessione e richiesta, chiusura)
#   proxy     file piccolo attraverso nginx come reverse proxy verso un secondo
#             server dello stesso processo (modulo upstream, keep-alive)
# nginx usa un solo worker sul core 1; wrk (2 thread, -c connessioni keep-alive,
# default 64) gira sui core 2 e 3, che devono esistere. Serve almeno una VM a
# 4 vCPU. Per ogni misura nginx viene avviato e fermato; gli stage si
# alternano. Valori in richieste al secondo: più alto è meglio.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

WRK_REF=a211dd5a7050b1f9e8a9870b95513060e72ac4a0
RUNS=5
DUR=10
CONNS=64
while getopts "r:d:c:" opt; do
	case $opt in
		r) RUNS=$OPTARG ;;
		d) DUR=$OPTARG ;;
		c) CONNS=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-r ripetizioni] [-d secondi] [-c connessioni] <stage>[,<stage>...]"
parse_stages "$1"
[ "$(nproc)" -ge 4 ] || die "servono almeno 4 CPU (nginx sul core 1, wrk sui core 2-3)"

DIR=$SS_ROOT/nginx
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/sbin/nginx" ] || die "stage $s: lancia build.sh $s"
done

# wrk, compilato normalmente (non strumentato), con LuaJIT e OpenSSL inclusi
WRK=$SS_ROOT/tools/wrk
if [ ! -x "$WRK/wrk" ]; then
	fetch_src https://github.com/wg/wrk "$WRK_REF" "$WRK"
	echo "== make wrk"
	make -C "$WRK" -j"$(nproc)" > "$WRK/build.log" 2>&1 || die "compilazione di wrk fallita: vedi $WRK/build.log"
fi

PORT=18080
if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
	die "la porta $PORT è già in uso"
fi
RUN=$(mktemp -d)
cleanup() {
	[ -f "$RUN/nginx.pid" ] && kill "$(cat "$RUN/nginx.pid")" 2>/dev/null
	rm -rf "$RUN"
}
trap cleanup EXIT

mkdir -p "$RUN/html" "$RUN/logs"
cp "$DIR/src/docs/html/index.html" "$RUN/html/small.html"
head -c 102400 "$DIR/src/src/http/ngx_http_core_module.c" > "$RUN/html/100k.html"
cp "$RUN/html/100k.html" "$RUN/html/gzip.html"
cat > "$RUN/nginx.conf" <<EOF
worker_processes 1;
worker_cpu_affinity 0010;
daemon on;
pid $RUN/nginx.pid;
error_log $RUN/logs/error.log;
events { worker_connections 1024; }
http {
    access_log off;
    sendfile on;
    tcp_nopush on;
    keepalive_requests 100000;
	upstream back { server 127.0.0.1:$((PORT + 1)); keepalive 32; }
	server {
        listen 127.0.0.1:$((PORT + 1));
        root $RUN/html;
    }
    server {
        listen 127.0.0.1:$PORT;
        root $RUN/html;
        location = /gzip.html { gzip on; gzip_types *; gzip_min_length 0; }
		location /proxy/ {
               proxy_pass http://back/;
               proxy_http_version 1.1;
               proxy_set_header Connection "";
           }
    }
}
EOF

# nome|percorso|header aggiuntivo
CASES='small|/small.html|
100k|/100k.html|
gzip|/gzip.html|Accept-Encoding: gzip
close|/small.html|Connection: close
proxy|/proxy/small.html|'

OUT=$(result_path bench nginx).csv
echo "stage,test,run,req/s" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	while IFS='|' read -r name path hdr; do
		for s in "${STAGES[@]}"; do
			rm -f "$RUN/nginx.pid"
			"$DIR/s$s/sbin/nginx" -p "$RUN" -c "$RUN/nginx.conf" || die "s$s: avvio di nginx fallito"
			for _ in $(seq 50); do [ -s "$RUN/nginx.pid" ] && break; sleep 0.1; done
			args=()
			[ -n "$hdr" ] && args=(-H "$hdr")
			res=$(taskset -c 2,3 "$WRK/wrk" -t2 -c"$CONNS" -d"${DUR}s" "${args[@]}" "http://127.0.0.1:$PORT$path")
			kill -QUIT "$(cat "$RUN/nginx.pid")"
			for _ in $(seq 50); do [ -e "$RUN/nginx.pid" ] || break; sleep 0.1; done
			# risposte non 2xx o errori di socket rendono la misura inutilizzabile
			echo "$res" | grep -q 'Non-2xx' && die "s$s $name: risposte non 2xx"$'\n'"$res"
			rps=$(echo "$res" | awk '/^Requests\/sec:/ {print $2}')
			[ -n "$rps" ] || die "s$s $name: output di wrk inatteso"$'\n'"$res"
			echo "s$s,$name,$run,$rps" >> "$OUT"
		done
	done <<< "$CASES"
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane in richieste/s; percentuale rispetto a s${STAGES[0]}, negativa = più lento)"
