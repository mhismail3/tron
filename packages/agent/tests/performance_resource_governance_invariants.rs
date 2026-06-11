//! Static invariants for the Performance / Resource Governance slice.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const SCORECARD_PATH: &str = "packages/agent/docs/performance-resource-governance-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/performance-resource-governance-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/performance-resource-governance-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/performance-resource-governance-inventory.tsv";
const TARGET_PATH: &str = "packages/agent/tests/performance_resource_governance_invariants.rs";
const TARGET_NAME: &str = "performance_resource_governance_invariants";

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn tracked_files_under(prefix: &str) -> Vec<String> {
    let output = std::process::Command::new("git")
        .args(["ls-files", prefix])
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output should be utf8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn assert_contains_all(path: &str, needles: &[&str]) {
    let source = read_repo_file(path);
    for needle in needles {
        assert!(
            source.contains(needle),
            "{path} missing required PRG marker: {needle}"
        );
    }
}

#[test]
fn prg_artifacts_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required PRG artifact missing: {path}"
        );
    }

    let readme = read_repo_file("README.md");
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        TARGET_NAME,
    ] {
        assert!(
            readme.contains(required),
            "README must mention PRG artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run PRG");
    }
}

#[test]
fn prg_scorecard_is_closed_at_full_weight() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Status: **closed**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Passing threshold: **100/100**"));

    let expected = [
        ("PRG-0", "Harness", 5),
        ("PRG-1", "Resource Boundary Inventory", 10),
        ("PRG-2", "Memory and Payload Bounds", 12),
        ("PRG-3", "Queue/Stream/Backpressure", 12),
        ("PRG-4", "Logs/Diagnostics/Audit Volume", 8),
        ("PRG-5", "Startup/Shutdown/Task Lifecycle", 10),
        ("PRG-6", "Storage Retention/Disk Governance", 10),
        (
            "PRG-7",
            "Provider/Model Retry/Stream Resource Discipline",
            8,
        ),
        ("PRG-8", "Load/Soak/Regression Harnesses", 8),
        ("PRG-9", "Static Guards/Cross-Slice Preservation", 10),
        ("PRG-10", "Docs/README/Evidence/Closeout", 7),
    ];
    let mut total = 0u32;
    for (id, name, weight) in expected {
        let row = scorecard
            .lines()
            .find(|line| line.starts_with(&format!("| {id} |")))
            .unwrap_or_else(|| panic!("missing PRG scorecard row {id}"));
        let columns: Vec<_> = row.trim_matches('|').split('|').map(str::trim).collect();
        assert_eq!(
            columns.get(1),
            Some(&name),
            "unexpected PRG row name: {row}"
        );
        assert_eq!(
            columns
                .get(2)
                .unwrap_or_else(|| panic!("missing weight in row: {row}"))
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid PRG weight in {row}: {error}")),
            weight,
            "unexpected PRG row weight: {row}"
        );
        assert_eq!(
            columns.get(3),
            Some(&"passed"),
            "PRG row must be passed at closeout: {row}"
        );
        total += weight;
    }
    assert_eq!(total, 100, "PRG scorecard weights must sum to 100");
}

#[test]
fn prg_evidence_manifest_lists_required_closeout_commands() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("Status: **closed**"));
    assert!(evidence.contains("Current score: **100/100**"));
    assert!(
        !evidence.contains("not_run") && !evidence.contains("TODO") && !evidence.contains("TBD"),
        "final evidence manifest must not retain placeholders"
    );

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml domains::logs --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml engine::tests::runtime --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml transport::runtime --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml providers::shared --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "evidence manifest must record closeout command: {command}"
        );
    }
    assert!(
        evidence.contains("git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj"),
        "evidence must include the iOS XcodeGen drift check"
    );
    assert!(
        evidence.contains("git diff --exit-code -- packages/mac-app/TronMac.xcodeproj"),
        "evidence must include the macOS XcodeGen drift check"
    );
    assert!(
        evidence.contains(
            "No iOS/macOS protocol, diagnostics, log reader, or settings files were touched"
        ),
        "evidence must record iOS targeted-test rationale"
    );
}

