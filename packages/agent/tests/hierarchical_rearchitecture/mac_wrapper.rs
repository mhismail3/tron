use super::support::*;

#[test]
fn mac_sources_use_hra14_target_boundaries() {
    let required_roots = [
        "packages/mac-app/Sources/App/Lifecycle",
        "packages/mac-app/Sources/App/CommandMode",
        "packages/mac-app/Sources/App/Composition",
        "packages/mac-app/Sources/Server/LaunchAgent",
        "packages/mac-app/Sources/Server/Health",
        "packages/mac-app/Sources/Server/Paths",
        "packages/mac-app/Sources/Server/PairingToken",
        "packages/mac-app/Sources/Server/ProcessControl",
        "packages/mac-app/Sources/MenuBar/Actions",
        "packages/mac-app/Sources/MenuBar/Controller",
        "packages/mac-app/Sources/MenuBar/Presentation",
        "packages/mac-app/Sources/Wizard/Flow",
        "packages/mac-app/Sources/Wizard/Components",
        "packages/mac-app/Sources/Support/Diagnostics",
        "packages/mac-app/Sources/Support/Feedback",
        "packages/mac-app/Sources/Support/Onboarding",
        "packages/mac-app/Sources/Support/Pairing",
        "packages/mac-app/Sources/Support/Theme",
    ];
    let banned_roots = ["packages/mac-app/Sources/Support/Observability"];
    let banned_root_files = [
        "packages/mac-app/Sources/App/EnvironmentSetup.swift",
        "packages/mac-app/Sources/App/MacAppStartupMaintenance.swift",
        "packages/mac-app/Sources/App/MacCommandLineMode.swift",
        "packages/mac-app/Sources/App/MacCommandModeServerStarter.swift",
        "packages/mac-app/Sources/App/MacRuntimeVariant.swift",
        "packages/mac-app/Sources/App/TronMacApp.swift",
        "packages/mac-app/Sources/Server/BearerTokenReader.swift",
        "packages/mac-app/Sources/Server/DevServerStopper.swift",
        "packages/mac-app/Sources/Server/LaunchAgentManaging.swift",
        "packages/mac-app/Sources/Server/ServerHealthAwaiter.swift",
        "packages/mac-app/Sources/Server/ServerPing.swift",
        "packages/mac-app/Sources/Server/ServerProcessProbe.swift",
        "packages/mac-app/Sources/Server/ServerStatusPoller.swift",
        "packages/mac-app/Sources/Server/SingleInstanceLock.swift",
        "packages/mac-app/Sources/Server/TronPaths.swift",
        "packages/mac-app/Sources/Server/TronUninstaller.swift",
        "packages/mac-app/Sources/MenuBar/MenuBarActionHandler.swift",
        "packages/mac-app/Sources/MenuBar/MenuBarController.swift",
        "packages/mac-app/Sources/MenuBar/MenuBarFeedbackAction.swift",
        "packages/mac-app/Sources/MenuBar/MenuBarItemBuilder.swift",
        "packages/mac-app/Sources/MenuBar/MenuBarLogReader.swift",
        "packages/mac-app/Sources/MenuBar/MenuBarLogsView.swift",
        "packages/mac-app/Sources/Wizard/WindowConfigurator.swift",
        "packages/mac-app/Sources/Wizard/WizardButtonStyle.swift",
        "packages/mac-app/Sources/Wizard/WizardLayout.swift",
        "packages/mac-app/Sources/Wizard/WizardState.swift",
        "packages/mac-app/Sources/Wizard/WizardView.swift",
        "packages/mac-app/Sources/Support/Observability/DiagnosticsRedactor.swift",
    ];

    let missing_required: Vec<_> = required_roots
        .iter()
        .copied()
        .filter(|path| !repo_path(path).is_dir())
        .collect();
    let present_banned_roots: Vec<_> = banned_roots
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();
    let present_banned_files: Vec<_> = banned_root_files
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing_required.is_empty()
            && present_banned_roots.is_empty()
            && present_banned_files.is_empty(),
        "HRA-14 Mac source hierarchy drift; missing roots: {missing_required:#?}; broad roots present: {present_banned_roots:#?}; loose root files present: {present_banned_files:#?}"
    );
}

#[test]
fn mac_tests_mirror_source_boundaries() {
    let required_roots = [
        "packages/mac-app/Tests/App",
        "packages/mac-app/Tests/Infrastructure/Fakes",
        "packages/mac-app/Tests/MenuBar",
        "packages/mac-app/Tests/Server",
        "packages/mac-app/Tests/Support",
        "packages/mac-app/Tests/Wizard",
    ];
    let banned_roots = [
        "packages/mac-app/Tests/Mocks",
        "packages/mac-app/Tests/Observability",
        "packages/mac-app/Tests/Services",
    ];

    let missing: Vec<_> = required_roots
        .iter()
        .copied()
        .filter(|path| !repo_path(path).is_dir())
        .collect();
    let present_banned: Vec<_> = banned_roots
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "HRA-14 Mac tests must mirror production feature boundaries; missing roots: {missing:#?}; old buckets still present: {present_banned:#?}"
    );
}

#[test]
fn mac_tests_have_no_remaining_overbudget_swift_files() {
    let mut swift_files = Vec::new();
    list_source_files(
        &repo_path("packages/mac-app/Tests"),
        &["swift"],
        &mut swift_files,
    );

    let over_budget: Vec<_> = swift_files
        .into_iter()
        .filter_map(|path| {
            let lines = source_line_count(&path);
            (lines > 700).then(|| {
                format!(
                    "{} has {lines} LOC over limit 700",
                    path.strip_prefix(repo_root())
                        .expect("Mac test should live under repo root")
                        .display()
                )
            })
        })
        .collect();

    assert!(
        over_budget.is_empty(),
        "HRA-14 must decompose over-budget Mac test files before closeout: {over_budget:#?}"
    );
}
