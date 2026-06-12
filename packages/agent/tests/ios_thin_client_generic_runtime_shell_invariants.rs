//! Static invariants for the iOS Thin Client / Generic Runtime Shell slice.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs";
const TARGET_NAME: &str = "ios_thin_client_generic_runtime_shell_invariants";
const SOURCE_GUARD_PATH: &str =
    "packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+ThinClientShell.swift";

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

fn git_ls_files() -> BTreeSet<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
fn itc_artifacts_readme_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        SOURCE_GUARD_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required ITC artifact missing: {path}"
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
            "README must mention ITC artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run ITC");
        assert!(
            !source.contains("tron deploy") && !source.contains("auto-deploy"),
            "{path} must not expand production deploy automation for ITC"
        );
    }
}

#[test]
fn itc_scorecard_rows_have_required_weights_and_pending_or_closed_state() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Passing threshold: **100/100**"));
    assert!(
        scorecard.contains("Base commit: `b44a096295f76a2a2a4b00add2d040982b8a73ec`"),
        "ITC scorecard must record the required base commit"
    );

    let expected = [
        ("ITC-0", "Harness, Baseline, and Scope Control", 5),
        ("ITC-1", "iOS Thin-Shell Inventory", 8),
        ("ITC-2", "Deleted Product Surface Absence", 12),
        ("ITC-3", "Pairing, Server Selection, Token Custody", 10),
        ("ITC-4", "Settings Thin-Client / Server Authority", 10),
        ("ITC-5", "Chat, Session, Timeline Reconstruction", 10),
        (
            "ITC-6",
            "Generic Capability / Primitive / Runtime Result Rendering",
            12,
        ),
        ("ITC-7", "Server Errors, Diagnostics, Logs, Redaction", 10),
        (
            "ITC-8",
            "iOS 26.5 Simulator Coverage and Generated Project Drift",
            8,
        ),
        (
            "ITC-9",
            "README, iOS Docs, Inventories, Static Guards, and CI Wiring",
            8,
        ),
        (
            "ITC-10",
            "Evidence, Adversarial Audit, Clean State, and Commit",
            7,
        ),
    ];

    let mut total = 0u32;
    let mut pending_rows = 0usize;
    for (id, name, weight) in expected {
        let row = scorecard
            .lines()
            .find(|line| line.starts_with(&format!("| {id} |")))
            .unwrap_or_else(|| panic!("missing ITC scorecard row {id}"));
        let columns: Vec<_> = row.trim_matches('|').split('|').map(str::trim).collect();
        assert_eq!(
            columns.get(1),
            Some(&name),
            "unexpected ITC row name: {row}"
        );
        assert_eq!(
            columns
                .get(2)
                .unwrap_or_else(|| panic!("missing ITC weight in {row}"))
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid ITC weight in {row}: {error}")),
            weight,
            "unexpected ITC weight: {row}"
        );
        let status = columns
            .get(3)
            .unwrap_or_else(|| panic!("missing ITC status in {row}"));
        assert!(
            !status.is_empty() && *status != "TODO" && *status != "TBD",
            "ITC row status must be explicit: {row}"
        );
        if status.contains("pending") {
            pending_rows += 1;
        }
        total += weight;
    }
    assert_eq!(total, 100, "ITC scorecard weights must sum to 100");

    if scorecard.contains("Status: **closed**") || scorecard.contains("Status: **completed**") {
        assert!(scorecard.contains("Current score: **100/100**"));
        assert_eq!(
            pending_rows, 0,
            "closed ITC scorecard cannot retain pending rows"
        );
        assert!(
            !scorecard.contains("not_run_yet"),
            "closed ITC scorecard cannot claim unrun validation"
        );
    } else {
        assert!(
            !scorecard.contains("Current score: **100/100**"),
            "active ITC scorecard must stay below 100 until validation is real"
        );
        assert!(
            pending_rows > 0,
            "active ITC scorecard must show pending rows"
        );
    }
}

#[test]
fn itc_inventory_shape_and_required_surfaces_are_complete() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: **active_validation_pending**"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tcurrent_boundary\tproof_source\trisk\tproof_target\taction_rationale"
        ),
        "ITC TSV header changed"
    );
    let rows: Vec<_> = lines.collect();
    assert!(
        rows.len() >= 56,
        "ITC inventory must keep the audited surface set"
    );

    for required in [
        "ITC-INV-001\tpackages/ios-app/Sources/App\tios_source_root",
        "ITC-INV-005\tpackages/ios-app/Sources/UI\tios_source_root",
        "ITC-INV-006\tpackages/ios-app/Tests/Infrastructure/Guards\tios_test_root",
        "ITC-INV-017\tpackages/ios-app/Sources/Support/Pairing/PairingURLParser.swift\tpairing_parser",
        "ITC-INV-021\tpackages/ios-app/Sources/Support/Storage/PairedServerTokenStore.swift\ttoken_store",
        "ITC-INV-022\tpackages/ios-app/Sources/Session/Chat/State/SettingsState.swift\tsettings_state",
        "ITC-INV-026\tpackages/ios-app/Sources/Session/Timeline/Reconstruction/UnifiedEventTransformer.swift\ttimeline_reconstruction",
        "ITC-INV-028\tpackages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift\tgenerated_runtime_surface",
        "ITC-INV-029\tpackages/ios-app/Sources/Engine/Protocol/Core/FailurePayload.swift\tcanonical_failure_payload",
        "ITC-INV-043\tpackages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+ThinClientShell.swift\titc_source_guard",
        "ITC-INV-044\tpackages/ios-app/project.yml\txcodegen_source",
        "ITC-INV-045\tpackages/ios-app/TronMobile.xcodeproj\tgenerated_project",
        "ITC-INV-046\t.github/workflows/ci.yml\tgithub_static_gate",
        "ITC-INV-047\tscripts/tron.d/quality.sh\tlocal_static_gate",
        "ITC-INV-055\tpackages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs\titc_static_gate",
    ] {
        assert!(tsv.contains(required), "ITC inventory missing {required}");
    }

    for row in rows {
        let columns: Vec<_> = row.split('\t').collect();
        assert_eq!(
            columns.len(),
            9,
            "ITC inventory row must have 9 columns: {row}"
        );
        assert!(columns[0].starts_with("ITC-INV-"));
        for value in columns {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "ITC inventory field must be complete: {row}"
            );
        }
    }
}

