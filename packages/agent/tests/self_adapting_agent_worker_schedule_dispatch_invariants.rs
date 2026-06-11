//! Static gates for the Self-Adapting Agent Worker Schedule Dispatch scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-dispatch-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-dispatch-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-dispatch-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-schedule-dispatch-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_worker_schedule_dispatch_invariants.rs";
const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\tcurrent_role\tsaawsd_rows\tproof\tresidual_risk";

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
        .filter(|line| line.starts_with("| SAAWSD-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            (
                columns[1].to_owned(),
                columns[3].parse().expect("SAAWSD weight must be numeric"),
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
fn saawsd_docs_readme_and_ci_are_linked() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Worker Schedule Dispatch Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `d701655306bc0ac42ce12a8142ad2a62b6ea0d1b`",
        "| SAAWSD-0 | Harness and Baseline | 5 | passed_after_fix |",
        "| SAAWSD-11 | Regression and Closeout | 10 | passed_after_fix |",
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Schedule Dispatch Evidence Manifest",
        "Status: **complete**",
        "| SAAWSD-0 | passed_after_fix |",
        "| SAAWSD-11 | passed_after_fix |",
        "trigger::dispatch",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Schedule Dispatch Inventory",
        "Status: SAAWSD campaign `complete`;",
        "`schedule_plan`",
        "`schedule_runtime`",
        "`tick_audit`",
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
            source.contains("self_adapting_agent_worker_schedule_dispatch_invariants"),
            "CI must include SAAWSD invariant target"
        );
    }
}

#[test]
fn saawsd_scorecard_and_inventory_are_complete() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAAWSD scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|(_, weight, _)| *weight).sum::<u32>(),
        100,
        "SAAWSD weights must sum to 100"
    );
    assert!(
        rows.iter()
            .all(|(_, _, status)| status == "passed_after_fix"),
        "all SAAWSD rows must be closed"
    );

    let tracked = git_ls_files();
    let inventory = parse_inventory();
    assert!(
        inventory.len() >= 32,
        "SAAWSD inventory must cover major surfaces"
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
        assert!(row[5].contains("SAAWSD-"), "{} must reference rows", row[0]);
        surfaces.insert(row[3].clone());
    }
    for surface in [
        "schedule_plan",
        "schedule_runtime",
        "autonomous_service_removed",
        "tick_audit",
        "trigger_dispatch",
        "queue_lease_replay",
        "forbidden_surface",
    ] {
        assert!(surfaces.contains(surface), "missing surface {surface}");
    }
}

#[test]
fn saawsd_resource_contracts_are_registered() {
    let definitions = read_repo_file(
        "packages/agent/src/engine/durability/resources/worker_schedule_definitions.rs",
    );
    for required in [
        "\"worker_schedule_plan\"",
        "\"tron.resource.worker_schedule_plan.v1\"",
        "\"worker_schedule_tick\"",
        "\"tron.resource.worker_schedule_tick.v1\"",
        "\"scheduleId\"",
        "\"triggerId\"",
        "\"autostartPlanResourceId\"",
        "\"anchorAtUtc\"",
        "\"intervalMs\"",
        "\"skip_missed_ticks_v1\"",
        "\"single_active_tick_v1\"",
        "\"tick_idempotency_replay_v1\"",
        "\"requested\"",
        "\"enqueued\"",
        "\"skipped_missed\"",
        "\"skipped_overlap\"",
        "\"failed\"",
    ] {
        assert!(
            definitions.contains(required),
            "schedule resource definitions missing {required}"
        );
    }
    let plan_start = definitions
        .find("\"worker_schedule_plan\"")
        .expect("schedule plan definition should exist");
    let tick_start = definitions
        .find("\"worker_schedule_tick\"")
        .expect("schedule tick definition should exist");
    let plan_definition = &definitions[plan_start..tick_start];
    assert!(
        plan_definition.contains("\"additionalProperties\": false"),
        "worker schedule plan schema must reject undeclared top-level fields"
    );
    let registration =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    assert!(registration.contains("worker_schedule_resource_type_definitions"));
    let workers = read_repo_file("packages/agent/src/engine/primitives/workers.rs");
    assert!(workers.contains("worker_schedule_plan"));
    assert!(workers.contains("worker_schedule_tick"));
}

