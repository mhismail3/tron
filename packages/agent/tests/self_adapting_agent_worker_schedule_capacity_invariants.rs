//! Static gates for the Self-Adapting Agent Worker Schedule Capacity scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-capacity-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-capacity-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-capacity-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-capacity-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_worker_schedule_capacity_invariants.rs";
const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\tcurrent_role\tsaawsc_rows\tproof\tresidual_risk";

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
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

fn git_ls_files() -> BTreeSet<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn parse_scorecard_rows() -> Vec<(String, u32, String)> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SAAWSC-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            (
                columns[1].to_owned(),
                columns[3].parse().expect("SAAWSC weight must be numeric"),
                columns[4].to_owned(),
            )
        })
        .collect()
}

fn parse_inventory() -> Vec<Vec<String>> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next().expect("inventory TSV must have a header"),
        INVENTORY_HEADER
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

#[test]
fn saawsc_docs_readme_and_ci_are_linked() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Worker Schedule Capacity Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `9e9393acde1284b0c684a5c15d9bf331133c9928`",
        "| SAAWSC-0 | Harness and Baseline | 5 | passed_after_fix |",
        "| SAAWSC-11 | Regression and Closeout | 8 | passed_after_fix |",
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Schedule Capacity Evidence Manifest",
        "Status: **complete**",
        "| SAAWSC-0 | passed_after_fix |",
        "| SAAWSC-11 | passed_after_fix |",
        "worker_schedule_scan_state",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Schedule Capacity Inventory",
        "Status: SAAWSC campaign `complete`;",
        "`resource_pagination`",
        "`scan_state`",
        "`schedule_runtime`",
        "`forbidden_surface`",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }
    for source in [local_ci, github_ci] {
        assert!(
            source.contains("self_adapting_agent_worker_schedule_capacity_invariants"),
            "CI must include SAAWSC invariant target"
        );
    }
}

#[test]
fn saawsc_scorecard_and_inventory_are_complete() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAAWSC scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|(_, weight, _)| *weight).sum::<u32>(),
        100,
        "SAAWSC weights must sum to 100"
    );
    assert!(
        rows.iter()
            .all(|(_, _, status)| status == "passed_after_fix"),
        "all SAAWSC rows must be closed"
    );

    let tracked = git_ls_files();
    let inventory = parse_inventory();
    assert!(
        inventory.len() >= 33,
        "SAAWSC inventory must cover major surfaces"
    );
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    for row in inventory {
        assert_eq!(row.len(), 8, "inventory rows must have 8 columns");
        assert!(
            ids.insert(row[0].clone()),
            "duplicate inventory id {}",
            row[0]
        );
        assert!(
            tracked.contains(&row[1]) || repo_path(&row[1]).exists(),
            "inventory path must be tracked, staged, or present: {}",
            row[1]
        );
        assert!(row[5].contains("SAAWSC-"), "{} must reference rows", row[0]);
        surfaces.insert(row[3].clone());
    }
    for surface in [
        "resource_pagination",
        "resource_store_memory",
        "resource_store_sqlite",
        "host_substrate",
        "scan_state",
        "schedule_runtime",
        "autonomous_service_removed",
        "schedule_tests",
        "predecessor_dispatch",
        "forbidden_surface",
        "closeout_gate",
    ] {
        assert!(surfaces.contains(surface), "missing surface {surface}");
    }
}

#[test]
fn saawsc_resource_pagination_is_internal_and_deterministic() {
    let types = read_repo_file("packages/agent/src/engine/durability/resources/types.rs");
    for required in [
        "ResourceListCursor",
        "ListResourcesPageRequest",
        "ListResourcesPage",
        "from_resource",
        "next_cursor",
        "has_more",
    ] {
        assert!(
            types.contains(required),
            "resource types missing {required}"
        );
    }

    let validation = read_repo_file("packages/agent/src/engine/durability/resources/validation.rs");
    assert!(validation.contains("validate_list_page_request"));
    assert!(validation.contains("validate_list_filter(&request.filter)"));
    assert!(validation.contains("resource list cursor resource id"));

    let memory = read_repo_file("packages/agent/src/engine/durability/resources/store/memory.rs");
    for required in [
        "list_page(ListResourcesPageRequest",
        "filter.limit.min(500)",
        ".updated_at",
        ".cmp(&left.updated_at)",
        ".then_with(|| right.resource_id.cmp(&left.resource_id))",
        "resource.updated_at < cursor.updated_at",
        "resource.resource_id < cursor.resource_id",
    ] {
        assert!(memory.contains(required), "memory store missing {required}");
    }

    let sqlite = read_repo_file("packages/agent/src/engine/durability/resources/store/mod.rs");
    for required in [
        "list_page(ListResourcesPageRequest",
        "filter.limit.min(500)",
        "ORDER BY updated_at DESC, resource_id DESC",
        "resource.updated_at < cursor.updated_at",
        "resource.resource_id < cursor.resource_id",
        "resources.len() > limit",
    ] {
        assert!(sqlite.contains(required), "sqlite store missing {required}");
    }

    let stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    assert!(stores.contains("pub(in crate::engine) fn list_page"));
    assert!(stores.contains("Self::InMemory(store) => store.list_page(request)"));
    assert!(stores.contains("Self::Sqlite(store) => store.list_page(request)"));
    let host = read_repo_file("packages/agent/src/engine/invocation/host/substrate_handle.rs");
    assert!(host.contains("pub(crate) async fn list_resources_page"));
}

