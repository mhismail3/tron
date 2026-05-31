//! Meta-test: every `[T]` (trusted-local) finding from the audit plan
//! carries an `INVARIANT:` marker in source that names the trust
//! boundary and its hardening path.
//!
//! Background: the Tron audit plan produced a set of findings tagged
//! `[T]` — accepted trade-offs under the trusted-local threat model
//! (the only callers are the user's own devices over Tailscale). Each
//! `[T]` trade-off is documented in source with an `INVARIANT:` block
//! naming:
//!   1. the current behavior,
//!   2. why it's safe under trusted-local,
//!   3. the concrete hardening path if the model changes.
//!
//! This test enforces the presence of those markers. If a future edit
//! silently strips the documentation, the marker vanishes, and this
//! test fails before the change can ship.
//!
//! To register a new `[T]` trade-off: add its (path, keyword) entry
//! to `TRUST_BOUNDARY_SITES` and commit the source-side INVARIANT
//! alongside. To remove one: only valid if the trade-off itself has
//! been hardened out of existence (e.g. real rate limiting replaces
//! the L7 documentation).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// Sites that must document a trusted-local trust boundary.
///
/// Format: `(relative_path, required_substring_case_insensitive)`.
/// The test asserts the file contains both the literal string
/// `"INVARIANT"` and the required substring (lowercased comparison).
const TRUST_BOUNDARY_SITES: &[(&str, &str)] = &[
    // C1 — filesystem services accept arbitrary paths
    ("src/domains/filesystem/service.rs", "trusted-local"),
    // C2 — server binds 0.0.0.0 by default
    ("src/main_cli.rs", "trusted-local"),
    // L8 — client-supplied bundleId trusted at register time
    ("src/domains/device/mod.rs", "trusted-local"),
    // L14 — `is_path_within` is lexical, no symlink resolution
    (
        "src/domains/agent/runner/guardrails/rules/path.rs",
        "trusted-local",
    ),
];

/// Sites outside the Rust crate (e.g. shell scripts) — keyed on the
/// repo root rather than `CARGO_MANIFEST_DIR`. Resolved separately.
const TRUST_BOUNDARY_REPO_SITES: &[(&str, &str)] = &[
    // L3 — launchd plist is user-writable
    ("scripts/tron.d/deploy.sh", "trusted-local"),
];

const LARGE_TEST_FILE_LIMIT_LINES: usize = 1_000;

/// Rust test files that intentionally remain above the large-file threshold.
///
/// Format: `(repo-relative path, scorecard reason marker, maximum expected lines)`.
const LARGE_TEST_FILE_AUDIT: &[(&str, &str, usize)] = &[
    (
        "packages/agent/tests/threat_model_invariants.rs",
        "cross-cutting static architecture gates",
        7_050,
    ),
    (
        "packages/agent/tests/integration/tests.rs",
        "transport e2e suite with shared WebSocket harness",
        3_300,
    ),
    (
        "packages/agent/src/domains/worktree/implementation/runtime/coordinator/tests.rs",
        "worktree coordinator lifecycle matrix",
        2_900,
    ),
    (
        "packages/agent/src/engine/tests/generated_ui.rs",
        "single generated-UI primitive matrix",
        2_050,
    ),
    (
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs",
        "SQLite event repository query matrix",
        1_750,
    ),
    (
        "packages/agent/src/domains/agent/runner/orchestrator/subagent_manager_tests.rs",
        "subagent manager orchestration matrix",
        1_700,
    ),
    (
        "packages/agent/src/domains/auth/provider_credentials/storage/tests.rs",
        "credential storage scenario matrix",
        1_425,
    ),
    (
        "packages/agent/src/engine/tests/module_activation/source_trust.rs",
        "module source-trust scenario matrix",
        1_500,
    ),
    (
        "packages/agent/src/domains/skills/implementation/runtime/tracker/tests.rs",
        "skill runtime tracker scenario matrix",
        1_350,
    ),
    (
        "packages/agent/src/domains/worktree/implementation/runtime/coordinator/rebase_on_main_tests.rs",
        "rebase-on-main conflict/recovery matrix",
        1_400,
    ),
    (
        "packages/agent/src/engine/tests/resource_kernel.rs",
        "single resource-kernel matrix",
        1_400,
    ),
    (
        "packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs",
        "stream processor event-shape matrix",
        1_350,
    ),
    (
        "packages/agent/src/domains/agent/runner/context/context_manager_tests.rs",
        "context manager policy/rules matrix",
        1_350,
    ),
    (
        "packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs",
        "compaction engine scenario matrix",
        1_300,
    ),
];

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Walk up from `crate_root` until we hit a directory that contains a
/// top-level `scripts/` sibling — that's the workspace/repo root.
fn repo_root() -> PathBuf {
    let mut cur = crate_root();
    for _ in 0..5 {
        if cur.join("scripts").join("tron").is_file() {
            return cur;
        }
        if !cur.pop() {
            break;
        }
    }
    panic!(
        "could not locate repo root from {:?}; scripts/tron not found walking up",
        crate_root()
    );
}

#[test]
fn fixed_ios_dashboard_removals_stay_in_force() {
    let repo_root = repo_root();

    for removed_path in [
        [
            "packages",
            "ios-app",
            "Sources",
            "Views",
            "Automations",
            "AutomationsDashboardView.swift",
        ],
        [
            "packages",
            "ios-app",
            "Sources",
            "Views",
            "VoiceNotes",
            "VoiceNotesListView.swift",
        ],
        [
            "packages",
            "ios-app",
            "Sources",
            "Views",
            "Browser",
            "SafariView.swift",
        ],
    ] {
        let path = removed_path
            .iter()
            .fold(repo_root.clone(), |path, segment| path.join(segment));
        assert!(
            !path.exists(),
            "fixed product-shell view must stay removed: {}",
            path.display()
        );
    }

    let ios_roots = [
        repo_root.join("packages").join("ios-app").join("Sources"),
        repo_root.join("packages").join("ios-app").join("Tests"),
    ];
    let forbidden = [
        "Automations".to_owned() + "Dashboard" + "View",
        "Voice".to_owned() + "Notes" + "List" + "View",
        "Safari".to_owned() + "View",
        "NavigationMode".to_owned() + "." + "automations",
        "NavigationMode".to_owned() + "." + "voiceNotes",
        "can".to_owned() + "Manage" + "Automations",
    ];
    for root in ios_roots {
        let mut stack = vec![root];
        while let Some(path) = stack.pop() {
            for entry in std::fs::read_dir(&path)
                .unwrap_or_else(|e| panic!("failed to enumerate {path:?}: {e}"))
            {
                let entry = entry.unwrap_or_else(|e| panic!("failed to read dir entry: {e}"));
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                if path.extension().and_then(|ext| ext.to_str()) != Some("swift") {
                    continue;
                }
                if path.file_name().and_then(|name| name.to_str()) == Some("SourceGuardTests.swift")
                {
                    continue;
                }
                let content = std::fs::read_to_string(&path)
                    .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
                for needle in &forbidden {
                    assert!(
                        !content.contains(needle),
                        "{} must not reintroduce fixed iOS dashboard shell marker `{needle}`",
                        path.display()
                    );
                }
            }
        }
    }
}

#[test]
fn architecture_documentation_stays_code_adjacent() {
    let repo_root = repo_root();
    let crate_root = crate_root();

    for retired in [
        "docs/capability-backed-truth-migration-plan.md",
        "docs/capability-orchestration-audit.md",
        "docs/collapsed-modular-engine-architecture.md",
        "docs/extreme-fault-tolerance-audit.md",
        "docs/manual-testing-readiness.md",
        "docs/modular-engine-audit.md",
        "docs/modular-engine-cleanup-audit.md",
        "docs/modular-engine-maturity-scorecard.md",
        "docs/modular-engine-next-phase-plan.md",
        "docs/module-package-trust-operations.md",
        "docs/product-shell-reachability-map.md",
        "docs/production-grade-codebase-audit.md",
        "docs/production-grade-rubric.md",
    ] {
        assert!(
            !repo_root.join(retired).exists(),
            "session/rubric audit doc must stay deleted; durable truth belongs near code/tests: {retired}"
        );
    }

    let docs_dir = repo_root.join("docs");
    if docs_dir.exists() {
        let mut markdown = Vec::new();
        visit_files_with_extensions(&docs_dir, &["md"], &mut markdown);
        assert!(
            markdown.is_empty(),
            "repo-level docs directory should not regain stale standalone markdown truth: {markdown:?}"
        );
    }

    let readme = std::fs::read_to_string(repo_root.join("README.md")).expect("read README");
    assert!(
        readme.contains("The durable architecture docs live beside the code they describe")
            && readme.contains("source files, `mod.rs` docs, `INVARIANT:` comments")
            && readme.contains("packages/agent/src/lib.rs")
            && readme.contains("packages/agent/src/engine/mod.rs")
            && readme.contains("packages/agent/src/domains/capability/mod.rs")
            && readme.contains("packages/agent/tests/threat_model_invariants.rs"),
        "README must point readers to code-adjacent architecture docs and invariant tests"
    );
    for retired_marker in [
        "docs/production-grade",
        "docs/capability-backed",
        "docs/extreme-fault",
        "docs/modular-engine",
        "docs/product-shell",
        "docs/manual-testing",
    ] {
        assert!(
            !readme.contains(retired_marker),
            "README must not link stale central proof doc marker `{retired_marker}`"
        );
    }

    for rel in [
        "src/lib.rs",
        "src/engine/mod.rs",
        "src/engine/primitives/mod.rs",
        "src/engine/resources/mod.rs",
        "src/domains/capability/mod.rs",
        "src/domains/cron/implementation/mod.rs",
    ] {
        let content = std::fs::read_to_string(crate_root.join(rel))
            .unwrap_or_else(|error| panic!("failed to read {rel}: {error}"));
        assert!(
            content.contains("//!") || content.contains("//!"),
            "{rel} must keep module-level progressive documentation"
        );
    }
}

