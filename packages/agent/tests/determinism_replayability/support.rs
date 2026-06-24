use std::path::PathBuf;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/determinism-replayability-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/determinism-replayability-evidence-manifest.md";
pub(super) const INVENTORY_PATH: &str =
    "packages/agent/docs/determinism-replayability-inventory.md";
pub(super) const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/determinism-replayability-inventory.tsv";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/determinism_replayability_invariants.rs";

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

pub(super) fn source_paths() -> Vec<PathBuf> {
    [
        "packages/agent/src",
        "packages/agent/tests",
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "scripts",
        ".github/workflows",
    ]
    .into_iter()
    .map(repo_path)
    .collect()
}

pub(super) fn read_source_tree_text() -> String {
    fn append_file(out: &mut String, path: &std::path::Path) {
        if !matches!(
            path.extension().and_then(|extension| extension.to_str()),
            Some("rs" | "swift" | "sh" | "yml" | "yaml")
        ) {
            return;
        }
        let text = std::fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        out.push_str("\n// FILE: ");
        out.push_str(&path.display().to_string());
        out.push('\n');
        out.push_str(&text);
    }

    fn append_path(out: &mut String, path: &std::path::Path) {
        if path.is_file() {
            append_file(out, path);
            return;
        }
        let entries = std::fs::read_dir(path)
            .unwrap_or_else(|error| panic!("failed to enumerate {}: {error}", path.display()));
        for entry in entries {
            let path = entry.expect("directory entry should be readable").path();
            if path.is_dir() {
                append_path(out, &path);
            } else {
                append_file(out, &path);
            }
        }
    }

    let mut out = String::new();
    for path in source_paths() {
        append_path(&mut out, &path);
    }
    out
}
