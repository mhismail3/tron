use super::support::*;

#[test]
fn mac_app_sources_stay_consolidated_to_primitive_roots() {
    for path in [
        "packages/mac-app/Sources/App/Lifecycle/TronMacApp.swift",
        "packages/mac-app/Sources/App/Composition/EnvironmentSetup.swift",
        "packages/mac-app/Sources/App/CommandMode/MacCommandLineMode.swift",
        "packages/mac-app/Sources/Server/LaunchAgent/LaunchAgentManaging.swift",
        "packages/mac-app/Sources/Server/Health/ServerPing.swift",
        "packages/mac-app/Sources/Server/Paths/TronPaths.swift",
        "packages/mac-app/Sources/Support/Onboarding/OnboardingModels.swift",
        "packages/mac-app/Sources/Support/Theme/TronColors.swift",
        "packages/mac-app/Sources/Support/Pairing/PairingURLBuilder.swift",
    ] {
        assert!(
            repo_path(path).exists(),
            "Mac primitive root missing retained file `{path}`"
        );
    }

    for path in [
        "packages/mac-app/Sources/TronMacApp.swift",
        "packages/mac-app/Sources/EnvironmentSetup.swift",
        "packages/mac-app/Sources/Services",
        "packages/mac-app/Sources/Theme",
        "packages/mac-app/Sources/Support/Observability",
        "packages/mac-app/Tests/Mocks",
        "packages/mac-app/Tests/Services",
        "packages/mac-app/Tests/Observability",
    ] {
        assert!(
            !repo_path(path).exists(),
            "Mac source root must not retain old grouping path `{path}`"
        );
    }
}

#[test]
fn scripts_surface_stays_manual_and_documented() {
    for path in ["scripts/auto-deploy", "scripts/tron.d/automation.sh"] {
        assert!(
            !repo_path(path).exists(),
            "automatic deployment helper must stay deleted: {path}"
        );
    }

    for path in [
        "README.md",
        "scripts/tron",
        "scripts/tron-cli",
        "scripts/tron-lib.sh",
        "packages/mac-app/Sources/Server/Paths/TronPaths.swift",
    ] {
        let text = read_repo_file(path);
        for banned in [
            concat!("auto", "-", "deploy"),
            "AUTO_DEPLOY",
            concat!("cmd_", "auto", "_deploy"),
            "com.tron.auto-deploy",
        ] {
            assert!(
                !text.contains(banned),
                "manual script surface must not retain `{banned}` in {path}"
            );
        }
    }
}

#[test]
fn docs_and_examples_stay_cleaned_to_primitive_owned_artifacts() {
    for path in [
        ".claude",
        "packages/ios-app/.claude",
        "packages/mac-app/.claude",
        "packages/agent/examples/local-packs",
    ] {
        assert!(
            !repo_path(path).exists(),
            "stale contributor/example artifact must stay deleted: {path}"
        );
    }

    for path in git_ls_files() {
        assert!(
            !path.starts_with(".claude/")
                && !path.contains("/.claude/")
                && !path.starts_with("packages/agent/examples/local-packs/"),
            "tracked stale contributor/example artifact must stay deleted: {path}"
        );
    }

    let scan_roots = [
        "README.md",
        "packages/agent/src",
        "packages/ios-app/docs",
        "packages/ios-app/Sources",
        "packages/mac-app/docs",
        "packages/mac-app/Sources",
    ];
    let banned_terms = [
        ".claude",
        "local-packs",
        "Local Worker Pack",
        "module::register_package",
        "Generated Controls",
        "Work dashboard",
        "retained until PCC-9",
    ];

    let mut files = Vec::new();
    for root in scan_roots {
        let path = repo_path(root);
        if path.is_file() {
            files.push(path);
        } else {
            collect_text_files(&path, &mut files);
        }
    }

    for file in files {
        let relative = file
            .strip_prefix(repo_root())
            .expect("scan file should live under repo root")
            .to_string_lossy()
            .to_string();
        if is_static_or_evidence_path(&relative) {
            continue;
        }
        let text = std::fs::read_to_string(&file)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", file.display()));
        for term in banned_terms {
            assert!(
                !text.contains(term),
                "stale contributor/example term `{term}` must stay out of {relative}"
            );
        }
    }
}

#[test]
fn final_retired_product_residue_stays_deleted_from_runtime_surfaces() {
    let checks: &[(&str, &[&str])] = &[
        (
            "scripts/tron-lib.sh",
            &[
                "$TRON_HOME\"/skills",
                "$WORKSPACE_DIR/inbox",
                "$WORKSPACE_DIR\"/{inbox",
                "voice-notes",
                "automations",
            ],
        ),
        (
            "packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift",
            &["CRON_", "IMPORT_", "cronNotFound", "importSessionNotFound"],
        ),
        (
            "packages/agent/src/engine/authority/grants/model.rs",
            &[
                "cron-scheduler",
                "mcp-catalog-refresh",
                "agent-worker-guide",
            ],
        ),
        (
            "packages/agent/src/domains/model/routing/presets.rs",
            &["policy_profile", "automation preset"],
        ),
        (
            "packages/agent/src/domains/session/event_store/store/event_store/session_lifecycle.rs",
            &[
                "ImportAtomic",
                "ImportEventSpec",
                "import_atomic",
                "DuplicateImport",
            ],
        ),
        (
            "packages/agent/src/shared/server/errors.rs",
            &["IMPORT_ALREADY_IMPORTED", "import_codes_are_distinct"],
        ),
        (
            "packages/agent/src/shared/server/error_mapping/mod.rs",
            &["DuplicateImport", "IMPORT_ALREADY_IMPORTED"],
        ),
    ];

    for (path, banned_terms) in checks {
        let text = read_repo_file(path);
        for term in *banned_terms {
            assert!(
                !text.contains(term),
                "retired product residue `{term}` must stay out of {path}"
            );
        }
    }

    assert!(
        !repo_path("packages/ios-app/Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Git.swift")
            .exists(),
        "retired iOS git workflow DTO file must stay deleted"
    );
}

#[test]
fn deleted_product_terms_stay_outside_scorecards_evidence_and_static_gates() {
    let banned_terms = [
        "AgentControl",
        "Agent Control",
        "PromptLibrary",
        "Prompt Library",
        "VoiceNotes",
        "Voice Notes",
        "SourceControl",
        "Source Control",
        "AuditDetails",
        "Audit Details",
        "Plugin Sources",
        "SessionTree",
        "postProcessing",
    ];

    for path in git_ls_files() {
        if is_static_or_evidence_path(&path) {
            continue;
        }
        if !matches!(
            Path::new(&path)
                .extension()
                .and_then(|extension| extension.to_str()),
            Some("md" | "rs" | "swift")
        ) {
            continue;
        }
        let text = read_repo_file(&path);
        for term in banned_terms {
            assert!(
                !text.contains(term),
                "deleted product term `{term}` must stay out of {path}"
            );
        }
    }
}
