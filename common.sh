# shellcheck shell=bash
# Funzioni comuni agli script build-*.sh, bench-*.sh e test-*.sh.
# Si include con:  . "$(dirname "$0")/../common.sh"
#
# Stage della pipeline:
#   0  baseline: nessuna protezione
#   1  solo runtime (relocate_stack + libruntime), nessun pass
#   2  runtime + pass IR (mascheramento store)
#   3  runtime + pass x86 (shadow stack)
#   4  runtime + pass IR + pass x86 (protezione completa)
#
# Cartelle (una per programma, sotto $SS_ROOT/<programma>):
#   src/        clone dei sorgenti, alla versione fissata nello script
#   build-sN/   copia dei sorgenti compilata per lo stage N
#   sN/         installazione dello stage N
#
# Tutti i percorsi si possono cambiare con variabili d'ambiente, per esempio
#   CLANG=/altro/clang ./build-lua.sh 4
# MASK_FLAGS aggiunge opzioni agli stage con il pass IR (2 e 4), per esempio
#   MASK_FLAGS="-mllvm -x86-shadow-stack-btr" ./build-lua.sh 4

: "${SS_ROOT:=$HOME/ss}"
: "${CLANG:=$HOME/llvm-project/build/bin/clang}"
: "${RT:=$HOME/runtime/build}"
: "${IR_PASS:=$HOME/shadow_stack/build/ShadowStack.so}"
: "${MASK_FLAGS:=}"

die() { echo "$(basename "$0"): $*" >&2; exit 1; }

# Ctrl+C: senza questo bash esce senza eseguire il trap EXIT (server lasciati accesi)
trap 'exit 130' INT TERM

# ---- stage --------------------------------------------------------------------------

# check_stage <stage>
check_stage() {
	case "$1" in
		0|1|2|3|4) ;;
		*) die "stage non valido: '$1' (0-4)" ;;
	esac
}

# parse_stages "0,1,4" -> array STAGES
parse_stages() {
	IFS=, read -r -a STAGES <<< "$1"
	[ ${#STAGES[@]} -gt 0 ] || die "nessuno stage indicato"
	local s
	for s in "${STAGES[@]}"; do check_stage "$s"; done
}

# stage_flags <stage> -> COPT (compilazione) e LDOPT (link)
stage_flags() {
	COPT=""
	LDOPT=""
	case "$1" in
		2) COPT="-fpass-plugin=$IR_PASS $MASK_FLAGS" ;;
		3) COPT="-mllvm -x86-shadow-stack-pass" ;;
		4) COPT="-fpass-plugin=$IR_PASS $MASK_FLAGS -mllvm -x86-shadow-stack-pass" ;;
	esac
	if [ "$1" -ge 1 ]; then
		# --no-as-needed: altrimenti il linker può scartare libruntime.so se il
		# programma non ne usa simboli, e il suo costruttore non verrebbe eseguito
		LDOPT="$RT/stckcpy.o -Wl,-e,relocate_stack -L$RT -Wl,-rpath,$RT -Wl,--push-state,--no-as-needed -lruntime -Wl,--pop-state"
	fi
}

# check_prereq <stage>: compilatore, runtime, pass e modulo necessari allo stage
check_prereq() {
	[ -x "$CLANG" ] || die "clang non trovato: $CLANG"
	if [ "$1" -ge 1 ]; then
		[ -f "$RT/stckcpy.o" ] || die "manca $RT/stckcpy.o (compila il runtime)"
		[ -f "$RT/libruntime.so" ] || die "manca $RT/libruntime.so (compila il runtime)"
		# durante build e test girano programmi appena compilati con il runtime
		[ -e /dev/shdwstck ] || die "/dev/shdwstck non esiste: carica il modulo"
	fi
	if [ "$1" = 2 ] || [ "$1" = 4 ]; then
		[ -f "$IR_PASS" ] || die "pass IR non trovato: $IR_PASS"
	fi
}

# ---- sorgenti -------------------------------------------------------------------------

# fetch_src <url git> <tag o commit> <cartella>: clona una volta, alla versione fissata
fetch_src() {
	local url=$1 ref=$2 dir=$3
	if [ ! -d "$dir/.git" ]; then
		echo "== clone $url ($ref)"
		git clone -q "$url" "$dir" || die "clone di $url fallito"
	fi
	git -C "$dir" -c advice.detachedHead=false checkout -q "$ref" ||
		die "$dir: versione $ref non trovata"
}

# fresh_copy <sorgenti> <destinazione>: copia pulita, senza .git
fresh_copy() {
	rm -rf "$2"
	mkdir -p "$2"
	tar -C "$1" --exclude=.git -cf - . | tar -C "$2" -xf -
}

# ---- verifica del binario ---------------------------------------------------------------

