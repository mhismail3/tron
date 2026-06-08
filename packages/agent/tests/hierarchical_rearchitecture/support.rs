//! Static gates for the whole-repo hierarchical rearchitecture campaign.

pub(super) use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;

pub(super) const FILE_INVENTORY_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv";
pub(super) const MOVE_MAP_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-move-map.tsv";
pub(super) const IOS_MOVE_MAP_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-ios-move-map.tsv";
pub(super) const IOS_PROJECT_MAP_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-ios-project-map.md";
pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md";
pub(super) const INVENTORY_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-inventory.md";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/hierarchical_rearchitecture_invariants.rs";

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
        .expect("git ls-files should run in repository tests");
    assert!(
        output.status.success(),
        "git ls-files failed with status {:?}",
        output.status.code()
    );
    String::from_utf8(output.stdout)
        .expect("git ls-files output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

pub(super) fn source_line_count(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        .lines()
        .count()
}

pub(super) fn list_source_files(root: &Path, extensions: &[&str], files: &mut Vec<PathBuf>) {
    if root.is_file() {
        if root
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extensions.contains(&extension))
        {
            files.push(root.to_path_buf());
        }
        return;
    }

    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|error| panic!("failed to enumerate {}: {error}", root.display()));
    for entry in entries {
        let path = entry.expect("directory entry should be readable").path();
        if path.is_dir() {
            list_source_files(&path, extensions, files);
        } else if path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extensions.contains(&extension))
        {
            files.push(path);
        }
    }
}

pub(super) fn parse_inventory(path: &str) -> HashMap<String, Vec<String>> {
    let text = read_repo_file(path);
    let mut lines = text.lines();
    assert_eq!(
        lines.next(),
        Some(
            "current_path\ttarget_path\tpackage\tarea\towner\tclassification\treason\tphase\tstatus\tnotes"
        ),
        "{path} must keep the stable HRA TSV header"
    );

    let allowed_classifications = HashSet::from([
        "retain_in_place",
        "move",
        "split",
        "merge",
        "delete",
        "asset",
        "generated",
        "external_boundary",
    ]);
    let allowed_statuses = HashSet::from([
        "pending",
        "running",
        "passed",
        "passed_after_fix",
        "failed_unfixed",
        "blocked",
        "deferred_to_successor",
    ]);

    let mut rows = HashMap::new();
    for line in lines {
        let columns: Vec<_> = line.split('\t').map(str::to_owned).collect();
        assert_eq!(
            columns.len(),
            10,
            "{path} row must have ten TSV columns: {line}"
        );
        assert!(
            !columns[0].is_empty() && !columns[1].is_empty(),
            "{path} row must include current and target paths: {line}"
        );
        assert!(
            allowed_classifications.contains(columns[5].as_str()),
            "{path} has invalid classification `{}` for {}",
            columns[5],
            columns[0]
        );
        assert!(
            allowed_statuses.contains(columns[8].as_str()),
            "{path} has invalid status `{}` for {}",
            columns[8],
            columns[0]
        );
        assert!(
            !columns[2].is_empty()
                && !columns[3].is_empty()
                && !columns[4].is_empty()
                && !columns[6].is_empty()
                && !columns[7].is_empty(),
            "{path} row must name package, area, owner, reason, and phase: {line}"
        );
        assert!(
            rows.insert(columns[0].clone(), columns).is_none(),
            "{path} has duplicate row for {line}"
        );
    }
    rows
}
