//! Static gate for the cleanup scorecard's large-file audit table.
//!
//! The cleanup scorecard is the source of truth for files that intentionally
//! remain above 1,000 LOC. This gate keeps that table exact: every current
//! large file must have an owner/reason/budget row, every row must still point
//! to a current large file, and the recorded LOC must match the repository.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const LARGE_FILE_LIMIT_LINES: usize = 1_000;
const MAX_BUDGET_HEADROOM_LINES: usize = 250;

#[derive(Debug)]
struct AuditRow {
    current_loc: usize,
    owner: String,
    reason: String,
    budget: usize,
}

#[test]
fn large_files_match_cleanup_scorecard_budget_table() {
    let repo_root = repo_root();
    let scorecard_path = repo_root.join("packages/agent/docs/codebase-cleanup-scorecard.md");
    let scorecard = std::fs::read_to_string(&scorecard_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", scorecard_path.display()));

    let rows = parse_large_file_audit_rows(&scorecard);
    let large_files = discover_large_files(&repo_root);

    assert_eq!(
        large_files.keys().collect::<Vec<_>>(),
        rows.keys().collect::<Vec<_>>(),
        "large-file audit table must exactly match files over {LARGE_FILE_LIMIT_LINES} LOC"
    );

    for (path, actual_loc) in large_files {
        let row = rows
            .get(&path)
            .unwrap_or_else(|| panic!("{path} should have a large-file audit row"));
        assert_eq!(
            row.current_loc, actual_loc,
            "{path} current LOC has drifted; update the cleanup scorecard large-file audit"
        );
        assert!(
            actual_loc <= row.budget,
            "{path} has grown to {actual_loc} LOC over budget {}; split it or raise the scorecard budget with a reason",
            row.budget
        );
        assert!(
            row.budget <= actual_loc + MAX_BUDGET_HEADROOM_LINES,
            "{path} budget {} has more than {MAX_BUDGET_HEADROOM_LINES} lines of slack over current LOC {actual_loc}",
            row.budget
        );
        assert!(
            !row.owner.is_empty() && !row.reason.is_empty(),
            "{path} must keep a concrete owner and reason"
        );
    }
}

fn parse_large_file_audit_rows(scorecard: &str) -> BTreeMap<String, AuditRow> {
    let mut rows = BTreeMap::new();
    let mut in_table = false;
    for line in scorecard.lines() {
        if line.starts_with("| File | Current LOC | Owner | Reason | Budget |") {
            in_table = true;
            continue;
        }
        if !in_table {
            continue;
        }
        if !line.starts_with('|') || line.trim().is_empty() {
            break;
        }
        if line.starts_with("|------") {
            continue;
        }
        let cells = line.split('|').map(str::trim).collect::<Vec<_>>();
        if cells.len() < 7 {
            continue;
        }
        let path = cells[1].trim_matches('`').to_owned();
        if path.is_empty() {
            continue;
        }
        rows.insert(
            path,
            AuditRow {
                current_loc: numeric_cell(cells[2], "Current LOC"),
                owner: cells[3].to_owned(),
                reason: cells[4].to_owned(),
                budget: numeric_cell(cells[5], "Budget"),
            },
        );
    }
    rows
}

fn numeric_cell(value: &str, label: &str) -> usize {
    let digits = value
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>();
    assert!(
        !digits.is_empty(),
        "{label} cell must contain digits: {value}"
    );
    digits
        .parse::<usize>()
        .unwrap_or_else(|error| panic!("invalid {label} value `{value}`: {error}"))
}

fn discover_large_files(repo_root: &Path) -> BTreeMap<String, usize> {
    let crate_root = repo_root.join("packages/agent");
    let mut files = Vec::new();
    files.extend(files_with_extensions(&crate_root.join("src"), &["rs"]));
    files.extend(files_with_extensions(&crate_root.join("tests"), &["rs"]));
    files.extend(files_with_extensions(
        &repo_root.join("packages/agent/skills"),
        &["sh"],
    ));
    for root in [
        repo_root.join("packages/ios-app/Sources"),
        repo_root.join("packages/ios-app/Tests"),
        repo_root.join("packages/mac-app/Sources"),
        repo_root.join("packages/mac-app/Tests"),
    ] {
        files.extend(files_with_extensions(&root, &["swift"]));
    }
    files.extend(files_with_extensions(&repo_root.join("scripts"), &["sh"]));
    files.push(repo_root.join("scripts/tron"));
    files.sort();
    files.dedup();

    let mut large_files = BTreeMap::new();
    for path in files {
        if !path.is_file() {
            continue;
        }
        let line_count = line_count(&path);
        if line_count > LARGE_FILE_LIMIT_LINES {
            let relative = path
                .strip_prefix(repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            large_files.insert(relative, line_count);
        }
    }
    large_files
}

fn files_with_extensions(root: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit_files_with_extensions(root, extensions, &mut files);
    files
}

fn visit_files_with_extensions(root: &Path, extensions: &[&str], files: &mut Vec<PathBuf>) {
    if !root.exists() {
        return;
    }
    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", root.display()));
    for entry in entries {
        let path = entry
            .unwrap_or_else(|error| panic!("failed to read entry in {}: {error}", root.display()))
            .path();
        if path.is_dir() {
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("");
            if matches!(name, "target" | ".build" | "DerivedData") {
                continue;
            }
            visit_files_with_extensions(&path, extensions, files);
        } else if path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| extensions.contains(&ext))
        {
            files.push(path);
        }
    }
}

fn line_count(path: &Path) -> usize {
    let content = std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    content.lines().count()
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("packages/agent should have a repo root grandparent")
        .to_path_buf()
}
