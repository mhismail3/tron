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
fn ios_hra8_move_map_covers_every_source_and_test_swift_file() {
    let map = read_repo_file(IOS_MOVE_MAP_PATH);
    let mut lines = map.lines();
    assert_eq!(
        lines.next(),
        Some("current_path\ttarget_path\towner\tphase\tclassification\tstatus\treason"),
        "{IOS_MOVE_MAP_PATH} must keep the HRA-8 iOS move-map header"
    );

    let allowed_phases = HashSet::from(["HRA-9", "HRA-10", "HRA-11", "HRA-12", "HRA-13"]);
    let allowed_classifications = HashSet::from(["move", "retain_in_place"]);
    let banned_target_prefixes = [
        "packages/ios-app/Sources/UI/Views",
        "packages/ios-app/Sources/Engine/Network",
        "packages/ios-app/Sources/Engine/Database",
        "packages/ios-app/Sources/Engine/EventStore",
        "packages/ios-app/Sources/Session/ViewModels/Managers",
        "packages/ios-app/Sources/Session/ViewModels/Utilities",
        "packages/ios-app/Sources/Support/Utilities",
        "packages/ios-app/Sources/Support/Extensions",
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

    let mut rows = HashMap::new();
    for line in lines {
        let columns: Vec<_> = line.split('\t').collect();
        assert_eq!(
            columns.len(),
            7,
            "{IOS_MOVE_MAP_PATH} row must have seven TSV columns: {line}"
        );
        let [
            current,
            target,
            owner,
            phase,
            classification,
            status,
            reason,
        ] = columns.as_slice()
        else {
            unreachable!("column length asserted above")
        };
        assert!(
            current.ends_with(".swift")
                && (current.starts_with("packages/ios-app/Sources/")
                    || current.starts_with("packages/ios-app/Tests/")),
            "{IOS_MOVE_MAP_PATH} row must cover only iOS source/test Swift files: {line}"
        );
        assert!(
            target.ends_with(".swift")
                && (target.starts_with("packages/ios-app/Sources/")
                    || target.starts_with("packages/ios-app/Tests/")),
            "{IOS_MOVE_MAP_PATH} row must map to an iOS source/test Swift target: {line}"
        );
        assert!(
            !owner.is_empty(),
            "{IOS_MOVE_MAP_PATH} row must name an owner: {line}"
        );
        assert!(
            allowed_phases.contains(*phase),
            "{IOS_MOVE_MAP_PATH} row has invalid target phase `{phase}`: {line}"
        );
        assert!(
            allowed_classifications.contains(*classification),
            "{IOS_MOVE_MAP_PATH} row has invalid classification `{classification}`: {line}"
        );
        assert_eq!(
            *status, "pending",
            "{IOS_MOVE_MAP_PATH} rows remain pending until HRA-9 through HRA-13 move the files: {line}"
        );
        assert!(
            !reason.is_empty(),
            "{IOS_MOVE_MAP_PATH} row must explain the target owner: {line}"
        );
        assert!(
            banned_target_prefixes
                .iter()
                .all(|prefix| !target.starts_with(prefix)),
            "{IOS_MOVE_MAP_PATH} target still points at an old technical bucket: {line}"
        );
        assert!(
            rows.insert((*current).to_owned(), (*target).to_owned())
                .is_none(),
            "{IOS_MOVE_MAP_PATH} has duplicate current path row: {current}"
        );
    }

    let mut swift_files = Vec::new();
    list_source_files(
        &repo_path("packages/ios-app/Sources"),
        &["swift"],
        &mut swift_files,
    );
    list_source_files(
        &repo_path("packages/ios-app/Tests"),
        &["swift"],
        &mut swift_files,
    );
    let expected: HashSet<_> = swift_files
        .into_iter()
        .map(|path| {
            path.strip_prefix(repo_root())
                .expect("iOS Swift file should live under repo root")
                .display()
                .to_string()
        })
        .collect();
    let actual: HashSet<_> = rows.keys().cloned().collect();
    let missing: Vec<_> = expected.difference(&actual).cloned().collect();
    let extra: Vec<_> = actual.difference(&expected).cloned().collect();

    assert!(
        missing.is_empty() && extra.is_empty(),
        "{IOS_MOVE_MAP_PATH} must cover every live iOS source/test Swift file exactly once; missing: {missing:#?}; extra: {extra:#?}"
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
