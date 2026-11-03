#!/usr/bin/env bash
# Suite di test di nginx (nginx-tests, circa 500 script Perl) sugli stage indicati.
#   Uso: ./test-nginx.sh [-j job] <stage>[,<stage>...]      es. ./test-nginx.sh 0,4
#
# Ogni script avvia l'nginx dello stage con una propria configurazione e lo
# interroga via HTTP/stream. I test per moduli non compilati (ssl, http2,
# perl, ...) vengono saltati, uguali in ogni stage. Servono perl e prove
# (perl-Test-Harness). Si confrontano gli script falliti con quelli di s0.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

TESTS_REF=fea1a48be821d52b1be0aa320029c96ddacc39f2
JOBS=$(nproc)
while getopts "j:" opt; do
	case $opt in j) JOBS=$OPTARG ;; *) die "opzione non valida" ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-j job] <stage>[,<stage>...]"
parse_stages "$1"
DIR=$SS_ROOT/nginx
fetch_src https://github.com/nginx/nginx-tests "$TESTS_REF" "$DIR/nginx-tests"
OUT=$PWD/test-nginx-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	[ -x "$DIR/s$s/sbin/nginx" ] || die "stage $s: lancia build-nginx.sh $s"
	t0=$(now)
	(cd "$DIR/nginx-tests" && TEST_NGINX_BINARY="$DIR/s$s/sbin/nginx" prove -j"$JOBS" .) > "$OUT/s$s.log" 2>&1
	# riepilogo di prove: "./xx.t (Wstat: ... Tests: ... Failed: N)"
	grep -oE '^[^ ]+\.t +\(Wstat' "$OUT/s$s.log" | sed 's/ *(Wstat//; s|^\./||' | sort -u > "$OUT/s$s.failed"
	echo "s$s: $(grep -E '^Result: ' "$OUT/s$s.log" | tail -1 || echo "nessun risultato"), $(wc -l < "$OUT/s$s.failed") script falliti ($(seconds "$t0") s)"
done

compare_failed "$OUT" "${STAGES[@]}"
echo "Log in $OUT/ (TEST_NGINX_VERBOSE=1 TEST_NGINX_BINARY=... prove -v file.t per i dettagli)"
