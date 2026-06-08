use super::support::*;

#[test]
fn mac_generated_project_policy_is_truthful() {
    let tracked = git_ls_files();
    assert!(
        !tracked
            .iter()
            .any(|path| path.starts_with("packages/mac-app/TronMac.xcodeproj/")),
        "Mac XcodeGen output must remain untracked"
    );

    let mac_gitignore = read_repo_file("packages/mac-app/.gitignore");
    assert!(
        mac_gitignore.contains("TronMac.xcodeproj/"),
        "packages/mac-app/.gitignore must ignore generated TronMac.xcodeproj"
    );

    let mut hits = Vec::new();
    for (workflow, required_commands) in [
        (
            ".github/workflows/ci.yml",
            [
                "xcodegen generate",
                "-project TronMac.xcodeproj",
                "xcodebuild test",
            ]
            .as_slice(),
        ),
        (
            ".github/workflows/release-mac.yml",
            [
                "xcodegen generate",
                "-project TronMac.xcodeproj",
                "xcodebuild archive",
            ]
            .as_slice(),
        ),
    ] {
        let text = read_repo_file(workflow);
        if text.contains("git diff --exit-code packages/mac-app/TronMac.xcodeproj") {
            hits.push(format!(
                "{workflow}: hollow Mac generated-project drift check"
            ));
        }
        if !text.contains("git check-ignore -q packages/mac-app/TronMac.xcodeproj") {
            hits.push(format!(
                "{workflow}: missing ignored Mac project policy proof"
            ));
        }
        for required in required_commands {
            if !text.contains(required) {
                hits.push(format!(
                    "{workflow}: missing Mac generated-project build/test proof `{required}`"
                ));
            }
        }
    }
    assert_no_hits(
        "Mac generated-project policy must be generation + build/test, not tracked diff",
        hits,
    );
}

#[test]
fn documented_source_truth_paths_exist_or_use_supported_globs() {
    let docs = [
        ("README.md", read_repo_file("README.md")),
        ("AGENTS.md", read_repo_file("AGENTS.md")),
    ];
    let banned_paths = [
        "packages/agent/src/domains/settings/implementation/types/",
        "packages/agent/src/domains/auth/provider_credentials/",
        "packages/agent/src/shared/protocol/events.rs",
        "packages/agent/src/shared/foundation/paths.rs",
    ];
    let required_paths = [
        "packages/agent/src/domains/settings/profile/types/",
        "packages/agent/src/domains/auth/credentials/",
        "packages/agent/src/shared/protocol/events/",
        "packages/agent/src/shared/foundation/paths/",
    ];

    let mut hits = Vec::new();
    for (name, text) in docs {
        for banned in banned_paths {
            if text.contains(banned) {
                hits.push(format!("{name}: stale source-truth path `{banned}`"));
            }
        }
        for required in required_paths {
            if !text.contains(required) {
                hits.push(format!("{name}: missing source-truth path `{required}`"));
            }
        }
        for required in required_paths {
            if !repo_path(required).exists() {
                hits.push(format!(
                    "{name}: required source-truth path does not exist: `{required}`"
                ));
            }
        }
    }

    assert_no_hits(
        "README/AGENTS source-of-truth paths must exist or be explicit supported globs",
        hits,
    );
}

#[test]
fn startup_domains_and_database_inventory_match_runtime_truth() {
    let readme = read_repo_file("README.md");
    let registration = read_repo_file("packages/agent/src/domains/registration/mod.rs");

    let expected_domains = [
        "system",
        "capability",
        "blob",
        "message",
        "settings",
        "auth",
        "agent",
        "logs",
        "session",
    ];

    let mut hits = Vec::new();
    let startup_section = readme
        .split("Startup registration currently keeps only loop infrastructure domains:")
        .nth(1)
        .and_then(|rest| rest.split("The agent namespace").next())
        .unwrap_or_default();
    if startup_section.contains("`context`") {
        hits.push("README startup-domain list still claims registered `context` domain".to_owned());
    }
    for domain in expected_domains {
        if !registration.contains(&format!("{domain}::worker_module")) {
            hits.push(format!("registration missing `{domain}` worker module"));
        }
        if !startup_section.contains(&format!("`{domain}`")) {
            hits.push(format!("README startup-domain list missing `{domain}`"));
        }
    }

    let mut actual_tables = create_table_names(&read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    ));
    for file in [
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_codec.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/authority/compensation.rs",
        "packages/agent/src/engine/durability/queue/mod.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/resources/store/sqlite_codec.rs",
    ] {
        actual_tables.extend(create_table_names(&read_repo_file(file)));
    }

    let documented_tables = markdown_code_spans(&readme)
        .into_iter()
        .filter(|path| {
            path.starts_with("engine_")
                || path.starts_with("storage_")
                || [
                    "schema_version",
                    "workspaces",
                    "sessions",
                    "events",
                    "blobs",
                    "logs",
                    "trace_records",
                ]
                .contains(&path.as_str())
        })
        .collect::<std::collections::BTreeSet<_>>();

    for table in actual_tables {
        if !documented_tables.contains(&table) {
            hits.push(format!("README database table inventory missing `{table}`"));
        }
    }

    assert_no_hits(
        "README startup domains and database inventory must match runtime truth",
        hits,
    );
}

