use super::support::*;

#[test]
fn ios_sources_do_not_use_broad_views_network_database_buckets() {
    let banned = [
        "packages/ios-app/Sources/UI/Views",
        "packages/ios-app/Sources/Engine/Network",
        "packages/ios-app/Sources/Engine/Database",
        "packages/ios-app/Sources/Engine/EventStore",
        "packages/ios-app/Sources/Session/ViewModels/Managers",
        "packages/ios-app/Sources/Session/ViewModels/Utilities",
        "packages/ios-app/Sources/Support/Utilities",
        "packages/ios-app/Sources/Support/Extensions",
    ];

    let present: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        present.is_empty(),
        "iOS sources must not retain broad technical buckets after HRA closeout: {present:#?}"
    );
}

#[test]
fn ios_tests_mirror_source_boundaries() {
    let required_roots = [
        "packages/ios-app/Tests/Infrastructure",
        "packages/ios-app/Tests/Engine",
        "packages/ios-app/Tests/Session",
        "packages/ios-app/Tests/UI",
        "packages/ios-app/Tests/Support",
    ];
    let banned_roots = [
        "packages/ios-app/Tests/Core",
        "packages/ios-app/Tests/Extensions",
        "packages/ios-app/Tests/Models",
        "packages/ios-app/Tests/Navigation",
        "packages/ios-app/Tests/Observability",
        "packages/ios-app/Tests/Onboarding",
        "packages/ios-app/Tests/Repositories",
        "packages/ios-app/Tests/Services",
        "packages/ios-app/Tests/Theme",
        "packages/ios-app/Tests/Utilities",
        "packages/ios-app/Tests/ViewModels",
        "packages/ios-app/Tests/Views",
    ];

    let missing: Vec<_> = required_roots
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned_roots
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "iOS tests must mirror production feature boundaries; missing roots: {missing:#?}; old buckets still present: {present_banned:#?}"
    );
}

#[test]
fn large_files_have_decomposition_budget_rows() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let mut source_files = Vec::new();
    for (path, extensions) in [
        ("packages/agent/src", &["rs"][..]),
        ("packages/agent/tests", &["rs"][..]),
        ("packages/ios-app/Sources", &["swift"][..]),
        ("packages/ios-app/Tests", &["swift"][..]),
        ("packages/mac-app/Sources", &["swift"][..]),
        ("packages/mac-app/Tests", &["swift"][..]),
    ] {
        list_source_files(&repo_path(path), extensions, &mut source_files);
    }

    let mut missing_budget_rows = Vec::new();
    for path in source_files {
        let relative = path
            .strip_prefix(repo_root())
            .expect("source file should live under repo root")
            .display()
            .to_string();
        let extension = path.extension().and_then(|extension| extension.to_str());
        let limit = if extension == Some("rs") { 900 } else { 700 };
        let lines = source_line_count(&path);
        if lines > limit {
            let budgeted = scorecard.lines().any(|line| {
                line.contains(&format!("| `{relative}` |")) && !line.contains("| pending |")
            });
            if !budgeted {
                missing_budget_rows.push(format!("{relative} has {lines} LOC over limit {limit}"));
            }
        }
    }

    assert!(
        missing_budget_rows.is_empty(),
        "over-budget files need explicit owner, reason, and decomposition or temporary budget rows: {missing_budget_rows:#?}"
    );
}
