use super::support::*;

#[test]
fn hierarchical_rearchitecture_scorecard_stays_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let manifest = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Hierarchical Rearchitecture Scorecard",
        "Current score: **100/100**",
        "Status: **completed**",
        "Total weight: **100**",
        "## Folder Justification Table",
        "## Large File Budgets",
        "## Static Gates",
        "HRA-0 | Scorecard, evidence, and static-gate setup | 5 | passed_after_fix",
        "HRA-1 | Whole-repo inventory and target architecture | 8 | passed_after_fix",
        "HRA-2 | Rust app, transport, shared, and platform roots | 6 | passed_after_fix",
        "HRA-3 | Rust engine kernel and invocation hierarchy | 10 | passed_after_fix",
        "HRA-4 | Rust engine durability and authority hierarchy | 8 | passed_after_fix",
        "HRA-5 | Rust domain vertical slices | 10 | passed_after_fix",
        "HRA-6 | Rust session and event-store hierarchy | 7 | passed_after_fix",
        "HRA-7 | Rust tests and progressive docs | 5 | passed_after_fix",
        "HRA-8 | iOS inventory, SourceGuard, and target project map | 6 | passed_after_fix",
        "HRA-9 | iOS Engine hierarchy | 8 | passed_after_fix",
        "HRA-10 | iOS Session hierarchy | 7 | passed_after_fix",
        "HRA-11 | iOS UI hierarchy | 6 | passed_after_fix",
        "HRA-12 | iOS Support foundation hierarchy | 4 | passed_after_fix",
        "HRA-13 | iOS tests and generated project closeout | 4 | passed_after_fix",
        "HRA-14 | Mac wrapper hierarchy audit | 2 | passed_after_fix",
        "HRA-15 | Scripts, README, and docs path closeout | 2 | passed_after_fix",
        "HRA-16 | Final adversarial review and closeout | 2 | passed_after_fix",
        FILE_INVENTORY_PATH,
        OWNERSHIP_MAP_PATH,
        IOS_OWNERSHIP_MAP_PATH,
        IOS_PROJECT_MAP_PATH,
        PLAN_SUMMARY_PATH,
    ] {
        assert!(
            scorecard.contains(required),
            "HRA scorecard missing required text: {required}"
        );
    }

    let score_total: u32 = scorecard
        .lines()
        .filter_map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            if columns.get(1).is_some_and(|cell| cell.starts_with("HRA-")) {
                columns.get(3).and_then(|cell| cell.parse::<u32>().ok())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(
        score_total, 100,
        "HRA scorecard row weights must sum to 100"
    );

    for required in [
        "# Hierarchical Rearchitecture Evidence Manifest",
        "Current score: **100/100**",
        "Status: **completed**",
        "| HRA-0 | passed_after_fix |",
        "| HRA-5 | passed_after_fix |",
        "| HRA-6 | passed_after_fix |",
        "| HRA-7 | passed_after_fix |",
        "| HRA-8 | passed_after_fix |",
        "| HRA-9 | passed_after_fix |",
        "| HRA-10 | passed_after_fix |",
        "| HRA-11 | passed_after_fix |",
        "| HRA-12 | passed_after_fix |",
        "| HRA-13 | passed_after_fix |",
        "| HRA-14 | passed_after_fix |",
        "| HRA-15 | passed_after_fix |",
        "| HRA-16 | passed_after_fix |",
        "## HRA-0 Red Static Gate",
    ] {
        assert!(
            manifest.contains(required),
            "HRA evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# Hierarchical Rearchitecture Inventory",
        "Status: `completed`",
        "Machine-Readable Artifacts",
        "Allowed classifications",
        "Allowed statuses",
        "HRA-1 Baseline Counts Updated After SACB-POST-2",
        PLAN_SUMMARY_PATH,
        IOS_OWNERSHIP_MAP_PATH,
        IOS_PROJECT_MAP_PATH,
    ] {
        assert!(
            inventory.contains(required),
            "HRA inventory missing required text: {required}"
        );
    }

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        FILE_INVENTORY_PATH,
        OWNERSHIP_MAP_PATH,
        IOS_OWNERSHIP_MAP_PATH,
        IOS_PROJECT_MAP_PATH,
        PLAN_SUMMARY_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            readme.contains(required),
            "README living architecture docs must link {required}"
        );
    }
}

#[test]
fn tracked_files_have_rearchitecture_inventory_rows() {
    let file_rows = parse_inventory(FILE_INVENTORY_PATH);
    let ownership_rows = parse_inventory(OWNERSHIP_MAP_PATH);

    let required_artifacts = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        FILE_INVENTORY_PATH,
        OWNERSHIP_MAP_PATH,
        IOS_OWNERSHIP_MAP_PATH,
        IOS_PROJECT_MAP_PATH,
        PLAN_SUMMARY_PATH,
        INVARIANT_TEST_PATH,
    ];

    for path in git_ls_files()
        .into_iter()
        .chain(required_artifacts.iter().map(|path| path.to_string()))
    {
        assert!(
            file_rows.contains_key(&path),
            "tracked file missing HRA file-inventory row: {path}"
        );
        assert!(
            ownership_rows.contains_key(&path),
            "tracked file missing HRA current-ownership-map row: {path}"
        );
    }
}

#[test]
fn completed_rearchitecture_has_no_open_inventory_statuses() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    if !scorecard.contains("Current score: **100/100**")
        || !scorecard.contains("Status: **completed**")
    {
        return;
    }

    let open_statuses = HashSet::from([
        "pending",
        "running",
        "blocked",
        "failed_unfixed",
        "deferred_to_successor",
    ]);
    let mut hits = Vec::new();

    for (path, status_column) in [
        (FILE_INVENTORY_PATH, 8),
        (OWNERSHIP_MAP_PATH, 8),
        (IOS_OWNERSHIP_MAP_PATH, 5),
    ] {
        let text = read_repo_file(path);
        for line in text.lines().skip(1) {
            let columns: Vec<_> = line.split('\t').collect();
            let Some(status) = columns.get(status_column) else {
                hits.push(format!("{path}: malformed row `{line}`"));
                continue;
            };
            if open_statuses.contains(*status) {
                hits.push(format!("{path}: open status `{status}` in `{line}`"));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "completed HRA scorecard must not retain open inventory statuses: {hits:#?}"
    );
}
