use super::support::*;

#[test]
fn hierarchical_rearchitecture_scorecard_stays_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let manifest = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Hierarchical Rearchitecture Scorecard",
        "Current score: **90/100**",
        "Status: **running**",
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
        "HRA-16 | Final adversarial review and closeout | 2 | pending",
        FILE_INVENTORY_PATH,
        MOVE_MAP_PATH,
        IOS_MOVE_MAP_PATH,
        IOS_PROJECT_MAP_PATH,
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
        "Current score: **90/100**",
        "Status: **running**",
        "| HRA-0 | passed_after_fix |",
        "| HRA-5 | passed_after_fix |",
        "| HRA-6 | passed_after_fix |",
        "| HRA-7 | passed_after_fix |",
        "| HRA-8 | passed_after_fix |",
        "| HRA-9 | passed_after_fix |",
        "| HRA-10 | passed_after_fix |",
        "| HRA-11 | passed_after_fix |",
        "| HRA-12 | passed_after_fix |",
        "## HRA-0 Red Static Gate",
    ] {
        assert!(
            manifest.contains(required),
            "HRA evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# Hierarchical Rearchitecture Inventory",
        "Status: `running`",
        "Machine-Readable Artifacts",
        "Allowed classifications",
        "Allowed statuses",
        "HRA-1 Baseline Counts Updated After HRA-12",
        IOS_MOVE_MAP_PATH,
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
        MOVE_MAP_PATH,
        IOS_MOVE_MAP_PATH,
        IOS_PROJECT_MAP_PATH,
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
    let move_rows = parse_inventory(MOVE_MAP_PATH);

    let required_artifacts = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        FILE_INVENTORY_PATH,
        MOVE_MAP_PATH,
        IOS_MOVE_MAP_PATH,
        IOS_PROJECT_MAP_PATH,
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
            move_rows.contains_key(&path),
            "tracked file missing HRA move-map row: {path}"
        );
    }
}
