use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/state-ownership-lifecycle-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/state-ownership-lifecycle-evidence-manifest.md";
pub(super) const INVENTORY_PATH: &str =
    "packages/agent/docs/state-ownership-lifecycle-inventory.md";
pub(super) const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/state-ownership-lifecycle-inventory.tsv";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/state_ownership_lifecycle_invariants.rs";

pub(super) const INVENTORY_HEADER: &str = "path\tlanguage\tstate_surface\towner\tstate_class\tscope\tcreation_path\tmutation_boundary\thydration_or_reconstruction\tretirement_or_retention\tconcurrency_or_task_guard\tsol_rows";

pub(super) const STATEFUL_MARKERS: &[&str] = &[
    "Mutex",
    "RwLock",
    "DashMap",
    "OnceLock",
    "ArcSwap",
    "Atomic",
    "tokio::spawn",
    "JoinHandle",
    "Task",
    "UserDefaults",
    "Keychain",
    "SQLite",
    "Store",
    "Repository",
    "cached",
    "pending",
    "cursor",
    "active",
    "status",
];

pub(super) const ALLOWED_STATE_CLASSES: &[&str] = &[
    "canonical_truth",
    "durable_substrate",
    "projection_cache",
    "ephemeral_runtime",
    "local_device_preference",
    "secret",
    "diagnostic_buffer",
    "test_fixture",
];

#[derive(Debug)]
pub(super) struct InventoryRow {
    pub(super) path: String,
    pub(super) language: String,
    pub(super) state_surface: String,
    pub(super) owner: String,
    pub(super) state_class: String,
    pub(super) scope: String,
    pub(super) creation_path: String,
    pub(super) mutation_boundary: String,
    pub(super) hydration_or_reconstruction: String,
    pub(super) retirement_or_retention: String,
    pub(super) concurrency_or_task_guard: String,
    pub(super) sol_rows: String,
}

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

pub(super) fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

pub(super) fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

pub(super) fn assert_contains_in_order(name: &str, text: &str, needles: &[&str]) {
    let mut offset = 0;
    for needle in needles {
        let Some(index) = text[offset..].find(needle) else {
            panic!("{name} missing `{needle}` after byte offset {offset}");
        };
        offset += index + needle.len();
    }
}

pub(super) fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

pub(super) fn is_production_rust_or_swift(path: &str) -> bool {
    let is_rust = path.starts_with("packages/agent/src/") && path.ends_with(".rs");
    let is_swift = path.starts_with("packages/ios-app/Sources/") && path.ends_with(".swift");
    (is_rust || is_swift)
        && !path.contains("/tests/")
        && !path.ends_with("/tests.rs")
        && !path.ends_with("/test_utils.rs")
}

pub(super) fn marker_paths() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| is_production_rust_or_swift(path))
        .filter(|path| repo_path(path).is_file())
        .filter(|path| {
            let text = read_repo_file(path);
            STATEFUL_MARKERS.iter().any(|marker| text.contains(marker))
        })
        .collect()
}

pub(super) fn parse_inventory() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header = lines.next().expect("inventory TSV must have a header");
    assert_eq!(header, INVENTORY_HEADER, "SOL inventory TSV header changed");

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                12,
                "inventory row {} must have 12 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                path: columns[0].to_owned(),
                language: columns[1].to_owned(),
                state_surface: columns[2].to_owned(),
                owner: columns[3].to_owned(),
                state_class: columns[4].to_owned(),
                scope: columns[5].to_owned(),
                creation_path: columns[6].to_owned(),
                mutation_boundary: columns[7].to_owned(),
                hydration_or_reconstruction: columns[8].to_owned(),
                retirement_or_retention: columns[9].to_owned(),
                concurrency_or_task_guard: columns[10].to_owned(),
                sol_rows: columns[11].to_owned(),
            }
        })
        .collect()
}

pub(super) fn inventory_by_path() -> BTreeMap<String, Vec<InventoryRow>> {
    let mut rows_by_path: BTreeMap<String, Vec<InventoryRow>> = BTreeMap::new();
    for row in parse_inventory() {
        rows_by_path.entry(row.path.clone()).or_default().push(row);
    }
    rows_by_path
}

pub(super) fn row_has_runtime_guard(row: &InventoryRow) -> bool {
    let guard = row.concurrency_or_task_guard.to_ascii_lowercase();
    [
        "shutdown",
        "abort",
        "join",
        "drop",
        "cancel",
        "scoped",
        "raii",
        "deinit",
        "stop",
        "clear",
        "server-switch reset",
        "view lifecycle",
        "fire-and-forget one-shot",
        "mainactor one-shot",
        "awaited",
    ]
    .iter()
    .any(|needle| guard.contains(needle))
}
