#!/usr/bin/env bash
# Confronta con pgbench la build di Postgres protetta (stage 4) con la baseline (stage 0).
# Risultati in bench-<data>.csv, una riga per esecuzione: stage,test,run,tps
#
# Uso: ./bench-pg.sh          (con il modulo caricato)
set -e

B=$HOME/pg-s4/bin          # stage 4: protezione completa
C=$HOME/pg-s0/bin          # stage 0: baseline
PORT=5433
SCALE=50                   # dimensione delle tabelle (50 ≈ 750 MB)
CLIENTS=8
THREADS=4
DURATION=60                # secondi per ogni esecuzione
RUNS=5                     # ripetizioni per ogni test

OUT=bench-$(date +%Y%m%d-%H%M%S).csv
echo "stage,test,run,tps" > "$OUT"

# Esegue pgbench e restituisce solo il numero dopo "tps = "
tps() {
	"$BIN/pgbench" -p $PORT -U postgres -c $CLIENTS -j $THREADS -T $DURATION "$@" postgres \
		| awk '/^tps/ {print $3}'
}

# run_stage <nome> <cartella dei binari> <cartella dei dati>
run_stage() {
	NAME=$1
	BIN=$2
	DATA=$3

	echo "== $NAME"
	if [ ! -d "$DATA" ]; then
		"$BIN/initdb" -D "$DATA" -U postgres > /dev/null
	fi

	# commit asincrono e tabelle tutte in memoria: misuriamo la CPU, non il disco
	"$BIN/pg_ctl" -D "$DATA" -l "$HOME/$NAME.log" -w \
		-o "-p $PORT -c synchronous_commit=off -c shared_buffers=1GB" start > /dev/null

	# stesse tabelle appena create per entrambi gli stage
	"$BIN/pgbench" -p $PORT -U postgres -i -s $SCALE -q postgres > /dev/null 2>&1

	echo "   riscaldamento (30 s, scartato)"
	"$BIN/pgbench" -p $PORT -U postgres -c $CLIENTS -j $THREADS -T 30 postgres > /dev/null 2>&1

	for test in tpcb select connect; do
		case $test in
			tpcb)    opts="-M prepared" ;;     # TPC-B completo
			select)  opts="-S -M prepared" ;;  # solo SELECT
			connect) opts="-C" ;;              # una connessione (fork) per transazione
		esac
		for run in $(seq 1 $RUNS); do
			value=$(tps $opts)
			echo "   $test #$run: $value tps"
			echo "$NAME,$test,$run,$value" >> "$OUT"
		done
	done

	"$BIN/pg_ctl" -D "$DATA" -w stop > /dev/null
}

run_stage s0 "$C" "$HOME/pgdata-s0"
run_stage s4 "$B" "$HOME/pgdata-s4"

echo
echo "Risultati in $OUT"