#[test]
fn saawsc_scan_state_contract_is_registered_and_safe() {
    let definitions = read_repo_file(
        "packages/agent/src/engine/durability/resources/worker_schedule_definitions.rs",
    );
    for required in [
        "\"worker_schedule_scan_state\"",
        "\"tron.resource.worker_schedule_scan_state.v1\"",
        "\"scannerId\"",
        "\"cursor\"",
        "\"pageSize\"",
        "\"maxPerPoll\"",
        "\"lastScannedCount\"",
        "\"budgetExhausted\"",
        "\"cancelled\"",
        "\"completed\"",
        "\"failed\"",
    ] {
        assert!(
            definitions.contains(required),
            "scan state definitions missing {required}"
        );
    }
    let workers = read_repo_file("packages/agent/src/engine/primitives/workers.rs");
    assert!(workers.contains("worker_schedule_scan_state"));
    let engine_mod = read_repo_file("packages/agent/src/engine/mod.rs");
    assert!(engine_mod.contains("WORKER_SCHEDULE_SCAN_STATE_ID"));
    assert!(engine_mod.contains("WORKER_SCHEDULE_SCAN_STATE_KIND"));
    assert!(engine_mod.contains("WORKER_SCHEDULE_SCAN_STATE_SCHEMA_ID"));
}

#[test]
fn saawsc_scheduler_uses_bounded_resume_wrap_and_cancellation() {
    let runtime = read_repo_file("packages/agent/src/engine/runtime/worker_schedule/mod.rs");
    let scan_state =
        read_repo_file("packages/agent/src/engine/runtime/worker_schedule/scan_state.rs");
    for required in [
        "SCHEDULE_SCAN_PAGE_SIZE: usize = 100",
        "SCHEDULE_SCAN_MAX_PER_POLL: usize = 500",
        "dispatch_due_once_with_cancellation",
        "load_scan_cursor",
        "persist_scan_state",
        "ListResourcesPageRequest",
        "ResourceListCursor::from_resource",
        "if cursor.is_some() && !wrapped",
        "budget_exhausted = true",
        "scan_cursor_from_payload",
        "scan_state_payload",
    ] {
        assert!(runtime.contains(required), "runtime missing {required}");
    }
    for required in [
        "ScanStatePersist",
        "schedule_scan_trace_id",
        "scan_state_payload",
        "scan_cursor_from_payload",
        "worker_schedule_capacity",
        "cursorOrder",
        "scanner_metadata_only",
        "worker schedule scan cursor updatedAt",
    ] {
        assert!(
            scan_state.contains(required),
            "scan-state helper missing {required}"
        );
    }
    for forbidden in [
        "worker::issue_activation",
        "worker::launch_activation",
        "consume_worker_activation_bundle",
        "WorkerProcessSupervisor",
        "Command::new",
        "activationBundle",
        "launchd",
        "SMAppService",
        "tron deploy",
    ] {
        assert!(
            !runtime.contains(forbidden),
            "schedule capacity runtime must not contain {forbidden}"
        );
    }

    assert!(
        !repo_path("packages/agent/src/transport/runtime/worker_schedule.rs").exists(),
        "SAASTC removes the autonomous transport schedule polling service"
    );
    let runtime_mod = read_repo_file("packages/agent/src/transport/runtime/mod.rs");
    for forbidden in [
        "EngineWorkerScheduleService",
        "WORKER_SCHEDULE_POLL_CADENCE",
        "scheduler.run()",
        "worker_schedule::",
    ] {
        assert!(
            !runtime_mod.contains(forbidden),
            "server runtime must not autostart schedule polling: {forbidden}"
        );
    }
}

#[test]
fn saawsc_tests_cover_capacity_cancellation_and_store_pages() {
    let schedule_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/worker_schedule_dispatch.rs");
    for required in [
        "worker_schedule_dispatch_resumes_beyond_first_scan_budget",
        "worker_schedule_dispatch_persists_cancelled_scan_without_enqueue",
        "for index in 0..500",
        "WORKER_SCHEDULE_SCAN_STATE_ID",
        "budgetExhausted",
        "assert_safe_scan_state_payload",
    ] {
        assert!(
            schedule_tests.contains(required),
            "schedule tests missing {required}"
        );
    }
    let support = read_repo_file(
        "packages/agent/src/engine/tests/runtime/worker_schedule_dispatch_support.rs",
    );
    assert!(support.contains("assert_safe_scan_state_payload"));
    assert!(support.contains("activationBundle"));
    assert!(support.contains("stdinPayload"));
    assert!(support.contains("saawsd:target:"));

    let store_tests =
        read_repo_file("packages/agent/src/engine/durability/resources/store/tests.rs");
    for required in [
        "in_memory_resource_pages_resume_without_duplicates",
        "sqlite_resource_pages_match_in_memory_cursor_semantics",
        "ListResourcesPageRequest",
        "ResourceListCursor::from_resource",
        "pagination must not duplicate resources",
    ] {
        assert!(
            store_tests.contains(required),
            "store tests missing {required}"
        );
    }
}

#[test]
fn saawsc_forbidden_surfaces_are_absent() {
    let repo_files = git_ls_files();
    for forbidden_path in [
        "packages/agent/skills",
        "packages/agent/src/service_manager",
        "packages/agent/src/launchd",
        "packages/ios-app/Sources/UI/Settings/Pages/WorkerSchedule",
    ] {
        assert!(
            !repo_files
                .iter()
                .any(|path| path.starts_with(forbidden_path)),
            "forbidden path introduced: {forbidden_path}"
        );
    }
    let transport = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    let provider = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
    );
    for source in [transport, provider] {
        for forbidden in [
            "worker_schedule_plan",
            "worker_schedule_tick",
            "worker_schedule_scan_state",
            "worker schedule",
            "scheduled launch",
            "schedule capacity",
        ] {
            assert!(
                !source.contains(forbidden),
                "schedule capacity must not be public/provider-visible: {forbidden}"
            );
        }
    }
}