#[test]
fn collapsed_engine_hardening_scorecard_stays_formalized() {
    let repo_root = repo_root();
    let crate_root = crate_root();
    let scorecard_path = repo_root
        .join("packages")
        .join("agent")
        .join("docs")
        .join("collapsed-engine-hardening-scorecard.md");
    assert!(
        scorecard_path.is_file(),
        "active collapsed-engine hardening scorecard must exist"
    );
    let scorecard = std::fs::read_to_string(&scorecard_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", scorecard_path.display()));

    for required in [
        "Initial score: **45/100 provisional**",
        "Current score: **",
        "Total: **",
        "## Scoring Rules",
        "## Failure Layer Taxonomy",
        "## Simulator Deep-Link Evidence Protocol",
        "## Scenario Ledger",
        "| RWO-N1 | Repo understanding and discovery |",
        "## Structural Cleanup Backlog",
        "## Static Gates To Add Or Strengthen",
        "| SCB-S1 | `capability::execute` ownership decomposition audit |",
        "| SCB-S1b | Deterministic route and decomposition ownership audit |",
        "| SCB-S2 | Capability registry ownership split audit |",
        "| SCB-S3 | Canonical bounded resource projection audit |",
        "| SCB-S4 | Provider normalization classification |",
        "| SCB-S5 | Hidden side-effect boundedness audit |",
        "| SCB-S6 | Test decomposition and large-file ownership audit |",
        "| SCB-S7 | Capability presentation ownership audit |",
        "| SCB-S8 | Chat and engine state parity |",
        "| RWO-N15-F1 | Harness terminal-state guard |",
        "| RWO-N16 | Pre-terminal worker disconnect retry |",
        "**RWO-N16: Pre-terminal Worker Failure/Retry/Cancellation Robustness**",
        "RWO-N16B: Queue Cancellation And Dead-Letter Robustness",
        "| RWO-N17 | Multi-session churn and harness ownership robustness |",
        "No scored collapsed-engine hardening scenario remains open after RWO-N17",
        "claude-sonnet-4-6",
        "gpt-5.5",
        "gemma4:e4b",
        "larger local models",
        "hidden_side_effect_resource_scans_stay_bounded_and_observable",
        "large_rust_test_files_have_scorecard_ownership_audit",
        "Generated UI action presentation semantics stay server-owned",
        "tron://session/<session_id>",
        "xcrun simctl openurl booted",
        "xcrun simctl install booted",
        "stale app binary is invalid parity evidence",
        "chat parity drift",
        "nonzero `simctl openurl` return code",
        "no pending approvals for the session\nfamily",
        "Do not treat `stream.turn_end` with `stopReason = \"tool_use\"` as terminal",
        "packages/agent/tests/fixtures/session_terminal_guard.py",
        "packages/agent/tests/fixtures/rwo_n16_live_agent_harness.py",
        "packages/agent/tests/fixtures/rwo_n16b_live_agent_harness.py",
        "packages/agent/tests/fixtures/rwo_n17_live_multi_session_harness.py",
        "dead_lettered",
        "No fallback readers, compatibility aliases, client-authored generated UI",
        "package/source/policy/trust/audit tables",
        "alternate worker-spawn paths",
    ] {
        assert!(
            scorecard.contains(required),
            "collapsed-engine scorecard missing required checkpoint text: {required}"
        );
    }

    let historical_scorecard = std::fs::read_to_string(
        repo_root
            .join("packages")
            .join("agent")
            .join("docs")
            .join("capability-orchestration-test-scorecard.md"),
    )
    .expect("read historical capability orchestration scorecard");
    assert!(
        historical_scorecard.contains("Historical status")
            && historical_scorecard.contains("collapsed-engine-hardening-scorecard.md"),
        "previous capability orchestration scorecard must point to the active collapsed-engine scorecard"
    );

    let readme = std::fs::read_to_string(repo_root.join("README.md")).expect("read README");
    assert!(
        readme.contains("packages/agent/docs/collapsed-engine-hardening-scorecard.md")
            && readme.contains("completed\n  collapsed-engine hardening scorecard")
            && readme.contains("historical covered-path evidence"),
        "README living-doc map must distinguish the active scorecard from historical evidence"
    );

    let ios_development = std::fs::read_to_string(
        repo_root
            .join("packages")
            .join("ios-app")
            .join("docs")
            .join("development.md"),
    )
    .expect("read iOS development docs");
    assert!(
        ios_development.contains("### Simulator Deep-Link Harnessing")
            && ios_development.contains("tron://session/<session_id>")
            && ios_development.contains("xcrun simctl openurl booted")
            && ios_development.contains("com.tron.mobile.beta")
            && ios_development.contains("parity drift")
            && ios_development.contains("engine_approvals.status")
            && ios_development.contains("no pending approvals")
            && ios_development.contains("stopReason = \"tool_use\"")
            && ios_development.contains("nonzero `simctl openurl` return code")
            && ios_development.contains("ContentView.onAppear")
            && ios_development.contains("session_terminal_guard.py"),
        "iOS development docs must preserve the simulator session deep-link harness procedure"
    );

    let terminal_guard = std::fs::read_to_string(
        repo_root
            .join("packages")
            .join("agent")
            .join("tests")
            .join("fixtures")
            .join("session_terminal_guard.py"),
    )
    .expect("read session terminal guard fixture");
    assert!(
        terminal_guard.contains("TERMINAL_STOP_REASON = \"end_turn\"")
            && terminal_guard.contains("no_end_turn")
            && terminal_guard.contains("open_queue_items")
            && terminal_guard.contains("pending_approvals")
            && terminal_guard.contains("dead_lettered")
            && terminal_guard.contains("stream.turn_start"),
        "session terminal guard must reject tool-use boundaries and pending engine work"
    );

    let rwo_n17_harness = std::fs::read_to_string(
        repo_root
            .join("packages")
            .join("agent")
            .join("tests")
            .join("fixtures")
            .join("rwo_n17_live_multi_session_harness.py"),
    )
    .expect("read RWO-N17 multi-session harness");
    assert!(
        rwo_n17_harness.contains("claude-sonnet-4-6")
            && rwo_n17_harness.contains("safe_run_cmd")
            && rwo_n17_harness.contains("\"openurl\"")
            && rwo_n17_harness.contains("\"returncode\"")
            && rwo_n17_harness.contains("activeHarnessSubscriptionCount")
            && rwo_n17_harness.contains("activeClientSubscriptionCount")
            && rwo_n17_harness.contains("visibleLeakCount")
            && rwo_n17_harness.contains("backgroundLeakCount")
            && rwo_n17_harness.contains("simulatorOk"),
        "RWO-N17 harness must keep current-model, simulator-return-code, subscription, and cross-session leakage checks"
    );

    let content_view = std::fs::read_to_string(
        repo_root
            .join("packages")
            .join("ios-app")
            .join("Sources")
            .join("Views")
            .join("Chat")
            .join("ContentView.swift"),
    )
    .expect("read iOS ContentView");
    assert!(
        content_view.contains("PendingSessionDeepLink")
            && content_view.contains("pendingSessionDeepLink(")
            && content_view.contains("processPendingDeepLinkSession()")
            && content_view.contains(".onAppear")
            && content_view.contains(".onChange(of: deepLinkSessionId)"),
        "ContentView must keep cold-start and live session deep links on one coordinator path"
    );

    let content_view_tests = std::fs::read_to_string(
        repo_root
            .join("packages")
            .join("ios-app")
            .join("Tests")
            .join("ViewModels")
            .join("ContentViewCoordinatorTests.swift"),
    )
    .expect("read ContentView coordinator tests");
    assert!(
        content_view_tests.contains("PendingSessionDeepLinkTests")
            && content_view_tests.contains("testPendingSessionDeepLinkPreservesSessionAndTarget"),
        "iOS tests must cover pending session deep-link state used by simulator harnesses"
    );

    let capability_mod = std::fs::read_to_string(crate_root.join("src/domains/capability/mod.rs"))
        .expect("read capability mod docs");
    assert!(
        capability_mod.contains("Provider integrations should only expose the `execute` primitive")
            && capability_mod.contains("`capability::search`, `capability::inspect`")
            && capability_mod.contains("never marked with\n//! model-facing capability metadata"),
        "capability module docs must keep execute as the only model-facing primitive and search/inspect operator-only"
    );

    let capability_contract =
        std::fs::read_to_string(crate_root.join("src/domains/capability/contract.rs"))
            .expect("read capability contract");
    assert!(
        capability_contract.contains("EXECUTE_FUNCTION_ID => json!")
            && capability_contract.contains("_ => serde_json::Value::Null")
            && capability_contract.contains("fn only_execute_has_model_metadata")
            && capability_contract
                .contains("assert!(model_metadata(SEARCH_FUNCTION_ID).is_null())")
            && capability_contract
                .contains("assert!(model_metadata(INSPECT_FUNCTION_ID).is_null())"),
        "capability contract tests must keep execute as the only model-facing primitive"
    );

    let invariant_tests =
        std::fs::read_to_string(crate_root.join("tests/threat_model_invariants.rs"))
            .expect("read threat-model invariant tests");
    for required_gate in [
        "product_shell_reachability_and_prompt_library_resources_stay_enforced",
        "provider_tool_terms_stay_inside_protocol_boundaries",
        "modular_substrate_has_no_raw_scope_or_worker_token_authority_fallbacks",
        "resource_native_orchestration_and_control_plane_gates_stay_on",
        "bounded_resource_projection_summaries_stay_canonical",
        "generated_ui_resource_and_renderer_gates_stay_on",
        "module_package_activation_gates_stay_on",
        "external_workers_and_sandbox_spawn_are_first_class_engine_surfaces",
        "current_architecture_terms_are_deleted_or_owned",
    ] {
        assert!(
            invariant_tests.contains(required_gate),
            "collapsed-engine static gate `{required_gate}` must remain present"
        );
    }

    let schema = std::fs::read_to_string(
        crate_root.join("src/domains/session/event_store/sqlite/migrations/v001_schema.sql"),
    )
    .expect("read consolidated schema");
    for forbidden_table in [
        "CREATE TABLE IF NOT EXISTS prompt_history",
        "CREATE TABLE IF NOT EXISTS prompt_snippets",
        "CREATE TABLE IF NOT EXISTS module_package",
        "CREATE TABLE IF NOT EXISTS module_source",
        "CREATE TABLE IF NOT EXISTS module_policy",
        "CREATE TABLE IF NOT EXISTS module_trust",
        "CREATE TABLE IF NOT EXISTS module_audit",
    ] {
        assert!(
            !schema.contains(forbidden_table),
            "collapsed substrate must not add side-channel table `{forbidden_table}`"
        );
    }
}

#[test]
fn codebase_cleanup_scorecard_stays_formalized() {
    let repo_root = repo_root();
    let crate_root = crate_root();
    let scorecard_path = repo_root
        .join("packages")
        .join("agent")
        .join("docs")
        .join("codebase-cleanup-scorecard.md");
    assert!(
        scorecard_path.is_file(),
        "active repo-local cleanup scorecard must exist"
    );
    let scorecard = std::fs::read_to_string(&scorecard_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", scorecard_path.display()));

    for required in [
        "Initial cleanup score: **0/100**",
        "Current score: **100/100**",
        "Status: **CLC-10 complete; cleanup scorecard at 100/100**",
        "Score normalization note",
        "## Operating Rules",
        "## Review Rubric",
        "## Static Gates",
        "## Scenario Ledger",
        "## Large-File Audit",
        "| CLC-0 |",
        "| CLC-1 |",
        "| CLC-2 |",
        "| CLC-3 |",
        "| CLC-4 |",
        "| CLC-5 |",
        "| CLC-6 |",
        "| CLC-7 |",
        "| CLC-8 |",
        "| CLC-9 |",
        "| CLC-10 |",
        "## CLC-10 Final Whole-Repo Sweep",
        "cleanup campaign is now at **100/100**",
        "## Maintenance State",
        "New cleanup exceptions require scorecard rows",
        "search_visible_content_contains_actionable_recipe",
        "RUST_LOG=info,ort=error",
        "Background `tron dev` health wait defaults to `30s`",
        "Installed service restarted",
        "/health",
        "stale-installed-app diagnostic",
        "providerSurface = \"capability\"",
        "scripts/tron dev -bd --json --wait 30",
        "gemma4:e4b",
        "larger local models",
        "session_storage_protocol_boundaries_stay_split",
        "model_provider_profile_boundaries_stay_split",
        "agent_runner_context_boundaries_stay_split",
        "smaller_domain_boundaries_stay_split",
        "ios_thin_client_boundaries_stay_split",
        "mac_script_boundaries_stay_split",
        "test_harness_boundaries_stay_split",
        "main_runtime.rs",
        "push_helpers_tests.rs",
        "events/tron/catalog.rs",
    ] {
        assert!(
            scorecard.contains(required),
            "cleanup scorecard missing required checkpoint text: {required}"
        );
    }
    assert!(
        !scorecard.contains("Next checkpoint: **CLC-7"),
        "cleanup scorecard must not point future sessions back at a completed checkpoint"
    );

    let readme = std::fs::read_to_string(repo_root.join("README.md")).expect("read README");
    assert!(
        readme.contains("packages/agent/docs/codebase-cleanup-scorecard.md")
            && readme.contains("completed repo-local\n  cleanup scorecard")
            && readme.contains("defaults dev logging to `RUST_LOG=info,ort=error`")
            && readme.contains("only after `/health` passes"),
        "README living-doc and CLI map must document the active cleanup scorecard and dev restore contract"
    );

    let tron_script = std::fs::read_to_string(repo_root.join("scripts/tron"))
        .expect("failed to read scripts/tron");
    let tron_dev = std::fs::read_to_string(repo_root.join("scripts/tron.d/dev.sh"))
        .expect("failed to read scripts/tron.d/dev.sh");
    let tron_service = std::fs::read_to_string(repo_root.join("scripts/tron-lib.d/service.sh"))
        .expect("failed to read scripts/tron-lib.d/service.sh");
    assert!(
        tron_script.contains("source \"$tron_cmd_module\"")
            && tron_dev.contains("local wait_seconds=30")
            && tron_dev.contains(r#"${RUST_LOG:-info,ort=error}"#)
            && !tron_dev.contains(r#"${RUST_LOG:-debug,ort=error}"#)
            && !tron_dev.contains("default: 12")
            && tron_dev.contains("restart_installed_service_after_dev 12"),
        "tron dev must keep info-level default logging, 30s background health wait, and shared restore helper"
    );
    assert!(
        tron_service.contains("wait_for_service_health")
            && tron_service.contains("print_installed_service_restart_diagnostic")
            && tron_service.contains(
                "Stale helpers can fail while parsing capability schema providerSurface values"
            )
            && tron_service
                .contains("print_success \"Installed service restarted (PID: ${pid:-unknown})\""),
        "installed-service restore must be health-gated and carry the stale-installed-app diagnostic"
    );
    let release_wrapper_start = tron_service
        .find("if release_wrapper_available; then")
        .expect("release wrapper start branch");
    let contributor_start = tron_service
        .find("if [ ! -f \"$PLIST_PATH\" ]; then")
        .expect("contributor plist fallback");
    assert!(
        release_wrapper_start < contributor_start
            && tron_service.contains("\"$RELEASE_APP_BINARY\" --tron-start-server-and-quit")
            && tron_service.contains("wait_for_service_health 5"),
        "tron start must prefer the health-gated installed SMAppService wrapper before contributor plist fallback"
    );

    let budgets = cleanup_scorecard_large_file_budgets(&scorecard);
    let large_files = cleanup_scorecard_large_files(&repo_root, &crate_root);
    for (path, line_count) in &large_files {
        let budget = budgets.get(path).unwrap_or_else(|| {
            panic!("{path} exceeds 1,000 LOC and needs a cleanup scorecard row")
        });
        assert!(
            line_count <= budget,
            "{path} has grown to {line_count} lines over the cleanup scorecard budget {budget}; decompose it or update the scorecard exception"
        );
    }
}

#[test]
fn post_100_operating_scorecard_stays_formalized() {
    let repo_root = repo_root();
    let scorecard_path =
        repo_root.join("packages/agent/docs/post-100-operating-conditions-scorecard.md");
    assert!(
        scorecard_path.is_file(),
        "post-100 operating scorecard must exist"
    );
    let scorecard = std::fs::read_to_string(&scorecard_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", scorecard_path.display()));

    for required in [
        "Initial score: **0/100**",
        "Current score: **",
        "collapsed-engine-hardening-scorecard.md`: **100/100**",
        "codebase-cleanup-scorecard.md`: **100/100**",
        "## Operating Loop",
        "## Evidence Contract",
        "## ROC Scenario Ledger",
        "## UI Inventory",
        "## UXR Scenario Ledger",
        "## Baseline Evidence",
        "scripts/tron ci fmt check clippy test",
        "scripts/tron dev -bd --json --wait 30",
        "curl -fsS http://localhost:9847/health",
        "Do not deep-link newly created harness sessions into the visible Simulator by",
        "Reserve `xcrun simctl openurl ... tron://session/<session_id>`",
        "Computer Use confirmation",
        "`notifications::mark_read`",
        "`notifications::mark_all_read`",
        "`capability::execute`",
        "`gemma4:e4b`",
        "`compact.*`",
        "No optimistic success before `/health`",
        "No scored collapsed-engine hardening scenario remains open after RWO-N17",
    ] {
        assert!(
            scorecard.contains(required),
            "post-100 scorecard missing required checkpoint text: {required}"
        );
    }
    for prefix in ["ROC", "UXR"] {
        for id in 0..=10 {
            let needle = format!("| {prefix}-{id} |");
            assert!(
                scorecard.contains(&needle),
                "post-100 scorecard missing {needle}"
            );
        }
    }
    for owner in [
        "ios_rendering",
        "ios_state_projection",
        "ios_action_wiring",
        "server_contract",
        "stream_or_reconstruction",
        "mac_wrapper_ui",
        "test_harness",
    ] {
        assert!(
            scorecard.contains(owner),
            "post-100 scorecard missing owner {owner}"
        );
    }

    let readme = std::fs::read_to_string(repo_root.join("README.md")).expect("read README");
    assert!(
        readme.contains("packages/agent/docs/post-100-operating-conditions-scorecard.md")
            && readme
                .contains("active\n  post-100 operating conditions and UI/UX regression scorecard")
            && readme.contains("completed\n  collapsed-engine hardening scorecard")
            && readme.contains("completed repo-local\n  cleanup scorecard"),
        "README living-doc map must name the active post-100 scorecard and completed 100/100 scorecards"
    );

    let ios_development =
        std::fs::read_to_string(repo_root.join("packages/ios-app/docs/development.md"))
            .expect("read iOS development docs");
    let mac_architecture =
        std::fs::read_to_string(repo_root.join("packages/mac-app/docs/architecture.md"))
            .expect("read Mac architecture docs");
    assert!(
        ios_development.contains("post-100-operating-conditions-scorecard.md")
            && ios_development.contains("Computer Use confirmation")
            && mac_architecture.contains("post-100-operating-conditions-scorecard.md")
            && mac_architecture.contains("SMAppService evidence"),
        "iOS and Mac docs must link post-100 simulator/wrapper evidence rules"
    );

    let collapsed = std::fs::read_to_string(
        repo_root.join("packages/agent/docs/collapsed-engine-hardening-scorecard.md"),
    )
    .expect("read collapsed-engine scorecard");
    let cleanup = std::fs::read_to_string(
        repo_root.join("packages/agent/docs/codebase-cleanup-scorecard.md"),
    )
    .expect("read cleanup scorecard");
    assert!(
        collapsed.contains("Current score: **100/100**")
            && collapsed.contains("Total: **100/100**")
            && collapsed.contains("post-100-operating-conditions-scorecard.md")
            && cleanup.contains("Current score: **100/100**")
            && cleanup.contains("Status: **CLC-10 complete; cleanup scorecard at 100/100**")
            && cleanup.contains("post-100-operating-conditions-scorecard.md"),
        "completed scorecards must stay at 100/100 and point future regression work to the post-100 scorecard"
    );
}

#[test]
fn ios_thin_client_boundaries_stay_split() {
    let repo_root = repo_root();
    let read = |relative: &str| {
        let path = repo_root.join(relative);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    };

    for relative in [
        "packages/ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift",
        "packages/ios-app/Sources/Views/EngineConsole/EngineConsoleComponents.swift",
        "packages/ios-app/Sources/Views/EngineConsole/EngineConsoleSection.swift",
        "packages/ios-app/Sources/Models/Messages/CapabilityInvocationTypes.swift",
        "packages/ios-app/Sources/Models/Messages/CapabilityInvocationDisplayModel.swift",
        "packages/ios-app/Sources/Models/Messages/CapabilityPresentation.swift",
        "packages/ios-app/Sources/Services/Network/EngineConnection.swift",
        "packages/ios-app/Sources/Services/Network/EngineConnectionTypes.swift",
        "packages/ios-app/Sources/Services/Network/EngineConnectionProtocolFrames.swift",
        "packages/ios-app/Sources/Views/Session/NewSessionFlow.swift",
        "packages/ios-app/Sources/Views/Session/NewSessionFlowTypes.swift",
        "packages/ios-app/Sources/Views/Session/NewSessionFlowComponents.swift",
        "packages/ios-app/Sources/Views/Capabilities/CapabilityInvocationViews.swift",
        "packages/ios-app/Sources/Views/Capabilities/CapabilityInvocationDetailComponents.swift",
        "packages/ios-app/Sources/Views/Capabilities/CapabilityResultRenderers.swift",
    ] {
        let path = repo_root.join(relative);
        assert!(
            path.is_file(),
            "CLC-7 split boundary file must exist: {relative}"
        );
        assert!(
            line_count(&path) <= 1_000,
            "CLC-7 source file must stay below 1,000 LOC after split: {relative}"
        );
    }

    let engine_console =
        read("packages/ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift");
    let capability_types =
        read("packages/ios-app/Sources/Models/Messages/CapabilityInvocationTypes.swift");
    let engine_connection =
        read("packages/ios-app/Sources/Services/Network/EngineConnection.swift");
    let new_session = read("packages/ios-app/Sources/Views/Session/NewSessionFlow.swift");
    let invocation_views =
        read("packages/ios-app/Sources/Views/Capabilities/CapabilityInvocationViews.swift");
    assert!(
        !engine_console.contains("struct EngineConsoleSectionChips")
            && !engine_console.contains("struct PluginCard")
            && !engine_console.contains("struct CapabilityInspectionSheet")
            && !engine_console.contains("enum ConsoleSection")
            && !capability_types.contains("struct CapabilityInvocationDisplayModel")
            && !capability_types.contains("enum CapabilityPresentation")
            && !engine_connection.contains("enum ConnectionState")
            && !engine_connection.contains("struct EngineHelloFrame")
            && !engine_connection.contains("final class EngineConnectionSessionDelegate")
            && !new_session.contains("struct NewSessionShortcutButton")
            && !new_session.contains("enum NewSessionProfileMode")
            && !invocation_views.contains("struct CapabilityDetailHeader")
            && !invocation_views.contains("struct CapabilityResultRenderer"),
        "CLC-7 parents must not regain extracted iOS component/type/protocol-frame bodies"
    );
}

#[test]
fn mac_script_boundaries_stay_split() {
    let repo_root = repo_root();
    let read = |relative: &str| {
        let path = repo_root.join(relative);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    };

    for relative in [
        "scripts/tron",
        "scripts/tron.d/automation.sh",
        "scripts/tron.d/deploy.sh",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/quality.sh",
        "scripts/tron.d/workspace.sh",
        "scripts/tron-lib.sh",
        "scripts/tron-lib.d/auth.sh",
        "scripts/tron-lib.d/bundle.sh",
        "scripts/tron-lib.d/logs.sh",
        "scripts/tron-lib.d/service.sh",
        "packages/agent/src/main.rs",
        "packages/agent/src/main_cli.rs",
        "packages/agent/src/main_runtime.rs",
        "packages/agent/src/platform/updater/mod.rs",
        "packages/agent/src/platform/updater/tests.rs",
        "packages/agent/src/platform/apns/push_helpers.rs",
        "packages/agent/src/platform/apns/push_helpers_tests.rs",
    ] {
        let path = repo_root.join(relative);
        assert!(
            path.is_file(),
            "CLC-8 script/startup boundary file must exist: {relative}"
        );
        assert!(
            line_count(&path) <= 1_000,
            "CLC-8 script/startup boundary must stay below 1,000 LOC: {relative}"
        );
    }

    let tron = read("scripts/tron");
    let tron_lib = read("scripts/tron-lib.sh");
    let deploy = read("scripts/tron.d/deploy.sh");
    let dev = read("scripts/tron.d/dev.sh");
    let service = read("scripts/tron-lib.d/service.sh");
    let main_rs = read("packages/agent/src/main.rs");
    let main_cli = read("packages/agent/src/main_cli.rs");
    let main_runtime = read("packages/agent/src/main_runtime.rs");
    let updater = read("packages/agent/src/platform/updater/mod.rs");
    let push_helpers = read("packages/agent/src/platform/apns/push_helpers.rs");
    assert!(
        tron.contains("\"$SCRIPT_DIR\"/tron.d/*.sh")
            && !tron.contains("cmd_dev()")
            && !tron.contains("cmd_deploy()")
            && !tron.contains("cmd_ci()")
            && tron_lib.contains("\"$TRON_LIB_MODULE_DIR\"/*.sh")
            && !tron_lib.contains("cmd_status()")
            && !tron_lib.contains("cmd_login()")
            && deploy.contains("cp \"$SCRIPT_DIR\"/tron-lib.d/*.sh")
            && service.contains("\"$CONTRIBUTOR_DIR/tron-lib.d\"")
            && dev.contains("restart_installed_service_after_dev 12"),
        "CLC-8 scripts must keep command-family bodies in modules, copy runtime modules during install/deploy, and preserve health-gated dev restore"
    );
    assert!(
        main_rs.contains("mod main_cli;")
            && main_rs.contains("mod main_runtime;")
            && !main_rs.contains("struct Cli")
            && !main_rs.contains("fn init_database")
            && main_cli.contains("struct Cli")
            && main_cli.contains("run_subcommand")
            && !main_cli.contains("init_database")
            && main_runtime.contains("run_server")
            && main_runtime.contains("fn init_database")
            && main_runtime.contains("fn init_services")
            && updater.contains("mod tests;")
            && !updater.contains("fn parse_triple")
            && push_helpers.contains("push_helpers_tests.rs")
            && !push_helpers.contains("to_apns_notification_maps_all_fields"),
        "CLC-8 binary/platform roots must keep CLI, runtime, and large test matrices in focused modules"
    );
}

#[test]
fn session_storage_protocol_boundaries_stay_split() {
    let crate_root = crate_root();
    let read = |relative: &str| {
        let path = crate_root.join(relative);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    };

    for relative in [
        "src/domains/session/event_store/sqlite/repositories/session.rs",
        "src/domains/session/event_store/sqlite/repositories/session/projections.rs",
        "src/domains/session/event_store/sqlite/repositories/session/tests.rs",
        "src/domains/session/event_store/event/reconstruct.rs",
        "src/domains/session/event_store/event/reconstruct/tests.rs",
        "src/domains/session/event_store/sqlite/migrations/mod.rs",
        "src/domains/session/event_store/sqlite/migrations/tests.rs",
        "src/domains/session/event_store/store/tests.rs",
        "src/shared/protocol/events.rs",
        "src/shared/protocol/events/capability.rs",
        "src/shared/protocol/events/factory.rs",
        "src/shared/protocol/events/stream.rs",
        "src/shared/protocol/events/tron.rs",
        "src/shared/protocol/events/tron/catalog.rs",
        "src/shared/protocol/events/tests.rs",
        "src/shared/storage.rs",
        "src/shared/storage/archive.rs",
        "src/shared/storage/maintenance.rs",
        "src/shared/storage/payloads.rs",
        "src/shared/storage/schema.rs",
        "src/shared/storage/stats.rs",
        "src/shared/storage/tests.rs",
        "src/transport/engine_ws.rs",
        "src/transport/engine_ws/outbound.rs",
        "src/transport/engine_ws/stream_projection.rs",
        "src/transport/engine_ws/wire.rs",
        "src/transport/engine_ws/tests.rs",
    ] {
        assert!(
            crate_root.join(relative).is_file(),
            "CLC-3 split boundary file must exist: {relative}"
        );
    }

    for relative in [
        "src/domains/session/event_store/sqlite/repositories/session.rs",
        "src/domains/session/event_store/event/reconstruct.rs",
        "src/domains/session/event_store/sqlite/migrations/mod.rs",
        "src/domains/session/event_store/store/tests.rs",
        "src/shared/protocol/events.rs",
        "src/shared/storage.rs",
        "src/transport/engine_ws.rs",
    ] {
        assert!(
            line_count(&crate_root.join(relative)) <= 1_000,
            "CLC-3 parent boundary must stay below 1,000 LOC: {relative}"
        );
    }

    let session = read("src/domains/session/event_store/sqlite/repositories/session.rs");
    let projections =
        read("src/domains/session/event_store/sqlite/repositories/session/projections.rs");
    assert!(
        session.contains("#[path = \"session/projections.rs\"]")
            && session.contains("#[path = \"session/tests.rs\"]")
            && projections.contains("pub struct MessagePreview")
            && projections.contains("pub struct ActivitySummaryLine")
            && projections.contains("pub fn get_message_previews(")
            && projections.contains("pub fn get_activity_summaries(")
            && projections.contains("pub(super) fn extract_text_from_payload("),
        "session dashboard projections must stay in the session/projections boundary"
    );
    for forbidden in [
        "pub fn get_message_previews(",
        "pub fn get_activity_summaries(",
        "pub(super) fn extract_text_from_payload(",
        "mod tests {",
    ] {
        assert!(
            !session.contains(forbidden),
            "session repository root must not regain extracted CLC-3 body `{forbidden}`"
        );
    }

    let reconstruct = read("src/domains/session/event_store/event/reconstruct.rs");
    let reconstruct_tests = read("src/domains/session/event_store/event/reconstruct/tests.rs");
    assert!(
        reconstruct.contains("#[path = \"reconstruct/tests.rs\"]")
            && !reconstruct.contains("mod tests {")
            && reconstruct_tests.contains("mod basic_capability;")
            && reconstruct_tests.contains("mod lifecycle_metadata;")
            && reconstruct_tests.contains("mod multimodal_performance;")
            && reconstruct_tests.contains("mod synthetic_interrupts;"),
        "event reconstruction tests must stay in scenario-owned child modules"
    );

    let migrations = read("src/domains/session/event_store/sqlite/migrations/mod.rs");
    let migration_tests = read("src/domains/session/event_store/sqlite/migrations/tests.rs");
    assert!(
        migrations.contains("mod tests;")
            && !migrations.contains("mod tests {")
            && migration_tests.contains("mod devices_retired;")
            && migration_tests.contains("mod mechanics;")
            && migration_tests.contains("mod schema_events;")
            && migration_tests.contains("mod sessions_logs;"),
        "migration tests must stay split from the migration runner"
    );

    let store_tests = read("src/domains/session/event_store/store/tests.rs");
    assert!(
        !store_tests.contains("#[test]")
            && store_tests.contains("mod activity_summary;")
            && store_tests.contains("mod append_counters;")
            && store_tests.contains("mod queries_state;")
            && store_tests.contains("mod tree_sessions;"),
        "event-store API test root must stay a fixture/module map only"
    );

    let events = read("src/shared/protocol/events.rs");
    let stream = read("src/shared/protocol/events/stream.rs");
    let catalog = read("src/shared/protocol/events/tron/catalog.rs");
    assert!(
        events.contains("#[path = \"events/capability.rs\"]")
            && events.contains("#[path = \"events/factory.rs\"]")
            && events.contains("#[path = \"events/stream.rs\"]")
            && events.contains("#[path = \"events/tron.rs\"]")
            && events.contains("#[path = \"events/tests.rs\"]")
            && !events.contains("pub enum TronEvent")
            && !events.contains("pub enum StreamEvent")
            && stream.contains("pub enum StreamEvent")
            && catalog.contains("macro_rules! tron_events")
            && catalog.contains("pub enum TronEvent")
            && catalog.contains("impl TronEvent")
            && catalog.contains("VARIANT_COUNT"),
        "protocol event DTOs must stay split while the exhaustive TronEvent catalog remains explicit"
    );

    let storage = read("src/shared/storage.rs");
    assert!(
        storage.contains("#[path = \"storage/archive.rs\"]")
            && storage.contains("#[path = \"storage/maintenance.rs\"]")
            && storage.contains("#[path = \"storage/payloads.rs\"]")
            && storage.contains("#[path = \"storage/schema.rs\"]")
            && storage.contains("#[path = \"storage/stats.rs\"]")
            && !storage.contains("pub fn store_content_blob(")
            && !storage.contains("pub fn archive_retired_database_files(")
            && !storage.contains("pub fn ensure_storage_schema(")
            && !storage.contains("pub fn storage_stats("),
        "shared storage root must stay a typed runtime facade, not regain helper implementations"
    );

    let engine_ws = read("src/transport/engine_ws.rs");
    let wire = read("src/transport/engine_ws/wire.rs");
    let stream_projection = read("src/transport/engine_ws/stream_projection.rs");
    let outbound = read("src/transport/engine_ws/outbound.rs");
    assert!(
        engine_ws.contains("#[path = \"engine_ws/outbound.rs\"]")
            && engine_ws.contains("#[path = \"engine_ws/stream_projection.rs\"]")
            && engine_ws.contains("#[path = \"engine_ws/wire.rs\"]")
            && !engine_ws.contains("pub(super) struct HelloMessage")
            && !engine_ws.contains("fn protocol_event_value(")
            && !engine_ws.contains("fn send_engine_ws_value(")
            && wire.contains("pub(super) struct HelloMessage")
            && wire.contains("pub(super) struct ProtocolEvent")
            && stream_projection.contains("pub(super) fn protocol_event_value(")
            && outbound.contains("pub(super) fn send_engine_ws_value("),
        "engine WebSocket root must stay on session flow while wire/projection/outbound concerns stay split"
    );
}

#[test]
fn model_provider_profile_boundaries_stay_split() {
    let crate_root = crate_root();
    let read = |relative: &str| {
        let path = crate_root.join(relative);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    };

    for relative in [
        "src/domains/model/providers/openai/types.rs",
        "src/domains/model/providers/openai/stream_handler.rs",
        "src/domains/model/providers/anthropic/types.rs",
        "src/domains/model/providers/anthropic/stream_handler.rs",
        "src/domains/model/providers/anthropic/message_converter.rs",
        "src/domains/model/providers/anthropic/provider.rs",
        "src/domains/model/providers/google/types.rs",
        "src/domains/model/providers/google/provider.rs",
        "src/domains/model/providers/ollama/message_converter.rs",
        "src/shared/foundation/profile.rs",
    ] {
        assert!(
            crate_root.join(relative).is_file() && line_count(&crate_root.join(relative)) <= 1_000,
            "CLC-4 provider/profile parent must stay below 1,000 LOC: {relative}"
        );
    }

    for relative in [
        "src/domains/model/providers/openai/types/config.rs",
        "src/domains/model/providers/openai/types/models.rs",
        "src/domains/model/providers/openai/types/responses.rs",
        "src/domains/model/providers/openai/types/tests.rs",
        "src/domains/model/providers/openai/types/models/catalog.rs",
        "src/domains/model/providers/openai/types/models/catalog/frontier.rs",
        "src/domains/model/providers/openai/types/models/catalog/retired.rs",
        "src/domains/model/providers/openai/types/models/catalog/specialized.rs",
        "src/domains/model/providers/openai/types/models/catalog/standard.rs",
        "src/domains/model/providers/openai/stream_handler/tests.rs",
        "src/domains/model/providers/anthropic/types/tests.rs",
        "src/domains/model/providers/anthropic/stream_handler/tests.rs",
        "src/domains/model/providers/anthropic/message_converter/tests.rs",
        "src/domains/model/providers/anthropic/provider/tests.rs",
        "src/domains/model/providers/google/types/tests.rs",
        "src/domains/model/providers/google/provider/tests.rs",
        "src/domains/model/providers/ollama/message_converter/tests.rs",
        "src/shared/foundation/profile/validation.rs",
        "src/shared/foundation/profile/tests.rs",
    ] {
        assert!(
            crate_root.join(relative).is_file(),
            "CLC-4 split boundary file must exist: {relative}"
        );
    }

    let openai_types = read("src/domains/model/providers/openai/types.rs");
    assert!(
        openai_types.contains("#[path = \"types/config.rs\"]")
            && openai_types.contains("#[path = \"types/models.rs\"]")
            && openai_types.contains("#[path = \"types/responses.rs\"]")
            && openai_types.contains("#[path = \"types/tests.rs\"]")
            && !openai_types.contains("pub struct ResponsesRequest")
            && !openai_types.contains("pub static OPENAI_MODELS")
            && !openai_types.contains("pub enum OpenAIAuth"),
        "OpenAI types root must stay a facade over config, model registry, Responses DTOs, and tests"
    );

    let openai_config = read("src/domains/model/providers/openai/types/config.rs");
    let openai_models = read("src/domains/model/providers/openai/types/models.rs");
    let openai_responses = read("src/domains/model/providers/openai/types/responses.rs");
    let openai_catalog = read("src/domains/model/providers/openai/types/models/catalog.rs");
    assert!(
        openai_config.contains("pub enum OpenAIAuthPath")
            && openai_config.contains("pub enum OpenAIAuth")
            && openai_config.contains("pub struct OpenAIConfig")
            && openai_models.contains("pub struct OpenAIModelInfo")
            && openai_models.contains("pub use catalog::OPENAI_MODELS")
            && openai_models.contains("pub fn get_openai_model(")
            && !openai_models.contains("ResponsesRequest")
            && !openai_models.contains("m.insert(")
            && openai_responses.contains("pub struct ResponsesRequest")
            && openai_responses.contains("pub struct ResponsesSseEvent")
            && openai_responses.contains("pub enum ResponsesInputItem")
            && openai_responses.contains("pub enum ResponsesToolEntry")
            && openai_catalog.contains("frontier::insert")
            && openai_catalog.contains("retired::insert")
            && openai_catalog.contains("specialized::insert")
            && openai_catalog.contains("standard::insert"),
        "OpenAI auth/config, model registry, catalog shards, and Responses DTOs must stay separated"
    );

    for relative in [
        "src/domains/model/providers/openai/stream_handler.rs",
        "src/domains/model/providers/anthropic/types.rs",
        "src/domains/model/providers/anthropic/stream_handler.rs",
        "src/domains/model/providers/anthropic/message_converter.rs",
        "src/domains/model/providers/anthropic/provider.rs",
        "src/domains/model/providers/google/types.rs",
        "src/domains/model/providers/google/provider.rs",
        "src/domains/model/providers/ollama/message_converter.rs",
        "src/shared/foundation/profile.rs",
    ] {
        let text = read(relative);
        assert!(
            text.contains("#[path =") && !text.contains("mod tests {"),
            "CLC-4 parent must keep extracted tests in a child module: {relative}"
        );
    }

    let profile = read("src/shared/foundation/profile.rs");
    let profile_validation = read("src/shared/foundation/profile/validation.rs");
    assert!(
        profile.contains("#[path = \"profile/validation.rs\"]")
            && profile.contains("#[path = \"profile/tests.rs\"]")
            && !profile.contains("fn validate_profile(")
            && !profile.contains("struct ContextBlockManifest")
            && profile_validation.contains("pub(super) enum ContextBlockProviderSurface")
            && profile_validation.contains("#[serde(rename = \"capability\")]")
            && profile_validation.contains("provider_surface: Option<ContextBlockProviderSurface>")
            && profile_validation.contains("pub(crate) const CAPABILITY_SCHEMA_PROVIDER_SURFACE")
            && profile_validation.contains("pub(crate) fn validate_context_block_manifest")
            && profile_validation.contains("pub(super) fn validate_profile"),
        "profile root must stay on profile loading while typed validation owns context provider surfaces"
    );
}

#[test]
fn agent_runner_context_boundaries_stay_split() {
    let crate_root = crate_root();
    let read = |relative: &str| {
        let path = crate_root.join(relative);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    };

    for relative in [
        "src/domains/agent/runner/agent/capability_invocation_executor.rs",
        "src/domains/agent/runner/agent/compaction_handler.rs",
        "src/domains/agent/runner/agent/turn_runner.rs",
        "src/domains/agent/runner/agent/turn_runner/capability_invocations.rs",
        "src/domains/agent/runner/hooks/engine.rs",
        "src/domains/agent/runner/hooks/prompt_handler.rs",
        "src/domains/agent/runner/orchestrator/orchestrator.rs",
        "src/domains/agent/runner/orchestrator/session_manager.rs",
        "src/domains/agent/runner/orchestrator/turn_accumulator.rs",
    ] {
        let text = read(relative);
        assert!(
            line_count(&crate_root.join(relative)) <= 1_000
                && text.contains("#[path =")
                && !text.contains("mod tests {"),
            "CLC-5 runtime parent must stay below 1,000 LOC with tests split out: {relative}"
        );
    }

    for relative in [
        "src/domains/agent/runner/agent/capability_invocation_executor/tests.rs",
        "src/domains/agent/runner/agent/compaction_handler/tests.rs",
        "src/domains/agent/runner/agent/turn_runner/tests.rs",
        "src/domains/agent/runner/agent/turn_runner/turn_context.rs",
        "src/domains/agent/runner/agent/turn_runner/capability_invocations/tests.rs",
        "src/domains/agent/runner/hooks/engine/tests.rs",
        "src/domains/agent/runner/hooks/engine/tests/context_results.rs",
        "src/domains/agent/runner/hooks/prompt_handler/tests.rs",
        "src/domains/agent/runner/orchestrator/orchestrator/tests.rs",
        "src/domains/agent/runner/orchestrator/session_manager/tests.rs",
        "src/domains/agent/runner/orchestrator/turn_accumulator/tests.rs",
    ] {
        assert!(
            crate_root.join(relative).is_file(),
            "CLC-5 split boundary file must exist: {relative}"
        );
    }

    let turn_runner = read("src/domains/agent/runner/agent/turn_runner.rs");
    let turn_context = read("src/domains/agent/runner/agent/turn_runner/turn_context.rs");
    assert!(
        turn_runner.contains("mod turn_context;")
            && turn_runner.contains("#[path = \"turn_runner/tests.rs\"]")
            && !turn_runner.contains("fn build_turn_context(")
            && !turn_runner.contains("fn resolve_provider_primitive_surface(")
            && turn_context.contains("pub(super) fn build_turn_context(")
            && turn_context.contains("pub(super) async fn build_capability_primer_context(")
            && turn_context.contains("pub(super) async fn resolve_provider_primitive_surface(")
            && turn_context.contains("pub(super) fn resolved_turn_policy_ids("),
        "turn runner root must stay on turn orchestration while turn context/surface resolution lives in turn_context"
    );

    let hook_engine_tests = read("src/domains/agent/runner/hooks/engine/tests.rs");
    assert!(
        hook_engine_tests.contains("#[path = \"tests/context_results.rs\"]")
            && line_count(&crate_root.join("src/domains/agent/runner/hooks/engine/tests.rs"))
                <= 1_000,
        "hook engine tests must stay decomposed enough to avoid a new large CLC-9 exception"
    );
}

#[test]
fn smaller_domain_boundaries_stay_split() {
    let crate_root = crate_root();
    let read = |relative: &str| {
        let path = crate_root.join(relative);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    };

    for relative in [
        "src/domains/cron/implementation/runtime/scheduler.rs",
        "src/domains/auth/provider_credentials/storage.rs",
        "src/domains/skills/implementation/runtime/tracker.rs",
        "src/domains/process/mod.rs",
        "src/domains/cron/implementation/execution/executor.rs",
        "src/domains/mcp/product_protocol/client.rs",
        "src/shared/foundation/paths.rs",
        "src/domains/auth/provider_credentials/openai.rs",
    ] {
        let text = read(relative);
        assert!(
            line_count(&crate_root.join(relative)) <= 1_000
                && text.contains("#[path =")
                && !text.contains("mod tests {"),
            "CLC-6 parent must keep extracted tests in a child module and stay below 1,000 LOC: {relative}"
        );
    }

    for relative in [
        "src/domains/worktree/implementation/scm/git.rs",
        "src/domains/worktree/implementation/scm/git/command.rs",
        "src/domains/worktree/implementation/scm/git/conflicts.rs",
        "src/domains/worktree/implementation/scm/git/error_classification.rs",
        "src/domains/worktree/implementation/scm/git/parsing.rs",
        "src/domains/worktree/implementation/scm/git/remote.rs",
        "src/domains/worktree/implementation/scm/git/state.rs",
        "src/domains/worktree/implementation/scm/git/tests.rs",
        "src/domains/worktree/implementation/scm/git/phase1_tests.rs",
        "src/domains/cron/implementation/runtime/scheduler/tests.rs",
        "src/domains/auth/provider_credentials/storage/tests.rs",
        "src/domains/skills/implementation/runtime/tracker/tests.rs",
        "src/domains/process/tests.rs",
        "src/domains/cron/implementation/execution/executor/tests.rs",
        "src/domains/mcp/product_protocol/client/tests.rs",
        "src/shared/foundation/paths/tests.rs",
        "src/domains/auth/provider_credentials/openai/tests.rs",
    ] {
        assert!(
            crate_root.join(relative).is_file(),
            "CLC-6 split boundary file must exist: {relative}"
        );
    }

    let git = read("src/domains/worktree/implementation/scm/git.rs");
    let git_command = read("src/domains/worktree/implementation/scm/git/command.rs");
    let git_remote = read("src/domains/worktree/implementation/scm/git/remote.rs");
    let git_state = read("src/domains/worktree/implementation/scm/git/state.rs");
    let git_conflicts = read("src/domains/worktree/implementation/scm/git/conflicts.rs");
    let git_parsing = read("src/domains/worktree/implementation/scm/git/parsing.rs");
    let git_errors = read("src/domains/worktree/implementation/scm/git/error_classification.rs");
    assert!(
        line_count(&crate_root.join("src/domains/worktree/implementation/scm/git.rs")) <= 1_000
            && git.contains("#[path = \"git/command.rs\"]")
            && git.contains("#[path = \"git/remote.rs\"]")
            && git.contains("#[path = \"git/state.rs\"]")
            && git.contains("#[path = \"git/conflicts.rs\"]")
            && git.contains("#[path = \"git/tests.rs\"]")
            && !git.contains("mod tests {")
            && !git.contains("pub async fn remote_list(")
            && !git.contains("pub async fn stash_push(")
            && !git.contains("pub async fn conflict_sections(")
            && !git.contains("async fn run_capture(")
            && git_command.contains("pub(crate) async fn run(")
            && git_command.contains("pub(super) async fn run_capture(")
            && git_remote.contains("pub async fn push(")
            && git_state.contains("pub async fn stash_pop(")
            && git_conflicts.contains("pub async fn conflict_sections(")
            && git_parsing.contains("pub(super) fn parse_worktree_porcelain(")
            && git_errors.contains("pub(crate) fn classify_remote_error("),
        "GitExecutor root must stay a command catalog while command execution, remote, state, conflict, parsing, and error-classification concerns live in child modules"
    );
}

#[test]
fn production_code_does_not_keep_placeholder_macros() {
    let repo_root = repo_root();
    let roots = [
        repo_root.join("packages/agent/src"),
        repo_root.join("packages/ios-app/Sources"),
        repo_root.join("packages/mac-app/Sources"),
    ];
    for root in roots {
        let mut files = Vec::new();
        visit_files_with_extensions(&root, &["rs", "swift"], &mut files);
        for path in files {
            let text = std::fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
            for marker in ["unimplemented!(", "todo!("] {
                assert!(
                    !text.contains(marker),
                    "{} must not keep placeholder macro `{marker}` in production source",
                    path.display()
                );
            }
        }
    }
}

#[test]
fn rust_test_ownership_stays_code_adjacent() {
    let repo_root = repo_root();
    let crate_root = crate_root();

    let old_engine_tests = crate_root.join("src/engine/tests.rs");
    assert!(
        !old_engine_tests.exists(),
        "engine/tests.rs must stay removed; engine tests belong in src/engine/tests/"
    );
    let engine_tests_mod_path = crate_root.join("src/engine/tests/mod.rs");
    let engine_tests_mod = std::fs::read_to_string(&engine_tests_mod_path)
        .unwrap_or_else(|error| panic!("failed to read {engine_tests_mod_path:?}: {error}"));
    let support_path = crate_root.join("src/engine/tests/support.rs");
    assert!(
        support_path.is_file(),
        "engine test shared fixtures must live in src/engine/tests/support.rs"
    );
    for module in [
        "approval",
        "catalog_discovery",
        "external_worker",
        "host_invocation",
        "ids_types",
        "leases_compensation",
        "ledger_idempotency",
        "meta_primitives",
        "state_queue",
        "streams",
        "triggers",
    ] {
        let file = crate_root
            .join("src/engine/tests")
            .join(format!("{module}.rs"));
        assert!(
            file.is_file(),
            "engine test concern module {module}.rs must exist"
        );
        assert!(
            engine_tests_mod.contains(&format!("mod {module};")),
            "engine tests mod.rs must declare concern module `{module}`"
        );
    }
    assert!(
        !engine_tests_mod.contains("#[test]") && !engine_tests_mod.contains("#[tokio::test]"),
        "engine/tests/mod.rs must contain declarations only, not test bodies"
    );
    let module_activation_path = crate_root.join("src/engine/tests/module_activation.rs");
    let module_activation_root = std::fs::read_to_string(&module_activation_path)
        .unwrap_or_else(|error| panic!("failed to read {module_activation_path:?}: {error}"));
    for module in [
        "health_integrity",
        "local_process_activation",
        "operator_surfaces",
        "package_registration",
        "source_trust",
        "trust_review",
    ] {
        assert!(
            module_activation_root.contains(&format!("mod {module};")),
            "module_activation.rs must declare concern module `{module}`"
        );
        assert!(
            crate_root
                .join("src/engine/tests/module_activation")
                .join(format!("{module}.rs"))
                .is_file(),
            "module activation test concern module {module}.rs must exist"
        );
    }
    assert!(
        !module_activation_root.contains("#[test]")
            && !module_activation_root.contains("#[tokio::test]"),
        "module_activation.rs must contain shared fixtures and declarations only"
    );
    let approval_path = crate_root.join("src/engine/approval.rs");
    let approval = std::fs::read_to_string(&approval_path)
        .unwrap_or_else(|error| panic!("failed to read {approval_path:?}: {error}"));
    assert!(
        approval.contains("mod tests;")
            && !approval.contains("mod tests {")
            && line_count(&approval_path) <= 1_000
            && crate_root.join("src/engine/approval/tests.rs").is_file(),
        "engine approval tests must stay in src/engine/approval/tests.rs and keep approval.rs below the review-smell threshold"
    );

    for (old_file, new_root, modules) in [
        (
            "src/domains/memory/retain/tests.rs",
            "src/domains/memory/retain/tests",
            &[
                "formatting",
                "parsing",
                "writers",
                "handler_events",
                "interactive_ids",
                "interactive_serialization",
            ][..],
        ),
        (
            "src/domains/mcp/product_protocol/tests.rs",
            "src/domains/mcp/product_protocol/tests",
            &["client", "manager", "router", "capability_index"][..],
        ),
        (
            "src/domains/session/commands/tests.rs",
            "src/domains/session/commands/tests",
            &["archive_delete", "archive_older_than"][..],
        ),
    ] {
        assert!(
            !crate_root.join(old_file).exists(),
            "broad domain test file {old_file} must stay split into concern modules"
        );
        let root = crate_root.join(new_root);
        let mod_path = root.join("mod.rs");
        let support_path = root.join("support.rs");
        assert!(mod_path.is_file(), "{new_root}/mod.rs must exist");
        assert!(support_path.is_file(), "{new_root}/support.rs must exist");
        let mod_text = std::fs::read_to_string(&mod_path)
            .unwrap_or_else(|error| panic!("failed to read {mod_path:?}: {error}"));
        assert!(
            !mod_text.contains("#[test]") && !mod_text.contains("#[tokio::test]"),
            "{new_root}/mod.rs must contain declarations only"
        );
        for module in modules {
            assert!(
                root.join(format!("{module}.rs")).is_file(),
                "{new_root}/{module}.rs must own its concern tests"
            );
            assert!(
                mod_text.contains(&format!("mod {module};")),
                "{new_root}/mod.rs must declare `{module}`"
            );
        }
    }

    let mac_sources = repo_root.join("packages/mac-app/Sources");
    for path in files_with_extensions(&mac_sources, &["swift"]) {
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        for forbidden in [
            "control::act",
            "targetFunctionId",
            "payloadTemplate",
            "requiredGrant",
            "module::activate",
            "worker::spawn",
            "signatureKeyRef",
        ] {
            assert!(
                !content.contains(forbidden),
                "{} must not construct server policy, package trust, worker spawn, or generated UI action targets",
                path.strip_prefix(&repo_root).unwrap_or(&path).display()
            );
        }
    }
}

#[test]
fn large_rust_test_files_have_scorecard_ownership_audit() {
    let repo_root = repo_root();
    let crate_root = crate_root();
    let scorecard_path =
        repo_root.join("packages/agent/docs/collapsed-engine-hardening-scorecard.md");
    let scorecard = std::fs::read_to_string(&scorecard_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", scorecard_path.display()));

    let mut test_files = files_with_extensions(&repo_root.join("packages/agent/tests"), &["rs"]);
    test_files.extend(
        files_with_extensions(&crate_root.join("src"), &["rs"])
            .into_iter()
            .filter(|path| is_src_rust_test_file(path)),
    );

    let mut large_files = BTreeMap::new();
    for path in test_files {
        let line_count = line_count(&path);
        if line_count > LARGE_TEST_FILE_LIMIT_LINES {
            let relative = path
                .strip_prefix(&repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            large_files.insert(relative, line_count);
        }
    }

    let audited = LARGE_TEST_FILE_AUDIT
        .iter()
        .map(|(path, _reason, _max_lines)| (*path).to_owned())
        .collect::<BTreeSet<_>>();
    let discovered = large_files.keys().cloned().collect::<BTreeSet<_>>();
    assert_eq!(
        discovered, audited,
        "every Rust test file over {LARGE_TEST_FILE_LIMIT_LINES} lines must be split or explicitly audited in SCB-S6"
    );

    for (path, reason, max_lines) in LARGE_TEST_FILE_AUDIT {
        let line_count = large_files
            .get(*path)
            .unwrap_or_else(|| panic!("{path} should be discovered as a large Rust test file"));
        assert!(
            *line_count <= *max_lines,
            "{path} has grown to {line_count} lines; split it or raise the audited budget with a scorecard reason"
        );
        assert!(
            scorecard.contains(path) && scorecard.contains(reason),
            "SCB-S6 scorecard audit must include {path} with reason marker `{reason}`"
        );
    }
}

#[test]
fn test_harness_boundaries_stay_split() {
    let repo_root = repo_root();
    let crate_root = crate_root();

    let guardrails_root = crate_root.join("src/domains/agent/runner/guardrails");
    assert!(
        !guardrails_root.join("tests.rs").exists(),
        "guardrails tests must stay split by concern under guardrails/tests/"
    );
    let guardrails_mod =
        std::fs::read_to_string(guardrails_root.join("mod.rs")).expect("read guardrails/mod.rs");
    assert!(
        guardrails_mod.contains("mod tests;") && !guardrails_mod.contains("#[path = \"tests.rs\"]"),
        "guardrails module should use the concern-owned test directory directly"
    );
    for relative in [
        "src/domains/agent/runner/guardrails/tests/mod.rs",
        "src/domains/agent/runner/guardrails/tests/serialization.rs",
        "src/domains/agent/runner/guardrails/tests/pattern_path_resource.rs",
        "src/domains/agent/runner/guardrails/tests/context_composite.rs",
        "src/domains/agent/runner/guardrails/tests/engine_audit.rs",
    ] {
        let path = crate_root.join(relative);
        assert!(
            path.is_file(),
            "guardrails test split file missing: {relative}"
        );
        assert!(
            line_count(&path) <= 1_000,
            "guardrails test split file must stay below 1,000 LOC: {relative}"
        );
    }

    let fixtures_root = repo_root.join("packages/agent/tests/fixtures");
    for relative in [
        "rwo_n7_live_worker_fixture.py",
        "rwo_n15_live_worker_fixture.py",
        "session_terminal_guard.py",
    ] {
        let path = fixtures_root.join(relative);
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        assert!(
            content.contains("--self-test"),
            "{relative} must keep a runnable fixture self-test"
        );
    }

    let n15 = std::fs::read_to_string(fixtures_root.join("rwo_n15_live_worker_fixture.py"))
        .expect("read RWO-N15 fixture");
    let self_test_pos = n15
        .find("if args.self_test:")
        .expect("RWO-N15 fixture self-test branch missing");
    let visibility_pos = n15
        .find("if args.visibility == \"session\"")
        .expect("RWO-N15 fixture visibility validation missing");
    assert!(
        self_test_pos < visibility_pos,
        "RWO-N15 fixture --self-test must run before live session/workspace visibility validation"
    );

    let n17 = std::fs::read_to_string(fixtures_root.join("rwo_n17_live_multi_session_harness.py"))
        .expect("read RWO-N17 harness");
    for required in [
        "claude-sonnet-4-6",
        "safe_run_cmd",
        "activeHarnessSubscriptionCount",
        "activeClientSubscriptionCount",
        "visibleLeakCount",
        "backgroundLeakCount",
        "simulatorOk",
    ] {
        assert!(
            n17.contains(required),
            "RWO-N17 harness must retain multi-session app-path evidence marker `{required}`"
        );
    }
}

#[test]
fn critical_execution_and_ui_boundaries_stay_split() {
    let crate_root = crate_root();
    let repo_root = repo_root();

    for required_file in [
        "src/domains/capability/operations/mod.rs",
        "src/domains/capability/operations/admin.rs",
        "src/domains/capability/operations/execute.rs",
        "src/domains/capability/operations/execute/input.rs",
        "src/domains/capability/operations/execute/result.rs",
        "src/domains/capability/operations/execute/trigger_metadata.rs",
        "src/domains/capability/operations/execute/tests/mod.rs",
        "src/domains/capability/operations/execute/tests/discovery.rs",
        "src/domains/capability/operations/execute/tests/normalization.rs",
        "src/domains/capability/operations/execute/tests/observe.rs",
        "src/domains/capability/operations/execute/tests/support.rs",
        "src/domains/capability/operations/execute/tests/terminal.rs",
        "src/domains/capability/operations/execute/tests/trigger_metadata.rs",
        "src/domains/capability/operations/target_arguments.rs",
        "src/domains/capability/operations/schema_validation.rs",
        "src/domains/capability/operations/presentation.rs",
        "src/domains/capability/operations/policy_profile.rs",
        "src/domains/capability/operations/run.rs",
        "src/domains/capability/operations/search.rs",
        "src/domains/capability/operations/inspect.rs",
        "src/domains/capability/operations/audit.rs",
        "src/domains/capability/operations/tests/mod.rs",
        "src/domains/capability/operations/tests/display.rs",
        "src/domains/capability/operations/tests/normalization.rs",
        "src/domains/capability/operations/tests/policy.rs",
        "src/domains/capability/operations/tests/resolution.rs",
        "src/domains/capability/operations/tests/result.rs",
        "src/domains/capability/operations/tests/admin.rs",
        "src/domains/capability/operations/tests/audit.rs",
        "src/domains/capability/operations/tests/support.rs",
        "src/domains/capability/registry/mod.rs",
        "src/domains/capability/registry/recipes.rs",
        "src/domains/capability/registry/search_policy.rs",
        "src/domains/capability/registry/store.rs",
        "src/domains/capability/registry/store/memory.rs",
        "src/domains/capability/registry/store/projection.rs",
        "src/domains/capability/registry/store/schema.rs",
        "src/domains/capability/registry/store/sqlite.rs",
        "src/domains/capability/registry/store/sqlite_runtime.rs",
        "src/domains/capability/registry/tests/mod.rs",
        "src/domains/capability/registry/tests/projection.rs",
        "src/domains/capability/registry/tests/recipes.rs",
        "src/domains/capability/registry/tests/index.rs",
        "src/domains/capability/registry/tests/primer.rs",
        "src/domains/capability/registry/tests/store.rs",
        "src/domains/capability/registry/tests/support.rs",
        "src/domains/capability_support/implementations/traits.rs",
        "src/domains/capability_support/implementations/traits/tests.rs",
        "src/engine/primitives/ui/authoring/mod.rs",
        "src/engine/primitives/ui/authoring/actions.rs",
        "src/engine/primitives/ui/authoring/prompt.rs",
        "src/engine/primitives/ui/authoring/notifications.rs",
        "src/engine/primitives/ui/authoring/subagent.rs",
        "src/engine/primitives/ui/authoring/source_control.rs",
        "src/engine/primitives/ui/authoring/agent_control.rs",
    ] {
        assert!(
            crate_root.join(required_file).is_file(),
            "critical execution/UI split boundary must exist: {required_file}"
        );
    }
    for removed_file in [
        "src/domains/capability/operations.rs",
        "src/domains/capability/registry.rs",
        "src/engine/primitives/ui/authoring.rs",
    ] {
        assert!(
            !crate_root.join(removed_file).exists(),
            "oversized retired single-file boundary must stay split: {removed_file}"
        );
    }
    let capability_operations =
        std::fs::read_to_string(crate_root.join("src/domains/capability/operations/mod.rs"))
            .expect("read capability operations root");
    for required in [
        "mod admin;",
        "mod schema_validation;",
        "mod presentation;",
        "mod policy_profile;",
        "mod tests;",
    ] {
        assert!(
            capability_operations.contains(required),
            "capability operations root must declare focused CLC-1 boundary `{required}`"
        );
    }
    for forbidden in [
        "mod tests {",
        "pub(crate) async fn registry_snapshot_value(",
        "pub(crate) async fn plugin_install_value(",
        "pub(super) fn validate_plugin_manifest(",
        "fn test_function(",
        "fn test_approval_record(",
        "fn validate_target_payload(",
        "fn render_search_summary(",
        "fn render_inspection_summary(",
        "fn validate_capability_execution_policy_payload(",
        "fn write_capability_execution_policy_to_profile_and_reload(",
    ] {
        assert!(
            !capability_operations.contains(forbidden),
            "capability operations root must not regain extracted CLC-1 helper `{forbidden}`"
        );
    }
    let capability_execute =
        std::fs::read_to_string(crate_root.join("src/domains/capability/operations/execute.rs"))
            .expect("read capability execute root");
    assert!(
        capability_execute.contains("mod input;")
            && capability_execute.contains("mod result;")
            && capability_execute.contains("mod trigger_metadata;")
            && capability_execute.contains("mod tests;"),
        "capability execute root must declare focused CLC-1 input/result/trigger-metadata/test boundaries"
    );
    assert!(
        line_count(&crate_root.join("src/domains/capability/operations/execute.rs")) <= 1_000,
        "capability execute root must stay below the 1,000 LOC review-smell threshold after CLC-1 extraction"
    );
    for forbidden in [
        "mod tests {",
        "struct OrchestratedExecuteInput",
        "const EXECUTE_WRAPPER_KEYS",
        "fn parse_orchestrated_execute_input(",
        "fn trigger_metadata_target_guidance_for_visible_catalog(",
        "fn trigger_metadata_target_guidance_for_intent(",
        "fn trigger_metadata_target_message(",
        "fn orchestration_result(",
        "fn attach_orchestration_details(",
        "fn capability_error_details(",
    ] {
        assert!(
            !capability_execute.contains(forbidden),
            "capability execute root must not regain extracted CLC-1 helper `{forbidden}`"
        );
    }
    let capability_execute_input = std::fs::read_to_string(
        crate_root.join("src/domains/capability/operations/execute/input.rs"),
    )
    .expect("read capability execute input");
    for required in [
        "struct OrchestratedExecuteInput",
        "const EXECUTE_WRAPPER_KEYS",
        "fn parse_orchestrated_execute_input(",
        "fn normalize_live_resource_inventory_operation(",
    ] {
        assert!(
            capability_execute_input.contains(required),
            "capability execute input boundary must own CLC-1 input helper `{required}`"
        );
    }
    let capability_execute_result = std::fs::read_to_string(
        crate_root.join("src/domains/capability/operations/execute/result.rs"),
    )
    .expect("read capability execute result");
    for required in [
        "fn orchestration_result(",
        "fn attach_orchestration_details(",
        "fn capability_error_details(",
        "fn enrich_orchestration_with_result(",
    ] {
        assert!(
            capability_execute_result.contains(required),
            "capability execute result boundary must own CLC-1 result helper `{required}`"
        );
    }
    let capability_execute_trigger_metadata = std::fs::read_to_string(
        crate_root.join("src/domains/capability/operations/execute/trigger_metadata.rs"),
    )
    .expect("read capability execute trigger metadata");
    for required in [
        "fn trigger_metadata_target_guidance_for_visible_catalog(",
        "fn trigger_metadata_target_guidance_for_intent(",
        "fn trigger_metadata_target_message(",
        "fn trigger_metadata_target_phase_details(",
    ] {
        assert!(
            capability_execute_trigger_metadata.contains(required),
            "capability execute trigger-metadata boundary must own CLC-1 helper `{required}`"
        );
    }
    assert!(
        capability_execute.contains("mod tests;"),
        "capability execute root must keep tests in an adjacent CLC-1 test module"
    );
    let capability_registry =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/mod.rs"))
            .expect("read capability registry root");
    assert!(
        capability_registry.contains("mod search_policy;")
            && capability_registry.contains("mod store;")
            && capability_registry.contains("mod tests;"),
        "capability registry root must declare focused CLC-1 search-policy, store, and test boundaries"
    );
    for forbidden in [
        "mod tests {",
        "pub(crate) struct CapabilitySearchPolicy",
        "pub(crate) struct CapabilitySearchFilters",
        "fn document_kind_matches(",
        "fn test_function(",
        "fn session_generated_function(",
        "pub(crate) struct SqliteCapabilityRegistryStore",
        "pub(crate) struct InMemoryCapabilityRegistryStore",
        "const CAPABILITY_REGISTRY_SCHEMA",
        "CREATE TABLE IF NOT EXISTS capability_plugins",
    ] {
        assert!(
            !capability_registry.contains(forbidden),
            "capability registry root must not regain extracted store helper `{forbidden}`"
        );
    }
    let capability_recipes =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/recipes.rs"))
            .expect("read capability recipes");
    for required in [
        "pub(crate) struct AgentCapabilityRecipeDisplay",
        "fn display_field_list(",
        "fn primer_execution_guidance(",
        "fn risky_direct_recipe_example_json(",
    ] {
        assert!(
            capability_recipes.contains(required),
            "capability recipes must own CLC-1 recipe display model helper `{required}`"
        );
    }
    for rel in [
        "src/domains/capability/operations/presentation.rs",
        "src/domains/capability/operations/schema_validation.rs",
        "src/domains/capability/operations/execute/result.rs",
        "src/domains/capability/registry/primer.rs",
    ] {
        let content = std::fs::read_to_string(crate_root.join(rel))
            .unwrap_or_else(|error| panic!("read {rel}: {error}"));
        assert!(
            content.contains("AgentCapabilityRecipeDisplay"),
            "{rel} must use the recipe-owned CLC-1 display model instead of rebuilding recipe text locally"
        );
        for forbidden in [
            "required_payload.join",
            "optional_payload.join",
            "serde_json::to_string(&recipe.execute_template)",
            "fn risky_direct_recipe_example(",
        ] {
            assert!(
                !content.contains(forbidden),
                "{rel} must not regain duplicated recipe display helper `{forbidden}`"
            );
        }
    }
    let capability_support_traits = std::fs::read_to_string(
        crate_root.join("src/domains/capability_support/implementations/traits.rs"),
    )
    .expect("read capability support traits");
    assert!(
        capability_support_traits.contains("mod tests;"),
        "capability support traits must keep tests in an adjacent CLC-1 test module"
    );
    assert!(
        !capability_support_traits.contains("mod tests {"),
        "capability support traits must not regain its broad inline test module"
    );
    let capability_registry_store =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/store.rs"))
            .expect("read capability registry store");
    for required in [
        "pub(crate) trait CapabilityRegistryStore",
        "mod memory;",
        "mod projection;",
        "mod schema;",
        "mod sqlite;",
        "mod sqlite_runtime;",
        "pub(crate) use memory::InMemoryCapabilityRegistryStore;",
        "pub(crate) use sqlite::SqliteCapabilityRegistryStore;",
    ] {
        assert!(
            capability_registry_store.contains(required),
            "capability registry store must own CLC-1 persistence boundary `{required}`"
        );
    }
    assert!(
        line_count(&crate_root.join("src/domains/capability/registry/store.rs")) <= 1_000,
        "capability registry store root must stay below the 1,000 LOC review-smell threshold after CLC-1 extraction"
    );
    for forbidden in [
        "pub(crate) struct SqliteCapabilityRegistryStore",
        "pub(crate) struct InMemoryCapabilityRegistryStore",
        "const CAPABILITY_REGISTRY_SCHEMA",
        "fn query_json_column(",
        "fn redact_audit_event(",
        "fn write_vectors(",
        "CREATE TABLE IF NOT EXISTS capability_plugins",
    ] {
        assert!(
            !capability_registry_store.contains(forbidden),
            "capability registry store root must not regain extracted persistence helper `{forbidden}`"
        );
    }
    let capability_registry_memory =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/store/memory.rs"))
            .expect("read capability registry memory store");
    assert!(
        capability_registry_memory.contains("pub(crate) struct InMemoryCapabilityRegistryStore")
            && capability_registry_memory
                .contains("impl CapabilityRegistryStore for InMemoryCapabilityRegistryStore"),
        "capability registry memory store must own the in-memory store implementation"
    );
    let capability_registry_schema =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/store/schema.rs"))
            .expect("read capability registry schema");
    assert!(
        capability_registry_schema.contains("pub(super) const CAPABILITY_REGISTRY_SCHEMA")
            && capability_registry_schema.contains("CREATE TABLE IF NOT EXISTS capability_plugins"),
        "capability registry schema boundary must own the SQLite schema text"
    );
    let capability_registry_sqlite =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/store/sqlite.rs"))
            .expect("read capability registry sqlite helpers");
    assert!(
        capability_registry_sqlite.contains("pub(crate) struct SqliteCapabilityRegistryStore")
            && capability_registry_sqlite.contains("fn initialize_schema(")
            && capability_registry_sqlite.contains("fn ensure_vector_table(")
            && capability_registry_sqlite.contains("fn write_vectors(")
            && capability_registry_sqlite.contains("fn vector_search("),
        "capability registry sqlite helper boundary must own SQLite opening, schema migration, and vector persistence"
    );
    let capability_registry_runtime = std::fs::read_to_string(
        crate_root.join("src/domains/capability/registry/store/sqlite_runtime.rs"),
    )
    .expect("read capability registry sqlite runtime");
    assert!(
        capability_registry_runtime
            .contains("impl CapabilityRegistryStore for SqliteCapabilityRegistryStore")
            && capability_registry_runtime.contains("fn sync_snapshot(")
            && capability_registry_runtime.contains("fn record_program_run(")
            && capability_registry_runtime.contains("fn resolve_pause(")
            && capability_registry_runtime.contains("fn update_run_status("),
        "capability registry sqlite runtime must own store trait mutation/query behavior"
    );
    let capability_registry_projection = std::fs::read_to_string(
        crate_root.join("src/domains/capability/registry/store/projection.rs"),
    )
    .expect("read capability registry projection helpers");
    assert!(
        capability_registry_projection.contains("fn query_bindings(")
            && capability_registry_projection.contains("fn query_implementations(")
            && capability_registry_projection.contains("fn redact_audit_event(")
            && capability_registry_projection.contains("fn redact_program_run("),
        "capability registry projection boundary must own query projection and redaction helpers"
    );

    let program_runtime =
        std::fs::read_to_string(crate_root.join("src/domains/program/runtime.rs"))
            .expect("failed to read program runtime");
    assert!(
        !program_runtime.contains("tools.search")
            && !program_runtime.contains("tools.inspect")
            && program_runtime.contains("tools.execute"),
        "program runtime must keep the internal composition host execute-only"
    );
    let event_database = std::fs::read_to_string(
        repo_root.join("packages/ios-app/Sources/Database/EventDatabase.swift"),
    )
    .expect("failed to read iOS EventDatabase");
    assert!(
        event_database.contains("EventDatabaseStorageMode")
            && event_database.contains("temporaryFallback"),
        "iOS EventDatabase must expose fallback-cache mode visibly"
    );
}

#[test]
fn capability_backed_truth_boundaries_stay_code_enforced() {
    let root = crate_root();
    let repo = repo_root();

    for rel in [
        "src/engine/tests/memory_retain_resources.rs",
        "src/engine/tests/notification_resources.rs",
        "src/engine/tests/subagent_lineage.rs",
        "src/engine/tests/generated_ui.rs",
        "src/engine/tests/cron_resources.rs",
        "src/engine/tests/prompt_library_resources.rs",
        "src/engine/tests/domain_outputs.rs",
    ] {
        assert!(
            root.join(rel).is_file(),
            "capability-backed truth proof must live in focused test boundary {rel}"
        );
    }

    for rel in [
        "src/domains/memory/retain/resources.rs",
        "src/domains/notifications/inbox.rs",
        "src/domains/agent/lineage.rs",
        "src/domains/cron/implementation/domain/truth.rs",
        "src/domains/prompt_library/mod.rs",
        "src/domains/voice_notes/mod.rs",
    ] {
        assert!(
            root.join(rel).is_file(),
            "capability-backed truth owner must be code-adjacent at {rel}"
        );
    }

    let readme = std::fs::read_to_string(repo.join("README.md")).expect("read README");
    assert!(
        readme.contains("Capability-backed truth")
            && readme.contains("resources, decisions, evidence, invocations, grants")
            && readme.contains("domain-owned hidden files or tables"),
        "README must describe the capability-backed truth invariant without relying on migration rubrics"
    );
}

#[test]
fn memory_retain_resource_truth_boundary_stays_enforced() {
    let root = crate_root();
    let memory_contract = std::fs::read_to_string(root.join("src/domains/memory/contract.rs"))
        .expect("read memory contract");
    assert!(
        memory_contract.contains("DurableOutputContract::ResourceBacked")
            && memory_contract.contains("artifact")
            && memory_contract.contains("materialized_file")
            && memory_contract.contains("evidence")
            && memory_contract.contains("\"resourceRefs\""),
        "memory retain capabilities must keep resource-backed output contracts and ref-aware schemas"
    );

    let retain_mod = std::fs::read_to_string(root.join("src/domains/memory/retain/mod.rs"))
        .expect("read memory retain mod");
    assert!(
        retain_mod.contains("mod resources;"),
        "memory retain resource persistence must stay in its focused resources boundary"
    );
    let retain_resources =
        std::fs::read_to_string(root.join("src/domains/memory/retain/resources.rs"))
            .expect("read memory retain resources");
    for required in [
        "artifact:memory-journal:",
        "artifact:memory-rule:",
        "artifact:memory-argument:",
        "evidence::attach",
        "memory_retain_recovery",
        "memory_projection_failure",
        "materialized_file::update",
        "resource::link",
        "resourceRefs",
    ] {
        assert!(
            retain_resources.contains(required),
            "memory retain resources boundary must contain `{required}`"
        );
    }

    for rel in [
        "src/domains/memory/retain/background.rs",
        "src/domains/memory/retain/mod.rs",
        "src/domains/memory/retain/resources.rs",
        "src/domains/memory/retain/writer.rs",
    ] {
        let content = std::fs::read_to_string(root.join(rel))
            .unwrap_or_else(|error| panic!("failed to read {rel}: {error}"));
        for forbidden in [
            "OpenOptions",
            "std::fs::write",
            "write_all",
            "create_dir_all",
        ] {
            assert!(
                !content.contains(forbidden),
                "{rel} must not use {forbidden} as retained-memory durable truth"
            );
        }
    }

    let context_service =
        std::fs::read_to_string(root.join("src/domains/agent/runtime/service/context.rs"))
            .expect("read agent context service");
    assert!(
        context_service.contains("load_retained_memory_resource_context")
            && context_service.contains("artifact:memory-rule:")
            && context_service.contains("artifact:memory-argument:"),
        "prompt context assembly must include resource-backed retained memory"
    );

    let engine_tests =
        std::fs::read_to_string(root.join("src/engine/tests/mod.rs")).expect("read engine tests");
    assert!(
        engine_tests.contains("mod memory_retain_resources;"),
        "memory retain resource tests must stay in an engine test ownership boundary"
    );
    let memory_tests =
        std::fs::read_to_string(root.join("src/engine/tests/memory_retain_resources.rs"))
            .expect("read memory retain resource tests");
    for required in [
        "memory_retain_produces_resource_backed_journal_and_projection",
        "memory_retain_idempotency_does_not_duplicate_memory_artifacts",
    ] {
        assert!(
            memory_tests.contains(required),
            "memory retain resource proof test `{required}` must remain present"
        );
    }
}

#[test]
fn grant_manifest_resource_and_ui_hardening_tests_stay_in_owning_boundaries() {
    let crate_root = crate_root();
    let engine_tests = std::fs::read_to_string(crate_root.join("src/engine/tests/mod.rs"))
        .expect("failed to read engine tests root");
    let grant_authority =
        std::fs::read_to_string(crate_root.join("src/engine/tests/grant_authority.rs"))
            .expect("failed to read grant authority tests");
    let module_source_trust = std::fs::read_to_string(
        crate_root.join("src/engine/tests/module_activation/source_trust.rs"),
    )
    .expect("failed to read module source-trust tests");
    let resource_kernel =
        std::fs::read_to_string(crate_root.join("src/engine/tests/resource_kernel.rs"))
            .expect("failed to read resource kernel tests");
    let generated_ui = std::fs::read_to_string(crate_root.join("src/engine/tests/generated_ui.rs"))
        .expect("failed to read generated UI tests");
    let grants_path = crate_root.join("src/engine/grants.rs");
    let grants = std::fs::read_to_string(&grants_path).expect("failed to read grants root");
    let grant_model = std::fs::read_to_string(crate_root.join("src/engine/grants/model.rs"))
        .expect("failed to read grant model boundary");
    let grant_sqlite =
        std::fs::read_to_string(crate_root.join("src/engine/grants/sqlite_codec.rs"))
            .expect("failed to read grant SQLite codec boundary");

    assert!(
        engine_tests.contains("mod grant_authority;")
            && grant_authority
                .contains("grant_derive_rejects_child_expansion_by_authority_dimension")
            && grant_authority.contains(
                "rejected_grants_fail_before_handler_execution_or_successful_resource_refs"
            )
            && grant_authority.contains("raw-scope"),
        "grant-authority hardening must live in the focused grant_authority test module"
    );
    assert!(
        module_source_trust.contains(
            "module_register_package_rejects_adversarial_manifest_shapes_without_persistence"
        ) && module_source_trust.contains("duplicate functionId")
            && module_source_trust.contains("secret-like value"),
        "adversarial package/source-trust tests must live in module_activation/source_trust.rs"
    );
    assert!(
        resource_kernel.contains(
            "resource_backed_invocation_rejects_malformed_or_wrong_kind_refs_without_persisting_refs"
        )
            && resource_kernel.contains("wrong-kind")
            && resource_kernel.contains("invalid-hash"),
        "resource-ref hardening tests must live in resource_kernel.rs"
    );
    assert!(
        generated_ui.contains(
            "ui_submit_action_rejects_invalid_input_and_stale_target_before_child_invocation"
        ) && generated_ui.contains("invalid user input must fail before target child invocation")
            && generated_ui
                .contains("stale target revision must fail before target child invocation")
            && generated_ui
                .contains("ui_surface_for_target_authors_prompt_library_resource_collections")
            && generated_ui
                .contains("ui_prompt_collection_actions_submit_through_stored_surface_coordinates"),
        "generated UI action hardening tests must live in generated_ui.rs"
    );
    assert!(
        grants.contains("mod model;")
            && grants.contains("mod sqlite_codec;")
            && grants.contains("pub use model::")
            && grants.contains("pub struct InMemoryEngineGrantStore")
            && grants.contains("pub struct SqliteEngineGrantStore")
            && line_count(&grants_path) <= 1_000
            && !grants.contains("pub struct EngineGrant")
            && !grants.contains("fn row_to_grant(")
            && !grants.contains("fn json_string"),
        "grant root must stay a store/policy boundary below 1,000 LOC"
    );
    assert!(
        grant_model.contains("pub struct EngineGrant")
            && grant_model.contains("pub struct DeriveGrant")
            && grant_model.contains("pub const BOOTSTRAP_GRANT_IDS")
            && grant_model.contains("pub(super) fn grant_event("),
        "grant model boundary must own records, requests, bootstrap grants, and event builders"
    );
    assert!(
        grant_sqlite.contains("pub(super) fn row_to_grant(")
            && grant_sqlite.contains("pub(super) fn json_string")
            && grant_sqlite.contains("pub(super) fn sqlite_err")
            && grant_sqlite.contains("pub(super) fn risk_as_str"),
        "grant SQLite codec boundary must own row/risk/JSON conversion helpers"
    );
}

fn assert_site(root: &Path, relative: &str, keyword: &str) {
    let path = root.join(relative);
    let content =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
    assert!(
        content.contains("INVARIANT"),
        "{relative} must contain an INVARIANT marker (trusted-local [T] finding)"
    );
    assert!(
        content.to_lowercase().contains(keyword),
        "{relative} must name `{keyword}` somewhere in its INVARIANT block"
    );
}

#[test]
fn every_trusted_local_finding_has_invariant_marker() {
    let crate_root = crate_root();
    for (rel, keyword) in TRUST_BOUNDARY_SITES {
        assert_site(&crate_root, rel, keyword);
    }

    let repo_root = repo_root();
    for (rel, keyword) in TRUST_BOUNDARY_REPO_SITES {
        assert_site(&repo_root, rel, keyword);
    }
}

/// Regression: the registered sites must all actually exist. A typo
/// in `TRUST_BOUNDARY_SITES` would otherwise only surface the first
/// time the specific file is read.
#[test]
fn every_registered_site_exists() {
    let crate_root = crate_root();
    for (rel, _) in TRUST_BOUNDARY_SITES {
        let path = crate_root.join(rel);
        assert!(
            path.is_file(),
            "registered site {rel} does not exist at {path:?}"
        );
    }
    let repo_root = repo_root();
    for (rel, _) in TRUST_BOUNDARY_REPO_SITES {
        let path = repo_root.join(rel);
        assert!(
            path.is_file(),
            "registered repo site {rel} does not exist at {path:?}"
        );
    }
}

#[test]
fn installed_pre_commit_hook_enforces_rustfmt_and_personal_info_guard() {
    let hook_installer = repo_root().join("scripts").join("install-hooks.sh");
    let content = std::fs::read_to_string(&hook_installer)
        .unwrap_or_else(|e| panic!("failed to read {hook_installer:?}: {e}"));

    assert!(
        content.contains("cargo fmt --all -- --check"),
        "pre-commit hook must block Rust formatting drift"
    );
    assert!(
        content.contains("personal-info-guard.sh\" --staged"),
        "pre-commit hook must keep the staged personal-info guard"
    );
}

#[test]
fn tron_dev_background_start_is_file_logged_and_health_checked() {
    let script_path = repo_root().join("scripts").join("tron.d").join("dev.sh");
    let content = std::fs::read_to_string(&script_path)
        .unwrap_or_else(|e| panic!("failed to read {script_path:?}: {e}"));
    let background_start = content
        .split("dev_start_background()")
        .nth(1)
        .and_then(|tail| tail.split("dev_stop()").next())
        .expect("scripts/tron must contain dev_start_background before dev_stop");

    assert!(
        background_start.contains("DEV_BACKGROUND_LOG"),
        "background dev startup must preserve server stdout/stderr in a file log"
    );
    assert!(
        background_start.contains("http://127.0.0.1:$PROD_PORT/health"),
        "background dev startup must wait for /health, not just a live pid"
    );
    assert!(
        background_start.contains("listener_pid_for_port \"$PROD_PORT\""),
        "background dev startup must report the actual listener pid instead of trusting the launched child pid"
    );
    assert!(
        background_start.contains("cmd_status_json"),
        "background dev startup must support machine-readable status for agent automation"
    );
    assert!(
        content.contains("create_dev_launchd_plist()")
            && background_start
                .contains("launchctl bootstrap \"gui/$(id -u)\" \"$DEV_PLIST_PATH\""),
        "background dev startup must use a transient LaunchAgent so automation shells do not own the server process group"
    );
    assert!(
        background_start.contains("launchd_stop \"$DEV_PLIST_NAME\"")
            && background_start
                .find("launchd_stop \"$DEV_PLIST_NAME\"")
                .zip(background_start.find("launchctl bootstrap"))
                .is_some_and(|(stop, bootstrap)| stop < bootstrap),
        "background dev startup must boot out stale dev takeover jobs before launchctl bootstrap"
    );
    assert!(
        content.contains("=== tron dev background exit") && content.contains("code=\\$exit_code"),
        "background dev startup must record process exit details for postmortem automation"
    );
    assert!(
        content.contains("trap \"\" HUP"),
        "background dev startup must ignore terminal hangups so non-interactive agents can launch it reliably"
    );
    assert!(
        background_start.contains("tail -n 80 \"$dev_log\""),
        "background dev startup failure must print the recent server log tail"
    );
    assert!(
        !background_start.contains(">/dev/null 2>&1 &"),
        "background dev startup must not discard pre-database startup failures"
    );
}

#[test]
fn tron_cli_status_and_logs_are_agent_automation_ready() {
    let repo_root = repo_root();
    let script_path = repo_root.join("scripts").join("tron");
    let script = std::fs::read_to_string(&script_path)
        .unwrap_or_else(|e| panic!("failed to read {script_path:?}: {e}"));
    let lib_path = repo_root.join("scripts").join("tron-lib.sh");
    let lib = std::fs::read_to_string(&lib_path)
        .unwrap_or_else(|e| panic!("failed to read {lib_path:?}: {e}"));
    let logs_path = repo_root.join("scripts").join("tron-lib.d").join("logs.sh");
    let logs = std::fs::read_to_string(&logs_path)
        .unwrap_or_else(|e| panic!("failed to read {logs_path:?}: {e}"));
    let service_path = repo_root
        .join("scripts")
        .join("tron-lib.d")
        .join("service.sh");
    let service = std::fs::read_to_string(&service_path)
        .unwrap_or_else(|e| panic!("failed to read {service_path:?}: {e}"));
    let dev_path = repo_root.join("scripts").join("tron.d").join("dev.sh");
    let dev = std::fs::read_to_string(&dev_path)
        .unwrap_or_else(|e| panic!("failed to read {dev_path:?}: {e}"));

    assert!(
        lib.contains("DB_PATH=\"$TRON_HOME/internal/database/tron.sqlite\""),
        "tron logs/status helpers must use the unified tron.sqlite database, not retired log.db"
    );
    assert!(
        logs.contains("--tail)") && logs.contains("--json)"),
        "tron logs must keep machine-friendly --tail and --json aliases used by automation"
    );
    assert!(
        service.contains("cmd_status_json()"),
        "tron status must expose a machine-readable status function"
    );
    assert!(
        service.contains("\"mode\"")
            && service.contains("\"listenerPid\"")
            && service.contains("\"healthy\""),
        "tron status --json must include mode, listenerPid, and healthy fields"
    );
    assert!(
        service.contains("\"pidFileStale\"")
            && service.contains("\"pidFilePid\"")
            && service.contains("\"logPath\"")
            && service.contains("\"devLaunchdLoaded\""),
        "tron status --json must expose stale pid-file and log-path diagnostics for agents"
    );
    assert!(
        lib.contains("DEV_BACKGROUND_LOG=\"$RUN_DIR/tron-dev-background.log\"")
            && lib.contains("DEV_BACKGROUND_PID_FILE=\"$RUN_DIR/tron-dev-background.pid\""),
        "dev background log and pid paths must stay centralized in scripts/tron-lib.sh"
    );
    assert!(
        script.contains("status)    shift; cmd_status \"$@\" ;;"),
        "main dispatch must pass status flags such as --json through to cmd_status"
    );
    assert!(
        dev.contains("--wait SECONDS") && dev.contains("--json"),
        "tron dev help and parser must advertise agent-friendly --wait and --json flags"
    );
}

#[test]
fn program_worker_binary_is_built_and_packaged_with_tron_helper() {
    let repo_root = repo_root();
    let script_path = repo_root.join("scripts").join("tron");
    let script = std::fs::read_to_string(&script_path)
        .unwrap_or_else(|e| panic!("failed to read {script_path:?}: {e}"));
    let dev_path = repo_root.join("scripts").join("tron.d").join("dev.sh");
    let dev = std::fs::read_to_string(&dev_path)
        .unwrap_or_else(|e| panic!("failed to read {dev_path:?}: {e}"));
    let deploy_path = repo_root.join("scripts").join("tron.d").join("deploy.sh");
    let deploy = std::fs::read_to_string(&deploy_path)
        .unwrap_or_else(|e| panic!("failed to read {deploy_path:?}: {e}"));
    assert!(
        dev.contains("--bin tron --bin tron-program-worker"),
        "tron dev/install flows must build the server and program-worker binaries together"
    );
    assert!(
        script.contains("RELEASE_PROGRAM_WORKER="),
        "workspace script must track the release program worker beside tron"
    );
    assert!(
        deploy.contains("tron-program-worker.bak"),
        "deploy rollback must back up the program worker with the server binary"
    );

    let lib_path = repo_root.join("scripts").join("tron-lib.sh");
    let lib = std::fs::read_to_string(&lib_path)
        .unwrap_or_else(|e| panic!("failed to read {lib_path:?}: {e}"));
    let bundle_path = repo_root
        .join("scripts")
        .join("tron-lib.d")
        .join("bundle.sh");
    let bundle = std::fs::read_to_string(&bundle_path)
        .unwrap_or_else(|e| panic!("failed to read {bundle_path:?}: {e}"));
    assert!(
        lib.contains("INSTALLED_PROGRAM_WORKER=")
            && lib.contains("tron-program-worker")
            && bundle.contains("Cannot create app bundle: sibling tron-program-worker missing"),
        "shared bundle creation must require and stage the sibling program-worker binary"
    );

    let bundle_script_path = repo_root
        .join("packages")
        .join("mac-app")
        .join("scripts")
        .join("bundle-agent.sh");
    let bundle_script = std::fs::read_to_string(&bundle_script_path)
        .unwrap_or_else(|e| panic!("failed to read {bundle_script_path:?}: {e}"));
    assert!(
        bundle_script.contains("--bin tron --bin tron-program-worker")
            && bundle_script.contains("STAGING_WORKER_PATH=")
            && bundle_script.contains("--worker-source"),
        "Mac helper staging must build and copy both helper executables"
    );

    for workflow in [
        ".github/workflows/ci.yml",
        ".github/workflows/release-mac.yml",
    ] {
        let path = repo_root.join(workflow);
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        assert!(
            content.contains("--bin tron --bin tron-program-worker")
                && content.contains("tron-program-worker"),
            "{workflow} must build and validate the program-worker helper"
        );
    }
}

#[test]
fn lower_layers_do_not_depend_on_server_transport_modules() {
    let crate_root = crate_root();
    for dir in [
        "src/domains/settings/implementation",
        "src/domains/cron/implementation",
        "src/domains/mcp/product_protocol",
    ] {
        let root = crate_root.join(dir);
        for path in rust_files_under(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("crate::app::"),
                "{} must not import server transport modules",
                path.strip_prefix(&crate_root).unwrap().display()
            );
        }
    }
}

#[test]
fn readme_does_not_advertise_removed_or_fictional_contracts() {
    let readme_path = repo_root().join("README.md");
    let readme = std::fs::read_to_string(&readme_path)
        .unwrap_or_else(|e| panic!("failed to read {readme_path:?}: {e}"));
    for removed in [
        concat!("server.", "auth.", "enforced"),
        concat!("Bearer", "Auth"),
        concat!("rpc/", "ad", "apters.rs"),
        concat!(
            "Full-text",
            " search (",
            "FT",
            "S5), task management (",
            "PA",
            "RA)"
        ),
        concat!("ensure_", "bearer_token()"),
        concat!("touch_", "onboarded_sentinel()"),
        concat!("atomic self", "-update + rollback"),
    ] {
        assert!(
            !readme.contains(removed),
            "README must not advertise removed/stale contract `{removed}`"
        );
    }
}

#[test]
fn managed_skills_use_capability_native_references() {
    let skills_root = repo_root().join("packages").join("agent").join("skills");
    let forbidden = [
        (
            concat!("allowed", "Tools"),
            "use allowedContracts frontmatter",
        ),
        (
            concat!("denied", "Tools"),
            "use deniedContracts frontmatter",
        ),
        ("AskUserQuestion", "use agent::ask_user"),
        ("NotifyApp", "use notifications::send"),
        ("WebFetch", "use web::fetch"),
        ("WebSearch", "use web::search"),
        ("SpawnSubagent", "use agent::spawn_subagent"),
        ("Display(", "use display::show"),
    ];

    for path in files_to_scan(&skills_root) {
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        for (term, replacement) in forbidden {
            assert!(
                !content.contains(term),
                "{} contains retired skill surface `{term}`; {replacement}",
                path.strip_prefix(repo_root()).unwrap().display()
            );
        }
    }
}

#[test]
fn server_blocking_work_uses_the_supervisor_entrypoint() {
    let crate_root = crate_root();
    for root in [
        crate_root.join("src/domains"),
        crate_root.join("src/shared/server"),
    ] {
        for path in rust_files_under(&root) {
            let rel = path.strip_prefix(&crate_root).unwrap();
            if rel == Path::new("src/shared/server/context.rs")
                || rel == Path::new("src/domains/capability_support/implementations/ui/input.rs")
                || rel
                    == Path::new(
                        "src/domains/capability_support/implementations/backends/process.rs",
                    )
                || rel
                    == Path::new("src/domains/session/event_store/store/event_store/auxiliary.rs")
            {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("tokio::task::spawn_blocking")
                    && !content.contains("spawn_blocking("),
                "{} must route blocking work through ServerRuntimeContext::run_blocking or run_blocking_task",
                rel.display()
            );
        }
    }
}

#[test]
fn removed_server_owned_settings_store_stays_deleted() {
    let crate_root = crate_root();
    let file_name = ["settings", "_service.rs"].concat();
    assert!(
        !crate_root
            .join("src/domains/settings")
            .join(file_name)
            .exists(),
        "settings persistence belongs to settings::SettingsStore, not server transport code"
    );
}

#[test]
fn tron_server_transport_has_no_removed_rpc_surface() {
    let repo_root = repo_root();
    let crate_root = crate_root();

    for removed in [
        ["src/server", "/rpc"].concat(),
        concat!("src/transport/json", "_", "rpc").to_string(),
        concat!("src/app/engine_", "br", "idge").to_string(),
    ] {
        assert!(
            !crate_root.join(&removed).exists(),
            "{removed} must stay deleted; Tron exposes the engine WebSocket protocol only"
        );
    }

    let forbidden = [
        concat!("Method", "Handler"),
        concat!("Handler", "Entry"),
        concat!("Rpc", "Capability", "Spec"),
        concat!("Json", "Rpc", "Alias", "Spec"),
        concat!("Json", "Rpc", "Request", "Id", "Seed"),
        concat!("Rpc", "Generic", "Trigger", "Handler"),
        concat!("Generic", "Trigger"),
        concat!("Json", "Rpc", "Event"),
        concat!("Broadcast", "Manager"),
        concat!("public", "_json", "_rpc"),
        concat!("rpc", "::"),
        concat!("rpc", ".read"),
        concat!("rpc", ".write"),
        concat!("/", "ws"),
    ];

    for root in [
        crate_root.join("src/app"),
        crate_root.join("src/transport"),
        crate_root.join("src/engine"),
        repo_root.join("README.md"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in forbidden {
                assert!(
                    !content.contains(needle),
                    "{} contains removed transport marker `{needle}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }
}

#[test]
fn capability_registry_authority_stays_deleted() {
    let crate_root = crate_root();
    let repo_root = repo_root();

    for removed in [
        ["src/tool", "_factory.rs"].concat(),
        "src/domains/capability_support/implementations/registry.rs".to_string(),
    ] {
        assert!(
            !crate_root.join(&removed).exists(),
            "{removed} must stay deleted; provider capabilities are capability primitives over domain-owned workers"
        );
    }

    let forbidden = [
        ["ModelCapability", "Registry"].concat(),
        ["ModelCapability", "Registry", "Config"].concat(),
        ["create_tool", "_registry"].concat(),
        ["tool", "_factory"].concat(),
        "registry.names()".to_string(),
        "registry.definitions()".to_string(),
        "registry-driven".to_string(),
    ];
    for root in [
        crate_root.join("src/main.rs"),
        crate_root.join("src/main_cli.rs"),
        crate_root.join("src/main_runtime.rs"),
        crate_root.join("src/domains/agent/runner"),
        crate_root.join("src/app"),
        crate_root.join("src/domains/capability_support"),
        repo_root.join("README.md"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in &forbidden {
                assert!(
                    !content.contains(needle),
                    "{} must not reintroduce deleted capability registry authority `{needle}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }

    assert!(
        !crate_root
            .join(["src/domains/", "tools", "/operations/execution.rs"].concat())
            .exists(),
        "legacy capability invocation handler must stay deleted"
    );
    let capability_executor_source = std::fs::read_to_string(
        crate_root.join("src/domains/agent/runner/agent/capability_invocation_executor.rs"),
    )
    .expect("failed to read agent capability executor");
    let capability_contract_source =
        std::fs::read_to_string(crate_root.join("src/domains/capability/contract.rs"))
            .expect("failed to read capability contract");
    assert!(
        capability_contract_source.contains("\"modelPrimitiveName\": \"execute\"")
            && !capability_contract_source.contains("\"modelPrimitiveName\": \"search\"")
            && !capability_contract_source.contains("\"modelPrimitiveName\": \"inspect\""),
        "provider metadata must expose only the single model-facing execute primitive"
    );
    let program_runtime_source =
        std::fs::read_to_string(crate_root.join("src/domains/program/runtime.rs"))
            .expect("failed to read program runtime");
    let program_protocol_source =
        std::fs::read_to_string(crate_root.join("src/domains/program/protocol.rs"))
            .expect("failed to read program protocol");
    for (label, content) in [
        ("program runtime", program_runtime_source),
        ("program protocol", program_protocol_source),
    ] {
        for forbidden in [
            "tools.search",
            "tools.inspect",
            "ProgramToolPrimitive::Search",
            "ProgramToolPrimitive::Inspect",
            "WorkerToolPrimitive::Search",
            "WorkerToolPrimitive::Inspect",
            "__tronSearchJson",
            "__tronInspectJson",
        ] {
            assert!(
                !content.contains(forbidden),
                "{label} must keep the internal JavaScript host surface execute-only; found `{forbidden}`"
            );
        }
    }
    for prompt_path in [
        "defaults/profiles/default/prompts/core.md",
        "defaults/profiles/default/prompts/chat.md",
        "defaults/profiles/default/prompts/local.md",
        "defaults/profiles/default/prompts/git-workflow.md",
        "defaults/profiles/default/prompts/processes/conflict-resolver.md",
    ] {
        let prompt = std::fs::read_to_string(crate_root.join(prompt_path))
            .unwrap_or_else(|e| panic!("failed to read {prompt_path}: {e}"));
        let has_retired_primitive_text = prompt.contains("exactly three model-facing primitives")
            || prompt.contains("search`, `inspect`, and `execute")
            || prompt.contains("search`, `inspect`, and\n`execute");
        let has_single_execute_text = prompt.contains("one model-facing primitive")
            || prompt.contains("model-facing primitive is `execute`")
            || prompt.contains("`execute` target `process::run`");
        assert!(
            !has_retired_primitive_text && has_single_execute_text,
            "{prompt_path} must teach the single execute primitive"
        );
        for retired_prompt_shape in [
            "search.queries",
            "inspect.targets",
            "Discover filesystem read/write/edit implementations with `search`",
            "inspect first",
            "Search capabilities search file contents",
            "Search for process/job capabilities",
            "Use the inspected `process::run` capability",
        ] {
            assert!(
                !prompt.contains(retired_prompt_shape),
                "{prompt_path} must not teach retired model-facing capability choreography: {retired_prompt_shape}"
            );
        }
    }
    let core_prompt =
        std::fs::read_to_string(crate_root.join("defaults/profiles/default/prompts/core.md"))
            .expect("failed to read core prompt");
    for guidance in [
        "`execute` is intent-first",
        "Do not invent a target",
        "retry the same selected target",
        "Put only target capability fields inside `arguments`",
    ] {
        assert!(
            core_prompt.contains(guidance),
            "core prompt must keep intent-first execute guidance: {guidance}"
        );
    }
    for guidance in [
        "Intent-first portal",
        "Start with natural-language intent alone",
        "never invent targets",
        "needs_input",
    ] {
        assert!(
            capability_contract_source.contains(guidance),
            "model metadata must keep intent-first execute guidance: {guidance}"
        );
    }
    let openai_converter = std::fs::read_to_string(
        crate_root.join("src/domains/model/providers/openai/message_converter.rs"),
    )
    .expect("failed to read OpenAI message converter");
    for guidance in [
        "It is intent-first",
        "Do not invent a",
        "only target capability arguments inside `arguments`",
        "When `execute` returns `needs_input`",
    ] {
        assert!(
            openai_converter.contains(guidance),
            "OpenAI provider clarification must keep execute guidance: {guidance}"
        );
    }
    for retired_runtime_term in [
        concat!("Tool", "Context"),
        concat!("capability", "_runtime"),
        concat!("Tron", "Tool"),
    ] {
        assert!(
            !capability_executor_source.contains(retired_runtime_term),
            "agent capability executor must not reintroduce the retired runtime path"
        );
    }
}

#[test]
fn capability_registry_ownership_stays_split() {
    let crate_root = crate_root();
    let registry_mod =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/mod.rs"))
            .expect("read capability registry root");
    let index =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/index.rs"))
            .expect("read capability registry index module");
    let primer =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/primer.rs"))
            .expect("read capability registry primer module");
    let recipes =
        std::fs::read_to_string(crate_root.join("src/domains/capability/registry/recipes.rs"))
            .expect("read capability registry recipes module");

    for required in [
        "mod index;",
        "mod primer;",
        "mod recipes;",
        "| `index` | Document identity, lexical ranking",
        "| `primer` | Context-primer policy",
        "| `recipes` | Capability recipe authoring",
    ] {
        assert!(
            registry_mod.contains(required),
            "registry root must document and declare ownership marker `{required}`"
        );
    }
    for forbidden in [
        "pub(crate) struct HybridLocalCapabilityIndex",
        "fn lexical_rank(",
        "fn vector_rank_with_provider(",
        "fn render_capability_primer(",
        "pub(crate) struct CapabilityContextPrimerPolicy",
        "fn recipe_payload_fields(",
    ] {
        assert!(
            !registry_mod.contains(forbidden),
            "registry root must not re-own split registry concern `{forbidden}`"
        );
    }
    for required in [
        "pub(crate) struct HybridLocalCapabilityIndex",
        "pub(super) fn search_sqlite_documents(",
        "pub(super) fn document_text_hash(",
        "pub(super) fn lexical_rank(",
        "fn vector_rank_with_provider(",
        "fn sqlite_vec_rank(",
        "pub(super) fn trust_rank(",
    ] {
        assert!(
            index.contains(required),
            "registry/index.rs must own search/index marker `{required}`"
        );
    }
    for required in [
        "pub(crate) struct CapabilityContextPrimerPolicy",
        "impl CapabilityRegistrySnapshot",
        "pub(crate) fn render_capability_primer(",
        "rendered_entries > 0",
        "CORE_CONTEXT_CAPABILITIES",
    ] {
        assert!(
            primer.contains(required),
            "registry/primer.rs must own primer marker `{required}`"
        );
    }
    for required in [
        "pub(super) fn agent_recipe_for_entry(",
        "fn recipe_payload_fields(",
        "fn recipe_execute_template(",
    ] {
        assert!(
            recipes.contains(required),
            "registry/recipes.rs must own recipe marker `{required}`"
        );
    }
}

#[test]
fn modular_substrate_has_no_raw_scope_or_worker_token_authority_fallbacks() {
    let crate_root = crate_root();
    let policy = std::fs::read_to_string(crate_root.join("src/engine/policy.rs"))
        .expect("failed to read engine policy");
    assert!(
        !policy.contains("required_authority.scopes") && !policy.contains("has_scope(scope)"),
        "engine invocation policy must not authorize from caller-supplied raw scope strings"
    );

    for root in [
        crate_root.join("src/engine"),
        crate_root.join("src/domains/sandbox"),
    ] {
        for path in rust_files_under(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("authorityCeiling") && !content.contains("authority_ceiling"),
                "{} must use grant identity/resource selectors, not token-owned authority lists",
                path.strip_prefix(&crate_root).unwrap_or(&path).display()
            );
        }
    }
}

#[test]
fn modular_engine_storage_generation_is_clean_break() {
    let storage = std::fs::read_to_string(crate_root().join("src/shared/storage.rs"))
        .expect("failed to read shared storage");
    let archive = std::fs::read_to_string(crate_root().join("src/shared/storage/archive.rs"))
        .expect("failed to read shared storage archive policy");
    assert!(
        storage.contains("CURRENT_STORAGE_GENERATION: &str = \"modular-engine-v4\""),
        "storage generation must stay on the retired notification-read-state clean-break generation"
    );
    assert!(
        storage.contains("prepare_active_database(&self.path)")
            && archive.contains("archive_incompatible_active_database(active_db_path)?"),
        "startup must archive incompatible active DB files before opening current schema"
    );
}

#[test]
fn notification_resource_truth_boundary_stays_enforced() {
    let root = crate_root();
    let notification_contract =
        std::fs::read_to_string(root.join("src/domains/notifications/contract.rs"))
            .expect("read notifications contract");
    assert!(
        notification_contract.contains("DurableOutputContract::resource_backed")
            && notification_contract.contains("notification")
            && notification_contract.contains("evidence")
            && notification_contract.contains("decisionRefs")
            && notification_contract.contains("resourceRefs"),
        "notification mutating capabilities must keep resource/evidence/decision-backed contracts"
    );

    let notification_deps = std::fs::read_to_string(root.join("src/domains/notifications/deps.rs"))
        .expect("read notifications deps");
    assert!(
        notification_deps.contains("engine_host: crate::engine::EngineHostHandle")
            && !notification_deps.contains("event_store"),
        "notifications durable truth must compose resource capabilities through the engine host"
    );

    let inbox = std::fs::read_to_string(root.join("src/domains/notifications/inbox.rs"))
        .expect("read notification inbox");
    for required in [
        "notification:",
        "notification_read",
        "notification_mark_all_read",
        "notification_delivery",
        "resource::create",
        "resource::update",
        "evidence::attach",
        "decision::create",
        "resource::link",
        "affects_notification",
        "linked_notification_targets",
    ] {
        assert!(
            inbox.contains(required),
            "notification inbox resource boundary must contain `{required}`"
        );
    }
    for forbidden in [
        "notification_read_state",
        "PooledConnection",
        "rusqlite",
        "FROM events",
        "JOIN sessions",
        "json_extract",
    ] {
        assert!(
            !inbox.contains(forbidden),
            "notification inbox must not reconstruct source truth through `{forbidden}`"
        );
    }

    let schema = std::fs::read_to_string(
        root.join("src/domains/session/event_store/sqlite/migrations/v001_schema.sql"),
    )
    .expect("read consolidated schema");
    assert!(
        !schema.contains("notification_read_state"),
        "fresh current schema must not create retired notification_read_state"
    );

    let ui = std::fs::read_to_string(root.join("src/engine/primitives/ui.rs"))
        .expect("read ui primitive");
    let ui_authoring = read_generated_ui_authoring_tree(&root);
    let ui_tree = [ui.as_str(), ui_authoring.as_str()].join("\n");
    for required in [
        "NOTIFICATION_INBOX_LAYOUT_PROFILE",
        "notifications.inbox.v1",
        "notifications::mark_read",
        "notifications::mark_all_read",
        "resource_collection target notification",
    ] {
        assert!(
            ui_tree.contains(required),
            "generated UI must keep notification inbox surface/action support `{required}`"
        );
    }

    let engine_tests =
        std::fs::read_to_string(root.join("src/engine/tests/mod.rs")).expect("read engine tests");
    let notification_tests =
        std::fs::read_to_string(root.join("src/engine/tests/notification_resources.rs"))
            .expect("read notification resource tests");
    assert!(
        engine_tests.contains("mod notification_resources;")
            && notification_tests.contains("notifications_send_list_and_read_are_resource_backed")
            && notification_tests
                .contains("notification_list_ignores_unregistered_event_only_rows")
            && notification_tests.contains("notification_read_state_requires_decision_linkage")
            && notification_tests
                .contains("notification_generated_inbox_surface_uses_stored_canonical_actions"),
        "notification resource tests must stay in their focused engine ownership boundary"
    );
}

#[test]
fn subagent_lineage_resource_truth_boundary_stays_enforced() {
    let root = crate_root();
    let repo = repo_root();

    let lineage = std::fs::read_to_string(root.join("src/domains/agent/lineage.rs"))
        .expect("read agent lineage helpers");
    assert!(
        lineage.contains("agent_result:subagent:")
            && lineage.contains("subagent_result_resource_id"),
        "subagent completed-output truth must keep deterministic agent_result resource ids"
    );

    let execution = std::fs::read_to_string(
        root.join("src/domains/agent/runner/orchestrator/subagent_manager/execution.rs"),
    )
    .expect("read subagent execution");
    assert!(
        execution.contains("subagent_result_resource_id(child_session_id)")
            && execution.contains("\"resourceId\"")
            && execution.contains("\"lifecycle\": \"final\""),
        "subagent completion must persist deterministic final agent_result resources"
    );

    let submissions =
        std::fs::read_to_string(root.join("src/domains/agent/operations/submissions.rs"))
            .expect("read agent submissions");
    for required in [
        "subagent_result_resource(",
        "resource::inspect",
        "ENGINE_INTERNAL_INVOKE_SCOPE",
        "parentSessionId",
        "subagentSessionId",
        "/scope/session",
        "\"resourceRefs\"",
        "\"resultResource\"",
        "SUBAGENT_RESULT_NOT_READY",
    ] {
        assert!(
            submissions.contains(required),
            "subagent status/result operations must keep resource-backed lineage marker `{required}`"
        );
    }

    let ui = std::fs::read_to_string(root.join("src/engine/primitives/ui.rs"))
        .expect("read generated UI primitive");
    let ui_authoring = read_generated_ui_authoring_tree(&root);
    let ui_tree = [ui.as_str(), ui_authoring.as_str()].join("\n");
    for required in [
        "SUBAGENT_COLLECTION_TARGET",
        "agent_result:subagent",
        "subagent.lineage.v1",
        "subagent_collection_projection",
        "subagent_collection_actions",
        "context_session_id",
        "EngineResourceScope::Session",
        "agent::subagent_status",
        "agent::subagent_result",
        "agent::cancel_subagent",
    ] {
        assert!(
            ui_tree.contains(required),
            "generated UI must keep subagent lineage surface/action support `{required}`"
        );
    }

    let engine_tests =
        std::fs::read_to_string(root.join("src/engine/tests/mod.rs")).expect("read engine tests");
    let lineage_tests = std::fs::read_to_string(root.join("src/engine/tests/subagent_lineage.rs"))
        .expect("read subagent lineage tests");
    assert!(
        engine_tests.contains("mod subagent_lineage;")
            && lineage_tests
                .contains("subagent_result_and_status_read_resource_truth_without_live_manager")
            && lineage_tests.contains(
                "generated_subagent_lineage_surface_uses_resource_truth_and_stored_actions"
            )
            && lineage_tests
                .contains("malformed_or_cross_session_subagent_resources_are_not_lineage_truth"),
        "subagent lineage tests must stay in the focused engine ownership boundary"
    );

    for rel in [
        "packages/ios-app/Sources/Views/Subagents/SubagentChip.swift",
        "packages/ios-app/Sources/Views/Subagents/SubagentDetailSheet.swift",
        "packages/ios-app/Sources/Views/Subagents/SubagentResultNotificationView.swift",
        "packages/ios-app/Sources/Views/Subagents/SubagentResultsListSheet.swift",
        "packages/ios-app/Sources/Views/Subagents/SubagentStatBadge.swift",
        "packages/ios-app/Sources/ViewModels/State/SubagentState.swift",
        "packages/ios-app/Sources/ViewModels/Chat/ChatViewModel+SubagentEvents.swift",
    ] {
        let content = std::fs::read_to_string(repo.join(rel))
            .unwrap_or_else(|error| panic!("failed to read {rel}: {error}"));
        for forbidden in [
            "targetFunctionId",
            "payloadTemplate",
            "requiredGrant",
            "UiActionSubmissionDTO",
            "agent::subagent_status",
            "agent::subagent_result",
            "agent::cancel_subagent",
        ] {
            assert!(
                !content.contains(forbidden),
                "{rel} must remain a thin subagent renderer and not construct generated UI action or capability policy `{forbidden}`"
            );
        }
    }

    let generated_ui_tests =
        std::fs::read_to_string(root.join("src/engine/tests/subagent_lineage.rs"))
            .expect("read subagent lineage tests");
    assert!(
        generated_ui_tests.contains("subagent.lineage.v1")
            && generated_ui_tests.contains(
                "generated_subagent_lineage_surface_uses_resource_truth_and_stored_actions"
            ),
        "subagent lineage generated surface proof must live with subagent lineage tests"
    );
}

#[test]
fn cron_schedule_truth_boundary_stays_resource_backed() {
    let root = crate_root();
    let repo = repo_root();

    let contract = std::fs::read_to_string(root.join("src/domains/cron/contract.rs"))
        .expect("read cron contract");
    for required in [
        "DurableOutputContract::resource_backed([\"decision\"])",
        "cron::create",
        "cron::update",
        "cron::delete",
        "resourceRefs",
    ] {
        assert!(
            contract.contains(required),
            "cron contract must keep decision-backed output marker `{required}`"
        );
    }

    let truth =
        std::fs::read_to_string(root.join("src/domains/cron/implementation/domain/truth.rs"))
            .expect("read cron truth boundary");
    for required in [
        "CRON_SCHEDULE_DECISION_TYPE",
        "CRON_RUN_EVIDENCE_TYPE",
        "decision:cron-schedule:",
        "evidence:cron-run:",
        "decision::create",
        "evidence::attach",
        "resource::update",
        "set_schedule_enabled",
    ] {
        assert!(
            truth.contains(required),
            "cron truth boundary must keep resource-backed marker `{required}`"
        );
    }

    let jobs = std::fs::read_to_string(root.join("src/domains/cron/operations/jobs.rs"))
        .expect("read cron job operations");
    for required in [
        "truth::list_schedule_records",
        "truth::create_schedule_decision",
        "truth::update_schedule_decision",
        "truth::archive_schedule_decision",
    ] {
        assert!(
            jobs.contains(required),
            "cron job operations must compose schedule truth through `{required}`"
        );
    }
    for forbidden in [
        "config::load_config",
        "config::save_config",
        "automations.json",
    ] {
        assert!(
            !jobs.contains(forbidden),
            "cron job operations must not use legacy file truth `{forbidden}`"
        );
    }

    let runs = std::fs::read_to_string(root.join("src/domains/cron/operations/runs.rs"))
        .expect("read cron run operations");
    assert!(
        runs.contains("truth::list_run_evidence")
            && runs.contains("truth::inspect_schedule_record")
            && !runs.contains("store::get_runs"),
        "cron run operations must bind from decision/evidence truth, not the runtime cache"
    );

    let callbacks = std::fs::read_to_string(root.join("src/domains/cron/callbacks.rs"))
        .expect("read cron callbacks");
    assert!(
        callbacks.contains("truth::attach_run_evidence")
            && callbacks.contains("truth::set_schedule_enabled"),
        "cron callbacks must persist run evidence and lifecycle flips through resource truth"
    );

    let scheduler =
        std::fs::read_to_string(root.join("src/domains/cron/implementation/runtime/scheduler.rs"))
            .expect("read cron scheduler");
    assert!(
        scheduler.contains("load_schedule_truth")
            && scheduler.contains("truth::list_schedule_records")
            && scheduler.contains("sync_job_cache")
            && scheduler.contains("truth::set_schedule_enabled"),
        "cron scheduler must derive from decision truth and keep cache lifecycle flips synchronized"
    );
    assert!(
        !scheduler.contains("config::load_config")
            && !scheduler.contains("config::save_config")
            && !scheduler.contains("automations.json")
            && !scheduler.contains("config_path")
            && !scheduler.contains("backup_path"),
        "cron scheduler must not retain file-backed schedule truth or fixture paths"
    );

    let config =
        std::fs::read_to_string(root.join("src/domains/cron/implementation/domain/config.rs"))
            .expect("read cron config helpers");
    assert!(
        !config.contains("load_config")
            && !config.contains("save_config")
            && !config.contains("automations.json")
            && config.contains("pub fn validate_job"),
        "cron config boundary must be validation-only; schedule truth is decision resources"
    );

    let engine_tests =
        std::fs::read_to_string(root.join("src/engine/tests/mod.rs")).expect("read engine tests");
    let cron_tests = std::fs::read_to_string(root.join("src/engine/tests/cron_resources.rs"))
        .expect("read cron resource tests");
    assert!(
        engine_tests.contains("mod cron_resources;")
            && cron_tests.contains("cron_create_update_delete_are_decision_backed")
            && cron_tests.contains("cron_get_runs_reads_evidence_truth")
            && cron_tests
                .contains("cron_runtime_lifecycle_flip_updates_decision_truth_idempotently")
            && cron_tests.contains("cron_runtime_cache_rows_are_not_product_truth")
            && cron_tests.contains("cron_run_rehydrates_runtime_cache_from_decision_truth")
            && cron_tests.contains("cron_run_rejects_disabled_schedule_decision"),
        "cron resource tests must stay in their focused engine ownership boundary"
    );

    let readme = std::fs::read_to_string(repo.join("README.md")).expect("read README");
    assert!(
        readme.contains("decision resources")
            && readme.contains("evidence resources")
            && readme.contains("scheduler runtime cache"),
        "README must classify cron decisions/evidence as truth and cron tables as cache"
    );
}

#[test]
fn resource_materialization_enforcement_gates_stay_on() {
    let crate_root = crate_root();
    for path in rust_files_under(&crate_root.join("src/engine")) {
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with("tests.rs"))
        {
            continue;
        }
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        assert!(
            !content.contains("engine_output_audit_observations")
                && !content.contains("EngineOutputAudit")
                && !content.contains("output_audit"),
            "{} must not keep output-audit as an active runtime acceptance path",
            path.strip_prefix(&crate_root).unwrap_or(&path).display()
        );
    }

    let process_contract =
        std::fs::read_to_string(crate_root.join("src/domains/process/contract.rs"))
            .expect("failed to read process contract");
    let capability_contract_source =
        std::fs::read_to_string(crate_root.join("src/domains/capability/contract.rs"))
            .expect("failed to read capability contract");
    assert!(
        process_contract.contains("\"required\": [\"command\", \"executionMode\"]"),
        "process::run must require executionMode so write-like commands cannot default to direct execution"
    );
    assert!(
        process_contract.contains("\"executionMode\": \"read_only\""),
        "process::run examples must not teach the retired no-executionMode request shape"
    );
    assert!(
        capability_contract_source
            .contains(r#"{\"command\":\"date\",\"executionMode\":\"read_only\"}"#)
            && capability_contract_source.contains("arguments")
            && !capability_contract_source.contains(r#"{\"command\":\"date\"} for process::run"#),
        "capability::execute model schema must teach complete target argument requirements"
    );
    assert!(
        capability_contract_source
            .contains("Do not call separate search, inspect, or approval::request tools")
            && capability_contract_source.contains("Start with natural-language intent alone")
            && capability_contract_source.contains("provide target only when")
            && capability_contract_source.contains("mutating or elevated-risk work still pauses")
            && capability_contract_source.contains("payload_to_arguments"),
        "capability::execute must define one-tool orchestration, correction, and approval semantics"
    );
    let openai_message_converter = std::fs::read_to_string(
        crate_root.join("src/domains/model/providers/openai/message_converter.rs"),
    )
    .expect("failed to read OpenAI message converter");
    assert!(
        openai_message_converter.contains("exact contract id and arguments")
            && openai_message_converter.contains("call that exact target once")
            && openai_message_converter
                .contains("do not run warm-up, probe, date, status, or example commands first")
            && openai_message_converter.contains("examples are templates only"),
        "model provider capability clarification must forbid exploratory example/probe calls"
    );
    assert!(
        process_contract.contains("process_resource_output_required")
            && process_contract.contains("materialized_file")
            && process_contract.contains("execution_output"),
        "process::run must keep conditional resource-backed output enforcement"
    );
    let process_worker = std::fs::read_to_string(crate_root.join("src/domains/process/mod.rs"))
        .expect("failed to read process worker");
    let process_tests = std::fs::read_to_string(crate_root.join("src/domains/process/tests.rs"))
        .expect("failed to read process worker tests");
    let process_bounds = std::fs::read_to_string(crate_root.join("src/domains/process/bounds.rs"))
        .expect("failed to read process boundary validation");
    let process_approval =
        std::fs::read_to_string(crate_root.join("src/domains/process/approval.rs"))
            .expect("failed to read process approval policy");
    assert!(
        process_worker
            .contains("approval::validate_run_payload_before_approval(&invocation.payload)")
            && process_approval.contains("validate_run_payload_before_approval")
            && process_approval.contains("run_requires_approval(payload)")
            && process_approval.contains("proven low-risk"),
        "process::run read_only execution must use the strict low-risk classifier, not a write-like blacklist"
    );
    assert!(
        process_worker.contains("validate_read_only_process_boundaries")
            && process_worker.contains("mod bounds")
            && process_bounds.contains("require_active_session_root")
            && process_bounds.contains("active_session_root")
            && process_bounds.contains("bounded_process_path")
            && process_bounds.contains("uses shell glob or brace expansion")
            && process_worker.contains(".env_clear()")
            && process_bounds.contains("safe_process_environment")
            && process_tests.contains("process_run_requires_active_session_worktree")
            && process_tests.contains("read_only_process_rejects_paths_outside_session_worktree")
            && process_tests
                .contains("read_only_process_rejects_symlink_operands_that_escape_worktree")
            && process_tests.contains("read_only_process_rejects_shell_glob_path_operands")
            && process_tests.contains(
                "sandbox_materialized_absolute_target_path_cannot_escape_session_worktree"
            ),
        "process::run must keep model-facing cwd/path/symlink/output target bounds and must not inherit the server environment"
    );
    assert!(
        process_approval.contains("validate_sandbox_command_write_targets")
            && process_approval.contains(
                "sandbox_materialized_home_relative_command_write_is_invalid_before_approval"
            )
            && process_worker.contains("prepare_sandbox_expected_output_dirs")
            && process_tests
                .contains("sandbox_materialized_nested_output_parent_is_prepared_inside_sandbox")
            && process_tests
                .contains("sandbox_materialized_home_relative_command_write_rejects_before_spawn"),
        "process::run sandbox materialization must reject undeclared/home/absolute command write targets before approval and prepare declared output parents inside the sandbox"
    );
    let capability_operations =
        std::fs::read_to_string(crate_root.join("src/domains/capability/operations/mod.rs"))
            .expect("failed to read capability operations");
    let capability_execute =
        std::fs::read_to_string(crate_root.join("src/domains/capability/operations/execute.rs"))
            .expect("failed to read capability execute operations");
    let capability_target_arguments = std::fs::read_to_string(
        crate_root.join("src/domains/capability/operations/target_arguments.rs"),
    )
    .expect("failed to read capability target argument operations");
    let capability_target_resolution = std::fs::read_to_string(
        crate_root.join("src/domains/capability/operations/target_resolution.rs"),
    )
    .expect("failed to read capability target resolution operations");
    let capability_run =
        std::fs::read_to_string(crate_root.join("src/domains/capability/operations/run.rs"))
            .expect("failed to read capability run operations");
    let capability_execute_tree = [
        capability_operations.as_str(),
        capability_execute.as_str(),
        capability_run.as_str(),
    ]
    .join("\n");
    assert!(
        capability_execute_tree.contains("preflight_rejection_result")
            && capability_execute_tree.contains("\"childInvocationCreated\": false")
            && capability_execute_tree.contains("\"approvalCreated\": false")
            && capability_execute_tree.contains("\"resourceRefs\": []")
            && capability_execute_tree
                .contains("validate_target_policy_before_approval(&function, &payload)")
            && capability_execute_tree.contains("validate_target_payload(&target.entry, &payload)"),
        "capability::execute target preflight rejections must return structured isError results without child invocations, approvals, or resource refs"
    );
    assert!(
        !capability_operations.contains("async fn execute_invoke_value")
            && !capability_operations.contains("async fn execute_program_value")
            && !capability_operations.contains("fn preflight_rejection_result"),
        "capability operations parent must not regain child execution, program execution, or preflight projection bodies"
    );
    for forbidden in [
        "fn normalize_intent_target_arguments",
        "fn normalize_contextual_target_arguments",
        "fn normalize_target_specific_arguments",
        "fn normalize_process_run_arguments",
        "fn normalize_filesystem_list_dir_arguments",
        "fn normalize_web_search_arguments",
        "fn normalize_filesystem_apply_patch_arguments",
        "fn normalize_process_expected_output_aliases",
        "fn intent_file_read_requests",
        "fn intent_resource_kind_requests",
        "fn intent_requests_worktree_diff",
    ] {
        assert!(
            !capability_execute.contains(forbidden),
            "target-specific execute affordance `{forbidden}` must stay in target_arguments.rs, not execute.rs"
        );
        assert!(
            capability_target_arguments.contains(forbidden),
            "target_arguments.rs must own target-specific execute affordance `{forbidden}`"
        );
    }
    for required in [
        "# INVARIANT: target-specific normalization stays classified",
        "\"process::run\"",
        "\"filesystem::list_dir\"",
        "\"web::search\"",
        "\"filesystem::apply_patch\"",
        "\"filesystem::read_file\"",
        "\"resource::list\"",
        "\"worktree::is_git_repo\"",
    ] {
        assert!(
            capability_target_arguments.contains(required),
            "target_arguments.rs must document and own classified target-specific execute affordance marker `{required}`"
        );
    }
    for forbidden in [
        "pub(super) fn deterministic_intent_route(",
        "pub(super) fn clarification_candidates_for_intent(",
        "pub(super) fn apply_argument_schema_fit_filter(",
        "pub(super) fn promote_argument_schema_fit_candidates(",
        "pub(super) fn validate_orchestration_constraints(",
        "pub(super) fn orchestration_constraints_allow_hit(",
        "pub(super) fn intent_strongly_matches_hit(",
        "pub(super) fn lacks_sufficient_intent_resolution_evidence(",
        "pub(super) fn decomposition_phase_details(",
        "pub(super) fn decomposition_result_message(",
    ] {
        assert!(
            !capability_execute.contains(forbidden),
            "target-resolution execute helper `{forbidden}` must stay in target_resolution.rs, not execute.rs"
        );
        assert!(
            capability_target_resolution.contains(forbidden),
            "target_resolution.rs must own target-resolution execute helper `{forbidden}`"
        );
    }
    for required in [
        "# INVARIANT: target resolution heuristics stay classified",
        "deterministic_worktree_diff",
        "deterministic_resource_inventory",
        "namespace_clarification",
        "argument_schema_fit",
        "multiple_resource_kinds_for_single_inventory_request",
        "multiple_files_for_single_target",
        "MIN_UNANCHORED_INTENT_SCORE",
    ] {
        assert!(
            capability_target_resolution.contains(required),
            "target_resolution.rs must document and own classified target-resolution marker `{required}`"
        );
    }

    let filesystem_contract =
        std::fs::read_to_string(crate_root.join("src/domains/filesystem/contract.rs"))
            .expect("failed to read filesystem contract");
    for function in [
        "filesystem::create_dir",
        "filesystem::write_file",
        "filesystem::edit_file",
        "filesystem::apply_patch",
    ] {
        assert!(
            filesystem_contract.contains(function),
            "filesystem contract must still expose {function}"
        );
    }
    assert!(
        filesystem_contract.contains("DurableOutputContract::resource_backed")
            && filesystem_contract.contains("materialized_file")
            && filesystem_contract.contains("patch_proposal"),
        "filesystem mutating writes must remain resource-backed"
    );

    let program_contract =
        std::fs::read_to_string(crate_root.join("src/domains/program/contract.rs"))
            .expect("failed to read program contract");
    assert!(
        !program_contract.contains("\"artifacts\""),
        "program::run_javascript contract must not reintroduce loose artifacts"
    );
    assert!(
        program_contract.contains("execution_output") && program_contract.contains("resourceRefs"),
        "program::run_javascript must publish retained output through execution_output resource refs"
    );

    let host = std::fs::read_to_string(crate_root.join("src/engine/host.rs"))
        .expect("failed to read engine host");
    for retired_audit_acceptance in [
        "program_artifact_without_resource",
        "agent_output_without_promoted_resource",
    ] {
        assert!(
            !host.contains(retired_audit_acceptance),
            "engine host must not accept {retired_audit_acceptance} as an audit-only output path"
        );
    }
}

#[test]
fn resource_native_orchestration_and_control_plane_gates_stay_on() {
    let crate_root = crate_root();

    let sandbox_contract =
        std::fs::read_to_string(crate_root.join("src/domains/sandbox/contract.rs"))
            .expect("failed to read sandbox contract");
    assert!(
        sandbox_contract.contains("worker::spawn")
            && !sandbox_contract.contains("sandbox::spawn_worker"),
        "worker creation must be exposed only through canonical worker::spawn"
    );

    let worker_guide = std::fs::read_to_string(crate_root.join("src/engine/primitives/worker.rs"))
        .expect("failed to read worker primitive contracts");
    assert!(
        worker_guide.contains("worker::spawn") && !worker_guide.contains("sandbox::spawn_worker"),
        "worker protocol guidance must teach worker::spawn, not sandbox::spawn_worker"
    );

    let resource = std::fs::read_to_string(crate_root.join("src/engine/primitives/resource.rs"))
        .expect("failed to read resource primitive contracts");
    for required in [
        "goal::working_set",
        "artifact::split",
        "artifact::compose",
        "artifact::merge",
        "artifact::search",
    ] {
        assert!(
            resource.contains(required),
            "resource primitive worker must expose `{required}` for goal working sets and artifact curation"
        );
    }
    let resource_wrapper = resource
        .split("fn resource_wrapper_function")
        .nth(1)
        .expect("resource primitive must keep resource_wrapper_function");
    assert!(
        resource_wrapper
            .contains(".with_idempotency(IdempotencyContract::caller_system_engine_ledger())"),
        "resource wrapper writes must stay system-idempotent for sessionless resource-backed domains"
    );

    let agent_contract = std::fs::read_to_string(crate_root.join("src/domains/agent/contract.rs"))
        .expect("failed to read agent contract");
    assert!(
        agent_contract.contains("agent::run_goal"),
        "agent::run_goal must be the canonical goal-run coordinator capability"
    );

    for path in rust_files_under(&crate_root.join("src/domains/agent")) {
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with("_tests.rs"))
        {
            continue;
        }
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        assert!(
            !content.contains("EventType::NotificationSubagentResult")
                && !content.contains("notification.subagent_result")
                && !content.contains("get_pending_subagent_results")
                && !content.contains("format_subagent_results"),
            "{} must not use notification markdown blobs as the durable subagent result path",
            path.strip_prefix(&crate_root).unwrap_or(&path).display()
        );
    }

    let control_contract = crate_root.join("src/engine/primitives/control.rs");
    assert!(
        control_contract.exists(),
        "control worker primitive contracts must live under engine/primitives/control.rs"
    );
    let control =
        std::fs::read_to_string(&control_contract).expect("failed to read control primitive");
    assert!(
        control.contains("control::snapshot")
            && control.contains("control::inspect")
            && !control.contains("control::act"),
        "control plane must be read/projection-only; mutations must remain canonical capabilities"
    );
}

#[test]
fn bounded_resource_projection_summaries_stay_canonical() {
    let crate_root = crate_root();

    let domains_mod =
        std::fs::read_to_string(crate_root.join("src/domains/mod.rs")).expect("read domains mod");
    let projection = std::fs::read_to_string(crate_root.join("src/domains/resource_projection.rs"))
        .expect("read domain resource projection helper");
    assert!(
        domains_mod.contains("pub(crate) mod resource_projection;")
            && projection.contains("MAX_RESOURCE_COLLECTION_LIMIT: usize = 500")
            && projection.contains("current_payloads_by_prefix")
            && projection.contains("resource_ids_by_prefix")
            && projection.contains("limit.clamp(1, MAX_RESOURCE_COLLECTION_LIMIT)")
            && projection.contains("\"resource::list\"")
            && projection.contains("\"resource::inspect\""),
        "domain resource collection summaries must stay on the bounded resource projection helper"
    );

    for (label, rel) in [
        ("prompt_library", "src/domains/prompt_library/mod.rs"),
        ("voice_notes", "src/domains/voice_notes/mod.rs"),
    ] {
        let content = std::fs::read_to_string(crate_root.join(rel))
            .unwrap_or_else(|error| panic!("failed to read {rel}: {error}"));
        assert!(
            content.contains("current_payloads_by_prefix")
                && content.contains("ResourceCollectionQuery")
                && content.contains("MAX_RESOURCE_COLLECTION_LIMIT")
                && !content.contains("\"limit\": 10_000")
                && !content.contains("limit: 10_000"),
            "{label} resource collection projection must stay bounded through domains/resource_projection.rs"
        );
    }

    let generated_ui = std::fs::read_to_string(crate_root.join("src/engine/primitives/ui.rs"))
        .expect("read generated UI primitive");
    let generated_ui_authoring = read_generated_ui_authoring_tree(&crate_root);
    assert!(
        generated_ui.contains("RESOURCE_COLLECTION_SCAN_LIMIT: usize = 500")
            && generated_ui_authoring.contains("current_resource_payloads_by_prefix")
            && generated_ui_authoring.contains("limit: RESOURCE_COLLECTION_SCAN_LIMIT")
            && !generated_ui_authoring.contains("limit: 10_000"),
        "generated UI resource collection authoring must use its bounded primitive-host projection helper"
    );

    let control = std::fs::read_to_string(crate_root.join("src/engine/primitives/control.rs"))
        .expect("read control primitive");
    assert!(
        control.contains("limit.clamp(1, 500)") && control.contains("limit: 500"),
        "control projections must keep bounded resource access"
    );

    let module_trust_audit =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/module/trust_audit.rs"))
            .expect("failed to read module trust audit");
    let module_source_trust = read_module_source_trust_tree(&crate_root);
    for (label, content) in [
        ("trust_audit", module_trust_audit.as_str()),
        ("source_trust", module_source_trust.as_str()),
    ] {
        assert!(
            content.contains("list_resources(ListResources")
                && content.contains("inspect_resource")
                && content.contains("limit: 500")
                && !content.contains("limit: 10_000"),
            "{label} module trust/audit projections must stay resource-native and bounded"
        );
    }
}

#[test]
fn hidden_side_effect_resource_scans_stay_bounded_and_observable() {
    let crate_root = crate_root();

    for (label, rel, limit_marker, required_markers) in [
        (
            "retained memory context",
            "src/domains/agent/runtime/service/context.rs",
            "RETAINED_MEMORY_CONTEXT_SCAN_LIMIT",
            &[
                "MAX_RESOURCE_COLLECTION_LIMIT",
                "\"resource::list\"",
                "\"resource::inspect\"",
                "artifact:memory-rule:",
                "artifact:memory-argument:",
            ][..],
        ),
        (
            "notification inbox",
            "src/domains/notifications/inbox.rs",
            "NOTIFICATION_TRUTH_SCAN_LIMIT",
            &[
                "MAX_RESOURCE_COLLECTION_LIMIT",
                "\"resource::list\"",
                "\"resource::inspect\"",
                "\"decision::create\"",
                "\"evidence::attach\"",
                "\"resource::link\"",
                "affects_notification",
            ][..],
        ),
        (
            "cron truth",
            "src/domains/cron/implementation/domain/truth.rs",
            "CRON_RESOURCE_TRUTH_SCAN_LIMIT",
            &[
                "MAX_RESOURCE_COLLECTION_LIMIT",
                "\"resource::list\"",
                "\"resource::inspect\"",
                "\"decision::create\"",
                "\"evidence::attach\"",
                "decision:cron-schedule:",
                "evidence:cron-run:",
            ][..],
        ),
    ] {
        let content = std::fs::read_to_string(crate_root.join(rel))
            .unwrap_or_else(|error| panic!("failed to read {rel}: {error}"));
        assert!(
            content.contains(limit_marker),
            "{label} must name its resource scan limit so hidden side-effect ownership stays auditable"
        );
        for marker in required_markers {
            assert!(
                content.contains(marker),
                "{label} must retain observable resource-capability marker `{marker}`"
            );
        }
        assert!(
            !content.contains("\"limit\": 10_000") && !content.contains("limit: 10_000"),
            "{label} must not reintroduce unbounded-looking resource scans"
        );
    }
}

#[test]
fn generated_ui_resource_and_renderer_gates_stay_on() {
    let crate_root = crate_root();
    let repo_root = repo_root();

    let resources = [
        crate_root.join("src/engine/resources/types.rs"),
        crate_root.join("src/engine/resources/definitions.rs"),
        crate_root.join("src/engine/resources/ui_surface.rs"),
    ]
    .into_iter()
    .map(|path| {
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    })
    .collect::<Vec<_>>()
    .join("\n");
    for required in [
        "UI_SURFACE_SCHEMA_ID",
        "tron.resource.ui_surface.v1",
        "tron.ui.catalog.core.v1",
        "validate_ui_surface_payload",
        "scan_ui_value_for_forbidden_content",
        "secret_ref",
        "file://",
    ] {
        assert!(
            resources.contains(required),
            "resource kernel must keep generated UI validation marker `{required}`"
        );
    }

    let ui = std::fs::read_to_string(crate_root.join("src/engine/primitives/ui.rs"))
        .expect("failed to read generated UI primitive");
    let ui_authoring = read_generated_ui_authoring_tree(&crate_root);
    let ui_validation =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/ui/validation.rs"))
            .expect("failed to read generated UI validation boundary");
    let ui_tree = [ui.as_str(), ui_authoring.as_str(), ui_validation.as_str()].join("\n");
    for required in [
        "ui::catalog",
        "ui::create_surface",
        "ui::update_surface",
        "ui::inspect_surface",
        "ui::surface_for_target",
        "ui::validate_surface",
        "ui::refresh_surface",
        "ui::expire_surface",
        "ui::discard_surface",
        "ui::submit_action",
        "DurableOutputContract::resource_backed([UI_SURFACE_KIND])",
        "action_child_invocation",
        "generated authoring",
        "targetFunctionId",
        "idempotencyKey",
        "presentation",
    ] {
        assert!(
            ui_tree.contains(required),
            "generated UI primitive must keep `{required}`"
        );
    }
    assert!(
        !ui_tree.contains("ui::render_contract"),
        "generated UI must expose ui::catalog, not a parallel render-contract API"
    );

    let action_summary =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/action_summary.rs"))
            .expect("failed to read action summary primitive");
    for required in [
        "action_presentation",
        "\"presentation\"",
        "\"buttonRole\"",
        "\"icon\"",
    ] {
        assert!(
            action_summary.contains(required),
            "canonical action summary projection must keep server-owned presentation marker `{required}`"
        );
    }

    let control = std::fs::read_to_string(crate_root.join("src/engine/primitives/control.rs"))
        .expect("failed to read control primitive");
    let control_actions =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/control/actions.rs"))
            .expect("failed to read control action catalog boundary");
    let control_tree = [control.as_str(), control_actions.as_str()].join("\n");
    assert!(
        control.contains("mod actions;")
            && control.contains("use actions::{actions_for_target, substrate_actions};")
            && line_count(&crate_root.join("src/engine/primitives/control.rs")) <= 1_000
            && control.contains("uiSurfaceRefs")
            && control_tree.contains("\"presentation\"")
            && control_actions.contains("fn substrate_actions(")
            && !control.contains("payloadTemplate")
            && !control.contains("inputSchema"),
        "control projections must expose UI surface presentation refs through the action catalog boundary without inlining action templates or schemas"
    );

    let renderer_path = repo_root
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Views")
        .join("EngineConsole")
        .join("GeneratedUISurfaceView.swift");
    let renderer = std::fs::read_to_string(&renderer_path)
        .unwrap_or_else(|e| panic!("failed to read {renderer_path:?}: {e}"));
    for component in [
        "Text",
        "Heading",
        "Monospace",
        "Badge",
        "Section",
        "List",
        "Table",
        "Tabs",
        "Disclosure",
        "ResourceRef",
        "InvocationRef",
        "GrantRef",
        "WorkerRef",
        "Metric",
        "TextField",
        "TextArea",
        "Select",
        "Toggle",
        "Stepper",
        "DateTime",
        "Button",
        "ButtonGroup",
        "Confirmation",
        "Progress",
        "Health",
        "Warning",
        "Error",
        "EmptyState",
    ] {
        assert!(
            renderer.contains(component),
            "iOS generated UI renderer must declare and render `{component}`"
        );
    }
    assert!(
        renderer.contains("Unsupported UI component")
            && renderer.contains("Unsupported Surface")
            && !renderer.contains("WKWebView")
            && !renderer.contains("WebView"),
        "iOS generated UI renderer must fail closed and must not render executable markup"
    );
    for required in [
        "UiActionPresentationDTO",
        "GeneratedUIActionButtonRole(presentation:",
        "presentationIcon(for:",
    ] {
        assert!(
            renderer.contains(required),
            "iOS generated UI renderer must consume server-owned action presentation `{required}`"
        );
    }
    for forbidden in [
        "isDestructive(action:",
        "actionSymbol(action:",
        "humanizedActionLabel",
        "text.contains(\"delete\")",
        "text.contains(\"refresh\")",
    ] {
        assert!(
            !renderer.contains(forbidden),
            "iOS generated UI renderer must not infer action semantics locally via `{forbidden}`"
        );
    }

    let generated_ui_dtos_path = repo_root
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Models")
        .join("EngineProtocol")
        .join("EngineProtocolTypes+GeneratedUI.swift");
    let generated_ui_dtos = std::fs::read_to_string(&generated_ui_dtos_path)
        .unwrap_or_else(|e| panic!("failed to read {generated_ui_dtos_path:?}: {e}"));
    assert!(
        generated_ui_dtos.contains("struct UiActionPresentationDTO")
            && generated_ui_dtos.contains("var presentation: UiActionPresentationDTO?"),
        "generated UI DTOs must expose server-owned action presentation without changing submissions"
    );
    let submission_dto = generated_ui_dtos
        .split("struct UiActionSubmissionDTO")
        .nth(1)
        .and_then(|tail| tail.split("struct UiActionResultDTO").next())
        .expect("UiActionSubmissionDTO must precede UiActionResultDTO");
    for allowed in [
        "surfaceResourceId",
        "surfaceVersionId",
        "actionId",
        "userInput",
        "idempotencyKey",
    ] {
        assert!(
            submission_dto.contains(allowed),
            "UI action submission DTO must include `{allowed}`"
        );
    }
    for forbidden in ["targetFunctionId", "payloadTemplate", "requiredGrant"] {
        assert!(
            !submission_dto.contains(forbidden),
            "iOS UI action submissions must not let the client choose `{forbidden}`"
        );
    }

    let capability_client_path = repo_root
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Services")
        .join("Network")
        .join("Clients")
        .join("CapabilityClient.swift");
    let capability_client = std::fs::read_to_string(&capability_client_path)
        .unwrap_or_else(|e| panic!("failed to read {capability_client_path:?}: {e}"));
    assert!(
        capability_client.contains("\"ui::surface_for_target\"")
            && capability_client.contains("\"ui::inspect_surface\"")
            && capability_client.contains("\"ui::validate_surface\"")
            && capability_client.contains("\"ui::refresh_surface\"")
            && capability_client.contains("\"ui::submit_action\"")
            && capability_client
                .contains("canonicalSubmission.idempotencyKey = idempotencyKey.rawValue"),
        "iOS must submit generated UI actions through the audited server gateway with one canonical idempotency key"
    );

    let engine_console_state_path = repo_root
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("ViewModels")
        .join("State")
        .join("EngineConsoleState.swift");
    let engine_console_state = std::fs::read_to_string(&engine_console_state_path)
        .unwrap_or_else(|e| panic!("failed to read {engine_console_state_path:?}: {e}"));
    let engine_console_view_path = repo_root
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Views")
        .join("EngineConsole")
        .join("EngineConsoleView.swift");
    let engine_console_view = std::fs::read_to_string(&engine_console_view_path)
        .unwrap_or_else(|e| panic!("failed to read {engine_console_view_path:?}: {e}"));
    assert!(
        engine_console_state.contains("controlAdvertisesAction")
            && engine_console_view
                .contains("state.controlAdvertisesAction(functionId: \"ui::surface_for_target\""),
        "iOS generated surface authoring affordances must be gated by server-advertised control actions"
    );
}

#[test]
fn engine_ledger_ownership_boundaries_stay_split() {
    let crate_root = crate_root();
    let ledger_path = crate_root.join("src/engine/ledger.rs");
    let ledger = std::fs::read_to_string(&ledger_path).expect("failed to read engine ledger");
    let outcome = std::fs::read_to_string(crate_root.join("src/engine/ledger/outcome.rs"))
        .expect("failed to read engine ledger outcome boundary");
    let sqlite_codec =
        std::fs::read_to_string(crate_root.join("src/engine/ledger/sqlite_codec.rs"))
            .expect("failed to read engine ledger SQLite codec boundary");

    assert!(
        ledger.contains("mod outcome;")
            && ledger.contains("mod sqlite_codec;")
            && ledger.contains("pub use outcome::{StoredEngineError, StoredInvocationOutcome};")
            && ledger.contains("pub trait EngineLedgerStore")
            && ledger.contains("pub struct InMemoryEngineLedgerStore")
            && ledger.contains("pub struct SqliteEngineLedgerStore")
            && line_count(&ledger_path) <= 1_000,
        "engine ledger root must stay a store contract plus in-memory/SQLite orchestration below 1,000 LOC"
    );
    for forbidden in [
        "pub struct StoredEngineError",
        "pub struct StoredInvocationOutcome",
        "const SQLITE_SCHEMA",
        "struct RawCatalogChangeRow",
        "fn raw_invocation_record(",
        "fn optional_stored_json_string",
    ] {
        assert!(
            !ledger.contains(forbidden),
            "engine ledger root must not regain extracted helper `{forbidden}`"
        );
    }
    assert!(
        outcome.contains("pub struct StoredEngineError")
            && outcome.contains("pub struct StoredInvocationOutcome")
            && outcome.contains("from_engine_error")
            && outcome.contains("to_replay_result"),
        "engine ledger outcome boundary must own stored error/result replay projection"
    );
    assert!(
        sqlite_codec.contains("pub(super) const SQLITE_SCHEMA")
            && sqlite_codec.contains("pub(super) struct RawCatalogChangeRow")
            && sqlite_codec.contains("pub(super) fn raw_invocation_record(")
            && sqlite_codec.contains("pub(super) fn optional_stored_json_string")
            && sqlite_codec.contains("pub(super) fn resolve_optional_stored_json_string")
            && sqlite_codec.contains("pub(super) fn ensure_column"),
        "engine ledger SQLite codec boundary must own schema, row reconstruction, and stored JSON helpers"
    );
}

#[test]
fn resource_kernel_and_generated_ui_ownership_boundaries_stay_split() {
    let crate_root = crate_root();
    let resources_dir = crate_root.join("src/engine/resources");
    let resources_mod = std::fs::read_to_string(resources_dir.join("mod.rs"))
        .expect("failed to read resource module facade");
    let resource_types = std::fs::read_to_string(resources_dir.join("types.rs"))
        .expect("failed to read resource types");
    let resource_definitions = std::fs::read_to_string(resources_dir.join("definitions.rs"))
        .expect("failed to read resource definitions");
    let resource_validation = std::fs::read_to_string(resources_dir.join("validation.rs"))
        .expect("failed to read resource validation");
    let resource_versions = std::fs::read_to_string(resources_dir.join("versions.rs"))
        .expect("failed to read resource versions");
    let resource_ui_surface = std::fs::read_to_string(resources_dir.join("ui_surface.rs"))
        .expect("failed to read resource UI-surface validation");
    let resource_store = std::fs::read_to_string(resources_dir.join("store.rs"))
        .expect("failed to read resource store");
    let resource_primitive_path = crate_root.join("src/engine/primitives/resource.rs");
    let resource_primitive = std::fs::read_to_string(&resource_primitive_path)
        .expect("failed to read resource primitive root");
    let resource_primitive_artifact =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/resource/artifact.rs"))
            .expect("failed to read resource primitive artifact boundary");
    let resource_primitive_common =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/resource/common.rs"))
            .expect("failed to read resource primitive common boundary");
    let resource_primitive_input =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/resource/input.rs"))
            .expect("failed to read resource primitive input boundary");
    let resource_primitive_materialized = std::fs::read_to_string(
        crate_root.join("src/engine/primitives/resource/materialized_file.rs"),
    )
    .expect("failed to read resource primitive materialized-file boundary");
    let resource_primitive_schemas =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/resource/schemas.rs"))
            .expect("failed to read resource primitive schema boundary");

    for module_name in [
        "mod definitions;",
        "mod store;",
        "mod types;",
        "mod ui_surface;",
        "mod validation;",
        "mod versions;",
    ] {
        assert!(
            resources_mod.contains(module_name),
            "resource facade must keep ownership submodule `{module_name}`"
        );
    }
    assert!(
        resources_mod.contains("pub use definitions::builtin_resource_type_definitions")
            && resources_mod.contains(
                "pub use store::{InMemoryEngineResourceStore, SqliteEngineResourceStore}"
            )
            && resources_mod.contains("pub use types::*")
            && resources_mod.contains("pub use ui_surface::ui_component_catalog")
            && resources_mod.contains("pub(crate) use ui_surface::validate_ui_surface_payload"),
        "resource facade must preserve the stable public import surface"
    );
    assert!(
        resource_types.contains("pub struct EngineResource")
            && resource_types.contains("pub struct EngineResourceTypeDefinition")
            && resource_types.contains("pub enum EngineResourceVersionState")
            && !resource_types.contains("CREATE TABLE")
            && !resource_types.contains("validate_ui_surface_payload"),
        "resource substrate types must stay separated from persistence and UI payload validation"
    );
    let resource_definition_tree =
        [resource_definitions.as_str(), resource_types.as_str()].join("\n");
    assert!(
        resource_definition_tree.contains("pub fn builtin_resource_type_definitions")
            && resource_definition_tree.contains("worker_package")
            && resource_definition_tree.contains("activation_record")
            && !resource_store.contains("fn builtin_resource_type_definitions"),
        "built-in resource type definitions must not drift back into the store module"
    );
    assert!(
        resource_validation.contains("validate_resource_payload")
            && resource_validation.contains("ensure_lifecycle")
            && resource_validation.contains("ensure_relation")
            && !resource_validation.contains("CREATE TABLE"),
        "generic resource validation must stay independent from store persistence"
    );
    assert!(
        resource_versions.contains("payload_hash")
            && !resource_store.contains("fn payload_hash")
            && !resource_store.contains("Sha256"),
        "version/hash helpers must stay outside store implementation details"
    );
    assert!(
        resource_ui_surface.contains("pub(crate) fn validate_ui_surface_payload")
            && resource_ui_surface.contains("pub fn ui_component_catalog")
            && resource_ui_surface.contains("UI_CATALOG_ID")
            && resource_ui_surface.contains("scan_ui_value_for_forbidden_content")
            && !resource_store.contains("validate_ui_surface_payload"),
        "UI surface payload validation must live in resources/ui_surface.rs"
    );
    assert!(
        resource_primitive.contains("mod artifact;")
            && resource_primitive.contains("mod common;")
            && resource_primitive.contains("mod input;")
            && resource_primitive.contains("mod materialized_file;")
            && resource_primitive.contains("mod schemas;"),
        "resource primitive root must keep focused CLC-2 artifact/common/input/materialized/schema boundaries"
    );
    assert!(
        line_count(&resource_primitive_path) <= 1_000,
        "resource primitive root must stay below the 1,000 LOC review-smell threshold after CLC-2 extraction"
    );
    for forbidden in [
        "fn artifact_split_response(",
        "fn materialized_file_create_response(",
        "fn register_type_schema(",
        "fn resource_scope_from_payload(",
        "fn resource_ref_from_resource(",
    ] {
        assert!(
            !resource_primitive.contains(forbidden),
            "resource primitive root must not regain extracted CLC-2 helper `{forbidden}`"
        );
    }
    assert!(
        resource_primitive_artifact.contains("fn artifact_split_response(")
            && resource_primitive_artifact.contains("fn artifact_compose_response(")
            && resource_primitive_artifact.contains("fn artifact_merge_response(")
            && resource_primitive_artifact.contains("fn artifact_search_response(")
            && resource_primitive_artifact.contains("fn goal_working_set_response("),
        "resource primitive artifact boundary must own artifact curation and goal working-set helpers"
    );
    assert!(
        resource_primitive_common.contains("fn create_typed_resource(")
            && resource_primitive_common.contains("fn lifecycle_resource_by_id(")
            && resource_primitive_common.contains("fn resource_ref_from_resource(")
            && resource_primitive_common.contains("fn wrapper_create_response("),
        "resource primitive common boundary must own wrapper mutation and resource-ref helpers"
    );
    assert!(
        resource_primitive_input.contains("fn resource_scope_from_payload(")
            && resource_primitive_input.contains("fn versioning_mode(")
            && resource_primitive_input.contains("fn optional_string_array("),
        "resource primitive input boundary must own payload parsing helpers"
    );
    assert!(
        resource_primitive_materialized.contains("fn materialized_file_create_response(")
            && resource_primitive_materialized.contains("fn artifact_materialize_response(")
            && resource_primitive_materialized.contains("fn patch_apply_response(")
            && resource_primitive_materialized.contains("fn sha256_hex("),
        "resource primitive materialized-file boundary must own file, artifact materialization, patch, and hash helpers"
    );
    assert!(
        resource_primitive_schemas.contains("fn register_type_schema(")
            && resource_primitive_schemas.contains("fn resource_refs_schema(")
            && resource_primitive_schemas.contains("fn materialized_file_create_schema(")
            && resource_primitive_schemas.contains("fn patch_propose_schema("),
        "resource primitive schema boundary must own request/response schemas"
    );
    for forbidden in [
        "dynamic catalog",
        "fallback renderer",
        "compatibility alias",
        "control::act",
        "CREATE TABLE ui_",
        "CREATE TABLE control_",
    ] {
        let resource_tree = [
            resources_mod.as_str(),
            resource_types.as_str(),
            resource_definitions.as_str(),
            resource_validation.as_str(),
            resource_versions.as_str(),
            resource_ui_surface.as_str(),
            resource_store.as_str(),
        ]
        .join("\n");
        assert!(
            !resource_tree.contains(forbidden),
            "resource kernel split must not introduce `{forbidden}`"
        );
    }

    let ui = std::fs::read_to_string(crate_root.join("src/engine/primitives/ui.rs"))
        .expect("failed to read generated UI primitive");
    let ui_schemas =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/ui/schemas.rs"))
            .expect("failed to read generated UI schema boundary");
    let ui_validation =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/ui/validation.rs"))
            .expect("failed to read generated UI validation boundary");
    assert!(
        ui.contains("mod schemas;")
            && ui.contains("mod validation;")
            && ui.contains("use schemas::*;")
            && ui.contains("use validation::{")
            && line_count(&crate_root.join("src/engine/primitives/ui.rs")) <= 1_000
            && ui.contains("IdempotencyContract::caller_system_engine_ledger()")
            && ui_schemas.contains("fn create_surface_schema(")
            && ui_schemas.contains("fn surface_for_target_schema(")
            && ui_schemas.contains("fn submit_action_schema(")
            && ui_validation.contains("fn validate_action_target")
            && ui_validation.contains("fn validate_action_payload_template_against_target_schema")
            && ui_validation.contains("pub(super) fn validate_surface")
            && ui_validation.contains("pub(super) fn validate_surface_targets")
            && ui_validation.contains("pub(in crate::engine) fn action_child_invocation")
            && !ui.contains("fn create_surface_schema")
            && !ui.contains("fn surface_for_target_schema")
            && !ui.contains("fn submit_action_schema")
            && !ui.contains("fn validate_action_target")
            && !ui.contains("fn surface_validation_state")
            && !ui.contains("fn validate_action_payload_template_against_target_schema")
            && !ui.contains("IdempotencyContract::caller_session_engine_ledger()"),
        "generated UI validation must stay split and UI writes must stay system-idempotent"
    );
    for forbidden in [
        "control::act",
        "dynamic catalog",
        "fallback renderer",
        "clientTargetFunctionId",
        "targetFunctionIdOverride",
        "CREATE TABLE ui_",
    ] {
        let ui_tree = [ui.as_str(), ui_validation.as_str()].join("\n");
        assert!(
            !ui_tree.contains(forbidden),
            "generated UI boundary must not introduce `{forbidden}`"
        );
    }
}

#[test]
fn module_package_activation_gates_stay_on() {
    let crate_root = crate_root();
    let repo_root = repo_root();

    let resources = [
        crate_root.join("src/engine/resources/types.rs"),
        crate_root.join("src/engine/resources/definitions.rs"),
    ]
    .into_iter()
    .map(|path| {
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    })
    .collect::<Vec<_>>()
    .join("\n");
    for required in [
        "worker_package",
        "module_config",
        "activation_record",
        "configured_by",
        "activates",
        "owns_worker",
        "uses_grant",
        "registered_capability",
    ] {
        assert!(
            resources.contains(required),
            "module activation resource model must keep `{required}`"
        );
    }

    let primitives = std::fs::read_to_string(crate_root.join("src/engine/primitives/mod.rs"))
        .expect("failed to read primitive module registry");
    assert!(
        primitives.contains("MODULE_WORKER_ID")
            && primitives.contains("module::registrations")
            && primitives.contains("primitive_worker(MODULE_WORKER_ID"),
        "module package lifecycle must be a first-party primitive worker"
    );

    let read_module_file = |relative: &str| {
        let path = crate_root.join(relative);
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"))
    };
    let module = read_module_file("src/engine/primitives/module.rs");
    let module_activation_lifecycle =
        read_module_file("src/engine/primitives/module/activation_lifecycle.rs");
    let module_actions = read_module_file("src/engine/primitives/module/actions.rs");
    let module_evidence = read_module_file("src/engine/primitives/module/evidence.rs");
    let module_grants = read_module_file("src/engine/primitives/module/grants.rs");
    let module_manifest = read_module_file("src/engine/primitives/module/manifest.rs");
    let module_package_lifecycle =
        read_module_file("src/engine/primitives/module/package_lifecycle.rs");
    let module_payload = read_module_file("src/engine/primitives/module/payload.rs");
    let module_registrations = read_module_file("src/engine/primitives/module/registrations.rs");
    let module_resources = read_module_file("src/engine/primitives/module/resources.rs");
    let module_schemas = read_module_file("src/engine/primitives/module/schemas.rs");
    let module_trust_review = read_module_file("src/engine/primitives/module/trust_review.rs");
    let module_trust_audit = read_module_file("src/engine/primitives/module/trust_audit.rs");
    let module_trust_audit_schedule =
        read_module_file("src/engine/primitives/module/trust_audit/schedule.rs");
    let module_source_trust = read_module_source_trust_tree(&crate_root);
    let module_health_integrity =
        read_module_file("src/engine/primitives/module/health_integrity.rs");
    let module_store_access = read_module_file("src/engine/primitives/module/store_access.rs");
    let module_activation_runtime =
        read_module_file("src/engine/primitives/module/activation_runtime.rs");
    let module_tree = [
        module.as_str(),
        module_activation_lifecycle.as_str(),
        module_actions.as_str(),
        module_evidence.as_str(),
        module_grants.as_str(),
        module_manifest.as_str(),
        module_package_lifecycle.as_str(),
        module_payload.as_str(),
        module_registrations.as_str(),
        module_resources.as_str(),
        module_schemas.as_str(),
        module_store_access.as_str(),
        module_trust_review.as_str(),
        module_trust_audit.as_str(),
        module_trust_audit_schedule.as_str(),
        module_source_trust.as_str(),
        module_health_integrity.as_str(),
        module_activation_runtime.as_str(),
    ]
    .join("\n");
    assert!(
        module.contains("mod activation_runtime;"),
        "module primitive must declare the activation runtime ownership boundary"
    );
    assert!(
        line_count(&crate_root.join("src/engine/primitives/module.rs")) <= 1_000
            && module.contains("mod store_access;")
            && module_store_access.contains("pub(super) fn inspect_resource(")
            && module_store_access.contains("pub(super) async fn inspect_worker(")
            && module.contains("mod package_lifecycle;")
            && module_package_lifecycle.contains("pub(super) fn register_package(")
            && module_package_lifecycle.contains("async fn package_diagnostics(")
            && module.contains("mod activation_lifecycle;")
            && module_activation_lifecycle.contains("pub(super) async fn activate(")
            && module_activation_lifecycle.contains("async fn activate_inner(")
            && module_activation_lifecycle.contains("fn upgrade_source(")
            && module.contains("mod evidence;")
            && module_evidence.contains("pub(super) struct EvidenceCreation")
            && module_evidence.contains("pub(super) fn create_evidence_resource(")
            && !module.contains("fn inspect_resource(")
            && !module.contains("fn register_package(")
            && !module.contains("async fn activate_inner(")
            && !module.contains("fn create_evidence_resource("),
        "module root must stay below 1,000 LOC while store access, package lifecycle, activation lifecycle, and evidence creation stay in focused submodules"
    );
    assert!(
        module.contains("mod grants;")
            && module_grants.contains("pub(super) fn child_grant_from_payload(")
            && module_grants.contains("pub(super) fn ensure_grant_request_narrows_caller(")
            && module_grants.contains("pub(super) fn ensure_grant_ceiling_narrows_caller(")
            && module_grants.contains("pub(super) fn ensure_grant_request_within_ceiling(")
            && module_grants.contains("pub(super) fn ensure_grant_ceiling_within_ceiling(")
            && module_grants.contains("pub(super) fn ensure_path_within_grant_roots(")
            && !module.contains("fn child_grant_from_payload(")
            && !module.contains("fn ensure_grant_request_narrows_caller(")
            && !module.contains("fn ensure_grant_ceiling_narrows_caller(")
            && !module.contains("fn ensure_grant_request_within_ceiling(")
            && !module.contains("fn ensure_grant_ceiling_within_ceiling(")
            && !module.contains("fn ensure_path_within_grant_roots("),
        "module grant derivation and narrowing checks must stay in grants.rs"
    );
    assert!(
        module.contains("mod manifest;")
            && module_manifest.contains("pub(super) fn validate_manifest(")
            && module_manifest.contains("pub(super) fn normalize_package_manifest(")
            && module_manifest.contains("pub(super) fn declared_capabilities(")
            && module_manifest.contains("pub(super) fn validate_runtime_entrypoint(")
            && module_manifest.contains("pub(super) fn resource_version_refs(")
            && module_manifest.contains("pub(super) fn manifest_digest(")
            && !module.contains("fn validate_manifest(")
            && !module.contains("fn normalize_package_manifest(")
            && !module.contains("fn declared_capabilities(")
            && !module.contains("fn validate_runtime_entrypoint(")
            && !module.contains("fn resource_version_refs(")
            && !module.contains("fn manifest_digest("),
        "module package manifest validation and runtime parsing must stay in manifest.rs"
    );
    assert!(
        module.contains("mod registrations;")
            && module.contains("pub(super) use registrations::registrations;")
            && module_registrations.contains("pub(in crate::engine::primitives) fn registrations(")
            && module_registrations.contains("fn module_read(")
            && module_registrations.contains("fn module_write(")
            && !module.contains("fn module_read(")
            && !module.contains("fn module_write("),
        "module function registration catalogue must stay in registrations.rs"
    );
    assert!(
        module.contains("mod resources;")
            && module_resources.contains("pub(super) fn upsert_resource(")
            && module_resources.contains("pub(super) fn resource_scope_and_token(")
            && module_resources.contains("pub(super) fn require_inspection(")
            && module_resources.contains("pub(super) fn resource_ref_from_resource(")
            && module_resources.contains("pub(super) fn link_if_possible(")
            && !module.contains("fn upsert_resource(")
            && !module.contains("fn resource_scope_and_token(")
            && !module.contains("fn require_inspection(")
            && !module.contains("fn resource_ref_from_resource(")
            && !module.contains("fn link_if_possible("),
        "module resource mutation and projection helpers must stay in resources.rs"
    );
    assert!(
        module.contains("mod schemas;")
            && module_schemas.contains("pub(super) fn register_package_schema(")
            && module_schemas.contains("pub(super) fn activate_schema(")
            && module_schemas.contains("pub(super) fn module_resource_response_schema(")
            && !module.contains("fn register_package_schema(")
            && !module.contains("fn activate_schema(")
            && !module.contains("fn module_resource_response_schema("),
        "module base request/response schemas must stay in schemas.rs"
    );
    assert!(
        module.contains("mod actions;")
            && module_actions.contains("pub(super) fn module_actions_for_package(")
            && module_actions.contains("pub(super) fn module_actions_for_trust_target(")
            && !module.contains("fn module_actions_for_package(")
            && !module.contains("fn module_actions_for_trust_target("),
        "module action catalogs must stay in actions.rs"
    );
    for helper in [
        "required_object",
        "required_value_str",
        "required_map_str",
        "string_array_from",
        "parse_risk",
        "parse_datetime",
        "hash_json",
        "append_string_array",
        "append_value_array",
        "bounded_json",
        "truncate_utf8_bytes",
        "reject_raw_secrets",
        "collect_secret_refs",
    ] {
        assert!(
            module_payload.contains(&format!("pub(super) fn {helper}")),
            "module payload helper `{helper}` must live in payload.rs"
        );
        assert!(
            !module.contains(&format!("fn {helper}(")),
            "module payload helper `{helper}` must not drift back into module.rs"
        );
    }
    assert!(
        module.contains("mod source_trust;") && module.contains("mod health_integrity;"),
        "module primitive must declare source-trust and health/integrity ownership boundaries"
    );
    for helper in [
        "spawn_local_process_worker",
        "resolve_materialized_command",
        "disconnect_volatile_worker",
        "disconnect_activation_worker",
        "stop_spawned_worker",
        "record_activation_runtime_failure",
        "revoke_active_grants_for_invocation",
        "recover_partial_activation_invocation",
        "activation_invocation_family",
    ] {
        assert!(
            module_activation_runtime.contains(helper),
            "activation runtime helper `{helper}` must live in activation_runtime.rs"
        );
        assert!(
            !module.contains(&format!("fn {helper}")),
            "activation runtime helper `{helper}` must not drift back into module.rs"
        );
    }
    for helper in [
        "register_source",
        "register_ed25519_trust_root",
        "register_local_digest_source",
        "register_source_revocation",
        "verify_source",
        "verify_signature",
        "approve_source",
        "revoke_source_approval",
        "policy_decide",
        "audit_policy",
        "record_policy_audit",
        "reconcile_trust",
        "inspect_trust",
        "renew_trust_root",
        "rotate_signature_key",
        "expire_trust_decision",
        "enforce_revocation",
        "evaluate_source_policy",
        "active_source_approval",
        "active_trust_root",
        "source_verification",
        "register_source_schema",
        "verify_source_schema",
        "verify_signature_schema",
        "audit_policy_schema",
        "inspect_trust_schema",
        "enforce_revocation_schema",
    ] {
        assert!(
            module_source_trust.contains(helper),
            "source-trust helper `{helper}` must live in source_trust.rs"
        );
        assert!(
            !module.contains(&format!("fn {helper}")),
            "source-trust helper `{helper}` must not drift back into module.rs"
        );
    }
    for helper in [
        "check_health",
        "verify_integrity",
        "recover_activation",
        "run_conformance",
        "evaluate_health_policy",
        "verify_package_payload",
        "verify_config_payload",
        "verify_activation_payload",
        "conformance_for_package",
        "verify_materialized_ref",
        "check_health_schema",
        "verify_integrity_schema",
        "recover_activation_schema",
        "run_conformance_schema",
    ] {
        assert!(
            module_health_integrity.contains(helper),
            "health/integrity helper `{helper}` must live in health_integrity.rs"
        );
        assert!(
            !module.contains(&format!("fn {helper}")),
            "health/integrity helper `{helper}` must not drift back into module.rs"
        );
    }
    for required in [
        "module::register_package",
        "module::inspect_package",
        "module::configure",
        "module::activate",
        "module::disable",
        "module::upgrade",
        "module::rollback",
        "module::quarantine",
        "module::check_health",
        "module::verify_integrity",
        "module::recover_activation",
        "module::verify_source",
        "module::approve_source",
        "module::revoke_source_approval",
        "module::policy_decide",
        "module::run_conformance",
        "module::register_source",
        "module::verify_signature",
        "module::audit_policy",
        "module::record_policy_audit",
        "module::reconcile_trust",
        "module::inspect_trust",
        "module::renew_trust_root",
        "module::rotate_signature_key",
        "module::expire_trust_decision",
        "module::enforce_revocation",
        "module::trust_audit_status",
        "module::record_trust_audit_retention",
        "DurableOutputContract::resource_backed",
        "ed25519",
        "trust-root:",
        "module_trust_root",
        "module_source_registration",
        "module_source_revocation",
        "signatureVerification",
        "derive_grant",
        "revoke_grant",
        "worker::spawn",
        "local_process",
        "spawnInvocationId",
        "healthEvidenceRef",
        "integrityDiagnostics",
        "sourceTrustStatus",
        "sourceEvidenceRefs",
        "sourceApprovalRefs",
        "conformanceEvidenceRefs",
        "renewedFromDecisionResourceId",
        "signature_key_rotation",
        "trust_decision_expired",
        "revocation_enforcement",
        "trust_review",
        "module_trust_audit_schedule",
        "scheduled_trust_audit",
        "trust_audit_retention_review",
        "module_activation_runtime_diagnostic",
        "record_activation_runtime_failure",
        "manual_recovery_required",
        "cleanupStatus",
        "leakedGrantRefs",
        "leakedWorkerRefs",
        "packageDigest",
        "secret_ref",
    ] {
        assert!(
            module_tree.contains(required),
            "module primitive must keep `{required}`"
        );
    }
    for forbidden in [
        "module::act\"",
        "module::run_action",
        "control::act",
        "sandbox::spawn_worker",
        "authorityCeiling",
        "legacy",
        "fallback",
        "std::process::Command",
        "tokio::process::Command",
        "Command::new",
        "health_report",
        "module_source_table",
        "module_policy_table",
        "module_conformance_table",
        "module_trust_table",
        "module_audit_table",
        "module_health_table",
        "module_cleanup_table",
    ] {
        assert!(
            !module_tree.contains(forbidden),
            "module primitive must not reintroduce `{forbidden}`"
        );
    }
    assert!(
        module.contains("mod trust_review;")
            && module.contains("mod trust_audit;")
            && module.contains("mod source_trust;")
            && module.contains("mod health_integrity;")
            && module_trust_audit.contains("mod schedule;")
            && module_trust_review.contains("TRUST_REVIEW_OPERATIONS")
            && module_trust_review.contains("fn resolve_trust_review")
            && module_trust_review.contains("fn recommended_actions_for_trust_review")
            && module_trust_audit.contains("fn schedule_trust_audit")
            && module_trust_audit.contains("fn trust_audit_status")
            && module_trust_audit.contains("fn run_scheduled_trust_audit")
            && module_trust_audit.contains("fn record_trust_audit_retention")
            && module_trust_audit_schedule.contains("parse_trust_audit_wall_clock_time")
            && module_trust_audit_schedule.contains("fn missed_buckets")
            && module_trust_audit_schedule.contains("trust_audit_current_due_bucket")
            && !module.contains("fn resolve_trust_review")
            && !module.contains("fn schedule_trust_audit")
            && !module.contains("fn trust_audit_status")
            && !module.contains("fn run_scheduled_trust_audit")
            && !module.contains("fn record_trust_audit_retention"),
        "trust review/audit implementation must stay in focused module primitive submodules"
    );

    let module_activation_tests =
        std::fs::read_to_string(crate_root.join("src/engine/tests/module_activation.rs"))
            .expect("failed to read module activation tests");
    let module_activation_source_trust_tests = std::fs::read_to_string(
        crate_root.join("src/engine/tests/module_activation/source_trust.rs"),
    )
    .expect("failed to read module source-trust tests");
    let module_activation_health_integrity_tests = std::fs::read_to_string(
        crate_root.join("src/engine/tests/module_activation/health_integrity.rs"),
    )
    .expect("failed to read module health/integrity tests");
    assert!(
        module_activation_tests.contains("mod source_trust;")
            && module_activation_tests.contains("mod health_integrity;")
            && module_activation_source_trust_tests.contains(
                "module_local_source_policy_requires_verification_and_approval_before_spawn"
            )
            && module_activation_source_trust_tests
                .contains("module_enforce_revocation_composes_canonical_activation_mutations")
            && module_activation_health_integrity_tests
                .contains("module_check_health_writes_evidence_and_updates_activation")
            && module_activation_health_integrity_tests.contains(
                "module_recover_activation_revokes_unsafe_authority_and_preserves_evidence"
            )
            && !module_activation_tests.contains(
                "module_local_source_policy_requires_verification_and_approval_before_spawn"
            )
            && !module_activation_tests
                .contains("module_check_health_writes_evidence_and_updates_activation"),
        "module activation tests must stay split by source-trust and health/integrity concern"
    );

    let host_meta = std::fs::read_to_string(crate_root.join("src/engine/host/meta.rs"))
        .expect("failed to read engine host meta boundary");
    let host_dispatched = host_meta
        .split("pub(super) fn is_host_dispatched_primitive_namespace")
        .nth(1)
        .expect("engine host must define primitive dispatch guard");
    assert!(
        !host_dispatched.contains("\"module\""),
        "module primitives must execute as async handled primitives so activation can compose worker::spawn without holding the host lock"
    );
    let runtime = std::fs::read_to_string(crate_root.join("src/engine/primitives/runtime.rs"))
        .expect("failed to read primitive runtime");
    assert!(
        !runtime.contains("module::dispatch"),
        "module lifecycle execution must not remain on the sync host-dispatched primitive runtime"
    );

    let control = std::fs::read_to_string(crate_root.join("src/engine/primitives/control.rs"))
        .expect("failed to read control primitive");
    let control_actions =
        std::fs::read_to_string(crate_root.join("src/engine/primitives/control/actions.rs"))
            .expect("failed to read control action catalog boundary");
    let control_tree = [control.as_str(), control_actions.as_str()].join("\n");
    assert!(
        control.contains("mod actions;")
            && control.contains("modulePackages")
            && control.contains("moduleConfigs")
            && control.contains("activationRecords")
            && control.contains("moduleSourceTrust")
            && control_tree.contains("module::inspect_package")
            && control_tree.contains("module::check_health")
            && control_tree.contains("module::verify_integrity")
            && control_tree.contains("module::recover_activation")
            && control_tree.contains("module::verify_source")
            && control_tree.contains("module::approve_source")
            && control_tree.contains("module::run_conformance")
            && control_tree.contains("module::register_source")
            && control_tree.contains("module::verify_signature")
            && control_tree.contains("module::audit_policy")
            && control_tree.contains("module::record_policy_audit")
            && control_tree.contains("module::reconcile_trust")
            && control_tree.contains("module::inspect_trust")
            && control_tree.contains("module::renew_trust_root")
            && control_tree.contains("module::rotate_signature_key")
            && control_tree.contains("module::expire_trust_decision")
            && control_tree.contains("module::enforce_revocation")
            && control_tree.contains("module::simulate_trust_change")
            && control_tree.contains("module::record_trust_review")
            && control_tree.contains("module::trust_audit_status")
            && control_tree.contains("module::schedule_trust_audit")
            && control_tree.contains("module::run_scheduled_trust_audit")
            && control_tree.contains("module::record_trust_audit_retention")
            && !control_tree.contains("module::act\""),
        "control projections must expose module resources/actions without a mutation multiplexer"
    );

    let resources = [
        crate_root.join("src/engine/resources/types.rs"),
        crate_root.join("src/engine/resources/definitions.rs"),
    ]
    .into_iter()
    .map(|path| {
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    })
    .collect::<Vec<_>>()
    .join("\n");
    assert!(
        resources.contains("sourceTrustStatus")
            && resources.contains("sourceEvidenceRefs")
            && resources.contains("conformanceEvidenceRefs")
            && resources.contains("trusts_source")
            && resources.contains("verifies_signature")
            && resources.contains("affects_package")
            && resources.contains("affects_activation")
            && resources.contains("revokes")
            && resources.contains("supersedes")
            && resources.contains("renewed_by")
            && resources.contains("rotates_from")
            && resources.contains("rotates_to")
            && resources.contains("enforces_revocation"),
        "worker_package resources must carry source trust and conformance refs"
    );
    let mut module_resource_native_paths = vec![
        crate_root.join("src/engine/grants.rs"),
        crate_root.join("src/engine/resources/store.rs"),
        crate_root.join("src/engine/resources/definitions.rs"),
        crate_root.join("src/engine/resources/validation.rs"),
        crate_root.join("src/engine/invocation.rs"),
        crate_root.join("src/engine/primitives/module.rs"),
        crate_root.join("src/engine/primitives/module/actions.rs"),
        crate_root.join("src/engine/primitives/module/activation_runtime.rs"),
        crate_root.join("src/engine/primitives/module/grants.rs"),
        crate_root.join("src/engine/primitives/module/manifest.rs"),
        crate_root.join("src/engine/primitives/module/payload.rs"),
        crate_root.join("src/engine/primitives/module/resources.rs"),
        crate_root.join("src/engine/primitives/module/schemas.rs"),
        crate_root.join("src/engine/primitives/module/trust_review.rs"),
        crate_root.join("src/engine/primitives/module/trust_audit.rs"),
        crate_root.join("src/engine/primitives/module/health_integrity.rs"),
    ];
    module_resource_native_paths
        .push(crate_root.join("src/engine/primitives/module/source_trust.rs"));
    module_resource_native_paths.extend(files_with_extensions(
        &crate_root.join("src/engine/primitives/module/source_trust"),
        &["rs"],
    ));
    for path in module_resource_native_paths {
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        assert!(
            !content.contains("CREATE TABLE module_")
                && !content.contains("CREATE TABLE package_")
                && !content.contains("CREATE TABLE source_")
                && !content.contains("CREATE TABLE trust_")
                && !content.contains("CREATE TABLE audit_")
                && !content.contains("CREATE TABLE conformance_")
                && !content.contains("CREATE TABLE policy_"),
            "module source trust must stay resource-native, not table-backed: {}",
            path.display()
        );
    }

    let ui = std::fs::read_to_string(crate_root.join("src/engine/primitives/ui.rs"))
        .expect("failed to read generated UI primitive");
    let ui_authoring = read_generated_ui_authoring_tree(&crate_root);
    let ui_tree = [ui.as_str(), ui_authoring.as_str()].join("\n");
    assert!(
        ui_tree.contains("\"package\"")
            && ui_tree.contains("\"module_config\"")
            && ui_tree.contains("\"activation\"")
            && ui_tree.contains("module::inspect_package")
            && ui_tree.contains("module::check_health")
            && ui_tree.contains("module::verify_integrity")
            && ui_tree.contains("module::recover_activation")
            && ui_tree.contains("module::verify_source")
            && ui_tree.contains("module::register_source")
            && ui_tree.contains("module::verify_signature")
            && ui_tree.contains("module::audit_policy")
            && ui_tree.contains("module::record_policy_audit")
            && ui_tree.contains("module::reconcile_trust")
            && ui_tree.contains("module::inspect_trust")
            && ui_tree.contains("module::renew_trust_root")
            && ui_tree.contains("module::rotate_signature_key")
            && ui_tree.contains("module::expire_trust_decision")
            && ui_tree.contains("module::enforce_revocation")
            && ui_tree.contains("module::simulate_trust_change")
            && ui_tree.contains("module::record_trust_review")
            && ui_tree.contains("module::trust_audit_status")
            && ui_tree.contains("module::schedule_trust_audit")
            && ui_tree.contains("module::run_scheduled_trust_audit")
            && ui_tree.contains("module::record_trust_audit_retention")
            && ui_tree.contains("module::run_conformance"),
        "generated UI authoring must support module package targets through canonical actions"
    );
    assert!(
        ui.contains("trust_review_operation_input_schema")
            && ui.contains("TRUST_REVIEW_OPERATIONS")
            && !ui.contains("\"expire\", \"renew\", \"rotate\", \"revoke\"")
            && !ui.contains("\"enforce_disable\", \"enforce_quarantine\""),
        "generated UI must derive trust-review operation schemas from the canonical module source"
    );
    let host = std::fs::read_to_string(crate_root.join("src/engine/host.rs"))
        .expect("failed to read engine host");
    let host_module_jobs =
        std::fs::read_to_string(crate_root.join("src/engine/host/module_jobs.rs"))
            .expect("failed to read engine host module jobs");
    assert!(
        host_module_jobs.contains("primitives::module::trust_audit_current_due_bucket")
            && host_module_jobs
                .contains("primitives::module::trust_audit_evidence_matches_due_bucket")
            && !host.contains("parse_trust_audit_wall_clock_time")
            && !host.contains("trust_audit_day_of_week_number"),
        "host queue projection must use module-owned trust audit due-bucket and completed-evidence helpers"
    );

    let capability_client_path = repo_root
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Services")
        .join("Network")
        .join("Clients")
        .join("CapabilityClient.swift");
    let capability_client = std::fs::read_to_string(&capability_client_path)
        .unwrap_or_else(|e| panic!("failed to read {capability_client_path:?}: {e}"));
    assert!(
        !capability_client.contains("module::act")
            && !capability_client.contains("control::act")
            && !capability_client.contains("targetFunctionId ="),
        "iOS must not construct module/control action targets locally"
    );
}

#[test]
fn retired_capability_event_surface_stays_deleted() {
    let repo_root = repo_root();
    let crate_root = crate_root();

    let forbidden_exact = [
        concat!("tool", ".", "call"),
        concat!("tool", ".", "result"),
        concat!("tool", ".", "progress"),
        concat!("error", ".", "tool"),
        concat!("tool", "_", "start"),
        concat!("tool", "_", "end"),
        concat!("tool", ".", "start"),
        concat!("tool", ".", "end"),
        concat!("tool", "Agent"),
        concat!("Tool", "Agent"),
        concat!("tool", "Count"),
        concat!("tool", "Status"),
        concat!("tool", "Order"),
        concat!("tool", "Execution", "Mode"),
        concat!("tool", "Schema"),
        concat!("local", "Tool", "Schema"),
        concat!("Tool", "Operation"),
        concat!("tool", "_", "operation"),
        concat!("agent", ".", "tool", "_"),
        concat!("tool", "::", "result"),
        concat!("Mcp", "Search"),
        concat!("Mcp", "Call"),
        concat!("Engine", "Discover"),
        concat!("Engine", "Inspect"),
        concat!("Engine", "Invoke"),
        concat!("Engine", "Watch"),
    ];

    for root in [
        crate_root.join("src"),
        crate_root.join("tests"),
        repo_root.join("README.md"),
        repo_root.join("packages/agent/docs"),
        repo_root.join("packages/agent/skills/self-inspect/reference"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in &forbidden_exact {
                assert!(
                    !content.contains(needle),
                    "{} must not reintroduce retired capability event/execution marker `{needle}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }
}

#[test]
fn provider_tool_terms_stay_inside_protocol_boundaries() {
    let repo_root = repo_root();
    let allowed_prefixes = [
        "packages/agent/src/domains/model/provider_protocol/",
        "packages/agent/src/domains/model/providers/",
        "packages/agent/src/domains/mcp/product_protocol/",
        "packages/agent/tests/threat_model_invariants.rs",
    ];
    let forbidden = [
        concat!("model", "Tool", "Name"),
        concat!("model", "_", "tool", "_", "name"),
        concat!("tool", "Call", "Id"),
        concat!("tool", "_", "call", "_", "id"),
        concat!("tool", "_", "name"),
        concat!("tool", "Name"),
        concat!("tool", "_", "calls"),
        concat!("Tool", "Call"),
        concat!("Tool", "Result"),
        concat!("Tool", "Use"),
        concat!("tool", "_", "use"),
        concat!("tool", "_", "result"),
    ];

    for root in [
        repo_root.join("README.md"),
        repo_root.join("packages/agent/src"),
        repo_root.join("packages/agent/tests"),
        repo_root.join("packages/agent/defaults"),
    ] {
        for path in files_to_scan(&root) {
            let rel = path
                .strip_prefix(&repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if allowed_prefixes
                .iter()
                .any(|prefix| rel.starts_with(prefix))
            {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in forbidden {
                assert!(
                    !content.contains(needle),
                    "{rel} contains provider/tool protocol term `{needle}` outside the protocol boundary"
                );
            }
        }
    }
}

#[test]
fn provider_argument_normalization_fails_closed() {
    let crate_root = crate_root();

    let parsing = std::fs::read_to_string(
        crate_root.join("src/domains/model/provider_protocol/capability_parsing.rs"),
    )
    .expect("read provider capability parsing boundary");
    assert!(
        parsing.contains("Result<Map<String, Value>, CapabilityArgumentParseError>"),
        "provider capability argument parsing must return a Result"
    );
    assert!(
        !parsing.contains("returning empty object"),
        "provider capability argument parsing must not fail open as empty arguments"
    );

    for relative in [
        "src/domains/model/providers/shared/stream_common.rs",
        "src/domains/model/providers/openai/stream_handler.rs",
        "src/domains/model/providers/google/stream_handler.rs",
        "src/domains/model/providers/kimi/stream_handler.rs",
    ] {
        let content = std::fs::read_to_string(crate_root.join(relative))
            .unwrap_or_else(|e| panic!("failed to read {relative}: {e}"));
        assert!(
            content.contains("parse_capability_call_arguments"),
            "{relative} must use the provider-protocol argument parser"
        );
        assert!(
            content.contains("StreamEvent::Error"),
            "{relative} must surface malformed provider arguments as stream errors"
        );
    }

    for relative in [
        "src/domains/model/providers/shared/stream_common.rs",
        "src/domains/model/providers/kimi/stream_handler.rs",
    ] {
        let content = std::fs::read_to_string(crate_root.join(relative))
            .unwrap_or_else(|e| panic!("failed to read {relative}: {e}"));
        assert!(
            !content.contains("serde_json::from_str(&"),
            "{relative} must not deserialize streamed provider arguments directly"
        );
        assert!(
            !content.contains("dispatching with empty args"),
            "{relative} must not preserve fail-open provider argument fallback language"
        );
    }
}

#[test]
fn retired_stale_shapes_stay_deleted() {
    let crate_root = crate_root();

    let retired_shapes = [
        (
            "src/shared/protocol/capabilities.rs".to_string(),
            "pub enum ToolExecutionContract".to_string(),
        ),
        (
            "src/shared/protocol/events.rs".to_string(),
            "TurnTokenUsage".to_string(),
        ),
        (
            "src/shared/protocol/events.rs".to_string(),
            "ResponseTokenUsage".to_string(),
        ),
        (
            "src/shared/foundation/profile.rs".to_string(),
            "pub type ProfileSpec".to_string(),
        ),
        (
            "src/shared/foundation/profile.rs".to_string(),
            ["pub ", "fall", "back", ": Option<String>"].concat(),
        ),
        (
            "src/domains/import/implementation/parser.rs".to_string(),
            "pub fn parse_session(".to_string(),
        ),
        (
            "defaults/profiles/default/profile.toml".to_string(),
            ["fall", "back", " ="].concat(),
        ),
    ];

    for (relative, needle) in retired_shapes {
        let path = crate_root.join(&relative);
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        assert!(
            !content.contains(&needle),
            "{relative} must not reintroduce retired stale shape `{needle}`"
        );
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CurrentBoundaryKind {
    Isolate,
    Recover,
}

#[derive(Clone, Copy, Debug)]
struct CurrentBoundaryAllow {
    relative_path_prefix: &'static str,
    marker: &'static str,
    kind: CurrentBoundaryKind,
    owner: &'static str,
    reason: &'static str,
    expires: &'static str,
}

const CURRENT_BOUNDARY_ALLOWLIST: &[CurrentBoundaryAllow] = &[
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/mcp/product_protocol/",
        marker: "JsonRpc",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::mcp",
        reason: "MCP itself is a current JSON-RPC product protocol; this is not the Tron engine transport.",
        expires: "none",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/mcp/product_protocol/",
        marker: "jsonrpc",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::mcp",
        reason: "MCP fixtures and wire DTOs must speak the MCP JSON-RPC product protocol.",
        expires: "none",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/model/providers/",
        marker: "isLegacy",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::model",
        reason: "Current iOS/provider model-list DTO key for retired-generation model metadata.",
        expires: "iOS DTO rename package",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/model/providers/",
        marker: "isDeprecated",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::model",
        reason: "Current iOS/provider model-list DTO key for retired provider model metadata.",
        expires: "iOS DTO rename package",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/session/event_store/sqlite/migrations/v005_drop_profile_migrations.sql",
        marker: "idx_profile_migrations_legacy",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::session",
        reason: "Historical SQLite object name that must be dropped by exact name in existing databases.",
        expires: "never; database object names are historical facts",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/agent/runner/orchestrator/recovery.rs",
        marker: "recover_incomplete_turns",
        kind: CurrentBoundaryKind::Recover,
        owner: "domains::agent",
        reason: "Startup turn recovery is current product behavior that persists through the event store.",
        expires: "none",
    },
];

#[test]
fn current_architecture_terms_are_deleted_or_owned() {
    let repo_root = repo_root();
    let scan_roots = [
        repo_root.join("README.md"),
        repo_root.join("packages/agent/src"),
        repo_root.join("packages/agent/tests"),
    ];
    let retired_terms = [
        ["leg", "acy"].concat(),
        ["fall", "back"].concat(),
        ["compat", "ibility"].concat(),
        ["back", "ward"].concat(),
        ["back", "wards"].concat(),
        ["depre", "cated"].concat(),
        ["sh", "im"].concat(),
        ["bri", "dge"].concat(),
        ["adap", "ter"].concat(),
    ];
    let isolated_protocol_terms = ["JsonRpc".to_string(), "jsonrpc".to_string()];
    let old_import_markers = [
        "crate::runtime::".to_string(),
        "crate::events::".to_string(),
        "crate::tools::".to_string(),
        "crate::cron::".to_string(),
        "crate::worktree::".to_string(),
        "crate::llm::".to_string(),
        "crate::mcp::".to_string(),
        "crate::settings::".to_string(),
        "crate::skills::".to_string(),
        "crate::prompt_library::".to_string(),
        "crate::import::".to_string(),
        "crate::transcription::".to_string(),
        ["src/server", "/domains"].concat(),
    ];

    for root in scan_roots {
        for path in files_to_scan(&root) {
            if path == Path::new(file!()) {
                continue;
            }
            let rel = path
                .strip_prefix(&repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if rel == "packages/agent/tests/threat_model_invariants.rs" {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            let lower = content.to_lowercase();

            for term in &retired_terms {
                let is_owned_current_boundary = CURRENT_BOUNDARY_ALLOWLIST.iter().any(|allow| {
                    rel.starts_with(allow.relative_path_prefix)
                        && content.contains(allow.marker)
                        && allow.marker.to_lowercase().contains(term)
                });
                assert!(
                    !lower.contains(term) || is_owned_current_boundary,
                    "{rel} contains retired architecture word `{term}`; rename/delete it or add an explicit current-boundary owner"
                );
            }
            for marker in &old_import_markers {
                assert!(
                    !content.contains(marker.as_str()),
                    "{rel} contains old root import/path `{marker}`"
                );
            }
            for marker in &isolated_protocol_terms {
                if !content.contains(marker) {
                    continue;
                }
                let allow = CURRENT_BOUNDARY_ALLOWLIST.iter().find(|allow| {
                    rel.starts_with(allow.relative_path_prefix) && allow.marker == marker
                });
                assert!(
                    allow.is_some(),
                    "{rel} contains isolated protocol marker `{marker}` without an owner/reason allowlist entry"
                );
            }
        }
    }

    for allow in CURRENT_BOUNDARY_ALLOWLIST {
        assert!(
            !allow.owner.is_empty()
                && !allow.reason.is_empty()
                && !allow.expires.is_empty()
                && matches!(
                    allow.kind,
                    CurrentBoundaryKind::Isolate | CurrentBoundaryKind::Recover
                ),
            "current-boundary allowlist entries must carry kind, owner, reason, and expiration"
        );
    }
}

#[test]
fn unified_storage_has_no_active_old_database_paths() {
    let repo_root = repo_root();
    let scan_roots = [
        repo_root.join("README.md"),
        repo_root.join("packages/agent/src"),
        repo_root.join("packages/agent/tests"),
        repo_root.join("packages/ios-app/Sources"),
        repo_root.join("packages/ios-app/Tests"),
        repo_root.join("packages/ios-app/docs"),
    ];
    let old_database_markers = ["log.db", "engine-ledger.sqlite", "tron.db", "log.db.lock"];
    for root in scan_roots {
        for path in files_to_scan(&root) {
            let rel = path
                .strip_prefix(&repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if rel == "packages/agent/src/shared/storage.rs"
                || rel == "packages/agent/src/shared/storage/archive.rs"
                || rel == "packages/agent/src/shared/storage/tests.rs"
                || rel == "packages/agent/tests/threat_model_invariants.rs"
            {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for marker in old_database_markers {
                assert!(
                    !content.contains(marker),
                    "{rel} contains retired active database path `{marker}`; use tron.sqlite or isolate it in shared::storage archive policy"
                );
            }
        }
    }
}

#[test]
fn blobs_are_owned_through_storage_payload_refs() {
    let repo_root = repo_root();
    let crate_root = crate_root();
    for path in rust_files_under(&crate_root.join("src")) {
        let rel = path
            .strip_prefix(&repo_root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        if !content.contains("store_content_blob(") {
            continue;
        }
        assert!(
            rel == "packages/agent/src/shared/storage.rs"
                || rel == "packages/agent/src/shared/storage/payloads.rs"
                || rel == "packages/agent/src/shared/storage/tests.rs"
                || rel
                    == "packages/agent/src/domains/session/event_store/sqlite/repositories/blob.rs",
            "{rel} calls store_content_blob directly; use store_json_value/store_json_bytes so every blob has a storage_payload_refs owner"
        );
    }
}

#[test]
fn current_architecture_ownership_report_is_current() {
    let repo_root = repo_root();
    let crate_root = crate_root();
    let src_root = crate_root.join("src");
    let expected_top_level = [
        "app",
        "domains",
        "engine",
        "platform",
        "shared",
        "transport",
    ];
    for directory in expected_top_level {
        assert!(
            src_root.join(directory).is_dir(),
            "current architecture root `{directory}` must exist"
        );
    }
    for retired_root in [
        "runtime",
        "events",
        "tools",
        "cron",
        "worktree",
        "llm",
        "mcp",
        "settings",
        "skills",
        "prompt_library",
        "import",
        "transcription",
        "server",
    ] {
        assert!(
            !src_root.join(retired_root).exists(),
            "retired root bucket `{retired_root}` must not exist"
        );
    }

    let domain_names = std::fs::read_dir(src_root.join("domains"))
        .expect("failed to read domains root")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().join("contract.rs").is_file())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    let primitive_workers = std::fs::read_dir(src_root.join("engine/primitives"))
        .expect("failed to read primitive root")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "rs"))
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();

    let report = format!(
        "Current Architecture Ownership Report\n\
         app: bootstrap, health, metrics, onboarding, shutdown\n\
         transport: /engine client protocol, /engine/workers socket transport, auth gate\n\
         engine primitives: {}\n\
         domains: {}\n\
         platform: APNs, updater/device sidecars\n\
         shared: foundation types, protocol DTOs, neutral helpers\n",
        primitive_workers.join(", "),
        domain_names.join(", "),
    );
    eprintln!("{report}");

    assert!(
        report.contains("transport: /engine")
            && report.contains("engine primitives:")
            && report.contains("domains:")
            && report.contains("platform:")
            && report.contains("shared:"),
        "ownership report must cover app, transport, engine, domains, platform, and shared"
    );
    assert!(
        repo_root.join("README.md").is_file(),
        "README remains the canonical architecture reference"
    );
}

#[test]
fn primitive_workers_are_owned_outside_host_bucket() {
    let crate_root = crate_root();
    let primitives_root = crate_root.join("src/engine/primitives");
    for primitive in [
        "stream.rs",
        "state.rs",
        "queue.rs",
        "approval.rs",
        "catalog.rs",
        "worker.rs",
        "observability.rs",
        "runtime.rs",
    ] {
        assert!(
            primitives_root.join(primitive).is_file(),
            "engine primitive worker contracts must live in src/engine/primitives/{primitive}"
        );
    }

    let host = std::fs::read_to_string(crate_root.join("src/engine/host.rs"))
        .expect("failed to read engine host");
    let host_meta = std::fs::read_to_string(crate_root.join("src/engine/host/meta.rs"))
        .expect("failed to read engine host meta boundary");
    let host_runtime_host =
        std::fs::read_to_string(crate_root.join("src/engine/host/runtime_host.rs"))
            .expect("failed to read engine host runtime host boundary");
    let host_catalog_handle =
        std::fs::read_to_string(crate_root.join("src/engine/host/catalog_handle.rs"))
            .expect("failed to read engine host catalog handle boundary");
    let host_module_jobs =
        std::fs::read_to_string(crate_root.join("src/engine/host/module_jobs.rs"))
            .expect("failed to read engine host module jobs boundary");
    let host_invocation_handle =
        std::fs::read_to_string(crate_root.join("src/engine/host/invocation_handle.rs"))
            .expect("failed to read engine host invocation handle boundary");
    let host_invocation_support =
        std::fs::read_to_string(crate_root.join("src/engine/host/invocation_support.rs"))
            .expect("failed to read engine host invocation support boundary");
    let host_substrate_handle =
        std::fs::read_to_string(crate_root.join("src/engine/host/substrate_handle.rs"))
            .expect("failed to read engine host substrate handle boundary");
    assert!(
        host.contains("mod meta;")
            && host.contains("pub use meta::{CatalogWatchRequest, CatalogWatchResponse};")
            && host_meta.contains("pub(super) const ENGINE_WORKER_ID")
            && host_meta.contains("pub(super) fn meta_function_definitions(")
            && host_meta.contains("pub(super) fn watch_request_from_payload(")
            && host_meta.contains("pub(super) fn delegated_child_invocation(")
            && host_meta.contains("pub(super) fn is_host_dispatched_primitive_namespace(")
            && !host.contains("fn meta_function_definitions(")
            && !host.contains("fn watch_request_from_payload(")
            && !host.contains("fn delegated_child_invocation(")
            && !host.contains("fn is_host_dispatched_primitive_namespace("),
        "engine host meta vocabulary, schemas, DTOs, and payload parsers must stay in host/meta.rs"
    );
    assert!(
        host.contains("mod runtime_host;")
            && host_runtime_host
                .contains("impl primitives::runtime::PrimitiveRuntimeHost for EngineHost")
            && host_runtime_host.contains("fn resource_type_definitions(")
            && host_runtime_host.contains("fn storage_stats(")
            && host_runtime_host.contains("fn stored_log_values(")
            && !host.contains("impl primitives::runtime::PrimitiveRuntimeHost for EngineHost"),
        "engine host primitive runtime implementation must stay in host/runtime_host.rs"
    );
    assert!(
        host.lines().count() < 1_000
            && host.contains("mod catalog_handle;")
            && host.contains("mod module_jobs;")
            && host.contains("mod invocation_handle;")
            && host.contains("mod invocation_support;")
            && host.contains("mod substrate_handle;")
            && host_catalog_handle.contains("pub async fn register_worker(")
            && host_catalog_handle.contains("pub async fn promote_function_visibility(")
            && host_module_jobs.contains("enqueue_due_module_health_checks")
            && host_module_jobs.contains("enqueue_due_module_trust_audits")
            && host_invocation_handle.contains("pub async fn invoke(&self")
            && host_invocation_handle.contains("invoke_queue_target")
            && host_invocation_handle.contains("execute_prepared_regular_with_recording_policy")
            && host_invocation_support.contains("pub(super) fn lease_request_from_requirement")
            && host_invocation_support.contains("pub(super) fn can_resolve_approval")
            && host_substrate_handle.contains("pub async fn request_approval(")
            && host_substrate_handle.contains("pub async fn enqueue_invocation(")
            && !host.contains("pub async fn invoke(&self, invocation: Invocation)")
            && !host.contains("pub async fn enqueue_due_module_health_checks")
            && !host.contains("pub async fn request_approval("),
        "EngineHost root must stay a host/type spine while handle catalog, module jobs, invocation, lease helpers, and substrate stores live in focused host submodules"
    );
    for removed in [
        "struct StreamPrimitiveHandler",
        "struct StatePrimitiveHandler",
        "struct QueuePrimitiveHandler",
        "struct ApprovalPrimitiveHandler",
        "fn stream_publish_schema",
        "fn state_set_schema",
        "fn queue_enqueue_schema",
        "fn approval_request_schema",
        "fn primitive_function(",
        "fn primitive_catalog_",
        "fn primitive_worker_",
        "fn primitive_trace_",
        "fn primitive_log_query",
        "fn primitive_metrics_snapshot",
        "dispatch_host_dispatched_primitive",
    ] {
        assert!(
            !host.contains(removed),
            "EngineHost must coordinate primitive execution without owning primitive contract, query, or response bucket `{removed}`"
        );
    }

    let primitive_runtime = std::fs::read_to_string(primitives_root.join("runtime.rs"))
        .expect("failed to read primitive runtime");
    let queue_root_path = crate_root.join("src/engine/queue.rs");
    let queue_root =
        std::fs::read_to_string(&queue_root_path).expect("failed to read engine queue root");
    let queue_runtime = std::fs::read_to_string(crate_root.join("src/engine/queue/runtime.rs"))
        .expect("failed to read engine queue runtime boundary");
    assert!(
        queue_root.contains("mod runtime;")
            && queue_root.contains("pub use runtime::{")
            && line_count(&queue_root_path) <= 1_000
            && !queue_root.contains("pub struct EngineQueueRuntime")
            && !queue_root.contains("fn queue_lifecycle_stream_event(")
            && queue_runtime.contains("pub struct EngineQueueRuntime")
            && queue_runtime.contains("fn queue_lifecycle_stream_event("),
        "engine queue root must keep runtime draining and lifecycle stream projection in src/engine/queue/runtime.rs"
    );
    for required in [
        "PrimitiveRuntimeHost",
        "catalog_list",
        "worker_list",
        "trace_get",
        "metrics_snapshot",
    ] {
        assert!(
            primitive_runtime.contains(required),
            "primitive query response shaping must live in src/engine/primitives/runtime.rs; missing `{required}`"
        );
    }
}

#[test]
fn external_workers_and_sandbox_spawn_are_first_class_engine_surfaces() {
    let crate_root = crate_root();
    let protocol = std::fs::read_to_string(crate_root.join("src/engine/protocol.rs"))
        .expect("failed to read worker protocol");
    for required in [
        "WorkerIdentity",
        "WorkerAuthPolicy",
        "WorkerRegistrationMode",
        "WorkerVisibility",
        "WorkerHealth",
        "WorkerLifecycleEvent",
        "WorkerStreamPublish",
        "PublishStream",
    ] {
        assert!(
            protocol.contains(required),
            "worker protocol must expose `{required}` for local-first worker lifecycle and stream publication"
        );
    }

    let external = std::fs::read_to_string(crate_root.join("src/engine/external.rs"))
        .expect("failed to read external worker runtime");
    for required in [
        "register_function",
        "register_trigger",
        "publish_stream",
        "publish_lifecycle_event",
        "worker.lifecycle",
        "external workers are loopback-only",
        "disconnect_timed_out",
        "mark_durable_worker_disconnected",
    ] {
        assert!(
            external.contains(required),
            "external worker runtime must keep `{required}` in the engine-owned worker lifecycle"
        );
    }

    let sandbox_contract =
        std::fs::read_to_string(crate_root.join("src/domains/sandbox/contract.rs"))
            .expect("failed to read sandbox contract");
    for required in [
        "worker::spawn",
        "sandbox::list_spawned_workers",
        "sandbox::get_spawned_worker",
        "sandbox::stop_spawned_worker",
        "sandbox-worker",
        "sandboxAutonomy",
        "worker:{workerId}",
    ] {
        assert!(
            sandbox_contract.contains(required),
            "worker::spawn must stay a high-risk domain-owned capability with complete engine metadata; missing `{required}`"
        );
    }
    assert!(
        !sandbox_contract.contains("sandbox::spawn_worker"),
        "sandbox::spawn_worker must not remain as a parallel public worker creation API"
    );
    for removed in [
        concat!("sandbox::", "list_", "containers"),
        concat!("sandbox::", "start_", "container"),
        concat!("sandbox::", "stop_", "container"),
        concat!("sandbox::", "kill_", "container"),
        concat!("sandbox::", "remove_", "container"),
    ] {
        assert!(
            !sandbox_contract.contains(removed),
            "retired container dashboard capability `{removed}` must stay deleted"
        );
    }
    assert!(
        !sandbox_contract.contains(".approval_required(true)"),
        "sandbox lifecycle capabilities are sandbox-autonomous and must not create user approvals"
    );

    let sandbox = std::fs::read_to_string(crate_root.join("src/domains/sandbox/mod.rs"))
        .expect("failed to read sandbox domain");
    assert!(
        sandbox.contains("\"worker::disconnect\"")
            && sandbox.contains("\"stream::publish\"")
            && !sandbox.contains(".unregister_worker("),
        "sandbox worker cleanup must route through engine worker/stream primitives, not direct catalog cleanup"
    );
}

#[test]
fn approvals_are_engine_owned_not_model_confirmation_tools() {
    let repo_root = repo_root();
    let agent_root = crate_root();
    let agent_contract = std::fs::read_to_string(agent_root.join("src/domains/agent/contract.rs"))
        .expect("failed to read agent contract");
    let agent_handlers = std::fs::read_to_string(agent_root.join("src/domains/agent/handlers.rs"))
        .expect("failed to read agent handlers");

    assert!(
        !agent_root
            .join(["src/domains/", "tools", "/operations/catalog.rs"].concat())
            .exists(),
        "approval UI must be engine-owned; GetConfirmation must not be a model-facing tool"
    );
    assert!(
        !agent_contract.contains("agent::submit_confirmation")
            && !agent_handlers.contains("submit_confirmation"),
        "model-level confirmation submission must not be a canonical agent capability"
    );
    for stale in [
        "/engine/approvals",
        "/api/approvals",
        "model-level GetConfirmation",
    ] {
        let capability_docs =
            std::fs::read_to_string(agent_root.join("src/domains/capability/mod.rs"))
                .expect("failed to read capability docs");
        assert!(
            !capability_docs.contains(stale),
            "capability guidance must not mention stale approval path `{stale}`"
        );
    }

    let ios_agent_client = std::fs::read_to_string(
        repo_root.join("packages/ios-app/Sources/Services/Network/Clients/AgentClient.swift"),
    )
    .expect("failed to read iOS agent client");
    assert!(
        !ios_agent_client.contains("submitConfirmation")
            && !ios_agent_client.contains("agent::submit_confirmation"),
        "iOS must resolve approvals through approval::resolve, never agent::submit_confirmation"
    );

    let ios_sources = repo_root.join("packages/ios-app/Sources");
    for path in files_with_extensions(&ios_sources, &["swift"]) {
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read iOS source {path:?}: {e}"));
        for stale in [
            "GetConfirmation",
            "getconfirmation",
            "submitConfirmation",
            "submit_confirmation",
            "confirmedAction",
            "confirmation_response",
        ] {
            assert!(
                !content.contains(stale),
                "{} contains stale model-confirmation approval path `{stale}`",
                path.strip_prefix(&repo_root).unwrap_or(&path).display()
            );
        }
    }
}

#[test]
fn agent_runtime_stays_engine_native() {
    let crate_root = crate_root();
    let agent_root = crate_root.join("src/domains/agent");
    let agent_mod =
        std::fs::read_to_string(agent_root.join("mod.rs")).expect("failed to read agent/mod.rs");
    for removed in [
        "hidden_function_registrations",
        "FunctionDefinition::new",
        "agent_prompt_apply_request_schema",
        "agent_prompt_queue_drain_request_schema",
    ] {
        assert!(
            !agent_mod.contains(removed),
            "agent/mod.rs must stay docs/exports only; hidden contracts belong in contract.rs, found `{removed}`"
        );
    }

    let agent_contract = std::fs::read_to_string(agent_root.join("contract.rs"))
        .expect("failed to read agent/contract.rs");
    for required in [
        "agent::prompt_apply",
        "agent::run_turn",
        "agent::prompt_queue_drain",
        ".visibility(VisibilityScope::Internal)",
    ] {
        assert!(
            agent_contract.contains(required),
            "agent hidden runtime capability contracts must live in agent/contract.rs with internal visibility; missing `{required}`"
        );
    }

    for path in rust_files_under(&agent_root) {
        let rel = path.strip_prefix(&crate_root).unwrap();
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        let production_content = content
            .split("#[cfg(test)]")
            .next()
            .unwrap_or(content.as_str());
        for removed in [
            "crate::domains::memory::retain",
            "crate::domains::prompt_library::store",
            "record_prompt_and_prune(",
        ] {
            assert!(
                !production_content.contains(removed),
                "{} must route cross-domain side effects through engine/domain capabilities, not `{removed}`",
                rel.display()
            );
        }
        assert!(
            !production_content.contains("target_revision: None"),
            "{} must pin hidden queue handoffs to the current function revision",
            rel.display()
        );
    }

    let capability_executor = std::fs::read_to_string(
        crate_root.join("src/domains/agent/runner/agent/capability_invocation_executor.rs"),
    )
    .expect("failed to read capability_invocation_executor.rs");
    assert!(
        !capability_executor.contains("TraceId::new(format!(\"tool:"),
        "model capability child invocations must inherit the agent run trace instead of minting detached tool traces"
    );
    assert!(
        capability_executor.contains("with_parent_invocation"),
        "model capability child invocations must carry the agent run-turn invocation as parent"
    );
}

#[test]
fn server_package_uses_domain_owned_engine_layout() {
    let crate_root = crate_root();
    let engine_types_path = crate_root.join("src/engine/types.rs");
    let engine_types = std::fs::read_to_string(&engine_types_path)
        .unwrap_or_else(|error| panic!("failed to read {engine_types_path:?}: {error}"));
    let engine_catalog_types =
        std::fs::read_to_string(crate_root.join("src/engine/types/catalog.rs"))
            .expect("failed to read engine catalog type boundary");
    assert!(
        engine_types.contains("mod catalog;")
            && engine_types.contains("pub use catalog::*;")
            && line_count(&engine_types_path) <= 1_000
            && !engine_types.contains("pub struct CatalogChange")
            && !engine_types.contains("pub enum CatalogSubjectKind")
            && engine_catalog_types.contains("pub struct CatalogChange")
            && engine_catalog_types.contains("pub enum CatalogSubjectKind"),
        "engine types root must keep catalog change DTOs in src/engine/types/catalog.rs"
    );

    for removed in [
        "src/server",
        "src/runtime",
        "src/events",
        "src/tools",
        "src/settings",
        "src/cron",
        "src/worktree",
        "src/llm",
        "src/mcp",
        "src/skills",
        "src/prompt_library",
        "src/transcription",
    ] {
        assert!(
            !crate_root.join(removed).exists(),
            "{removed} must stay deleted; implementation code is owned by domains, app, transport, platform, engine, or shared"
        );
    }

    let domains_root = crate_root.join("src/domains");
    assert!(
        domains_root.is_dir(),
        "domains directory must exist as the canonical worker surface"
    );
    for entry in std::fs::read_dir(&domains_root).expect("failed to read domains directory") {
        let entry = entry.expect("failed to read domain entry");
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if !path.join("mod.rs").is_file() {
            continue;
        }
        let domain_name = path.file_name().unwrap().to_string_lossy();
        if domain_name == "capability_support" {
            assert!(
                !path.join("contract.rs").exists()
                    && !path.join("deps.rs").exists()
                    && !path.join("handlers.rs").exists()
                    && !path.join("operations").exists(),
                "capability_support is a support namespace and must not own an active worker surface"
            );
            continue;
        }
        assert!(
            path.join("contract.rs").is_file(),
            "domain worker module `{domain_name}` must own a contract.rs file"
        );
        assert!(
            path.join("deps.rs").is_file(),
            "domain worker module `{domain_name}` must own a deps.rs file"
        );
        assert!(
            path.join("handlers.rs").is_file(),
            "domain worker module `{domain_name}` must own a handlers.rs operation binding file"
        );
        assert!(
            !path.join("spec.rs").exists(),
            "domain worker module `{domain_name}` must not split contract truth into spec.rs"
        );
    }
    for required in ["agent", "auth", "cron", "session", "settings", "worktree"] {
        let domain_root = domains_root.join(required);
        assert!(
            domain_root.is_dir(),
            "domain worker module `{required}` must own its vertical slice"
        );
        assert!(
            domain_root.join("contract.rs").is_file(),
            "domain worker module `{required}` must own its capability contracts"
        );
        assert!(
            domain_root.join("deps.rs").is_file(),
            "domain worker module `{required}` must own its narrow dependency bundle"
        );
        assert!(
            domain_root.join("handlers.rs").is_file(),
            "domain worker module `{required}` must own operation bindings"
        );
        assert!(
            !domain_root.join("spec.rs").exists(),
            "domain worker module `{required}` must keep its canonical function inventory in contract.rs"
        );
    }
    for required in [
        "agent", "auth", "context", "cron", "job", "mcp", "memory", "model", "session", "worktree",
    ] {
        let domain_root = domains_root.join(required);
        let operations_mod = domain_root.join("operations").join("mod.rs");
        assert!(
            operations_mod.is_file(),
            "flow-critical domain worker `{required}` must expose an operations/ boundary"
        );
        let operations_content = std::fs::read_to_string(&operations_mod)
            .unwrap_or_else(|e| panic!("failed to read {operations_mod:?}: {e}"));
        assert!(
            !operations_content.contains("pub(crate) async fn")
                && !operations_content.contains("pub(super) async fn")
                && !operations_content.contains("impl InProcessFunctionHandler"),
            "flow-critical domain worker `{required}` operations/mod.rs must stay an export map, not a mixed-purpose executable file"
        );
        let operation_files = std::fs::read_dir(domain_root.join("operations"))
            .unwrap_or_else(|e| panic!("failed to read operations dir for {required}: {e}"))
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "rs"))
            .filter(|path| path.file_name().is_some_and(|name| name != "mod.rs"))
            .collect::<Vec<_>>();
        assert!(
            !operation_files.is_empty(),
            "flow-critical domain worker `{required}` must split executable operations into workflow files"
        );
        assert!(
            operation_files.iter().any(|path| {
                let content = std::fs::read_to_string(path)
                    .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
                content.contains("pub(crate) async fn")
                    || content.contains("pub(crate) fn")
                    || content.contains("impl ")
                    || content.contains("InProcessFunctionHandler")
            }),
            "flow-critical domain worker `{required}` operation files must contain executable operation code"
        );
    }
    assert!(
        !domains_root.join("schemas").exists(),
        "domain schemas must live in domain-owned contract modules, not a shared schemas bucket"
    );
    assert!(
        !domains_root.join("catalog/contracts.rs").exists(),
        "catalog must aggregate contracts, not own domain contract policy"
    );

    let domains_mod = std::fs::read_to_string(domains_root.join("mod.rs"))
        .expect("failed to read domains/mod.rs");
    for removed in [
        "use std::",
        "use serde",
        "use serde_json",
        "use crate::",
        "pub(crate) use worker::",
        "pub use worker::",
    ] {
        assert!(
            !domains_mod.contains(removed),
            "root domains module must stay docs/module declarations only and not retain `{removed}`"
        );
    }
    for removed in [
        "pub(crate) struct DomainRegistrationContext",
        "pub(crate) struct DomainFunctionRegistration",
        "pub(crate) struct DomainWorkerModule",
        "pub(crate) fn domain_worker_module",
    ] {
        assert!(
            !domains_mod.contains(removed),
            "root domains module must expose worker types from worker.rs instead of defining `{removed}`"
        );
    }
    assert!(
        !domains_mod.contains("async fn capability_function_value"),
        "canonical functions must carry concrete domain handlers instead of executing through a central dispatcher"
    );
    assert!(
        !domains_mod.contains("handler_for_method"),
        "domain handlers must be registered by domain worker modules, not a central method match"
    );
    assert!(
        !domains_mod.contains("EngineCapabilityDeps"),
        "domain setup must not reintroduce the broad EngineCapabilityDeps shape"
    );
    assert!(
        !domains_mod.contains("_stream_topics"),
        "domain registration must validate stream topics instead of ignoring them"
    );
    assert!(
        !domains_mod.contains("publish_engine_stream_event"),
        "domain stream publication must be owned by domain-local publishers, not a shared catch-all helper"
    );
    for removed in [
        "DomainFunctionHandler",
        "DomainHandlerFn",
        "domain_handler!",
        "domain_function_registration",
    ] {
        assert!(
            !domains_mod.contains(removed),
            "root domains module must not retain central execution plumbing `{removed}`"
        );
    }

    for required in [
        "worker.rs",
        "agent/runtime/service/request.rs",
        "agent/runtime/service/deps.rs",
        "agent/runtime/service/plan.rs",
        "agent/runtime/service/spawn.rs",
        "agent/runtime/service/execute.rs",
        "agent/runtime/service/queue.rs",
        "agent/runtime/service/events.rs",
        "agent/runtime/service/agent_build.rs",
        "agent/runtime/service/completion.rs",
        "agent/runtime/service/context.rs",
        "agent/runtime/service/hooks.rs",
        "agent/runtime/service/worktree.rs",
        "agent/runtime/runtime/user_event.rs",
        "agent/runtime/runtime/bootstrap.rs",
        "agent/runtime/runtime/pending.rs",
        "agent/runtime/runtime/session_update.rs",
        "agent/runtime/runtime/skills.rs",
        "session/commands/create.rs",
        "session/commands/archive.rs",
        "session/commands/delete.rs",
        "session/commands/fork.rs",
        "session/commands/preload.rs",
        "session/context/cache.rs",
        "session/context/dynamic.rs",
        "session/context/rules.rs",
        "session/context/types.rs",
        "context/queries/audit.rs",
        "context/queries/payload_preview.rs",
        "context/queries/prepare.rs",
        "context/queries/snapshot.rs",
        "capability_support/interactive_enrichment/payload.rs",
        "capability_support/interactive_enrichment/questions.rs",
        "memory/retain/auto_retain/decision.rs",
        "memory/retain/auto_retain/state.rs",
        "memory/retain/auto_retain/fire.rs",
        "worktree/git_workflow/branches.rs",
        "worktree/git_workflow/conflicts.rs",
        "worktree/git_workflow/finalize.rs",
        "worktree/git_workflow/merge.rs",
        "worktree/git_workflow/rebase.rs",
        "worktree/git_workflow/remote.rs",
        "worktree/git_workflow/shared.rs",
        "worktree/git_workflow/subagent.rs",
    ] {
        assert!(
            domains_root.join(required).is_file(),
            "domain readability split must keep `{required}` as an owned workflow module"
        );
    }
    let execute_lines =
        std::fs::read_to_string(domains_root.join("agent/runtime/service/execute.rs"))
            .expect("failed to read agent runtime execute spine")
            .lines()
            .count();
    assert!(
        execute_lines <= 400,
        "agent runtime execute.rs must stay a lifecycle spine, not a mixed-purpose body ({execute_lines} lines)"
    );

    for required in [
        "session/agent.rs",
        "session/lifecycle.rs",
        "session/worktree.rs",
    ] {
        assert!(
            crate_root
                .join("src/transport/runtime/streams")
                .join(required)
                .is_file(),
            "runtime stream projection must keep `{required}` split by event family"
        );
    }
    let catalog = std::fs::read_to_string(domains_root.join("catalog.rs"))
        .expect("failed to read domains/catalog.rs");
    for removed in [
        "CAPABILITY_SEEDS",
        "capability_seed!",
        "canonical_parts_for_method",
        "domain_worker_for_method",
        "domain_authority_scope_for_method",
        "capability_spec_for_method",
        "capability_specs_for_methods",
        "request_schema_for_method",
        "response_schema_for_method",
    ] {
        assert!(
            !catalog.contains(removed),
            "catalog must aggregate domain-owned contracts, not retain central `{removed}` logic"
        );
    }
    let shared_contract = std::fs::read_to_string(domains_root.join("contract.rs"))
        .expect("failed to read domains/contract.rs");
    for removed in [
        "match method",
        "capability_specs_for_methods",
        "capability_spec_for_method",
        "request_schema_for_method",
        "response_schema_for_method",
        "domain_authority_scope_for_method",
    ] {
        assert!(
            !shared_contract.contains(removed),
            "shared contract builder must stay method-agnostic and not retain `{removed}`"
        );
    }

    for path in rust_files_under(&domains_root) {
        let rel = path.strip_prefix(&crate_root).unwrap();
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        assert!(
            !content.contains("capability_context"),
            "{} must not use the old broad capability_context field name",
            rel.display()
        );
        assert!(
            !content.contains("EngineCapabilityDeps"),
            "{} must not reintroduce EngineCapabilityDeps",
            rel.display()
        );
        let production_content = content
            .split("#[cfg(test)]")
            .next()
            .unwrap_or(content.as_str());
        let is_test_only_file = is_src_rust_test_file(&path);
        if rel.starts_with("src/domains") && !is_test_only_file {
            assert!(
                !production_content.contains("use super::*;"),
                "{} must import explicit local/shared symbols instead of parent wildcard exports",
                rel.display()
            );
            assert!(
                !production_content.contains("use crate::domains::*;"),
                "{} must not replace parent wildcard imports with the root domain prelude",
                rel.display()
            );
        }
        if rel.ends_with("deps.rs") {
            assert!(
                !production_content.contains("ServerRuntimeContext"),
                "{} must not store or construct deps from the full ServerRuntimeContext",
                rel.display()
            );
        }
        let allowed_setup_boundary = rel == Path::new("src/domains/mod.rs")
            || rel == Path::new("src/domains/registration.rs")
            || rel == Path::new("src/domains/worker.rs");
        if !allowed_setup_boundary {
            assert!(
                !production_content.contains("&ServerRuntimeContext"),
                "{} production domain operations must take narrow deps, not &ServerRuntimeContext",
                rel.display()
            );
        }
        assert!(
            !content.contains(".stream_topics(vec![\"resource.leases\", \"catalog.changes\"])")
                && !content.contains("\"streamTopics\":[\"resource.leases\",\"catalog.changes\"]"),
            "{} must not copy engine-global stream topics into domain contracts",
            rel.display()
        );
        assert!(
            !content.contains("server_context: Arc<ServerRuntimeContext>"),
            "{} must expose narrow deps instead of storing the full ServerRuntimeContext",
            rel.display()
        );
        let is_stream_publisher = rel
            .file_name()
            .is_some_and(|name| name == "stream.rs" || name == "callbacks.rs");
        let is_runtime_primitive = rel.starts_with("src/domains/cron/callbacks.rs");
        if rel.starts_with("src/domains") && !is_stream_publisher && !is_runtime_primitive {
            assert!(
                !production_content.contains("publish_stream_event(")
                    && !production_content.contains("PublishStreamEvent"),
                "{} must publish domain events through typed domain stream publishers",
                rel.display()
            );
        }
        if rel.ends_with("handlers.rs") {
            assert!(
                production_content.contains("operation_bindings!"),
                "{} must use a declarative local operation binding table",
                rel.display()
            );
            for removed in [
                "match operation_key",
                "match key",
                "struct FunctionHandler",
                "impl InProcessFunctionHandler",
            ] {
                assert!(
                    !production_content.contains(removed),
                    "{} must not reintroduce handler-owned dispatch shape `{removed}`",
                    rel.display()
                );
            }
            assert!(
                !production_content.contains("\"agent::prompt\" =>")
                    && !production_content.contains("\"auth::get\" =>")
                    && !production_content.contains("\"worktree::get_status\" =>")
                    && !production_content.contains("\"git::clone\" =>")
                    && !production_content.contains("\"cron::list\" =>")
                    && !production_content.contains("\"mcp::status\" =>")
                    && !production_content.contains("\"job::background\" =>")
                    && !production_content
                        .contains(&format!("\"{}\" =>", concat!("tool", "::result")))
                    && !production_content.contains("\"session::create\" =>"),
                "{} must bind by domain operation key, not canonical function id",
                rel.display()
            );
        }
    }
}

#[test]
fn retired_browser_stream_capabilities_stay_deleted() {
    let repo_root = repo_root();
    for root in [
        crate_root().join("src/domains"),
        repo_root.join("packages/ios-app/Sources"),
        repo_root.join("packages/ios-app/Tests"),
        repo_root.join("README.md"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for removed in [
                "browser::start_stream",
                "browser::stop_stream",
                "BrowserStartStream",
                "BrowserStopStream",
                "startBrowserStream",
                "stopBrowserStream",
            ] {
                assert!(
                    !content.contains(removed),
                    "{} contains retired browser stream capability `{removed}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }
}

#[test]
fn domains_and_runtime_do_not_import_client_transport_modules() {
    let crate_root = crate_root();
    for root in [
        crate_root.join("src/domains"),
        crate_root.join("src/transport/runtime"),
        crate_root.join("src/shared/server"),
    ] {
        for path in rust_files_under(&root) {
            let rel = path.strip_prefix(&crate_root).unwrap();
            if rel == Path::new("src/shared/server/test_support.rs") {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("server::transport") && !content.contains("crate::transport::"),
                "{} must not import client transport modules",
                rel.display()
            );
        }
    }
}

#[test]
fn domains_do_not_import_other_domains_private_operations() {
    let crate_root = crate_root();
    let domains_root = crate_root.join("src/domains");
    for path in rust_files_under(&domains_root) {
        let rel = path.strip_prefix(&crate_root).unwrap();
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));

        let Some(domain_name) = rel
            .components()
            .nth(2)
            .and_then(|component| component.as_os_str().to_str())
        else {
            continue;
        };

        for needle in ["crate::domains::", "super::super::"] {
            for line in content.lines().filter(|line| line.contains(needle)) {
                if !line.contains("::operations")
                    && !line.contains("::runtime::")
                    && !line.contains("::service")
                {
                    continue;
                }
                assert!(
                    line.contains(&format!("domains::{domain_name}::operations"))
                        || line.contains(&format!("domains::{domain_name}::runtime::"))
                        || line.contains(&format!("domains::{domain_name}::service"))
                        || line.contains("super::super::operations"),
                    "{} must not import another domain's private operations, runtime workflows, or services: {line}",
                    rel.display()
                );
            }
        }
    }
}

#[test]
fn main_background_work_is_registered_with_shutdown() {
    let main_runtime_path = crate_root().join("src/main_runtime.rs");
    let content = std::fs::read_to_string(&main_runtime_path)
        .unwrap_or_else(|e| panic!("failed to read {main_runtime_path:?}: {e}"));
    for required in [
        "register_blocking_supervisor_shutdown(server.shutdown())",
        "shutdown.register_task(handle)",
        "server.shutdown().register_task(sandbox_cleanup)",
        "server.shutdown().register_task(eviction_task)",
        "server.shutdown().register_task(cron_cancel_forwarder)",
        "shutdown_handles.push(h)",
    ] {
        assert!(
            content.contains(required),
            "main_runtime.rs must keep shutdown ownership marker `{required}`"
        );
    }
}

#[test]
fn operator_consequence_and_voice_note_resource_boundaries_stay_enforced() {
    let root = crate_root();
    let primitives_mod = std::fs::read_to_string(root.join("src/engine/primitives/mod.rs"))
        .expect("read primitives mod");
    assert!(
        primitives_mod.contains("mod action_summary"),
        "operator action summaries must have one primitive-owned helper boundary"
    );

    for rel in [
        "src/engine/primitives/control/actions.rs",
        "src/engine/primitives/module/actions.rs",
        "src/engine/primitives/module/trust_audit.rs",
        "src/engine/primitives/ui.rs",
    ] {
        let content = std::fs::read_to_string(root.join(rel)).unwrap_or_else(|error| {
            panic!("failed to read {rel}: {error}");
        });
        assert!(
            content.contains("action_summary"),
            "{rel} must use the canonical action-summary/consequence helper"
        );
    }

    let voice_contract = std::fs::read_to_string(root.join("src/domains/voice_notes/contract.rs"))
        .expect("read voice notes contract");
    assert!(
        voice_contract.contains("DurableOutputContract::resource_backed")
            && voice_contract.contains("materialized_file")
            && voice_contract.contains("artifact")
            && voice_contract.contains("\"resourceRefs\""),
        "voice_notes::save/delete must stay resource-backed and expose resourceRefs"
    );
    for rel in [
        "src/domains/voice_notes/mod.rs",
        "src/domains/voice_notes/service.rs",
    ] {
        let content = std::fs::read_to_string(root.join(rel)).unwrap_or_else(|error| {
            panic!("failed to read {rel}: {error}");
        });
        for forbidden in [
            "std::fs::write",
            "std::fs::read_dir",
            "std::fs::remove_file",
        ] {
            assert!(
                !content.contains(forbidden),
                "{rel} must not use {forbidden} as durable voice-note truth"
            );
        }
    }

    let engine_tests =
        std::fs::read_to_string(root.join("src/engine/tests/mod.rs")).expect("read engine tests");
    assert!(
        engine_tests.contains("mod domain_outputs;"),
        "voice-note resource-backed domain output tests must stay in the focused boundary"
    );
    let domain_output_tests =
        std::fs::read_to_string(root.join("src/engine/tests/domain_outputs.rs"))
            .expect("read domain output tests");
    for required in [
        "voice_notes_save_list_and_delete_are_resource_backed",
        "voice_notes_save_idempotency_does_not_duplicate_resources",
        "voice_notes_invalid_audio_fails_without_accepted_resource_refs",
    ] {
        assert!(
            domain_output_tests.contains(required),
            "domain output hardening test `{required}` must remain present"
        );
    }
}

#[test]
fn product_shell_reachability_and_prompt_library_resources_stay_enforced() {
    let repo = repo_root();
    let crate_root = crate_root();

    let prompt_library_root = repo
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Views")
        .join("PromptLibrary");
    let prompt_sheet =
        std::fs::read_to_string(prompt_library_root.join("PromptLibrarySheet.swift"))
            .expect("read PromptLibrarySheet");
    assert!(
        prompt_sheet.contains("PromptLibraryManagementSurfaceSheet")
            && prompt_sheet.contains("onSelect(text)")
            && prompt_sheet.contains("onSelect(item.text)")
            && !prompt_sheet.contains("SnippetEditorSheet")
            && !prompt_sheet.contains("showClearHistoryAlert")
            && !prompt_sheet.contains("isCreatingSnippet")
            && !prompt_sheet.contains("editingSnippet"),
        "PromptLibrarySheet must remain a thin picker and delegate management to generated UI"
    );
    assert!(
        !prompt_library_root
            .join("SnippetEditorSheet.swift")
            .exists(),
        "fixed Prompt Library snippet editor must stay removed"
    );
    let prompt_history_list =
        std::fs::read_to_string(prompt_library_root.join("PromptHistoryListView.swift"))
            .expect("read PromptHistoryListView");
    let prompt_snippet_list =
        std::fs::read_to_string(prompt_library_root.join("PromptSnippetListView.swift"))
            .expect("read PromptSnippetListView");
    let prompt_picker_state = std::fs::read_to_string(
        repo.join("packages/ios-app/Sources/ViewModels/State/PromptLibraryState.swift"),
    )
    .expect("read PromptLibraryState");
    assert!(
        prompt_history_list.contains(".onTapGesture { onSelect(item.text) }")
            && prompt_snippet_list.contains(".onTapGesture { onSelect(snippet.text) }"),
        "Prompt Library picker lists must remain selection-only composer insertion"
    );
    for (file, content) in [
        ("PromptLibrarySheet.swift", prompt_sheet.as_str()),
        ("PromptHistoryListView.swift", prompt_history_list.as_str()),
        ("PromptSnippetListView.swift", prompt_snippet_list.as_str()),
        ("PromptLibraryState.swift", prompt_picker_state.as_str()),
    ] {
        for forbidden in [
            "createSnippet",
            "updateSnippet",
            "deleteSnippet",
            "deleteHistory",
            "clearHistory",
            ".swipeActions",
            "targetFunctionId",
            "payloadTemplate",
            "requiredGrant",
            "UiActionSubmissionDTO",
        ] {
            assert!(
                !content.contains(forbidden),
                "{file} must not own fixed management or generated action path `{forbidden}`"
            );
        }
    }
    let prompt_management = std::fs::read_to_string(
        prompt_library_root.join("PromptLibraryManagementSurfaceSheet.swift"),
    )
    .expect("read generated prompt management sheet");
    for required in [
        "resource_collection",
        "prompt_library.snippets.v1",
        "prompt_library.history.v1",
        "GeneratedUISurfaceView",
        "submitUiAction",
    ] {
        assert!(
            prompt_management.contains(required),
            "generated Prompt Library management sheet must include `{required}`"
        );
    }
    for forbidden in ["targetFunctionId", "payloadTemplate", "requiredGrant"] {
        assert!(
            !prompt_management.contains(forbidden),
            "iOS generated Prompt Library management must not construct `{forbidden}`"
        );
    }

    let agent_control_root = repo
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Views")
        .join("AgentControl");
    let source_changes_root = repo
        .join("packages")
        .join("ios-app")
        .join("Sources")
        .join("Views")
        .join("SourceChanges");
    for (label, root) in [
        ("AgentControl", agent_control_root.as_path()),
        ("SourceChanges", source_changes_root.as_path()),
    ] {
        for entry in std::fs::read_dir(root)
            .unwrap_or_else(|error| panic!("read {label} source root: {error}"))
        {
            let entry = entry.unwrap_or_else(|error| panic!("read {label} entry: {error}"));
            let path = entry.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("swift") {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("read {path:?}: {error}"));
            for forbidden in [
                "targetFunctionId",
                "payloadTemplate",
                "requiredGrant",
                "UiActionSubmissionDTO",
            ] {
                assert!(
                    !content.contains(forbidden),
                    "{label} fixed shell file {path:?} must not construct generated action `{forbidden}`"
                );
            }
        }
    }

    let generated_ui_tests =
        std::fs::read_to_string(crate_root.join("src/engine/tests/generated_ui.rs"))
            .expect("read generated ui tests");
    for required in [
        "source_control.session.v1",
        "agent_control.session.v1",
        "ui_surface_for_target_authors_source_control_session_surface",
        "ui_surface_for_target_authors_agent_control_session_surface",
    ] {
        assert!(
            generated_ui_tests.contains(required),
            "generated UI tests must keep source-control/AgentControl generated boundary proof `{required}`"
        );
    }

    let prompt_contract =
        std::fs::read_to_string(crate_root.join("src/domains/prompt_library/contract.rs"))
            .expect("read prompt_library contract");
    assert!(
        prompt_contract.contains("DurableOutputContract")
            && prompt_contract.contains("resourceRefs")
            && prompt_contract.contains("artifact"),
        "prompt_library mutating contracts must stay resource-backed artifact outputs"
    );

    let prompt_deps =
        std::fs::read_to_string(crate_root.join("src/domains/prompt_library/deps.rs"))
            .expect("read prompt_library deps");
    assert!(
        prompt_deps.contains("engine_host: crate::engine::EngineHostHandle")
            && !prompt_deps.contains("event_store"),
        "prompt_library durable state must compose resource capabilities through the engine host"
    );

    let schema = std::fs::read_to_string(
        crate_root.join("src/domains/session/event_store/sqlite/migrations/v001_schema.sql"),
    )
    .expect("read consolidated schema");
    for forbidden in [
        "CREATE TABLE IF NOT EXISTS prompt_history",
        "CREATE TABLE IF NOT EXISTS prompt_snippets",
        "idx_prompt_history_",
        "idx_prompt_snippets_",
    ] {
        assert!(
            !schema.contains(forbidden),
            "active consolidated schema must not recreate retired prompt-library table/index `{forbidden}`"
        );
    }

    for rel in [
        "src/domains/prompt_library/mod.rs",
        "src/domains/prompt_library/deps.rs",
        "src/domains/prompt_library/handlers.rs",
        "src/domains/prompt_library/implementation/mod.rs",
    ] {
        let content = std::fs::read_to_string(crate_root.join(rel))
            .unwrap_or_else(|error| panic!("failed to read {rel}: {error}"));
        let production_content = content
            .split("#[cfg(test)]")
            .next()
            .unwrap_or(content.as_str());
        for forbidden in [
            "rusqlite",
            "prompt_snippets",
            "INSERT INTO prompt_",
            "UPDATE prompt_",
            "DELETE FROM prompt_",
            "SELECT ",
        ] {
            assert!(
                !production_content.contains(forbidden),
                "{rel} must not use prompt-library DB tables as runtime truth"
            );
        }
    }
    assert!(
        !crate_root
            .join("src/domains/prompt_library/implementation/store.rs")
            .exists(),
        "prompt_library store.rs must stay deleted; resources are source truth"
    );

    let engine_tests =
        std::fs::read_to_string(crate_root.join("src/engine/tests/mod.rs")).expect("read tests.rs");
    assert!(
        engine_tests.contains("mod prompt_library_resources;"),
        "prompt-library resource tests must stay in their focused boundary"
    );
    let prompt_resource_tests =
        std::fs::read_to_string(crate_root.join("src/engine/tests/prompt_library_resources.rs"))
            .expect("read prompt_library resource tests");
    for required in [
        "prompt_snippets_are_resource_backed_without_retired_tables",
        "prompt_history_is_resource_backed_deduped_without_retired_tables",
        "prompt_history_skip_and_validation_fail_without_accepted_refs",
        "prompt_library_idempotency_and_history_delete_clear_do_not_duplicate_resources",
    ] {
        assert!(
            prompt_resource_tests.contains(required),
            "prompt-library resource proof test `{required}` must remain present"
        );
    }
}

fn rust_files_under(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit_rust_files(root, &mut files);
    files
}

fn cleanup_scorecard_large_file_budgets(scorecard: &str) -> BTreeMap<String, usize> {
    let mut budgets = BTreeMap::new();
    let mut in_table = false;
    for line in scorecard.lines() {
        if line.starts_with("| File | LOC @ CLC-0 | Owner | Reason | Budget |")
            || line.starts_with("| File | Current LOC | Owner | Reason | Budget |")
        {
            in_table = true;
            continue;
        }
        if !in_table {
            continue;
        }
        if !line.starts_with('|') || line.trim().is_empty() {
            break;
        }
        if line.starts_with("|------") {
            continue;
        }
        let cells = line.split('|').map(str::trim).collect::<Vec<_>>();
        if cells.len() < 7 {
            continue;
        }
        let path = cells[1].trim_matches('`');
        let budget_digits = cells[5]
            .chars()
            .filter(char::is_ascii_digit)
            .collect::<String>();
        if path.is_empty() || budget_digits.is_empty() {
            continue;
        }
        let budget = budget_digits
            .parse::<usize>()
            .unwrap_or_else(|error| panic!("invalid cleanup budget `{}`: {error}", cells[5]));
        budgets.insert(path.to_owned(), budget);
    }
    budgets
}

fn cleanup_scorecard_large_files(repo_root: &Path, crate_root: &Path) -> BTreeMap<String, usize> {
    let mut files = Vec::new();
    files.extend(files_with_extensions(&crate_root.join("src"), &["rs"]));
    files.extend(files_with_extensions(&crate_root.join("tests"), &["rs"]));
    files.extend(files_with_extensions(
        &repo_root.join("packages/agent/skills"),
        &["sh"],
    ));
    for root in [
        repo_root.join("packages/ios-app/Sources"),
        repo_root.join("packages/ios-app/Tests"),
        repo_root.join("packages/mac-app/Sources"),
        repo_root.join("packages/mac-app/Tests"),
    ] {
        files.extend(files_with_extensions(&root, &["swift"]));
    }
    files.extend(files_with_extensions(&repo_root.join("scripts"), &["sh"]));
    files.push(repo_root.join("scripts/tron"));
    files.sort();
    files.dedup();

    let mut large_files = BTreeMap::new();
    for path in files {
        if !path.is_file() {
            continue;
        }
        let line_count = line_count(&path);
        if line_count > 1_000 {
            let relative = path
                .strip_prefix(repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            large_files.insert(relative, line_count);
        }
    }
    large_files
}

fn is_src_rust_test_file(path: &Path) -> bool {
    let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    if file_name == "tests.rs"
        || file_name.ends_with("_tests.rs")
        || file_name.starts_with("tests_")
    {
        return true;
    }
    path.components()
        .any(|component| component.as_os_str().to_str() == Some("tests"))
}

fn line_count(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        .lines()
        .count()
}

fn read_generated_ui_authoring_tree(crate_root: &Path) -> String {
    [
        "src/engine/primitives/ui/authoring/mod.rs",
        "src/engine/primitives/ui/authoring/actions.rs",
        "src/engine/primitives/ui/authoring/prompt.rs",
        "src/engine/primitives/ui/authoring/notifications.rs",
        "src/engine/primitives/ui/authoring/subagent.rs",
        "src/engine/primitives/ui/authoring/source_control.rs",
        "src/engine/primitives/ui/authoring/agent_control.rs",
    ]
    .into_iter()
    .map(|rel| {
        let path = crate_root.join(rel);
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    })
    .collect::<Vec<_>>()
    .join("\n")
}

fn read_module_source_trust_tree(crate_root: &Path) -> String {
    let mut files = vec![crate_root.join("src/engine/primitives/module/source_trust.rs")];
    files.extend(files_with_extensions(
        &crate_root.join("src/engine/primitives/module/source_trust"),
        &["rs"],
    ));
    files.sort();
    files
        .into_iter()
        .map(|path| {
            std::fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn files_to_scan(root: &Path) -> Vec<PathBuf> {
    if root.is_file() {
        return vec![root.to_path_buf()];
    }
    let mut files = Vec::new();
    visit_files(root, &mut files);
    files
}

fn files_with_extensions(root: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit_files_with_extensions(root, extensions, &mut files);
    files
}

fn visit_files_with_extensions(root: &Path, extensions: &[&str], files: &mut Vec<PathBuf>) {
    if !root.exists() {
        return;
    }
    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|e| panic!("failed to read directory {root:?}: {e}"));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| panic!("failed to read entry in {root:?}: {e}"));
        let path = entry.path();
        if path.is_dir() {
            visit_files_with_extensions(&path, extensions, files);
        } else if path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| extensions.contains(&ext))
        {
            files.push(path);
        }
    }
}

fn visit_files(root: &Path, files: &mut Vec<PathBuf>) {
    if !root.exists() {
        return;
    }
    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|e| panic!("failed to read directory {root:?}: {e}"));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| panic!("failed to read entry in {root:?}: {e}"));
        let path = entry.path();
        if path.is_dir() {
            visit_files(&path, files);
        } else if matches!(
            path.extension().and_then(|ext| ext.to_str()),
            Some("rs" | "md")
        ) {
            files.push(path);
        }
    }
}

fn visit_rust_files(path: &Path, files: &mut Vec<PathBuf>) {
    if path.is_file() {
        if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            files.push(path.to_path_buf());
        }
        return;
    }

    let entries = std::fs::read_dir(path)
        .unwrap_or_else(|e| panic!("failed to read directory {path:?}: {e}"));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| panic!("failed to read directory entry: {e}"));
        visit_rust_files(&entry.path(), files);
    }
}
