#!/usr/bin/env bash
# Benchmark di OpenSSL: openssl speed (senza assembly, quindi il codice C).
#   Uso: ./bench-openssl.sh [-r ripetizioni] [-s secondi] <stage>[,<stage>...]
#
#   sha256, sha512, aes-128-gcm, chacha20-poly1305   MB/s su blocchi da 16 KB
#   rsa2048, ecdsap256, ed25519                      firme e verifiche al secondo
# Una invocazione per algoritmo (-s secondi, default 3), su un solo core; gli
# stage si alternano. Valori più alti sono migliori: nel riepilogo una
# percentuale negativa è un rallentamento.
set -uo pipefail
. "$(dirname "$0")/common.sh"

RUNS=5
SECS=3
while getopts "r:s:" opt; do
	case $opt in
		r) RUNS=$OPTARG ;;
		s) SECS=$OPTARG ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-r ripetizioni] [-s secondi] <stage>[,<stage>...]"
parse_stages "$1"

DIR=$SS_ROOT/openssl
for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/openssl" ] || die "stage $s: $DIR/s$s/openssl non trovato (lancia build-openssl.sh $s)"
done

# nome|argomenti di openssl speed
CASES='sha256|sha256
sha512|sha512
aes-128-gcm|-evp aes-128-gcm
chacha20-poly1305|-evp chacha20-poly1305
rsa2048|rsa2048
ecdsap256|ecdsap256
ed25519|ed25519'

OUT=$PWD/bench-openssl-$(date +%Y%m%d-%H%M%S).csv
echo "stage,test,run,valore" > "$OUT"
for run in $(seq 1 "$RUNS"); do
	echo "== ripetizione $run/$RUNS"
	while IFS='|' read -r name args; do
		for s in "${STAGES[@]}"; do
			# -mr: output per macchine, una riga "+Fn:..." per algoritmo
			# shellcheck disable=SC2086
			res=$(taskset -c 1 "$DIR/s$s/openssl" speed -mr -seconds "$SECS" -bytes 16384 $args 2>/dev/null |
				grep '^+F') || die "s$s $name: openssl speed fallito"
			IFS=: read -r -a f <<< "$res"
			case ${f[0]} in
				+F)  echo "s$s,$name MB/s,$run,$(awk -v b="${f[-1]}" 'BEGIN {printf "%.2f", b / 1e6}')" ;;
				+F2|+F4)
				     echo "s$s,$name sign/s,$run,${f[3]}"
				     echo "s$s,$name verify/s,$run,${f[4]}" ;;
				+F6) echo "s$s,$name sign/s,$run,${f[4]}"
				     echo "s$s,$name verify/s,$run,${f[5]}" ;;
				*)   die "s$s $name: formato inatteso: $res" ;;
			esac >> "$OUT"
		done
	done <<< "$CASES"
done

echo
summary "$OUT" "${STAGES[0]}"
echo
echo "Risultati in $OUT (mediane; percentuale rispetto a s${STAGES[0]}, negativa = più lento)"
