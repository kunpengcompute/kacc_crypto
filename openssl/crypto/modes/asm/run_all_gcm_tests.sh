#!/bin/bash

# SVE2 AES-GCM test suite runner.
# This mirrors the AES-XTS workflow: generate assembly from .pl, compile the
# benchmark harness against that object, run correctness first, then performance.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSSL_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build-gcm-all"
GCM_SPEED_SIZES="${GCM_SPEED_SIZES:-16 64 256 1024 8192 16384}"

print_header() {
    echo ""
    echo "========================================================================="
    echo "$1"
    echo "========================================================================="
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

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

print_version_stamp() {
    local head asm_stamp

    head="$(git -C "$OPENSSL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [[ -f "$BUILD_DIR/ghash-sve2-armv8_64.S" ]]; then
        asm_stamp="$(stat -c '%y' "$BUILD_DIR/ghash-sve2-armv8_64.S" 2>/dev/null || stat -f '%Sm' "$BUILD_DIR/ghash-sve2-armv8_64.S" 2>/dev/null || echo unknown)"
    else
        asm_stamp="missing"
    fi

    echo "Code version: openssl_dev HEAD=$head"
    echo "Generated assembly timestamp: $asm_stamp"
    echo "GCM test target: focused SVE2 AES-GCM product benchmark"
    echo ""
}

check_sve2_support() {
    print_info "Checking SVE2 support..."

    if [[ "$(uname -m)" != "aarch64" ]]; then
        print_warning "Not running on ARM64 architecture"
        return 0
    fi

    if command -v lscpu >/dev/null 2>&1 && lscpu | grep -q "sve2"; then
        print_success "SVE2 support detected"
        return 0
    fi

    print_warning "Could not verify SVE2 support from lscpu"
    return 0
}

prepare_build_dir() {
    print_info "Preparing build directory..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    print_success "Build directory ready: $BUILD_DIR"
}

check_openssl_build() {
    local openssl_lib="$1"

    if [[ ! -f "$openssl_lib" ]]; then
        print_error "libcrypto not found: $openssl_lib"
        echo "Build this OpenSSL tree first, or set OPENSSL_LIB explicitly." >&2
        exit 1
    fi
    if [[ ! -f "$OPENSSL_DIR/include/openssl/configuration.h" ]]; then
        print_error "generated OpenSSL header not found: $OPENSSL_DIR/include/openssl/configuration.h"
        echo "Run Configure/build first in this source tree." >&2
        exit 1
    fi
}

generate_assembly() {
    print_info "Generating SVE2 GHASH assembly..."
    perl "$SCRIPT_DIR/ghash-sve2-armv8_64.pl" linux64 "$BUILD_DIR/ghash-sve2-armv8_64.S"

    if [[ -f "$BUILD_DIR/ghash-sve2-armv8_64.S" ]]; then
        print_success "Assembly generated: $BUILD_DIR/ghash-sve2-armv8_64.S"
    else
        print_error "Failed to generate SVE2 GHASH assembly"
        exit 1
    fi
}

compile_assembly() {
    local cflags="$1"

    print_info "Compiling SVE2 GHASH object..."
    gcc $cflags \
        -I"$OPENSSL_DIR/crypto" \
        -c -o "$BUILD_DIR/ghash-sve2-armv8_64.o" \
        "$BUILD_DIR/ghash-sve2-armv8_64.S"

    if [[ -f "$BUILD_DIR/ghash-sve2-armv8_64.o" ]]; then
        print_success "Object compiled: $BUILD_DIR/ghash-sve2-armv8_64.o"
    else
        print_error "Failed to compile SVE2 GHASH object"
        exit 1
    fi
}

compile_gcm_bench() {
    local cflags="$1"
    local openssl_lib="$2"

    print_info "Compiling AES-GCM test harness..."
    gcc $cflags -DGCM_BENCH_USE_ASM_SVE2 \
        -I"$OPENSSL_DIR/include" \
        -I"$OPENSSL_DIR/crypto" \
        -I"$OPENSSL_DIR" \
        -o "$BUILD_DIR/gcm_unit_bench" \
        "$SCRIPT_DIR/gcm_unit_bench.c" \
        "$BUILD_DIR/ghash-sve2-armv8_64.o" \
        "$openssl_lib" -lpthread -ldl

    if [[ -f "$BUILD_DIR/gcm_unit_bench" ]]; then
        print_success "Test harness compiled: $BUILD_DIR/gcm_unit_bench"
    else
        print_error "Failed to compile AES-GCM test harness"
        exit 1
    fi
}

run_speed_matrix() {
    local title="$1"
    shift
    local units=("$@")
    local sizes=($GCM_SPEED_SIZES)
    local unit
    local size
    local output
    local gbps
    local sum
    local count
    local mean
    local values

    print_info "$title"
    echo "Values are best_gbps; mean is arithmetic mean over listed sizes."
    printf "%-32s" "unit"
    for size in "${sizes[@]}"; do
        printf " %9s" "${size}B"
    done
    printf " %9s\n" "mean"
    printf "%-32s" "----"
    for size in "${sizes[@]}"; do
        printf " %9s" "---------"
    done
    printf " %9s\n" "---------"

    for unit in "${units[@]}"; do
        sum="0"
        count=0
        values=()
        for size in "${sizes[@]}"; do
            output="$(./gcm_unit_bench --unit "$unit" --size "$size")"
            gbps="$(printf '%s\n' "$output" | awk -v u="$unit" -v s="$size" '$1 == u && $2 == s { v = $4 } END { print v }')"
            if [[ -z "$gbps" ]]; then
                print_error "failed to parse benchmark output for unit=$unit size=$size"
                printf '%s\n' "$output" >&2
                return 1
            fi
            values+=("$gbps")
            sum="$(awk -v a="$sum" -v b="$gbps" 'BEGIN { printf "%.6f", a + b }')"
            count=$((count + 1))
        done

        mean="$(awk -v s="$sum" -v c="$count" 'BEGIN { printf "%.2f", s / c }')"
        printf "%-32s" "$unit"
        for gbps in "${values[@]}"; do
            printf " %9.2f" "$gbps"
        done
        printf " %9.2f\n" "$mean"
    done

    echo ""
}

run_functional_test() {
    print_header "Running Functional Test"

    cd "$BUILD_DIR"
    if ./gcm_unit_bench --verify-only; then
        print_success "Functional test passed"
        return 0
    else
        print_error "Functional test failed"
        return 1
    fi
}

run_performance_test() {
    print_header "Running Performance Test"

    cd "$BUILD_DIR"
    print_info "OpenSSL-speed compatible sizes: $GCM_SPEED_SIZES"

    run_speed_matrix "Running NEON AES-GCM key-size matrix" \
        neon-128-gcm-enc \
        neon-192-gcm-enc \
        neon-256-gcm-enc \
        neon-128-gcm-dec \
        neon-192-gcm-dec \
        neon-256-gcm-dec

    run_speed_matrix "Running SVE2 AES-GCM product matrix" \
        aes-128-gcm-sve2-enc \
        aes-192-gcm-sve2-enc \
        aes-256-gcm-sve2-enc \
        aes-128-gcm-sve2-dec \
        aes-192-gcm-sve2-dec \
        aes-256-gcm-sve2-dec
    if [[ "${RUN_GCM_PMU:-0}" != "0" ]] && command -v perf >/dev/null 2>&1; then
        print_info "Running PMU convergence set"
        for unit in \
            kernel-eor3-enc \
            neon-128-gcm-enc \
            neon-192-gcm-enc \
            neon-256-gcm-enc \
            aes-128-gcm-sve2-enc \
            aes-192-gcm-sve2-enc \
            aes-256-gcm-sve2-enc \
            aes-128-gcm-sve2-dec \
            aes-192-gcm-sve2-dec \
            aes-256-gcm-sve2-dec
        do
            echo "=== PMU: $unit ==="
            perf stat -e cycles,instructions -r "${RUN_GCM_PMU_REPEAT:-3}" \
                ./gcm_unit_bench --unit "$unit"
        done
    fi

    print_success "Performance test completed"
}

main() {
    local cflags="-O3 -g"
    local march="${GCM_BENCH_MARCH:-armv9-a+sve2-aes+crypto}"
    local openssl_lib
    local failed=0

    print_header "SVE2 AES-GCM Test Suite"
    openssl_lib="$(detect_libcrypto)"

    if [[ "$(uname -m)" == "aarch64" ]]; then
        cflags="$cflags -march=$march"
    fi

    check_sve2_support
    prepare_build_dir
    print_version_stamp
    check_openssl_build "$openssl_lib"
    generate_assembly
    compile_assembly "$cflags"
    compile_gcm_bench "$cflags" "$openssl_lib"

    if ! run_functional_test; then
        failed=1
    fi
    if ! run_performance_test; then
        failed=1
    fi

    print_header "Test Suite Complete"
    if [[ $failed -eq 0 ]]; then
        print_success "All AES-GCM tests passed"
        exit 0
    else
        print_error "Some AES-GCM tests failed"
        exit 1
    fi
}

main "$@"