#[test]
fn prg_inventory_has_expected_header_and_resource_rows() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: Complete"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tresource_dimension\tcurrent_bound_proof\trisk\tproof_target\taction_rationale"
        ),
        "PRG TSV header changed"
    );

    let mut ids = BTreeSet::new();
    let rows: Vec<_> = lines.collect();
    assert_eq!(
        rows.len(),
        30,
        "PRG inventory must keep the audited row set"
    );
    for row in &rows {
        let columns: Vec<_> = row.split('\t').collect();
        assert_eq!(
            columns.len(),
            9,
            "PRG inventory row must have 9 columns: {row}"
        );
        assert!(
            ids.insert(columns[0].to_owned()),
            "duplicate PRG inventory id {}",
            columns[0]
        );
        assert!(
            columns[0].starts_with("PRG-INV-"),
            "inventory id must use PRG prefix: {}",
            columns[0]
        );
        for (field, value) in [
            ("path", columns[1]),
            ("surface_kind", columns[2]),
            ("owner", columns[3]),
            ("resource_dimension", columns[4]),
            ("current_bound_proof", columns[5]),
            ("risk", columns[6]),
            ("proof_target", columns[7]),
            ("action_rationale", columns[8]),
        ] {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "{} has invalid {field} field: {value}",
                columns[0]
            );
        }
    }

    for required in [
        "PRG-INV-001\tpackages/agent/src/domains/model/providers/shared/sse.rs\tprovider_sse_parser",
        "PRG-INV-007\tpackages/agent/src/domains/model/providers/kimi/stream_handler/mod.rs\tkimi_stream_handler",
        "PRG-INV-008\tpackages/agent/src/domains/model/providers/ollama/provider.rs\tollama_ndjson_parser",
        "PRG-INV-011\tpackages/agent/src/domains/agent/loop/stream_state.rs\tagent_stream_state",
        "PRG-INV-012\tpackages/agent/src/domains/agent/loop/orchestrator/streaming_journal/mod.rs\tstreaming_journal",
        "PRG-INV-015\tpackages/agent/src/transport/engine/socket/outbound.rs\tengine_ws_outbound",
        "PRG-INV-019\tscripts/tron-lib.d/logs.sh\tcli_logs_reader",
        "PRG-INV-030\tpackages/agent/tests/performance_resource_governance_invariants.rs\tprg_static_harness",
    ] {
        assert!(
            tsv.contains(required),
            "PRG inventory missing required row: {required}"
        );
    }
}

