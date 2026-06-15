#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  OPENSSL_DIR=/path/to/openssl ./scripts/install_rsa_rsaz29_x8.sh
  ./scripts/install_rsa_rsaz29_x8.sh /path/to/openssl

Installs the retained SVE2 RSA2048 radix29 x8 source overlay into an OpenSSL
tree.  Only the final hand-written AMM/square/gather kernels and the
end-to-end validation benchmark are installed; intermediate experiment probes
are intentionally excluded.
USAGE
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openssl_dir="${1:-${OPENSSL_DIR:-}}"

if [ -z "${openssl_dir}" ]; then
    usage >&2
    exit 2
fi

if [ ! -d "${openssl_dir}/crypto/bn/asm" ] \
   || [ ! -d "${openssl_dir}/test" ] \
   || [ ! -f "${openssl_dir}/libcrypto.a" ]; then
    echo "error: OPENSSL_DIR must be a built OpenSSL source tree with libcrypto.a: ${openssl_dir}" >&2
    exit 2
fi

install -m 0644 \
    "${repo_dir}/openssl/crypto/bn/asm/rsaz29-sve2-x8.S" \
    "${openssl_dir}/crypto/bn/asm/rsaz29-sve2-x8.S"
install -m 0644 \
    "${repo_dir}/openssl/test/rsa2048_private_rsaz29_x8_bench.c" \
    "${openssl_dir}/test/rsa2048_private_rsaz29_x8_bench.c"
