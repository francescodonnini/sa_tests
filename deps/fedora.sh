#!/usr/bin/env bash
# Installa con dnf i pacchetti che servono a build, test e benchmark.
#   Uso: ./deps-fedora.sh [programma...]      es. ./deps-fedora.sh nginx memcached
# Senza argomenti installa le dipendenze di tutti i programmi.
#
# Le librerie -devel sono di sistema e non strumentate: servono a compilare
# il programma (o i client dei benchmark), non fanno parte di ciò che si misura.
set -euo pipefail

# strumenti usati da common.sh e da tutti gli script: clone, build, verify_bin
# (objdump, readelf, nm), taskset, riepiloghi (awk). "perl" su Fedora installa
# l'interprete con tutti i moduli core (servono a OpenSSL, Git, nginx-tests...)
BASE="git make cmake tar patch gawk binutils util-linux perl perl-Test-Harness python3"

declare -A DEPS=(
	[zstd]=""
	[xz]=""
	[git]="zlib-devel"
	[php]="autoconf bison re2c"
	# moduli C facoltativi della stdlib; pyperformance crea i venv con pip
	[cpython]="openssl-devel libffi-devel zlib-devel bzip2-devel xz-devel sqlite-devel
		readline-devel ncurses-devel gdbm-devel libuuid-devel"
	# wrk compila da sé LuaJIT e OpenSSL: servono solo gcc e make
	[nginx]="pcre2-devel zlib-devel gcc"
	# memtier_benchmark (C++) per il benchmark
	[memcached]="autoconf automake libevent-devel gcc-c++ openssl-devel zlib-devel"
	[openssl]=""
	# amalgamation e speedtest1.c scaricati da sqlite.org e GitHub
	[sqlite]="curl unzip"
	# dal repository git servono i generatori del parser
	[postgres]="bison flex"
	# tclsh per la suite di test (runtest)
	[redis]="tcl"
	[duckdb]="ninja-build gcc-c++ python3"
)

if [ $# -eq 0 ]; then
	set -- "${!DEPS[@]}"
fi
PKGS=$BASE
for p in "$@"; do
	[ -n "${DEPS[$p]+x}" ] || { echo "programma sconosciuto: $p (${!DEPS[*]})" >&2; exit 1; }
	PKGS="$PKGS ${DEPS[$p]}"
done

# shellcheck disable=SC2086
sudo dnf install -y $PKGS