#[test]
fn saawsd_runtime_composes_only_through_trigger_dispatch() {
    let runtime = read_repo_file("packages/agent/src/engine/runtime/worker_schedule/mod.rs");
    let overlap = read_repo_file("packages/agent/src/engine/runtime/worker_schedule/overlap.rs");
    let tick_dispatch =
        read_repo_file("packages/agent/src/engine/runtime/worker_schedule/tick_dispatch.rs");
    let runtime_surface = format!("{runtime}\n{overlap}\n{tick_dispatch}");
    for required in [
        "EngineWorkerScheduleRuntime",
        "dispatch_due_once",
        "dispatch_due_for_schedule",
        "AcquireResourceLease",
        "worker_schedule_dispatch",
        "TRIGGER_DISPATCH_FUNCTION",
        "\"deliveryMode\": \"enqueue\"",
        "target_idempotency_key",
        "skipped_missed",
        "skipped_overlap",
        "WORKER_TRIGGER_LAUNCH_ATTEMPT_KIND",
        "SCHEDULE_SCAN_MAX_PER_POLL",
    ] {
        assert!(
            runtime_surface.contains(required),
            "runtime missing {required}"
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
            !runtime_surface.contains(forbidden),
            "schedule runtime must not contain {forbidden}"
        );
    }

    let contracts =
        read_repo_file("packages/agent/src/engine/runtime/worker_schedule/contracts.rs");
    for required in [
        "parse_utc_time",
        "MIN_INTERVAL_MS..=MAX_INTERVAL_MS",
        "require_literal(payload, \"missedTickPolicy\", \"skip_missed_ticks_v1\")",
        "require_literal(payload, \"overlapPolicy\", \"single_active_tick_v1\")",
        "require_literal(payload, \"duplicatePolicy\", \"tick_idempotency_replay_v1\")",
        "targetKeyFingerprint",
        "redacted",
        "reject_secret_material_in_value",
    ] {
        assert!(contracts.contains(required), "contracts missing {required}");
    }
}

#[test]
fn saawsd_tests_cover_explicit_dispatch_replay_and_negative_paths() {
    let runtime_mod = read_repo_file("packages/agent/src/transport/runtime/mod.rs");
    assert!(
        !repo_path("packages/agent/src/transport/runtime/worker_schedule.rs").exists(),
        "SAASTC removes the autonomous transport schedule polling service"
    );
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

    let tests = format!(
        "{}\n{}",
        read_repo_file("packages/agent/src/engine/tests/runtime/worker_schedule_dispatch.rs"),
        read_repo_file(
            "packages/agent/src/engine/tests/runtime/worker_schedule_dispatch_support.rs"
        )
    );
    for required in [
        "worker_schedule_dispatch_enqueues_and_drains_trigger_launch_once",
        "worker_schedule_dispatch_replays_same_tick_after_restart_without_duplicate_launch",
        "worker_schedule_dispatch_skips_missed_ticks_without_backfill_storm",
        "worker_schedule_dispatch_records_overlap_without_second_enqueue",
        "worker_schedule_dispatch_rejects_invalid_plans_before_enqueue",
        "assert_safe_tick_payload",
        "fake.starts.load(Ordering::SeqCst)",
    ] {
        assert!(tests.contains(required), "runtime tests missing {required}");
    }
}

#[test]
fn saawsd_forbidden_surfaces_are_absent() {
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
            "worker schedule",
            "scheduled launch",
        ] {
            assert!(
                !source.contains(forbidden),
                "schedule dispatch must not be public/provider-visible: {forbidden}"
            );
        }
    }
}
