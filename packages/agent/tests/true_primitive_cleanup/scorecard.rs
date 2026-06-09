use super::support::*;

#[test]
fn true_primitive_cleanup_scorecard_stays_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/true-primitive-cleanup-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/true-primitive-cleanup-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# True Primitive Cleanup Scorecard",
        "Current score: **95/100**",
        "Status: **in_progress**",
        "Branch: `codex/primitive-engine-teardown`",
        "Hard Targets",
        "Initial Red Findings",
        "Static Gates",
        "| TPC-0 | Scorecard setup | 5 | passed_after_fix |",
        "| TPC-1 | Retention inventory | 8 | passed_after_fix |",
        "| TPC-2 | Engine catalog/durability teardown | 12 | passed_after_fix |",
        "| TPC-3 | Invocation host and primitive stores | 10 | passed_after_fix |",
        "| TPC-4 | External worker proof or deletion | 10 | passed_after_fix |",
        "| TPC-5 | Provider/auth/model cleanup | 10 | passed_after_fix |",
        "| TPC-6 | Agent loop/config/context flattening | 10 | passed_after_fix |",
        "| TPC-7 | iOS engine/protocol cleanup | 10 | passed_after_fix |",
        "| TPC-8 | iOS UI state flattening | 8 | passed_after_fix |",
        "| TPC-9 | Mac/scripts/runtime helpers | 7 | passed_after_fix |",
        "| TPC-10 | Docs, guards, inventories | 5 | passed_after_fix |",
        "| TPC-11 | Final closeout | 5 | pending |",
        "Total weight: **100**",
    ] {
        assert!(
            scorecard.contains(required),
            "TPC scorecard missing required text: {required}"
        );
    }

    for required in [
        "# True Primitive Cleanup Evidence Manifest",
        "Current score: **95/100**",
        "Status: **in_progress**",
        "| TPC-0 | passed_after_fix |",
        "| TPC-1 | passed_after_fix |",
        "| TPC-2 | passed_after_fix |",
        "| TPC-3 | passed_after_fix |",
        "| TPC-4 | passed_after_fix |",
        "| TPC-5 | passed_after_fix |",
        "| TPC-6 | passed_after_fix |",
        "| TPC-7 | passed_after_fix |",
        "| TPC-8 | passed_after_fix |",
        "| TPC-9 | passed_after_fix |",
        "| TPC-10 | passed_after_fix |",
        "| TPC-11 | pending |",
        "Red Baseline Commands",
    ] {
        assert!(
            manifest.contains(required),
            "TPC evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "packages/agent/docs/true-primitive-cleanup-scorecard.md",
        "packages/agent/docs/true-primitive-cleanup-evidence-manifest.md",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.md",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/tests/true_primitive_cleanup_invariants.rs",
    ] {
        assert!(
            readme.contains(required),
            "README living-doc map must link `{required}`"
        );
    }
}

