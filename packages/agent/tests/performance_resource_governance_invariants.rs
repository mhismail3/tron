//! Static and synthetic invariants for the Performance / Resource Governance slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::json;
use tron::engine::{
    ActorId, ActorKind, AuthorityGrantId, EngineHostHandle, EnqueueInvocation, FunctionId,
    MAX_ACTIVE_QUEUE_ITEMS_PER_QUEUE, MAX_QUEUE_PAYLOAD_BYTES, TraceId,
};

const SCORECARD_PATH: &str = "packages/agent/docs/performance-resource-governance-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/performance-resource-governance-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/performance-resource-governance-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/performance-resource-governance-inventory.tsv";
const TARGET_PATH: &str = "packages/agent/tests/performance_resource_governance_invariants.rs";
const TARGET_NAME: &str = "performance_resource_governance_invariants";

#[derive(Debug)]
struct ScorecardRow {
    id: String,
    name: String,
    weight: u32,
    status: String,
}

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

fn git_ls_files(prefix: &str) -> Vec<String> {
    let output = Command::new("git")
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

fn tracked_or_present(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files(path).iter().any(|tracked| tracked == path)
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| PERF-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid scorecard weight in {line}: {error}")),
                status: columns[3].to_owned(),
            }
        })
        .collect()
}

#[test]
fn perf_artifacts_and_static_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing PERF artifact: {path}");
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("codex/performance-resource-governance-current"));
    assert!(scorecard.contains("c99a5439d9538dfc88de2883bf6b4383c8e1c037"));

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
            "README must mention PERF artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(TARGET_NAME),
            "{path} must run PERF invariant target"
        );
    }
}

#[test]
fn perf_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "PERF-0",
            ("Baseline, lineage, and stale-branch quarantine", 5_u32),
        ),
        ("PERF-1", ("Whole resource-governance inventory", 8)),
        ("PERF-2", ("Queue and concurrency backpressure", 12)),
        ("PERF-3", ("Stream, frame, and payload bounds", 12)),
        (
            "PERF-4",
            ("Cancellation, timeout, and shutdown semantics", 12),
        ),
        ("PERF-5", ("Memory, log, file, and blob retention", 10)),
        (
            "PERF-6",
            ("Startup, restart, and dev-server predictability", 8),
        ),
        ("PERF-7", ("Load/soak regression harness", 10)),
        ("PERF-8", ("Server/iOS/runtime boundary behavior", 8)),
        (
            "PERF-9",
            ("Docs, README, predecessor inventories, and CI wiring", 8),
        ),
        (
            "PERF-10",
            ("Verification, adversarial self-audit, and clean commit", 7),
        ),
    ]);
    assert_eq!(rows.len(), expected.len(), "PERF must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected PERF row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "PERF scorecard weights must sum to 100");
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Status: **complete**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Passing threshold: **100/100**"));
    let normalized_scorecard = scorecard.to_lowercase().replace('-', " ");
    assert!(normalized_scorecard.contains("stale branch quarantine"));
    for forbidden in ["TODO", "TBD", "placeholder", "pending"] {
        assert!(
            !scorecard.contains(forbidden),
            "closed PERF scorecard must not contain {forbidden}"
        );
    }
}

#[test]
fn perf_inventory_is_structured_and_covers_resource_surfaces() {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tresource_risk\tcurrent_bound\taction\tproof\tscorecard_rows"
        ),
        "PERF TSV header changed"
    );

    let rows: Vec<Vec<&str>> = lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').collect())
        .collect();
    assert!(
        rows.len() >= 30,
        "PERF inventory row count regressed: {}",
        rows.len()
    );

    let allowed_surfaces = BTreeSet::from([
        "queue",
        "task_lifecycle",
        "provider_stream",
        "transport",
        "storage",
        "event_store",
        "logs",
        "retention",
        "startup",
        "ci",
        "docs",
        "test",
    ]);
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    for row in &rows {
        assert_eq!(row.len(), 9, "PERF row must have 9 fields: {row:?}");
        assert!(
            ids.insert(row[0]),
            "duplicate PERF inventory id: {}",
            row[0]
        );
        assert!(row[0].starts_with("PERF-INV-"));
        assert!(
            tracked_or_present(row[1]),
            "untracked PERF path: {}",
            row[1]
        );
        assert!(
            allowed_surfaces.contains(row[2]),
            "{} has unknown surface {}",
            row[0],
            row[2]
        );
        assert!(!row[5].trim().is_empty(), "{} missing bound", row[0]);
        surfaces.insert(row[2]);
    }

    for required in [
        "queue",
        "task_lifecycle",
        "provider_stream",
        "transport",
        "storage",
        "event_store",
        "logs",
        "retention",
        "startup",
        "ci",
        "docs",
        "test",
    ] {
        assert!(
            surfaces.contains(required),
            "PERF inventory missing surface {required}"
        );
    }
}