#[test]
fn mac_launch_agent_and_subprocess_have_physical_owners() {
    let mut hits = Vec::new();
    for path in [
        "packages/mac-app/Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift",
        "packages/mac-app/Tests/Server/LaunchAgent/LiveLaunchAgentManagerTests.swift",
        "packages/mac-app/Sources/Support/Foundation/Subprocess.swift",
    ] {
        if !repo_path(path).exists() {
            hits.push(format!("missing physical owner `{path}`"));
        }
    }

    let server_ping = read_repo_file("packages/mac-app/Sources/Server/Health/ServerPing.swift");
    for forbidden in [
        "LiveLaunchAgentManager",
        "SMAppService",
        "launchctl",
        "enum Subprocess",
    ] {
        if server_ping.contains(forbidden) {
            hits.push(format!(
                "ServerPing.swift still owns launch-agent/process concern `{forbidden}`"
            ));
        }
    }

    assert_no_hits(
        "Mac launch-agent manager and subprocess helper must live under their owners",
        hits,
    );
}

#[test]
fn mac_source_guards_cover_wrapper_contracts() {
    let guard_path = "packages/mac-app/Tests/Infrastructure/Guards/MacSourceGuardTests.swift";
    let mut hits = Vec::new();
    if !repo_path(guard_path).exists() {
        hits.push(format!("missing `{guard_path}`"));
    } else {
        let guard = read_repo_file(guard_path);
        for required in [
            "required roots",
            "banned roots",
            "helper-resource layout",
            "staged-binary policy",
            "bundle-agent --clean",
            "590",
        ] {
            if !guard.contains(required) {
                hits.push(format!("{guard_path}: missing guard coverage `{required}`"));
            }
        }
    }

    let bundle = read_repo_file("packages/mac-app/scripts/bundle-agent.sh");
    if !bundle.contains("--clean") {
        hits.push("bundle-agent.sh missing --clean mode".to_owned());
    }
    assert_no_hits(
        "Mac SourceGuard-style tests must cover wrapper source/resource/script policy",
        hits,
    );
}

#[test]
fn ios_transport_and_chat_tests_mirror_production_owners() {
    let mut hits = Vec::new();
    for required in [
        "packages/ios-app/Tests/Engine/Transport/Retry/ConnectionManagerTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Retry/ConnectionErrorClassifierTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Retry/ConnectionToastPolicyTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Retry/NetworkDiagnosticsFormatterTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Retry/ReconnectProbePolicyTests.swift",
        "packages/ios-app/Tests/Engine/Transport/WebSocket/EngineClientTests.swift",
        "packages/ios-app/Tests/Engine/Transport/WebSocket/WebSocketAuthTests.swift",
        "packages/ios-app/Tests/Session/Chat/Coordinators/MessagingCoordinatorTests.swift",
        "packages/ios-app/Tests/Session/Chat/Messaging/StreamingManagerTests.swift",
        "packages/ios-app/Tests/Session/Chat/ViewModel/ChatViewModelEventRoutingTests.swift",
    ] {
        if !repo_path(required).exists() {
            hits.push(format!("missing mirrored iOS test owner `{required}`"));
        }
    }
    for stale in [
        "packages/ios-app/Tests/Engine/Transport/Clients/ConnectionManagerTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Clients/ConnectionErrorClassifierTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Clients/ConnectionToastPolicyTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Clients/NetworkDiagnosticsFormatterTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Clients/ReconnectProbePolicyTests.swift",
    ] {
        if repo_path(stale).exists() {
            hits.push(format!("stale iOS test path remains `{stale}`"));
        }
    }

    let sourceguard = list_tracked_files_with_extension("swift")
        .into_iter()
        .filter(|path| {
            path.starts_with("packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests")
        })
        .map(|path| read_repo_file(&path))
        .collect::<Vec<_>>()
        .join("\n");
    for required in [
        "Sources/Engine/Transport/Retry",
        "Tests/Session/Chat/ViewModel",
    ] {
        if !sourceguard.contains(required) {
            hits.push(format!(
                "SourceGuard missing dense-root coverage `{required}`"
            ));
        }
    }

    assert_no_hits(
        "iOS transport/chat tests must mirror production owner folders",
        hits,
    );
}

