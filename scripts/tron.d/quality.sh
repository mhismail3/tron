#!/bin/bash
# quality.sh - sourced by tron; do not execute directly.

run_tests() {
    print_status "Running tests..."
    # The WebSocket integration target shares process-global test server
    # plumbing and must run serially. Keep unit/binary tests parallel for
    # speed, then run each integration target with the harness shape it needs.
    if (cd "$RUST_WORKSPACE" \
        && cargo test --workspace --lib --bins -- --quiet 2>&1 \
        && cargo test --test db_path_guard -- --quiet 2>&1 \
        && cargo test --test threat_model_invariants -- --quiet 2>&1 \
        && cargo test --test integration -- --test-threads=1 --quiet 2>&1); then
        print_success "Tests passed"
        return 0
    else
        return 1
    fi
}

run_fmt_check() {
    print_status "Checking formatting..."
    (cd "$RUST_WORKSPACE" && cargo fmt --all -- --check) || { print_error "Format check failed (run: cargo fmt --all)"; return 1; }
    print_success "Formatting OK"
}

run_clippy() {
    print_status "Running clippy..."
    (cd "$RUST_WORKSPACE" && cargo clippy --workspace --all-targets) || { print_error "Clippy failed"; return 1; }
    print_success "Clippy passed"
}

run_doc_check() {
    print_status "Building docs..."
    (cd "$RUST_WORKSPACE" && RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps) || { print_error "Doc build failed"; return 1; }
    print_success "Docs OK"
}

run_coverage() {
    if ! command -v cargo-tarpaulin &> /dev/null; then
        print_error "cargo-tarpaulin not installed. Install with: cargo install cargo-tarpaulin"
        return 1
    fi
    print_status "Running coverage..."
    (cd "$RUST_WORKSPACE" && cargo tarpaulin --workspace --out Html --output-dir target/coverage) || { print_error "Coverage failed"; return 1; }
    print_success "Coverage report: $RUST_WORKSPACE/target/coverage/tarpaulin-report.html"
}

bench_baseline_triplet() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m | tr '[:upper:]' '[:lower:]')

    case "$os" in
        darwin) os="macos" ;;
    esac

    case "$arch" in
        arm64) arch="aarch64" ;;
        x86_64) arch="x86_64" ;;
    esac

    echo "${os}-${arch}"
}

default_bench_baseline() {
    echo "$BENCH_BASELINE_DIR/$(bench_baseline_triplet).json"
}

run_bench_gate() {
    local baseline="${1:-$(default_bench_baseline)}"

    if [ ! -f "$baseline" ]; then
        print_error "Benchmark baseline not found: $baseline"
        print_status "Create or refresh it with: tron bench bless"
        return 1
    fi

    mkdir -p "$SCRIPT_DIR/artifacts/benchmarks"
    local stamp out_file
    stamp="$(date +"%Y%m%d-%H%M%S")"
    out_file="$SCRIPT_DIR/artifacts/benchmarks/compare-${stamp}.json"

    print_status "Running benchmark regression gate against $(basename "$baseline")..."
    python3 "$BENCH_SCRIPT" \
        --scenario gate \
        --iterations "$BENCH_GATE_ITERATIONS" \
        --baseline "$baseline" \
        --enforce-gates \
        --max-p95-regression-pct "$BENCH_GATE_MAX_P95_REGRESSION_PCT" \
        --max-mean-regression-pct "$BENCH_GATE_MAX_MEAN_REGRESSION_PCT" \
        --output "$out_file" || {
            print_error "Benchmark gate failed"
            print_status "Comparison report: $out_file"
            return 1
        }
    print_success "Benchmark gate passed"
    print_status "Comparison report: $out_file"
}

cmd_ci() {
    require_project_dir

    local steps=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            fmt)      steps+=(fmt); shift ;;
            check)    steps+=(check); shift ;;
            clippy)   steps+=(clippy); shift ;;
            test)     steps+=(test); shift ;;
            bench)    steps+=(bench); shift ;;
            doc)      steps+=(doc); shift ;;
            coverage) steps+=(coverage); shift ;;
            -h|--help)
                echo ""
                echo -e "${CYAN}tron ci${NC} - Run CI checks"
                echo ""
                echo "Usage: tron ci [steps...]"
                echo ""
                echo "Steps (run in order listed):"
                echo "  fmt        Check formatting (cargo fmt --check)"
                echo "  check      Compile check (cargo check --all-targets)"
                echo "  clippy     Lint with -D warnings"
                echo "  test       Run all tests"
                echo "  bench      Run benchmark regression gate"
                echo "  doc        Build docs with -D warnings"
                echo "  coverage   Generate coverage report (requires cargo-tarpaulin)"
                echo ""
                echo "With no arguments, runs: fmt check clippy test bench doc"
                echo ""
                return 0
                ;;
            *) print_error "Unknown CI step: $1"; return 1 ;;
        esac
    done

    # Default: all steps (except coverage)
    if [ ${#steps[@]} -eq 0 ]; then
        steps=(fmt check clippy test bench doc)
    fi

    print_header "CI Checks"
    local failed=false

    for step in "${steps[@]}"; do
        case "$step" in
            fmt)      run_fmt_check || failed=true ;;
            check)    print_status "Compile checking..."; (cd "$RUST_WORKSPACE" && cargo check --workspace --all-targets) && print_success "Check passed" || { print_error "Check failed"; failed=true; } ;;
            clippy)   run_clippy || failed=true ;;
            test)     run_tests || failed=true ;;
            bench)    run_bench_gate || failed=true ;;
            doc)      run_doc_check || failed=true ;;
            coverage) run_coverage || failed=true ;;
        esac

        if [ "$failed" = true ]; then
            echo ""
            print_error "CI failed at: $step"
            return 1
        fi
    done

    echo ""
    print_success "All CI checks passed"
}