#[test]
fn provider_stream_memory_limits_are_source_guarded() {
    assert_contains_all(
        "packages/agent/src/domains/model/providers/shared/sse.rs",
        &[
            "DEFAULT_MAX_SSE_LINE_BYTES",
            "pub max_line_bytes: usize",
            "SseParseError",
            "provider SSE line exceeded",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/shared/stream_pipeline.rs",
        &["parse_sse_lines", "StreamEvent::Error"],
    );
    for path in [
        "packages/agent/src/domains/model/providers/openai/provider/mod.rs",
        "packages/agent/src/domains/model/providers/anthropic/provider/mod.rs",
        "packages/agent/src/domains/model/providers/google/provider/mod.rs",
        "packages/agent/src/domains/model/providers/kimi/provider.rs",
        "packages/agent/src/domains/model/providers/minimax/provider.rs",
    ] {
        assert_contains_all(path, &["max_line_bytes", "DEFAULT_MAX_SSE_LINE_BYTES"]);
    }
    assert_contains_all(
        "packages/agent/src/domains/model/providers/shared/stream_common/mod.rs",
        &[
            "MAX_PROVIDER_STREAM_TEXT_BYTES",
            "MAX_PROVIDER_STREAM_THINKING_BYTES",
            "MAX_PROVIDER_STREAM_SIGNATURE_BYTES",
            "MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES",
            "MAX_PROVIDER_STREAM_TOOL_INVOCATIONS",
            "StreamAccumulatorLimitError",
            "append_stream_field_bounded",
            "stream_limit_error_event",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/openai/stream_handler/mod.rs",
        &[
            "MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES",
            "append_stream_field_bounded",
            "try_set_text",
            "try_set_thinking",
            "capability_argument_failed",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/anthropic/stream_handler/mod.rs",
        &[
            "try_accumulate_text",
            "try_accumulate_thinking",
            "try_accumulate_signature",
            "stream_limit_error_event",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/google/stream_handler/mod.rs",
        &[
            "MAX_PROVIDER_STREAM_TOOL_INVOCATIONS",
            "MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES",
            "check_stream_field_bytes",
            "stream_limit_error_event",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/kimi/stream_handler/mod.rs",
        &[
            "MAX_PROVIDER_STREAM_TEXT_BYTES",
            "MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES",
            "MAX_PROVIDER_STREAM_TOOL_INVOCATIONS",
            "append_stream_field_bounded",
            "state.failed",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/ollama/provider.rs",
        &[
            "DEFAULT_MAX_SSE_LINE_BYTES",
            "Ollama NDJSON line exceeded",
            "StreamEvent::Error",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/ollama/stream_handler/mod.rs",
        &[
            "MAX_PROVIDER_STREAM_TEXT_BYTES",
            "MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES",
            "MAX_PROVIDER_STREAM_TOOL_INVOCATIONS",
            "check_stream_field_bytes",
            "state.failed",
        ],
    );
}

#[test]
fn agent_journal_and_engine_backpressure_limits_are_source_guarded() {
    assert_contains_all(
        "packages/agent/src/domains/agent/loop/stream_state.rs",
        &[
            "MAX_AGENT_STREAM_TEXT_BYTES",
            "MAX_AGENT_STREAM_THINKING_BYTES",
            "MAX_AGENT_STREAM_TOOL_ARGUMENT_BYTES",
            "ensure_append_within_limit",
            "ensure_capability_arguments_within_limit",
            "agent stream",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/agent/loop/orchestrator/streaming_journal/mod.rs",
        &[
            "MAX_STREAMING_JOURNAL_BYTES",
            "ensure_journal_size_budget",
            "ensure_recovered_size_budget",
            "streaming journal exceeds",
        ],
    );
    assert_contains_all(
        "packages/agent/src/transport/engine/socket/mod.rs",
        &[
            "OUTBOUND_QUEUE_CAPACITY",
            "STREAM_MAX_LIMIT",
            "push_subscription_events",
        ],
    );
    assert_contains_all(
        "packages/agent/src/transport/engine/socket/outbound.rs",
        &[
            "OUTBOUND_SEND_TIMEOUT",
            "tokio::time::timeout",
            "engine_ws_overload_total",
            "closing slow consumer",
        ],
    );
    assert_contains_all(
        "packages/agent/src/transport/engine/socket/tests.rs",
        &[
            "push_subscription_closes_slow_consumer_after_bounded_backpressure",
            "OUTBOUND_SEND_TIMEOUT",
            "slow consumers must be closed",
        ],
    );
}

#[test]
fn logs_storage_shutdown_retry_and_retention_surfaces_stay_bounded() {
    assert_contains_all(
        "packages/agent/src/domains/logs/mod.rs",
        &[
            "DEFAULT_RECENT_LIMIT",
            "MAX_RECENT_LIMIT",
            "limit must be <=",
        ],
    );
    assert_contains_all(
        "scripts/tron-lib.d/logs.sh",
        &[
            "local max_limit=1000",
            "Invalid limit: $limit (max: $max_limit)",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/session/event_store/store/event_store/logs.rs",
        &[
            "MAX_CLIENT_LOG_INGEST_ENTRIES",
            "MAX_CLIENT_LOG_MESSAGE_BYTES",
        ],
    );
    assert_contains_all(
        "packages/agent/src/shared/observability/transport.rs",
        &["TransportConfig", "batch_size", "compact_log_data"],
    );
    assert_contains_all(
        "packages/agent/src/shared/storage/mod.rs",
        &[
            "DEFAULT_MAX_INLINE_PAYLOAD_BYTES",
            "DEFAULT_VERBOSE_RETENTION_DAYS",
            "enforce_size_budget",
        ],
    );
    assert_contains_all(
        "packages/agent/src/shared/storage/maintenance.rs",
        &[
            "retention_run",
            "enforce_size_budget",
            "checkpoint_database",
        ],
    );
    assert_contains_all(
        "packages/agent/src/app/lifecycle/shutdown.rs",
        &[
            "DEFAULT_SHUTDOWN_TIMEOUT",
            "PER_CALLBACK_TIMEOUT",
            "register_task",
            "abort",
        ],
    );
    assert_contains_all(
        "packages/agent/src/app/bootstrap/mod.rs",
        &["retention_run", "enforce_size_budget", "register_task"],
    );
    assert_contains_all(
        "packages/agent/src/domains/model/providers/shared/retry.rs",
        &["max_retries", "max_delay_ms", "token.cancelled()"],
    );
    assert_contains_all(
        "packages/agent/src/transport/runtime/mod.rs",
        &["shutdown.register_task", "heartbeat.run()"],
    );
}

#[test]
fn predecessor_gates_remain_wired_and_successor_surfaces_absent() {
    let readme = read_repo_file("README.md");
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let ci = read_repo_file(".github/workflows/ci.yml");
    for target in [
        "security_authority_capability_boundaries_invariants",
        "public_protocol_api_contract_discipline_invariants",
        "provider_model_boundary_discipline_invariants",
        "observability_diagnostics_auditability_invariants",
        "data_integrity_storage_evolution_migration_discipline_invariants",
        "off_plan_successor_teardown_cleanup_invariants",
        "primitive_trace_execution",
    ] {
        assert!(
            readme.contains(target),
            "README missing predecessor {target}"
        );
        assert!(
            quality.contains(target),
            "local quality missing predecessor {target}"
        );
        assert!(
            ci.contains(target),
            "GitHub static gate missing predecessor {target}"
        );
    }

    for forbidden in [
        "self_adapting_agent_worker_activation_invariants",
        "self_adapting_agent_worker_bundle_handoff_invariants",
        "self_adapting_agent_worker_orchestration_invariants",
        "self_adapting_agent_worker_schedule_capacity_invariants",
        "self_adapting_agent_worker_schedule_dispatch_invariants",
        "self_adapting_agent_worker_trigger_launch_invariants",
    ] {
        assert!(
            !quality.contains(forbidden) && !ci.contains(forbidden),
            "successor worker target must stay out of PRG gates: {forbidden}"
        );
    }
    assert!(
        tracked_files_under("packages/agent/skills").is_empty(),
        "primitive branch must not reintroduce repo-managed first-party skills"
    );
}
