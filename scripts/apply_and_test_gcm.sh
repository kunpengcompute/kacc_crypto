#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_gcm.sh
  ./scripts/apply_and_test_gcm.sh /path/to/openssl

Applies the SVE2 AES-GCM dispatch overlay to an OpenSSL tree, then runs the
focused GCM function tests and the full NEON/SVE2 performance comparison.
USAGE
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openssl_dir="${1:-${OPENSSL_DIR:-}}"

if [ -z "${openssl_dir}" ]; then
    usage >&2
    exit 2
fi

"${repo_dir}/scripts/install_sve2_gcm_dispatch.sh" "${openssl_dir}"

(
    cd "${openssl_dir}/crypto/modes/asm"
    ./run_gcm_unit_bench.sh --verify-only
    ./run_all_gcm_tests.sh
)
