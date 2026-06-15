#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
  ./scripts/apply_and_test_rsa.sh /path/to/openssl

Environment:
  RSA_BENCH_ITERS=N     Benchmark iterations. Default: 1000.
  RSA_BENCH_CORE=N      Optional CPU core for taskset pinning.
  RSA_BENCH_MODE=MODE   all|native_default|native_no_blind|rsaz29_math|rsaz29_blind.
                        Default: all.
  CC=compiler           Default: cc.
USAGE
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openssl_dir="${1:-${OPENSSL_DIR:-}}"

if [ -z "${openssl_dir}" ]; then
    usage >&2
    exit 2
fi

"${repo_dir}/scripts/install_rsa_rsaz29_x8.sh" "${openssl_dir}"

cc_bin="${CC:-cc}"
iters="${RSA_BENCH_ITERS:-1000}"
mode="${RSA_BENCH_MODE:-all}"
bench="${openssl_dir}/test/rsa2048_private_rsaz29_x8_bench"

"${cc_bin}" -O3 -g -fno-omit-frame-pointer -std=gnu11 \
    -march=armv8.6-a+sve2 \
    -I"${openssl_dir}/include" -I"${openssl_dir}" \
    -o "${bench}" \
    "${openssl_dir}/test/rsa2048_private_rsaz29_x8_bench.c" \
    "${openssl_dir}/crypto/bn/asm/rsaz29-sve2-x8.S" \
    "${openssl_dir}/libcrypto.a" -pthread -ldl

if [ -n "${RSA_BENCH_CORE:-}" ]; then
    taskset -c "${RSA_BENCH_CORE}" "${bench}" "${iters}" "${mode}"
else
    "${bench}" "${iters}" "${mode}"
fi