#[tokio::test]
async fn queue_depth_and_payload_bounds_reject_bursts() {
    let handle = EngineHostHandle::new_in_memory().expect("in-memory engine host");
    for index in 0..MAX_ACTIVE_QUEUE_ITEMS_PER_QUEUE {
        handle
            .enqueue_invocation(queue_request(
                "perf-burst",
                json!({ "index": index, "message": "bounded" }),
            ))
            .await
            .expect("queue item below active-depth bound should enqueue");
    }

    let error = handle
        .enqueue_invocation(queue_request("perf-burst", json!({ "index": "overflow" })))
        .await
        .expect_err("queue must reject active-depth overflow");
    assert!(
        error.to_string().contains("active depth limit exceeded"),
        "unexpected queue depth error: {error}"
    );

    let error = EngineHostHandle::new_in_memory()
        .expect("in-memory engine host")
        .enqueue_invocation(queue_request(
            "perf-payload",
            json!({ "payload": "x".repeat(MAX_QUEUE_PAYLOAD_BYTES + 1) }),
        ))
        .await
        .expect_err("queue must reject oversized payloads");
    assert!(
        error
            .to_string()
            .contains("queue payload exceeds maximum size"),
        "unexpected queue payload error: {error}"
    );
}

#[test]
fn source_bounds_stay_at_owner_boundaries() {
    let queue = read_repo_file("packages/agent/src/engine/durability/queue/mod.rs");
    for required in [
        "MAX_ACTIVE_QUEUE_ITEMS_PER_QUEUE",
        "MAX_QUEUE_LIST_PAGE_SIZE",
        "MAX_QUEUE_PAYLOAD_BYTES",
        "validate_queue_payload",
    ] {
        assert!(queue.contains(required), "queue owner missing {required}");
    }

    let queue_memory = read_repo_file("packages/agent/src/engine/durability/queue/memory.rs");
    let queue_sqlite = read_repo_file("packages/agent/src/engine/durability/queue/sqlite_store.rs");
    for source in [queue_memory, queue_sqlite] {
        assert!(
            source.contains("MAX_ACTIVE_QUEUE_ITEMS_PER_QUEUE")
                && source.contains("validate_queue_payload"),
            "all queue stores must enforce depth and payload bounds"
        );
    }

    let sse = read_repo_file("packages/agent/src/domains/model/providers/shared/sse.rs");
    assert!(sse.contains("MAX_PROVIDER_STREAM_FRAME_BYTES"));
    assert!(sse.contains("ProviderError::SseParse"));

    let ollama = read_repo_file("packages/agent/src/domains/model/providers/ollama/provider.rs");
    assert!(ollama.contains("MAX_PROVIDER_STREAM_FRAME_BYTES"));
    assert!(ollama.contains("Ollama NDJSON frame exceeded maximum size"));

    let accumulator =
        read_repo_file("packages/agent/src/domains/model/providers/shared/stream_common/mod.rs");
    for required in [
        "MAX_STREAM_ACCUMULATED_TEXT_BYTES",
        "MAX_STREAM_ACCUMULATED_THINKING_BYTES",
        "MAX_STREAM_CAPABILITY_ARGUMENT_BYTES",
        "MAX_ACTIVE_STREAM_CAPABILITY_INVOCATIONS",
        "append_with_limit",
    ] {
        assert!(
            accumulator.contains(required),
            "stream accumulator missing {required}"
        );
    }

    let engine_ws = read_repo_file("packages/agent/src/transport/engine/socket/mod.rs");
    assert!(engine_ws.contains("MAX_ENGINE_WS_FRAME_BYTES"));
    assert!(engine_ws.contains("engine WebSocket frame exceeds maximum size"));

    let worker_ws = read_repo_file("packages/agent/src/transport/runtime/external_workers.rs");
    assert!(worker_ws.contains("MAX_EXTERNAL_WORKER_FRAME_BYTES"));
    assert!(worker_ws.contains("worker protocol frame exceeds maximum size"));
}

