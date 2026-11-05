#!/usr/bin/env bash
# Suite di regressione di Postgres sugli stage indicati.
#   Uso: ./test.sh [-i] [-c] <stage>[,<stage>...]      es. ./test.sh 0,4
#
#   regress   la regressione principale (make check, circa 220 test SQL)
#   -i        anche src/test/isolation (transazioni concorrenti)
#   -c        anche i moduli di contrib/ (make -C contrib check), più lunghi
# make check crea un'istanza temporanea con i binari della build dello stage,
# quindi esegue il codice strumentato, fork comprese (una per connessione).
# Non gira come root (initdb lo rifiuta). Si confrontano i test falliti con s0.
set -uo pipefail
. "$(dirname "$0")/../common.sh"

SUITES=("regress:.")
while getopts "ic" opt; do
	case $opt in
		i) SUITES+=("isolation:src/test/isolation") ;;
		c) SUITES+=("contrib:contrib") ;;
		*) die "opzione non valida" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "uso: $0 [-i] [-c] <stage>[,<stage>...]"
parse_stages "$1"
[ "$(id -u)" -ne 0 ] || die "initdb non gira come root: lancia lo script come utente normale"

DIR=$SS_ROOT/postgres
OUT=$(result_path test postgres)
mkdir -p "$OUT"

# nomi dei test falliti nel log di pg_regress, uno per riga
# (recente: "not ok 12 - nome ..."; più vecchio: "test nome ... FAILED")
failed_tests() {
	grep -E '^not ok|\.\.\. FAILED|FAILED \(' "$1" |
		sed -E 's/^not ok +[0-9]+ +[-+] +//; s/^(test +)?//; s/[ .]+FAILED.*//; s/ +[0-9]+ ms$//' |
		awk '{print $1}' | sort -u
}

for s in "${STAGES[@]}"; do
	check_prereq "$s"
	B=$DIR/build-s$s
	[ -f "$B/GNUmakefile" ] || die "stage $s: lancia build.sh $s"
	# stessi flag della build: se make check ricompila qualcosa, lo fa come il resto
	stage_flags "$s"
	: > "$OUT/s$s.failed"
	for suite in "${SUITES[@]}"; do
		name=${suite%%:*}
		dir=${suite#*:}
		log=$OUT/s$s-$name.log
		t0=$(now)
		touch "$OUT/.start"
		make -C "$B/$dir" check COPT="$COPT" LDFLAGS_EX="$LDOPT" > "$log" 2>&1
		rc=$?
		failed_tests "$log" | sed "s/^/$name: /" > "$OUT/s$s-$name.failed"
		cat "$OUT/s$s-$name.failed" >> "$OUT/s$s.failed"
		# diff dei risultati di ogni cartella di test che ne ha prodotto uno
		find "$B/$dir" -name regression.diffs -newer "$OUT/.start" 2> /dev/null |
			while read -r d; do cp "$d" "$OUT/s$s-$(echo "${d#"$B"/}" | tr / _)"; done
		n=$(wc -l < "$OUT/s$s-$name.failed")
		if [ $rc -eq 0 ]; then
			echo "s$s $name: ok ($(seconds "$t0") s)"
		elif [ "$n" -gt 0 ]; then
			echo "s$s $name: $n test falliti ($(seconds "$t0") s)"
		else
			echo "s$s $name: FALLITO senza test identificati (exit $rc): vedi $log"
			echo "$name: (exit $rc)" >> "$OUT/s$s.failed"
		fi
	done
done

rm -f "$OUT/.start"
compare_failed "$OUT" "${STAGES[@]}"
echo "Log, elenchi dei test falliti e diff in $OUT/"