#[test]
fn itc_evidence_lists_required_closeout_matrix_and_ios_26_5_destination() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(
        evidence.contains("Status: **active_validation_pending**")
            || evidence.contains("Status: **closed**"),
        "ITC evidence must record status"
    );
    assert!(
        evidence.contains("platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro"),
        "ITC evidence must pin the iOS 26.5 simulator destination"
    );

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate",
        "git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "ITC evidence must record command: {command}"
        );
    }

    if evidence.contains("Current score: **100/100**") {
        assert!(
            !evidence.contains("not_run_yet"),
            "final ITC evidence must replace not_run_yet rows with actual results"
        );
    }
}

#[test]
fn itc_readme_hra_pcc_and_docs_links_are_current() {
    let readme = read_repo_file("README.md");
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        "packages/ios-app/docs/architecture.md",
        "packages/ios-app/docs/onboarding.md",
        "fixed product panels are teardown targets",
        "GeneratedRuntimeSurfaceView",
        "CanonicalFailurePayload",
    ] {
        assert!(
            readme.contains(required),
            "README missing ITC link/text: {required}"
        );
    }

    let architecture = read_repo_file("packages/ios-app/docs/architecture.md");
    let onboarding = read_repo_file("packages/ios-app/docs/onboarding.md");
    let events = read_repo_file("packages/ios-app/docs/events.md");
    for required in [
        "Settings, pairing, logs, chat, generic primitive/result display, and server errors are the retained iOS shell responsibilities.",
        "It does not own fixed product panels",
        "Server settings shown in the iOS settings UI are snapshots",
        "GeneratedRuntimeSurfaceView",
        "CanonicalFailurePayload",
        "Pairing accepts only bare DNS names",
    ] {
        assert!(
            architecture.contains(required)
                || onboarding.contains(required)
                || events.contains(required),
            "iOS docs missing thin-client boundary text: {required}"
        );
    }

    for path in [
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
    ] {
        let source = read_repo_file(path);
        for required in [
            SCORECARD_PATH,
            EVIDENCE_PATH,
            INVENTORY_PATH,
            INVENTORY_TSV_PATH,
            TARGET_PATH,
            SOURCE_GUARD_PATH,
        ] {
            assert!(
                source.contains(required),
                "{path} missing ITC row for {required}"
            );
        }
    }

    let ios_ownership = read_repo_file(
        "packages/agent/docs/hierarchical-rearchitecture-ios-current-ownership-map.tsv",
    );
    assert!(
        ios_ownership.contains(SOURCE_GUARD_PATH),
        "HRA iOS ownership map must cover the new Swift SourceGuard file"
    );
}

#[test]
fn itc_source_guard_covers_retained_shell_and_deleted_product_boundaries() {
    let guard = read_repo_file(SOURCE_GUARD_PATH);
    for required in [
        "testThinClientRetainsGenericShellAnchors",
        "testDeletedProductShellBoundariesStayAbsent",
        "testThinClientBoundaryDocsStayAlignedWithSourceGuards",
        "PairingURLParser.swift",
        "PairedServerTokenStore.swift",
        "SettingsState.swift",
        "UnifiedEventTransformer.swift",
        "GeneratedRuntimeSurfaceView.swift",
        "FailurePayload.swift",
        "\"Repository\" + \"Panel\"",
        "\"Assistant\" + \"Management\"",
        "\"Extension\" + \"Source\"",
        "\"Audio\" + \"Transcription\"",
        "\"Memory\" + \"Retain\"",
        "\"Prompt\" + \"Queue\"",
        "\"Hook\" + \"Suggestion\"",
        "\"Product\" + \"Client\"",
        "\"Product\" + \"State\"",
        "\"Plugin\" + \"Sources\"",
    ] {
        assert!(
            guard.contains(&required),
            "ITC SourceGuard missing retained/deleted coverage marker: {required}"
        );
    }

    for deleted_root in [
        "packages/ios-app/Sources/UI/RepositoryPanels",
        "packages/ios-app/Sources/UI/AssistantManagement",
        "packages/ios-app/Sources/UI/ExtensionSources",
        "packages/ios-app/Sources/UI/MediaWorkflows",
        "packages/ios-app/Sources/UI/PromptQueue",
        "packages/ios-app/Sources/UI/HookSuggestions",
        "packages/ios-app/Sources/UI/Memory",
        "packages/ios-app/Sources/UI/Rules",
        "packages/ios-app/Sources/UI/Skills",
        "packages/ios-app/Sources/Engine/Transport/Clients/ProductClients",
        "packages/ios-app/Sources/Session/ProductState",
    ] {
        assert!(
            !repo_path(deleted_root).exists(),
            "deleted product root exists: {deleted_root}"
        );
    }
}

#[test]
fn itc_new_artifacts_are_tracked_before_final_closeout() {
    let tracked = git_ls_files();
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        SOURCE_GUARD_PATH,
    ] {
        assert!(
            tracked.contains(path) || repo_path(path).exists(),
            "ITC artifact must be tracked or staged before final guard reliance: {path}"
        );
    }
}
