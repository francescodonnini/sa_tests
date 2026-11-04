#!/usr/bin/env bash
# Compila DuckDB per uno stage.   Uso: ./build-duckdb.sh <stage 0-4>
#
# DuckDB è C++ (più qualche libreria C in third_party): il pass IR e il pass
# x86 lavorano allo stesso modo, ma libstdc++ è di sistema e non strumentata.
# Si compilano, con CMake in modalità Release:
#   duckdb             la shell
#   test/unittest      il runner dei test (sqllogictest + test C++)
#   benchmark_runner   il runner dei benchmark (BUILD_BENCHMARKS)
# Estensioni incluse staticamente: core_functions e parquet (sempre), tpch
# (dati e query TPC-H per i benchmark) e json.
# CMake gira senza report del pass (i suoi programmi di prova non contano).
#
# La build è grande: con la unity build ogni processo di clang può superare i
# 2-3 GB, quindi i job paralleli sono limitati dalla RAM (JOBS per cambiarli).
# Servono ninja e python3:  dnf install ninja-build python3
# Risultato: $SS_ROOT/duckdb/sN/duckdb
set -euo pipefail
. "$(dirname "$0")/../common.sh"

DUCKDB_REF=v2.0.0
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

# un job ogni 3 GB di RAM, al massimo uno per CPU
MEM_GB=$(awk '/^MemTotal/ {print int($2 / 1048576)}' /proc/meminfo)
: "${JOBS:=$(( MEM_GB / 3 < $(nproc) ? (MEM_GB / 3 > 0 ? MEM_GB / 3 : 1) : $(nproc) ))}"

DIR=$SS_ROOT/duckdb
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/duckdb/duckdb "$DUCKDB_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

GEN=()
command -v ninja > /dev/null && GEN=(-G Ninja)

echo "== cmake (stage $STAGE)"
# OVERRIDE_GIT_DESCRIBE: la copia non ha .git, la versione si fissa qui
cmake -S "$BUILD" -B "$BUILD/build" "${GEN[@]}" -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="${CLANG}++" \
	-DCMAKE_C_FLAGS="$COPT" -DCMAKE_CXX_FLAGS="$COPT" \
	-DCMAKE_EXE_LINKER_FLAGS="$LDOPT" \
	-DOVERRIDE_GIT_DESCRIBE="$DUCKDB_REF-0-g0000000000" \
	-DBUILD_EXTENSIONS="tpch;json" -DBUILD_BENCHMARKS=1 -DBUILD_UNITTESTS=1 \
	-DENABLE_SANITIZER=0 -DENABLE_UBSAN=0 > "$BUILD/cmake.log" 2>&1 ||
	die "cmake fallito: vedi $BUILD/cmake.log"

REPORT=$BUILD/ss-report.csv
echo "== build con $JOBS job (stage $STAGE)"
SS_REPORT_DEST=$REPORT cmake --build "$BUILD/build" -j"$JOBS" \
	--target duckdb unittest benchmark_runner > "$BUILD/make.log" 2>&1 ||
	die "compilazione fallita: vedi $BUILD/make.log"

mkdir -p "$DIR/s$STAGE"
cp "$BUILD/build/duckdb" "$DIR/s$STAGE/duckdb"
verify_bin "$DIR/s$STAGE/duckdb" "$STAGE"
verify_bin "$BUILD/build/test/unittest" "$STAGE"
verify_bin "$BUILD/build/benchmark/benchmark_runner" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/duckdb"