cmd_bench() {
    require_project_dir

    local BENCH_DIR="$SCRIPT_DIR/artifacts/benchmarks"
    local subcmd="${1:-run}"
    shift 2>/dev/null || true

    case "$subcmd" in
        run)
            local iterations=100
            local scenario="all"
            local save=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -i|--iterations) iterations="$2"; shift 2 ;;
                    -s|--scenario)    scenario="$2"; shift 2 ;;
                    --save)           save=true; shift ;;
                    -h|--help)
                        echo ""
                        echo -e "${CYAN}tron bench run${NC} - Run benchmarks"
                        echo ""
                        echo "Usage: tron bench run [options]"
                        echo ""
                        echo "Options:"
                        echo "  -i, --iterations N   Turns per scenario (default: 100)"
                        echo "  -s, --scenario NAME  ping, session_create, session_list, gate, all"
                        echo "  --save               Save result as a baseline"
                        echo ""
                        return 0
                        ;;
                    *) print_error "Unknown option: $1"; return 1 ;;
                esac
            done

            local output_args=()
            if [ "$save" = true ]; then
                mkdir -p "$BENCH_DIR"
                local stamp
                stamp="$(date +"%Y%m%d-%H%M%S")"
                local out_file="$BENCH_DIR/baseline-${stamp}.json"
                output_args=(--output "$out_file")
            fi

            print_header "Running benchmarks"
            python3 "$BENCH_SCRIPT" \
                --scenario "$scenario" \
                --iterations "$iterations" \
                "${output_args[@]}"

            if [ "$save" = true ]; then
                print_success "Baseline saved to: $out_file"
            fi
            ;;

        bless)
            local baseline
            baseline="$(default_bench_baseline)"
            mkdir -p "$(dirname "$baseline")"

            print_header "Refreshing benchmark baseline"
            print_status "Writing baseline to $baseline"
            python3 "$BENCH_SCRIPT" \
                --scenario gate \
                --iterations "$BENCH_GATE_ITERATIONS" \
                --output "$baseline"

            print_success "Baseline refreshed: $baseline"
            ;;

        compare)
            local baseline=""
            local iterations="$BENCH_GATE_ITERATIONS"
            local enforce=true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -b|--baseline)    baseline="$2"; shift 2 ;;
                    -i|--iterations)  iterations="$2"; shift 2 ;;
                    --no-enforce)     enforce=false; shift ;;
                    -h|--help)
                        echo ""
                        echo -e "${CYAN}tron bench compare${NC} - Compare against baseline"
                        echo ""
                        echo "Usage: tron bench compare -b <baseline.json> [options]"
                        echo ""
                        echo "Options:"
                        echo "  -b, --baseline FILE  Baseline JSON to compare against"
                        echo "                       (default: $(default_bench_baseline))"
                        echo "  -i, --iterations N   Turns per scenario (default: $BENCH_GATE_ITERATIONS)"
                        echo "  --no-enforce         Don't fail on gate violations"
                        echo ""
                        return 0
                        ;;
                    *) print_error "Unknown option: $1"; return 1 ;;
                esac
            done

            if [[ -z "$baseline" ]]; then
                baseline="$(default_bench_baseline)"
            fi

            mkdir -p "$BENCH_DIR"
            local stamp
            stamp="$(date +"%Y%m%d-%H%M%S")"
            local out_file="$BENCH_DIR/compare-${stamp}.json"

            local enforce_args=()
            if [ "$enforce" = true ]; then
                enforce_args=(--enforce-gates)
            fi

            print_header "Comparing against baseline"
            python3 "$BENCH_SCRIPT" \
                --scenario all \
                --iterations "$iterations" \
                --baseline "$baseline" \
                "${enforce_args[@]}" \
                --output "$out_file"

            print_success "Comparison saved to: $out_file"
            ;;

        -h|--help|help)
            echo ""
            echo -e "${CYAN}tron bench${NC} - Performance benchmarks"
            echo ""
            echo "Usage: tron bench <subcommand> [options]"
            echo ""
            echo "Subcommands:"
            echo "  run       Run benchmarks (use --save to store results)"
            echo "  bless     Refresh the checked-in benchmark baseline for this platform"
            echo "  compare   Compare current performance against a baseline"
            echo ""
            echo "Run 'tron bench <subcommand> -h' for subcommand help."
            echo ""
            ;;

        *) print_error "Unknown bench subcommand: $subcmd"; return 1 ;;
    esac
}
