#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  ./run_all_tests.sh

Environment:
  OPENSSL_LIB=/path/to/libcrypto.{a,so}  Optional libcrypto override.
  XTS_BENCH_MARCH=arch                   Default: armv9-a+sve2-aes+crypto.
  RUN_PERF=0|1                           Run performance test. Default: 1.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
openssl_dir="$(cd "${script_dir}/../../.." && pwd)"
build_dir="${script_dir}/build-xts-all"
cc_bin="${CC:-}"
run_perf="${RUN_PERF:-${RUN_KPERF:-1}}"
march="${XTS_BENCH_MARCH:-armv9-a+sve2-aes+crypto}"

select_c_compiler() {
    local candidate="$1"
    local probe_dir="${build_dir}/compiler-probe"
    local probe_c="${probe_dir}/probe.c"
    local probe_bin="${probe_dir}/probe"

    mkdir -p "${probe_dir}"
    printf 'int main(void) { return 0; }\n' > "${probe_c}"

    if [ -n "${candidate}" ] && [ "$(basename "${candidate}")" != "ld" ]; then
        if command -v "${candidate}" >/dev/null 2>&1 \
           && env -u CFLAGS -u CPPFLAGS -u LDFLAGS -u LDLIBS -u LIBS \
              "${candidate}" -x c "${probe_c}" -o "${probe_bin}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    fi

    for candidate in gcc clang cc; do
        if command -v "${candidate}" >/dev/null 2>&1 \
           && env -u CFLAGS -u CPPFLAGS -u LDFLAGS -u LDLIBS -u LIBS \
              "${candidate}" -x c "${probe_c}" -o "${probe_bin}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    echo "error: no working C compiler found; set CC to gcc/clang/cc" >&2
    return 1
}

run_cc() {
    env -u CFLAGS -u CPPFLAGS -u LDFLAGS -u LDLIBS -u LIBS "$@"
}

check_host_binary() {
    local bin="$1"
    local symbols="${build_dir}/$(basename "${bin}").symbols"

    if command -v readelf >/dev/null 2>&1; then
        readelf -Ws "${bin}" >"${symbols}" 2>/dev/null || true
        if ! grep -q '[[:space:]]_start$' "${symbols}"; then
            echo "error: ${bin} has no _start symbol; host C runtime was not linked" >&2
            return 1
        fi
    elif command -v nm >/dev/null 2>&1; then
        nm "${bin}" >"${symbols}" 2>/dev/null || true
        if ! grep -q '[[:space:]]_start$' "${symbols}"; then
            echo "error: ${bin} has no _start symbol; host C runtime was not linked" >&2
            return 1
        fi
    fi
}

detect_libcrypto() {
    if [ -n "${OPENSSL_LIB:-}" ]; then
        printf '%s\n' "${OPENSSL_LIB}"
    elif [ -f "${openssl_dir}/libcrypto.a" ]; then
        printf '%s\n' "${openssl_dir}/libcrypto.a"
    elif [ -f "${openssl_dir}/.openssl/lib/libcrypto.a" ]; then
        printf '%s\n' "${openssl_dir}/.openssl/lib/libcrypto.a"
    elif [ -f "${openssl_dir}/libcrypto.so" ]; then
        printf '%s\n' "${openssl_dir}/libcrypto.so"
    elif [ -f "${openssl_dir}/libcrypto.so.3" ]; then
        printf '%s\n' "${openssl_dir}/libcrypto.so.3"
    else
        printf '%s\n' "${openssl_dir}/libcrypto.a"
    fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$(uname -m)" != "aarch64" ]; then
    echo "error: SVE2 AES-XTS tests must run on AArch64" >&2
    exit 2
fi

libcrypto="$(detect_libcrypto)"
if [ ! -f "${libcrypto}" ]; then
    echo "error: libcrypto not found: ${libcrypto}" >&2
    echo "Build OpenSSL first, or set OPENSSL_LIB=/path/to/libcrypto.a." >&2
    exit 2
fi
if [ ! -f "${openssl_dir}/include/openssl/configuration.h" ]; then
    echo "error: generated OpenSSL header not found" >&2
    echo "Run Configure/build first in this OpenSSL source tree." >&2
    exit 2
fi

mkdir -p "${build_dir}"
cc_bin="$(select_c_compiler "${cc_bin}")"
echo "Using C compiler: ${cc_bin}"
"${cc_bin}" --version | sed -n '1p'

echo "Generating SVE2 AES-XTS assembly..."
perl "${script_dir}/aesv8-armx-sve2.pl" linux64 \
    "${build_dir}/aesv8-armx-sve2.S"

echo "Compiling SVE2 AES-XTS assembly..."
run_cc "${cc_bin}" -O3 -g -march="${march}" \
    -I"${openssl_dir}/crypto" \
    -c -o "${build_dir}/aesv8-armx-sve2.o" \
    "${build_dir}/aesv8-armx-sve2.S"

link_args=("${libcrypto}")
run_env=()
case "${libcrypto}" in
*.so|*.so.*)
    libcrypto_dir="$(cd "$(dirname "${libcrypto}")" && pwd)"
    link_args+=("-Wl,-rpath,${libcrypto_dir}")
    run_env=("LD_LIBRARY_PATH=${libcrypto_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}")
    ;;
esac

echo "Compiling SVE2 AES-XTS unit test..."
echo "Linking unit test with host C runtime..."
run_cc "${cc_bin}" -O3 -g -fno-omit-frame-pointer -std=gnu11 \
    -march="${march}" \
    -I"${openssl_dir}/include" \
    -I"${openssl_dir}" \
    -o "${build_dir}/sve2_unit_tests" \
    "${script_dir}/sve2_unit_tests.c" \
    "${build_dir}/aesv8-armx-sve2.o" \
    "${link_args[@]}" -pthread -ldl
check_host_binary "${build_dir}/sve2_unit_tests"

echo "Running SVE2 AES-XTS unit test..."
env "${run_env[@]}" "${build_dir}/sve2_unit_tests"

if [ "${run_perf}" != "0" ]; then
    echo "Compiling SVE2 AES-XTS performance test..."
    run_cc "${cc_bin}" -O3 -g -fno-omit-frame-pointer -std=gnu11 \
        -march="${march}" \
        -I"${openssl_dir}/include" \
        -I"${openssl_dir}" \
        -o "${build_dir}/sve2_performance_test" \
        "${script_dir}/sve2_performance_test.c" \
        "${build_dir}/aesv8-armx-sve2.o" \
        "${link_args[@]}" -pthread -ldl
    check_host_binary "${build_dir}/sve2_performance_test"

    echo "Running SVE2 AES-XTS performance test..."
    env "${run_env[@]}" "${build_dir}/sve2_performance_test"
fi
