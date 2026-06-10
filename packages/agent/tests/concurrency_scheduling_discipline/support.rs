use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/concurrency-scheduling-discipline-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/concurrency-scheduling-discipline-evidence-manifest.md";
pub(super) const INVENTORY_PATH: &str =
    "packages/agent/docs/concurrency-scheduling-discipline-inventory.md";
pub(super) const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/concurrency_scheduling_discipline_invariants.rs";

pub(super) const INVENTORY_HEADER: &str = "path\tlanguage\tsurface\towner\tscheduler_class\tstart_site\tstop_or_cancel_site\tbackpressure_or_capacity\tordering_or_fairness\ttimeout_or_deadline\tblocking_policy\ttest_evidence\tcsd_rows";

pub(super) const ALLOWED_SCHEDULER_CLASSES: &[&str] = &[
    "tracked_background_task",
    "scoped_request_task",
    "bounded_queue",
    "unbounded_queue_exception",
    "timer_loop",
    "debounce_or_coalescer",
    "ack_coalescer",
    "blocking_supervisor",
    "actor_serialization",
    "main_actor_ui",
    "external_callback_bridge",
    "view_scoped_task",
    "test_fixture",
];

const RUST_MARKERS: &[&str] = &[
    "tokio::spawn",
    "mpsc::channel",
    "broadcast::channel",
    "watch::channel",
    "oneshot::channel",
    "CancellationToken",
    "tokio::time::sleep",
    "tokio::time::timeout",
    "thread::sleep",
    "std::thread::sleep",
];

#[derive(Debug, Clone)]
pub(super) struct InventoryRow {
    pub(super) path: String,
    pub(super) language: String,
    pub(super) surface: String,
    pub(super) owner: String,
    pub(super) scheduler_class: String,
    pub(super) start_site: String,
    pub(super) stop_or_cancel_site: String,
    pub(super) backpressure_or_capacity: String,
    pub(super) ordering_or_fairness: String,
    pub(super) timeout_or_deadline: String,
    pub(super) blocking_policy: String,
    pub(super) test_evidence: String,
    pub(super) csd_rows: String,
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

pub(super) fn is_production_rust(path: &str) -> bool {
    path.starts_with("packages/agent/src/")
        && path.ends_with(".rs")
        && !path.contains("/tests/")
        && !path.ends_with("/tests.rs")
        && !path.ends_with("/test_utils.rs")
}

pub(super) fn is_production_swift(path: &str) -> bool {
    path.starts_with("packages/ios-app/Sources/") && path.ends_with(".swift")
}

pub(super) fn is_production_rust_or_swift(path: &str) -> bool {
    is_production_rust(path) || is_production_swift(path)
}

pub(super) fn has_swift_scheduling_marker(source: &str) -> bool {
    source.contains("Task {")
        || source.contains("Task{")
        || source.contains("Task(")
        || source.contains("Task<")
        || source.contains("Task.")
        || source.contains("Task =")
        || source.contains(".task {")
        || source.contains(".task(")
        || source.contains("DispatchQueue")
        || source.contains("AsyncStream")
        || source.contains("Timer")
        || source.contains("debounce")
        || source.contains("AsyncSemaphore")
}

pub(super) fn has_rust_scheduling_marker(source: &str) -> bool {
    RUST_MARKERS.iter().any(|marker| source.contains(marker))
}

pub(super) fn marker_paths() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| is_production_rust_or_swift(path))
        .filter(|path| repo_path(path).is_file())
        .filter(|path| {
            let source = read_repo_file(path);
            if path.ends_with(".rs") {
                has_rust_scheduling_marker(&source)
            } else {
                has_swift_scheduling_marker(&source)
            }
        })
        .collect()
}

pub(super) fn parse_inventory() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header = lines.next().expect("inventory TSV must have a header");
    assert_eq!(header, INVENTORY_HEADER, "CSD inventory TSV header changed");

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                13,
                "inventory row {} must have 13 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                path: columns[0].to_owned(),
                language: columns[1].to_owned(),
                surface: columns[2].to_owned(),
                owner: columns[3].to_owned(),
                scheduler_class: columns[4].to_owned(),
                start_site: columns[5].to_owned(),
                stop_or_cancel_site: columns[6].to_owned(),
                backpressure_or_capacity: columns[7].to_owned(),
                ordering_or_fairness: columns[8].to_owned(),
                timeout_or_deadline: columns[9].to_owned(),
                blocking_policy: columns[10].to_owned(),
                test_evidence: columns[11].to_owned(),
                csd_rows: columns[12].to_owned(),
            }
        })
        .collect()
}

pub(super) fn inventory_by_path() -> BTreeMap<String, InventoryRow> {
    parse_inventory()
        .into_iter()
        .map(|row| (row.path.clone(), row))
        .collect()
}

pub(super) fn text_has_any(text: &str, needles: &[&str]) -> bool {
    let lower = text.to_ascii_lowercase();
    needles
        .iter()
        .any(|needle| lower.contains(&needle.to_ascii_lowercase()))
}
