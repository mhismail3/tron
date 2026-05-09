//! Path extraction from tool call arguments.
//!
//! Pure function that extracts file paths touched by a tool call, converts
//! them to project-relative paths, and filters out paths outside the project.

use std::path::Path;

/// Tool names and their argument keys that contain file paths.
const TOOL_PATH_ARGS: &[(&str, &str)] = &[
    ("Read", "file_path"),
    ("Write", "file_path"),
    ("Edit", "file_path"),
    ("NotebookEdit", "notebook_path"),
    ("Grep", "path"),
    ("Glob", "path"),
    ("Search", "path"),
    ("Find", "path"),
];

/// Extract project-relative file paths touched by a tool call.
///
/// Resolves relative paths against `working_dir`, then strips `project_root`
/// to produce project-relative paths. Returns empty if the tool doesn't touch
/// files or the path is outside the project.
pub fn extract_touched_paths(
    tool_name: &str,
    arguments: &serde_json::Map<String, serde_json::Value>,
    working_dir: &Path,
    project_root: &Path,
) -> Vec<String> {
    let arg_key = match TOOL_PATH_ARGS.iter().find(|(name, _)| *name == tool_name) {
        Some((_, key)) => *key,
        None => return vec![],
    };

    let raw_path = match arguments.get(arg_key).and_then(|v| v.as_str()) {
        Some(p) if !p.is_empty() => p,
        _ => return vec![],
    };

    let absolute = if Path::new(raw_path).is_absolute() {
        Path::new(raw_path).to_path_buf()
    } else {
        working_dir.join(raw_path)
    };

    match absolute.strip_prefix(project_root) {
        Ok(relative) => {
            let rel_str = relative
                .components()
                .map(|c| c.as_os_str().to_string_lossy().to_string())
                .collect::<Vec<_>>()
                .join("/");
            if rel_str.is_empty() {
                vec![]
            } else {
                vec![rel_str]
            }
        }
        Err(_) => vec![],
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::Path;

    fn args(pairs: &[(&str, &str)]) -> serde_json::Map<String, serde_json::Value> {
        let mut map = serde_json::Map::new();
        for (k, v) in pairs {
            let _ = map.insert((*k).to_owned(), json!(*v));
        }
        map
    }

    const PROJECT: &str = "/project";
    const WD: &str = "/project";

    #[test]
    fn extract_paths_from_read_tool() {
        let result = extract_touched_paths(
            "Read",
            &args(&[("file_path", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/foo.rs"]);
    }

    #[test]
    fn extract_paths_from_write_tool() {
        let result = extract_touched_paths(
            "Write",
            &args(&[("file_path", "/project/src/bar.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/bar.rs"]);
    }

    #[test]
    fn extract_paths_from_edit_tool() {
        let result = extract_touched_paths(
            "Edit",
            &args(&[("file_path", "/project/src/lib.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/lib.rs"]);
    }

    #[test]
    fn extract_paths_from_notebook_edit() {
        let result = extract_touched_paths(
            "NotebookEdit",
            &args(&[("notebook_path", "/project/notebooks/test.ipynb")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["notebooks/test.ipynb"]);
    }

    #[test]
    fn extract_paths_from_search_tool() {
        let result = extract_touched_paths(
            "Search",
            &args(&[("path", "/project/src")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src"]);
    }

    #[test]
    fn extract_paths_from_grep_tool() {
        let result = extract_touched_paths(
            "Grep",
            &args(&[("path", "/project/src/context")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/context"]);
    }

    #[test]
    fn extract_paths_from_glob_tool() {
        let result = extract_touched_paths(
            "Glob",
            &args(&[("path", "/project/crates")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["crates"]);
    }

    #[test]
    fn unknown_tool_returns_empty() {
        let result = extract_touched_paths(
            "UnknownTool",
            &args(&[("file_path", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn bash_tool_returns_empty() {
        let result = extract_touched_paths(
            "Bash",
            &args(&[("command", "ls -la")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn relative_path_resolved_against_wd() {
        let result = extract_touched_paths(
            "Read",
            &args(&[("file_path", "src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/foo.rs"]);
    }

    #[test]
    fn absolute_path_stripped_to_relative() {
        let result = extract_touched_paths(
            "Read",
            &args(&[("file_path", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/foo.rs"]);
    }

    #[test]
    fn path_outside_project_returns_empty() {
        let result = extract_touched_paths(
            "Read",
            &args(&[("file_path", "/other/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn missing_arg_returns_empty() {
        let result = extract_touched_paths(
            "Read",
            &args(&[("wrong_key", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn empty_path_returns_empty() {
        let result = extract_touched_paths(
            "Read",
            &args(&[("file_path", "")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn working_dir_different_from_project_root() {
        let result = extract_touched_paths(
            "Read",
            &args(&[("file_path", "foo.rs")]),
            Path::new("/project/packages/agent"),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["packages/agent/foo.rs"]);
    }
}