#[test]
fn rust_progressive_docs_and_loc_split_plans_are_current() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let mut hits = Vec::new();
    for file in [
        "packages/agent/src/app/mod.rs",
        "packages/agent/src/domains/mod.rs",
        "packages/agent/src/engine/mod.rs",
        "packages/agent/src/shared/mod.rs",
        "packages/agent/src/transport/mod.rs",
    ] {
        let source = read_repo_file(file);
        for section in [
            "## Submodules",
            "## Entry Points",
            "## Invariants",
            "## Test Ownership",
        ] {
            if !source.contains(section) {
                hits.push(format!("{file} missing progressive-doc section {section}"));
            }
        }
    }

    for extension in ["rs", "swift"] {
        for file in list_tracked_files_with_extension(extension) {
            if !(file.starts_with("packages/agent/src/")
                || file.starts_with("packages/agent/tests/")
                || file.starts_with("packages/ios-app/Sources/")
                || file.starts_with("packages/ios-app/Tests/")
                || file.starts_with("packages/mac-app/Sources/")
                || file.starts_with("packages/mac-app/Tests/"))
            {
                continue;
            }
            let loc = source_line_count(&file);
            if loc >= 890
                && !(scorecard.contains(&format!("| `{file}` | {loc} |"))
                    && scorecard.contains("concrete split plan"))
            {
                hits.push(format!(
                    "{file}: {loc} LOC lacks current concrete split plan row"
                ));
            }
        }
    }

    assert_no_hits("Rust docs and 890+ LOC split plans must be current", hits);
}

#[test]
fn local_and_github_ci_run_the_same_static_closeout_targets() {
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let ci = read_repo_file(".github/workflows/ci.yml");
    let required_targets = [
        "primitive_engine_teardown_plan_invariants",
        "primitive_code_cleanup_invariants",
        "hierarchical_rearchitecture_invariants",
        "post_hra_adversarial_hardening_invariants",
        "post_aha_adversarial_closeout_invariants",
        "primitive_trace_execution",
        "db_path_guard",
        "integration",
    ];
    let mut hits = Vec::new();
    for target in required_targets {
        if !quality.contains(&format!("\n        {target}\n")) {
            hits.push(format!(
                "scripts/tron ci test target array missing `{target}`"
            ));
        }
        let ci_command = match target {
            "integration" => {
                "cargo test --test integration -- --test-threads=1 --quiet".to_string()
            }
            _ => format!("cargo test --test {target} -- --quiet"),
        };
        if !ci.contains(&ci_command) {
            hits.push(format!("GitHub CI missing command `{ci_command}`"));
        }
    }
    assert_no_hits(
        "Local and GitHub CI must run the same closeout target set",
        hits,
    );
}

#[test]
fn aha_provenance_privacy_and_residue_policy_are_in_repo() {
    let mut hits = Vec::new();
    for path in [
        "packages/agent/docs/post-hra-adversarial-hardening-plan-summary.md",
        "packages/agent/docs/post-aha-adversarial-closeout-scorecard.md",
        "packages/agent/docs/post-aha-adversarial-closeout-evidence-manifest.md",
    ] {
        if !repo_path(path).exists() {
            hits.push(format!("missing in-repo provenance artifact `{path}`"));
        }
    }

    let privacy_guard = read_repo_file("scripts/personal-info-guard.sh");
    for required in [
        "packages/mac-app",
        "packages/ios-app",
        "packages/agent",
        "AGENTS.md",
        "README.md",
    ] {
        if !privacy_guard.contains(required) {
            hits.push(format!(
                "personal-info guard missing scan scope `{required}`"
            ));
        }
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Allowed fallback/compatibility wording contexts",
        "historical evidence",
        "provider protocol term",
        "external CLI behavior",
    ] {
        if !scorecard.contains(required) {
            hits.push(format!("PAC scorecard missing residue policy `{required}`"));
        }
    }

    assert_no_hits(
        "AHA provenance, privacy coverage, and residue policy must be durable in repo",
        hits,
    );
}