#[test]
fn cancellation_timeout_shutdown_and_retention_anchors_exist() {
    let retry = read_repo_file("packages/agent/src/domains/model/providers/shared/retry.rs");
    assert!(retry.contains("CancellationToken"));
    assert!(retry.contains("token.cancelled()"));
    assert!(retry.contains("ProviderError::Cancelled"));

    let shutdown = read_repo_file("packages/agent/src/app/lifecycle/shutdown.rs");
    for required in [
        "DEFAULT_SHUTDOWN_TIMEOUT",
        "PER_CALLBACK_TIMEOUT",
        "ABORT_DRAIN_TIMEOUT",
        "register_task",
        "abort_all",
    ] {
        assert!(shutdown.contains(required), "shutdown missing {required}");
    }

    let storage = read_repo_file("packages/agent/src/shared/storage/maintenance.rs");
    for required in [
        "checkpoint_database",
        "retention_run",
        "enforce_size_budget",
        "wal_checkpoint(TRUNCATE)",
        "DELETE FROM blobs",
    ] {
        assert!(
            storage.contains(required),
            "storage maintenance missing {required}"
        );
    }

    let logs =
        read_repo_file("packages/agent/src/domains/session/event_store/store/event_store/logs.rs");
    assert!(logs.contains("MAX_CLIENT_LOG_INGEST_ENTRIES"));
    assert!(logs.contains("MAX_CLIENT_LOG_MESSAGE_BYTES"));
}

#[test]
fn predecessor_inventory_rows_record_perf_as_next_original_slice() {
    for (path, required) in [
        (
            "packages/agent/docs/provider-model-boundary-discipline-inventory.tsv",
            "Performance / Resource Governance follows PMBD on current original lineage",
        ),
        (
            "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
            "Performance / Resource Governance extends PPACD frame/payload boundary proof",
        ),
        (
            "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv",
            "Performance / Resource Governance extends DSEMD storage/WAL/retention proof",
        ),
        (
            "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv",
            "Performance / Resource Governance extends CSD bounded task and queue proof",
        ),
        (
            "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv",
            "Performance / Resource Governance extends ODA bounded diagnostics proof",
        ),
        (
            "packages/agent/docs/failure-semantics-inventory.tsv",
            "Performance / Resource Governance extends FSC timeout/cancellation proof",
        ),
        (
            "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
            "Performance / Resource Governance extends SACB resource-boundary proof",
        ),
        (
            "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
            "Performance / Resource Governance extends TPC retention proof",
        ),
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains(required),
            "{path} missing PERF predecessor inventory marker"
        );
    }
}

fn queue_request(queue: &str, payload: serde_json::Value) -> EnqueueInvocation {
    EnqueueInvocation {
        queue: queue.to_owned(),
        function_id: FunctionId::new("perf::work").expect("valid function id"),
        payload,
        actor_id: ActorId::new("perf-agent").expect("valid actor id"),
        actor_kind: ActorKind::Agent,
        authority_grant_id: AuthorityGrantId::new("perf-grant").expect("valid grant id"),
        authority_scopes: vec!["perf.invoke".to_owned()],
        runtime_metadata: BTreeMap::new(),
        trace_id: TraceId::new("perf-trace").expect("valid trace id"),
        parent_invocation_id: None,
        trigger_id: None,
        session_id: Some("perf-session".to_owned()),
        workspace_id: Some("perf-workspace".to_owned()),
        idempotency_key: None,
    }
}
