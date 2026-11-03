#!/usr/bin/env bash
# Compila e installa nginx per uno stage.   Uso: ./build-nginx.sh <stage 0-4>
#
# Servono pcre2 e zlib di sistema (rewrite, gzip), su Fedora:
#   dnf install pcre2-devel zlib-devel
# Le librerie di sistema non sono strumentate. Niente SSL: i test che lo usano
# vengono saltati allo stesso modo in ogni stage.
# configure compila e linka dei programmi di prova con --with-cc-opt e
# --with-ld-opt: girano anch'essi con il runtime (serve il modulo caricato);
# il report del pass si attiva solo durante make.
# Risultato: $SS_ROOT/nginx/sN/sbin/nginx
set -euo pipefail
. "$(dirname "$0")/../common.sh"

NGINX_REF=release-1.30.6
STAGE=${1:-}; check_stage "$STAGE"
check_prereq "$STAGE"
stage_flags "$STAGE"

DIR=$SS_ROOT/nginx
BUILD=$DIR/build-s$STAGE
fetch_src https://github.com/nginx/nginx "$NGINX_REF" "$DIR/src"
fresh_copy "$DIR/src" "$BUILD"

echo "== configure (stage $STAGE)"
(cd "$BUILD" && ./auto/configure --prefix="$DIR/s$STAGE" \
	--with-cc="$CLANG" --with-cc-opt="-O2 $COPT" --with-ld-opt="$LDOPT" \
	--with-http_realip_module --with-http_addition_module --with-http_sub_module \
	--with-http_dav_module --with-http_gunzip_module --with-http_gzip_static_module \
	--with-http_auth_request_module --with-http_random_index_module \
	--with-http_secure_link_module --with-http_slice_module --with-http_stub_status_module \
	--with-stream --with-stream_realip_module --with-threads) > "$BUILD/configure.log" 2>&1 ||
	die "configure fallito: vedi $BUILD/configure.log"

REPORT=$BUILD/ss-report.csv
echo "== make"
rm -rf "$DIR/s$STAGE"
SS_REPORT_DEST=$REPORT make -C "$BUILD" -j"$(nproc)" > "$BUILD/make.log" 2>&1 ||
	die "compilazione fallita: vedi $BUILD/make.log"
make -C "$BUILD" install > /dev/null

verify_bin "$DIR/s$STAGE/sbin/nginx" "$STAGE"
ir_report "$REPORT"
echo "== stage $STAGE pronto: $DIR/s$STAGE/sbin/nginx"
