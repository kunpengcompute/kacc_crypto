#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
  ./scripts/apply_and_test_xts.sh /path/to/openssl

Environment:
  RUN_KPERF=0|1          Forwarded to run_all_tests.sh. Default: 0.
  RUN_TWEAK_BENCH=0|1   Forwarded to run_all_tests.sh. Default: 0.
USAGE
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openssl_dir="${1:-${OPENSSL_DIR:-}}"

if [ -z "${openssl_dir}" ]; then
    usage >&2
    exit 2
fi

if [ ! -d "${openssl_dir}/crypto/aes/asm" ]; then
    echo "error: OPENSSL_DIR does not look like an OpenSSL source tree: ${openssl_dir}" >&2
    exit 2
fi

"${repo_dir}/scripts/install_sve2_xts_dispatch.sh" "${openssl_dir}"

cd "${openssl_dir}/crypto/aes"
ln -sf libcrypto-lib-aesv8-armx.o libcrypto-shlib-aesv8-armx.o

cd asm
RUN_KPERF="${RUN_KPERF:-0}" \
RUN_TWEAK_BENCH="${RUN_TWEAK_BENCH:-0}" \
./run_all_tests.sh
