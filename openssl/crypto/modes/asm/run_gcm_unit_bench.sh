#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSSL_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build-gcm-unit"

detect_libcrypto() {
    if [[ -n "${OPENSSL_LIB:-}" ]]; then
        echo "$OPENSSL_LIB"
    elif [[ -f "$OPENSSL_DIR/libcrypto.a" ]]; then
        echo "$OPENSSL_DIR/libcrypto.a"
    elif [[ -f "$OPENSSL_DIR/.openssl/lib/libcrypto.a" ]]; then
        echo "$OPENSSL_DIR/.openssl/lib/libcrypto.a"
    else
        echo "$OPENSSL_DIR/libcrypto.a"
    fi
}

print_header() {
    echo ""
    echo "========================================================================="
    echo "$1"
    echo "========================================================================="
    echo ""
}

print_version_stamp() {
    local head

    head="$(git -C "$OPENSSL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Code version: openssl_dev HEAD=$head"
    echo "Default run: focused AES-128-GCM SVE2 product candidate."
    echo "             use --unit all for the 128/192/256 enc/dec matrix."
    echo "Note: the SVE2 path requires compiler support for"
    echo "      -march=armv9-a+sve2-aes+crypto. Override with GCM_BENCH_MARCH"
    echo "      if the target compiler uses another spelling."
    echo ""
}

run_speed_matrix() {
    local bench="$1"
    local unit="$2"
    shift 2
    local sizes=("$@")
    local size
    local output
    local gbps
    local sum="0"
    local count=0
    local values=()
    local mean

    echo "OpenSSL-speed size matrix, values are best_gbps:"
    printf "%-72s" "unit"
    for size in "${sizes[@]}"; do
        printf " %9s" "${size}B"
    done
    printf " %9s\n" "mean"
    printf "%-72s" "----"
    for size in "${sizes[@]}"; do
        printf " %9s" "---------"
    done
    printf " %9s\n" "---------"

    for size in "${sizes[@]}"; do
        output="$("$bench" --unit "$unit" --size "$size")"
        gbps="$(printf '%s\n' "$output" | awk -v u="$unit" -v s="$size" '$1 == u && $2 == s { v = $4 } END { print v }')"
        if [[ -z "$gbps" ]]; then
            echo "failed to parse benchmark output for unit=$unit size=$size" >&2
            printf '%s\n' "$output" >&2
            return 1
        fi
        values+=("$gbps")
        sum="$(awk -v a="$sum" -v b="$gbps" 'BEGIN { printf "%.6f", a + b }')"
        count=$((count + 1))
    done

    mean="$(awk -v s="$sum" -v c="$count" 'BEGIN { printf "%.2f", s / c }')"
    printf "%-72s" "$unit"
    for gbps in "${values[@]}"; do
        printf " %9.2f" "$gbps"
    done
    printf " %9.2f\n" "$mean"
}

main() {
    local cflags="-O3 -g"
    local march="${GCM_BENCH_MARCH:-armv9-a+sve2-aes+crypto}"
    local openssl_lib
    local asm_obj=""
    local asm_define=""
    local default_unit="aes-128-gcm-sve2-enc"
    local speed_sizes=(${GCM_SPEED_SIZES:-16 64 256 1024 8192 16384})
    local has_unit=0
    local has_size=0
    local has_verify=0
    local unit_value=""
    local arg
    local i

    print_header "AES-GCM Unit Benchmark"
    print_version_stamp

    openssl_lib="$(detect_libcrypto)"

    if [[ "$(uname -m)" == "aarch64" ]]; then
        cflags="$cflags -march=$march"
    fi

    if [[ ! -f "$openssl_lib" ]]; then
        echo "libcrypto not found: $openssl_lib" >&2
        echo "Build this OpenSSL tree first, or set OPENSSL_LIB explicitly." >&2
        exit 1
    fi
    if [[ ! -f "$OPENSSL_DIR/include/openssl/configuration.h" ]]; then
        echo "generated OpenSSL header not found: $OPENSSL_DIR/include/openssl/configuration.h" >&2
        echo "Run Configure/build first in this source tree." >&2
        exit 1
    fi

    mkdir -p "$BUILD_DIR"

    if [[ "$(uname -m)" == "aarch64" ]]; then
        perl "$SCRIPT_DIR/ghash-sve2-armv8_64.pl" linux64 \
            "$BUILD_DIR/ghash-sve2-armv8_64.S"
        gcc $cflags \
            -I"$OPENSSL_DIR/crypto" \
            -c -o "$BUILD_DIR/ghash-sve2-armv8_64.o" \
            "$BUILD_DIR/ghash-sve2-armv8_64.S"
        asm_obj="$BUILD_DIR/ghash-sve2-armv8_64.o"
        asm_define="-DGCM_BENCH_USE_ASM_SVE2"
    fi

    gcc $cflags $asm_define \
        -I"$OPENSSL_DIR/include" \
        -I"$OPENSSL_DIR/crypto" \
        -I"$OPENSSL_DIR" \
        -o "$BUILD_DIR/gcm_unit_bench" \
        "$SCRIPT_DIR/gcm_unit_bench.c" \
        $asm_obj \
        "$openssl_lib" -lpthread -ldl

    for ((i = 1; i <= $#; i++)); do
        arg="${!i}"
        if [[ "$arg" == "--unit" ]]; then
            has_unit=1
            i=$((i + 1))
            unit_value="${!i}"
        elif [[ "$arg" == "--size" ]]; then
            has_size=1
            i=$((i + 1))
        elif [[ "$arg" == "--verify-only" ]]; then
            has_verify=1
        fi
    done

    if [[ $# -eq 0 ]]; then
        echo "Default size sweep follows openssl speed AES-GCM sizes:"
        echo "  ${speed_sizes[*]}"
        run_speed_matrix "$BUILD_DIR/gcm_unit_bench" "$default_unit" \
            "${speed_sizes[@]}"
    elif [[ $has_verify -ne 0 ]]; then
        "$BUILD_DIR/gcm_unit_bench" "$@"
    elif [[ $has_unit -eq 0 && $has_size -eq 0 ]]; then
        echo "Default size sweep follows openssl speed AES-GCM sizes:"
        echo "  ${speed_sizes[*]}"
        run_speed_matrix "$BUILD_DIR/gcm_unit_bench" "$default_unit" \
            "${speed_sizes[@]}"
    elif [[ $has_unit -ne 0 && $has_size -eq 0 && "$unit_value" != "all" ]]; then
        echo "Size sweep follows openssl speed AES-GCM sizes:"
        echo "  ${speed_sizes[*]}"
        run_speed_matrix "$BUILD_DIR/gcm_unit_bench" "$unit_value" \
            "${speed_sizes[@]}"
    elif [[ $has_unit -eq 0 ]]; then
        "$BUILD_DIR/gcm_unit_bench" --unit "$default_unit" "$@"
    else
        "$BUILD_DIR/gcm_unit_bench" "$@"
    fi
}

main "$@"
