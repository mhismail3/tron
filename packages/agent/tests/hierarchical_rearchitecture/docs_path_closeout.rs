use super::support::*;

#[test]
fn live_docs_scripts_and_workflows_do_not_claim_old_paths() {
    let scan_files = [
        "README.md",
        "CONTRIBUTING.md",
        "AGENTS.md",
        "packages/ios-app/README.md",
        "packages/ios-app/docs/architecture.md",
        "packages/ios-app/docs/development.md",
        "packages/ios-app/docs/events.md",
        "packages/ios-app/docs/onboarding.md",
        "packages/mac-app/docs/architecture.md",
        "packages/mac-app/docs/development.md",
        "scripts/personal-info-guard.sh",
        "scripts/tron",
        "scripts/tron-cli",
        "scripts/tron-version",
        "scripts/tron-release-notes",
        "scripts/tron-lib.sh",
        "scripts/tron-lib.d/auth.sh",
        "scripts/tron-lib.d/bundle.sh",
        "scripts/tron-lib.d/logs.sh",
        "scripts/tron-lib.d/service.sh",
        "scripts/tron.d/deploy.sh",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/quality.sh",
        "scripts/tron.d/workspace.sh",
        ".github/workflows/ci.yml",
        ".github/workflows/release-ios.yml",
        ".github/workflows/release-mac.yml",
    ];

    let stale_needles = [
        "packages/agent/src/app/onboarding/mod.rs",
        "packages/agent/src/core/foundation/paths.rs",
        "packages/ios-app/Sources/Views/Chat/ContentView.swift",
        "Tests/\n├── ViewModels/",
        "├── Services/          # Service tests",
        "├── Core/              # Event plugin tests",
        "├── Views/             # Sheet, card, and presentation behavior tests",
        "└── Navigation/        # Deep link tests",
        "Sources/App/TronMacApp.swift",
        "Sources/App/EnvironmentSetup.swift",
        "Sources/Server/TronPaths.swift",
        "packages/mac-app/Tests/Services",
        "WizardStepTests.swift",
        "Engine/Network",
        "Engine/Database",
        "Engine/EventStore",
        "Session/ViewModels",
        "UI/Views",
        "Support/Utilities",
        "Support/Extensions",
        "Support/Observability",
        "main_cli.rs",
        "main_runtime.rs",
        "main_tests.rs",
        "engine/host.rs",
    ];

    let mut stale_hits = Vec::new();
    for file in scan_files {
        let text = read_repo_file(file);
        for needle in stale_needles {
            if text.contains(needle) {
                stale_hits.push(format!("{file}: {needle}"));
            }
        }
    }

    assert!(
        stale_hits.is_empty(),
        "HRA-15 live docs/scripts/workflows still claim old paths: {stale_hits:#?}"
    );
}
