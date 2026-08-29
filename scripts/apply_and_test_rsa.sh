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
  RSA_BENCH_BITS=all|2048|4096
                        RSA key size to benchmark. Default: all.
  RSA_BENCH_RUN=0|1     Run the benchmark after compiling. Default: 0.
  RSA_BENCH_LINK=auto|static|shared
                        OpenSSL libcrypto link mode. Default: auto.
  OPENSSL_LIB=/path/to/libcrypto.{a,so}
                        Optional explicit libcrypto path.
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

cc_bin="${CC:-}"
iters="${RSA_BENCH_ITERS:-1000}"
mode="${RSA_BENCH_MODE:-all}"
bits="${RSA_BENCH_BITS:-all}"
run_bench="${RSA_BENCH_RUN:-0}"
link_mode="${RSA_BENCH_LINK:-auto}"
build_dir="${openssl_dir}/test/.rsa-rsaz29-x8-build"

select_c_compiler() {
    local candidate="$1"
    local probe_c="${build_dir}/compiler-probe.c"
    local probe_bin="${build_dir}/compiler-probe"

    mkdir -p "${build_dir}"
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

case "${bits}" in
all)
    bits_list=(2048 4096)
    ;;
2048|4096)
    bits_list=("${bits}")
    ;;
*)
    echo "error: unsupported RSA_BENCH_BITS=${bits}, expected all, 2048 or 4096" >&2
    exit 2
    ;;
esac

case "${link_mode}" in
auto|static|shared)
    ;;
*)
    echo "error: unsupported RSA_BENCH_LINK=${link_mode}, expected auto, static or shared" >&2
    exit 2
    ;;
esac

case "${run_bench}" in
0|1)
    ;;
*)
    echo "error: unsupported RSA_BENCH_RUN=${run_bench}, expected 0 or 1" >&2
    exit 2
    ;;
esac

cc_bin="$(select_c_compiler "${cc_bin}")"
echo "Using C compiler: ${cc_bin}"
"${cc_bin}" --version | sed -n '1p'

find_static_libcrypto() {
    if [ -n "${OPENSSL_LIB:-}" ]; then
        [ -f "${OPENSSL_LIB}" ] && printf '%s\n' "${OPENSSL_LIB}"
        return
    fi
    for candidate in \
        "${openssl_dir}/libcrypto.a" \
        "${openssl_dir}/.openssl/lib/libcrypto.a"; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return
        fi
    done
}

find_shared_libcrypto() {
    if [ -n "${OPENSSL_LIB:-}" ]; then
        [ -f "${OPENSSL_LIB}" ] && printf '%s\n' "${OPENSSL_LIB}"
        return
    fi
    for candidate in \
        "${openssl_dir}/libcrypto.so" \
        "${openssl_dir}/libcrypto.so.3" \
        "${openssl_dir}/lib/libcrypto.so" \
        "${openssl_dir}/lib64/libcrypto.so" \
        "${openssl_dir}/.openssl/lib/libcrypto.so" \
        "${openssl_dir}/.openssl/lib64/libcrypto.so"; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return
        fi
    done
}

libcrypto=""
if [ "${link_mode}" = "static" ] || [ "${link_mode}" = "auto" ]; then
    libcrypto="$(find_static_libcrypto)"
fi
if [ -z "${libcrypto}" ] && { [ "${link_mode}" = "shared" ] || [ "${link_mode}" = "auto" ]; }; then
    libcrypto="$(find_shared_libcrypto)"
fi
if [ -z "${libcrypto}" ]; then
    echo "error: libcrypto not found for RSA_BENCH_LINK=${link_mode}: ${openssl_dir}" >&2
    echo "hint: build OpenSSL first, or set OPENSSL_LIB=/path/to/libcrypto.a or libcrypto.so" >&2
    exit 2
fi

libcrypto_dir="$(cd "$(dirname "${libcrypto}")" && pwd)"
link_args=("${libcrypto}")
run_env=()
case "${libcrypto}" in
*.so|*.so.*)
    link_args+=("-Wl,-rpath,${libcrypto_dir}")
    run_env=("LD_LIBRARY_PATH=${libcrypto_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}")
    ;;
esac

bench_list=()
for bits in "${bits_list[@]}"; do
    bench="${openssl_dir}/test/rsa${bits}_private_rsaz29_x8_bench"
    bench_list+=("${bench}")

    echo "Compiling RSA${bits} rsaz29 x8 benchmark..."
    run_cc "${cc_bin}" -O3 -g -fno-omit-frame-pointer -std=gnu11 \
        -Wno-deprecated-declarations \
        -march=armv8.6-a+sve2 \
        -I"${openssl_dir}/include" -I"${openssl_dir}" \
        -o "${bench}" \
        "${openssl_dir}/test/rsa${bits}_private_rsaz29_x8_bench.c" \
        "${openssl_dir}/crypto/bn/asm/rsaz29-sve2-x8.S" \
        "${link_args[@]}" -pthread -ldl
    check_host_binary "${bench}"
    echo "Generated ${bench}"
done

if [ "${run_bench}" = "0" ]; then
    exit 0
fi

for i in "${!bits_list[@]}"; do
    bits="${bits_list[$i]}"
    bench="${bench_list[$i]}"

    echo "Running RSA${bits} rsaz29 x8 benchmark: iterations=${iters} mode=${mode}"
    if [ "${bits}" = "4096" ] && [ "${iters}" -ge 1000 ]; then
        echo "Note: RSA4096 with 1000 iterations and mode=all can run for several minutes."
    fi

    if [ -n "${RSA_BENCH_CORE:-}" ]; then
        env "${run_env[@]}" taskset -c "${RSA_BENCH_CORE}" "${bench}" "${iters}" "${mode}"
    else
        env "${run_env[@]}" "${bench}" "${iters}" "${mode}"
    fi
done
