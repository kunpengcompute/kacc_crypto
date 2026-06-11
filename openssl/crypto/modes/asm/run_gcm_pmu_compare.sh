#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSSL_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build-gcm-unit"
BENCH="$BUILD_DIR/gcm_unit_bench"
PERF_REPEAT="${GCM_PMU_REPEAT:-3}"
BENCH_REPEATS="${GCM_BENCH_REPEATS:-5}"
EVENTS="${GCM_PMU_EVENTS:-cycles,instructions,stalled-cycles-frontend,stalled-cycles-backend}"
SIZES=(${GCM_PMU_SIZES:-16 64 256 1024 8192 16384})
UNITS=(${GCM_PMU_UNITS:-neon-256-gcm-enc aes-256-gcm-sve2-enc neon-128-gcm-enc aes-128-gcm-sve2-enc neon-128-gcm-dec aes-128-gcm-sve2-dec})

prepare_bench() {
    if [[ "${GCM_PMU_SKIP_BUILD:-0}" != "0" && -x "$BENCH" ]]; then
        return
    fi

    "$SCRIPT_DIR/run_gcm_unit_bench.sh" --verify-only >/dev/null
}

extract_last_bench_line() {
    local unit="$1"
    local size="$2"
    awk -v u="$unit" -v s="$size" '$1 == u && $2 == s { line = $0 } END { print line }'
}

extract_event_value() {
    local event="$1"
    awk -F, -v e="$event" '$3 == e ":u" || $3 == e { gsub(/ /, "", $1); v = $1 } END { print v }'
}

run_one() {
    local unit="$1"
    local size="$2"
    local out
    local err
    local status
    local line
    local iterations
    local best_gbps
    local cycles
    local instructions
    local frontend
    local backend
    local bytes
    local ipc
    local cpb
    local ipb
    local frontend_pct
    local backend_pct

    out="$(mktemp)"
    err="$(mktemp)"
    set +e
    perf stat -x, -r "$PERF_REPEAT" -e "$EVENTS" \
        "$BENCH" --unit "$unit" --size "$size" >"$out" 2>"$err"
    status=$?
    set -e

    if [[ $status -ne 0 ]]; then
        printf "%-72s %8s %10s %10s %14s %14s %8s %10s %10s %9s %9s\n" \
            "$unit" "$size" "FAIL" "-" "-" "-" "-" "-" "-" "-" "-"
        sed 's/^/# perf: /' "$err" >&2
        rm -f "$out" "$err"
        return 0
    fi

    line="$(extract_last_bench_line "$unit" "$size" <"$out")"
    if [[ -z "$line" ]]; then
        printf "%-72s %8s %10s %10s %14s %14s %8s %10s %10s %9s %9s\n" \
            "$unit" "$size" "NOPARSE" "-" "-" "-" "-" "-" "-" "-" "-"
        sed 's/^/# stdout: /' "$out" >&2
        sed 's/^/# perf: /' "$err" >&2
        rm -f "$out" "$err"
        return 0
    fi

    iterations="$(awk '{ print $3 }' <<<"$line")"
    best_gbps="$(awk '{ print $4 }' <<<"$line")"
    cycles="$(extract_event_value cycles <"$err")"
    instructions="$(extract_event_value instructions <"$err")"
    frontend="$(extract_event_value stalled-cycles-frontend <"$err")"
    backend="$(extract_event_value stalled-cycles-backend <"$err")"

    if [[ -z "$cycles" || -z "$instructions" ]]; then
        printf "%-72s %8s %10s %10s %14s %14s %8s %10s %10s %9s %9s\n" \
            "$unit" "$size" "$best_gbps" "$iterations" "NOEVENT" "NOEVENT" "-" "-" "-" "-" "-"
        sed 's/^/# perf: /' "$err" >&2
        rm -f "$out" "$err"
        return 0
    fi

    bytes="$(awk -v s="$size" -v it="$iterations" -v r="$BENCH_REPEATS" 'BEGIN { printf "%.0f", s * it * r }')"
    ipc="$(awk -v i="$instructions" -v c="$cycles" 'BEGIN { printf "%.3f", i / c }')"
    cpb="$(awk -v c="$cycles" -v b="$bytes" 'BEGIN { printf "%.4f", c / b }')"
    ipb="$(awk -v i="$instructions" -v b="$bytes" 'BEGIN { printf "%.4f", i / b }')"
    frontend_pct="$(awk -v s="${frontend:-0}" -v c="$cycles" 'BEGIN { printf "%.1f%%", 100.0 * s / c }')"
    backend_pct="$(awk -v s="${backend:-0}" -v c="$cycles" 'BEGIN { printf "%.1f%%", 100.0 * s / c }')"

    printf "%-72s %8s %10.2f %10s %14.0f %14.0f %8s %10s %10s %9s %9s\n" \
        "$unit" "$size" "$best_gbps" "$iterations" "$cycles" \
        "$instructions" "$ipc" "$cpb" "$ipb" "$frontend_pct" "$backend_pct"

    rm -f "$out" "$err"
}

main() {
    local unit
    local size

    if ! command -v perf >/dev/null 2>&1; then
        echo "perf not found" >&2
        exit 1
    fi

    prepare_bench

    echo "AES-GCM PMU compare"
    echo "repo: $OPENSSL_DIR"
    echo "bench: $BENCH"
    echo "events: $EVENTS"
    echo "perf_repeat: $PERF_REPEAT"
    echo "bench_repeats: $BENCH_REPEATS"
    echo ""
    printf "%-72s %8s %10s %10s %14s %14s %8s %10s %10s %9s %9s\n" \
        "unit" "size" "GB/s" "iters" "cycles" "instructions" "IPC" "cyc/B" "inst/B" "FE_stall" "BE_stall"
    printf "%-72s %8s %10s %10s %14s %14s %8s %10s %10s %9s %9s\n" \
        "----" "----" "----" "-----" "------" "------------" "---" "-----" "------" "--------" "--------"

    for unit in "${UNITS[@]}"; do
        for size in "${SIZES[@]}"; do
            run_one "$unit" "$size"
        done
    done
}

main "$@"