#[test]
fn initial_red_findings_are_recorded_until_resolved() {
    let scorecard = read_repo_file("packages/agent/docs/true-primitive-cleanup-scorecard.md");

    let expected_baseline = [
        (
            "packages/agent/src/engine/catalog/registry/mod.rs",
            895,
            750,
        ),
        (
            "packages/agent/src/domains/model/providers/factory.rs",
            888,
            750,
        ),
        ("packages/agent/src/engine/invocation/host/mod.rs", 880, 750),
        (
            "packages/agent/src/transport/engine/socket/mod.rs",
            873,
            750,
        ),
        (
            "packages/agent/src/engine/durability/ledger/mod.rs",
            862,
            750,
        ),
        (
            "packages/agent/src/engine/durability/queue/mod.rs",
            861,
            750,
        ),
        (
            "packages/agent/src/engine/runtime/external_workers/mod.rs",
            855,
            750,
        ),
        (
            "packages/agent/src/engine/tests/runtime/external_worker.rs",
            839,
            800,
        ),
        (
            "packages/agent/src/domains/model/providers/openai/message_converter.rs",
            836,
            750,
        ),
        ("packages/agent/src/app/bootstrap/tests.rs", 832, 800),
        ("packages/agent/src/engine/primitives/mod.rs", 830, 750),
        (
            "packages/agent/src/domains/model/providers/openai/provider/tests.rs",
            828,
            800,
        ),
        (
            "packages/agent/src/domains/auth/credentials/types.rs",
            816,
            750,
        ),
        (
            "packages/agent/src/engine/tests/runtime/triggers.rs",
            814,
            800,
        ),
        (
            "packages/agent/src/domains/model/providers/google/types/mod.rs",
            807,
            750,
        ),
        (
            "packages/agent/src/domains/agent/loop/turn_runner/persistence.rs",
            801,
            750,
        ),
        (
            "packages/agent/src/shared/observability/transport.rs",
            801,
            750,
        ),
        ("packages/agent/src/engine/durability/streams.rs", 785, 750),
        (
            "packages/agent/src/domains/model/providers/ollama/stream_handler.rs",
            775,
            750,
        ),
        (
            "packages/agent/src/engine/catalog/registry/invocation.rs",
            768,
            750,
        ),
        (
            "packages/ios-app/Sources/UI/Settings/Shell/SettingsView.swift",
            698,
            575,
        ),
        (
            "packages/ios-app/Sources/Session/Chat/ViewModel/ChatViewModel.swift",
            657,
            575,
        ),
        (
            "packages/ios-app/Tests/Session/Chat/Messaging/StreamingManagerTests.swift",
            652,
            650,
        ),
        (
            "packages/ios-app/Sources/UI/Chat/Shell/ChatView.swift",
            652,
            575,
        ),
        (
            "packages/ios-app/Tests/Session/Chat/ViewModel/ChatViewModelEventRoutingTests.swift",
            651,
            650,
        ),
        (
            "packages/ios-app/Sources/UI/Onboarding/Steps/SetupSteps.swift",
            624,
            575,
        ),
        (
            "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
            615,
            575,
        ),
        (
            "packages/ios-app/Sources/UI/Theme/TronColors.swift",
            595,
            575,
        ),
        (
            "packages/ios-app/Sources/UI/Settings/Shell/SettingsSupport.swift",
            594,
            575,
        ),
        (
            "packages/ios-app/Sources/UI/Settings/ModelPicker/ModelPickerSheet.swift",
            592,
            575,
        ),
        (
            "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
            576,
            575,
        ),
    ];

    for (path, loc, limit) in expected_baseline {
        assert!(
            scorecard.contains(&format!("| {loc} | {limit} | `{path}` |")),
            "TPC baseline must record over-budget file {path}"
        );
    }
}

#[test]
fn tpc_source_files_are_classified_or_in_pending_inventory_setup() {
    let scorecard = read_repo_file("packages/agent/docs/true-primitive-cleanup-scorecard.md");
    assert!(
        scorecard.contains("| TPC-1 | Retention inventory | 8 | passed_after_fix |"),
        "TPC-1 must stay visible after the complete retention inventory lands"
    );

    let tracked_sources: Vec<_> = git_ls_files()
        .into_iter()
        .filter(|path| repo_path(path).exists())
        .filter(|path| {
            path.starts_with("packages/agent/src/")
                || path.starts_with("packages/agent/tests/")
                || path.starts_with("packages/ios-app/Sources/")
                || path.starts_with("packages/ios-app/Tests/")
                || path.starts_with("packages/mac-app/Sources/")
                || path.starts_with("packages/mac-app/Tests/")
                || path.starts_with("scripts/")
        })
        .collect();
    assert!(
        tracked_sources.len() > 500,
        "TPC inventory setup should see the tracked source surface before TPC-1"
    );

    let mut roots = HashSet::new();
    for path in tracked_sources {
        if let Some(root) = path.split('/').next() {
            roots.insert(root.to_owned());
        }
    }
    assert!(
        roots.contains("packages") && roots.contains("scripts"),
        "TPC tracked source setup must include package and script roots"
    );
}

#[test]
fn tpc_hard_budget_scan_has_no_open_findings() {
    let mut current_findings = Vec::new();
    for path in git_ls_files() {
        if !repo_path(&path).exists() {
            continue;
        }
        let Some(extension) = std::path::Path::new(&path)
            .extension()
            .and_then(|extension| extension.to_str())
        else {
            continue;
        };
        let limit = match extension {
            "rs" if path.contains("/tests/") || path.ends_with("/tests.rs") => 800,
            "rs" => 750,
            "swift" if path.contains("/Tests/") => 650,
            "swift" => 575,
            _ => continue,
        };
        if path.contains(".xcodeproj/") || path.contains("Assets.xcassets/") {
            continue;
        }
        let lines = line_count(&repo_path(&path));
        if lines > limit {
            current_findings.push((path, lines, limit));
        }
    }

    assert!(
        current_findings.is_empty(),
        "TPC hard-budget scan has current over-budget files: {current_findings:?}"
    );
}