# verify_bin <binario> <stage> [soglia]: il binario è davvero quello dello stage?
# Il preambolo del pass x86 legge __ss_shadow_offset; relocate_stack ne ha pochi.
verify_bin() {
	local bin=$1 stage=$2 min=${3:-100} refs entry reloc n
	[ -x "$bin" ] || die "binario non trovato: $bin"
	refs=$(objdump -d "$bin" | grep -c '__ss_shadow_offset' || true)
	echo "   $(basename "$bin"): $refs riferimenti a __ss_shadow_offset"
	case "$stage" in
		3|4) [ "$refs" -ge "$min" ] || die "stage $stage ma $bin non è strumentato" ;;
		1|2) [ "$refs" -lt 100 ] || die "stage $stage ma $bin contiene la strumentazione x86" ;;
		0)   [ "$refs" -eq 0 ] || die "stage 0 ma $bin contiene riferimenti allo shadow stack" ;;
	esac

	entry=$(readelf -h "$bin" | awk '/Entry point/ {print $4}')
	reloc=$(nm "$bin" 2>/dev/null | awk '$3 == "relocate_stack" {print $1}')
	if [ "$stage" -ge 1 ]; then
		[ -n "$reloc" ] || die "relocate_stack non presente in $bin"
		[ $((entry)) -eq $((16#$reloc)) ] || die "$bin: entry point $entry diverso da relocate_stack"
		n=$(ldd "$bin" | grep -c "$RT/libruntime.so" || true)
		[ "$n" -ge 1 ] || die "$bin: libruntime.so non risolta da $RT"
	else
		[ -z "$reloc" ] || die "stage 0 ma $bin contiene relocate_stack"
	fi
}

# ir_report <file csv>: riepilogo del report del pass IR (stage 2 e 4)
ir_report() {
	[ -s "$1" ] || return 0
	awk -F, '{for (i = 2; i <= 7; i++) t[i] += $i}
	END {printf "   pass IR: %d file, %d funzioni, %d store, %d mascherati (%.1f%%), saltati: constaddr %d, knownbits %d, domtree %d\n",
		NR, t[2], t[3], t[4], t[3] ? 100 * t[4] / t[3] : 0, t[5], t[6], t[7]}' "$1"
	echo "   dettaglio per file: $1"
}

# ---- misure ---------------------------------------------------------------------------

# now: istante in nanosecondi
now() { date +%s%N; }

# seconds <inizio ns>: secondi trascorsi, con tre decimali
seconds() { awk -v a="$1" -v b="$(now)" 'BEGIN {printf "%.3f", (b - a) / 1e9}'; }

# summary <csv stage,test,run,valore> <stage di riferimento>: mediane per test e stage
summary() {
	awk -F, -v ref="s$2" '
	NR > 1 { k = $2 SUBSEP $1; n[k]++; v[k, n[k]] = $4; tests[$2]; stages[$1] }
	END {
		for (k in n) {
			m = n[k]
			for (i = 1; i <= m; i++) a[i] = v[k, i]
			for (i = 2; i <= m; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
			med[k] = (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
		}
		printf "%-28s", "test"
		ns = 0; for (s in stages) st[++ns] = s
		for (i = 2; i <= ns; i++) { x = st[i]; for (j = i - 1; j >= 1 && st[j] > x; j--) st[j + 1] = st[j]; st[j + 1] = x }
		for (i = 1; i <= ns; i++) printf " %14s", st[i]
		printf "\n"
		for (t in tests) {
			printf "%-28s", t
			for (i = 1; i <= ns; i++) {
				k = t SUBSEP st[i]
				if (!(k in med)) { printf " %14s", "-"; continue }
				r = t SUBSEP ref
				if (st[i] != ref && (r in med) && med[r] > 0)
					printf " %8.3f %+5.1f%%", med[k], (med[k] / med[r] - 1) * 100
				else
					printf " %14.3f", med[k]
			}
			printf "\n"
		}
	}' "$1"
}

# ---- test ---------------------------------------------------------------------------

# compare_failed <cartella risultati> <stage...>: test falliti solo negli stage protetti
compare_failed() {
	local out=$1 s extra
	shift
	[ -f "$out/s0.failed" ] || return 0
	echo
	echo "== test che falliscono solo nello stage (rispetto a s0)"
	for s in "$@"; do
		[ "$s" -eq 0 ] && continue
		extra=$(comm -13 <(sort -u "$out/s0.failed") <(sort -u "$out/s$s.failed"))
		if [ -z "$extra" ]; then
			echo "   s$s: nessuno"
		else
			echo "   s$s: $(echo "$extra" | wc -l)"
			echo "$extra" | sed 's/^/     /' | head -30
		fi
	done
}
