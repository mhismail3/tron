//! Path extraction from tool call arguments.
//!
//! Pure function that extracts file paths touched by a capability call, converts
//! them to project-relative paths, and filters out paths outside the project.

use std::path::Path;

/// Capability ids and their argument keys that contain file paths.
const CAPABILITY_PATH_ARGS: &[(&str, &str)] = &[
    ("filesystem::read_file", "path"),
    ("filesystem::write_file", "path"),
    ("filesystem::edit_file", "path"),
    ("filesystem::apply_patch", "path"),
    ("filesystem::diff", "path"),
    ("filesystem::find", "path"),
    ("filesystem::glob", "path"),
    ("filesystem::search_text", "path"),
];

/// Extract project-relative file paths touched by a capability call.
///
/// Resolves relative paths against `working_dir`, then strips `project_root`
/// to produce project-relative paths. Returns empty if the capability doesn't touch
/// files or the path is outside the project.
pub fn extract_touched_paths(
    tool_name: &str,
    arguments: &serde_json::Map<String, serde_json::Value>,
    working_dir: &Path,
    project_root: &Path,
) -> Vec<String> {
    let (capability_id, payload) = normalize_capability_payload(tool_name, arguments);
    let arg_key = match CAPABILITY_PATH_ARGS
        .iter()
        .find(|(name, _)| *name == capability_id)
    {
        Some((_, key)) => *key,
        None => return vec![],
    };

    let raw_path = match payload.get(arg_key).and_then(|v| v.as_str()) {
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

fn normalize_capability_payload<'a>(
    tool_name: &'a str,
    arguments: &'a serde_json::Map<String, serde_json::Value>,
) -> (&'a str, &'a serde_json::Map<String, serde_json::Value>) {
    if tool_name != "execute" {
        return (tool_name, arguments);
    }
    let capability_id = [
        "contractId",
        "implementationId",
        "functionId",
        "capabilityId",
    ]
    .iter()
    .find_map(|key| arguments.get(*key).and_then(serde_json::Value::as_str))
    .unwrap_or(tool_name);
    let payload = arguments
        .get("payload")
        .and_then(serde_json::Value::as_object)
        .unwrap_or(arguments);
    (capability_id, payload)
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
    fn extract_paths_from_filesystem_read() {
        let result = extract_touched_paths(
            "filesystem::read_file",
            &args(&[("path", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/foo.rs"]);
    }

    #[test]
    fn extract_paths_from_filesystem_write() {
        let result = extract_touched_paths(
            "filesystem::write_file",
            &args(&[("path", "/project/src/bar.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/bar.rs"]);
    }

    #[test]
    fn extract_paths_from_filesystem_edit() {
        let result = extract_touched_paths(
            "filesystem::edit_file",
            &args(&[("path", "/project/src/lib.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/lib.rs"]);
    }

    #[test]
    fn extract_paths_from_execute_payload() {
        let mut execute_args = serde_json::Map::new();
        execute_args.insert("contractId".to_owned(), json!("filesystem::write_file"));
        execute_args.insert(
            "payload".to_owned(),
            json!({"path": "/project/notebooks/test.ipynb"}),
        );
        let result =
            extract_touched_paths("execute", &execute_args, Path::new(WD), Path::new(PROJECT));
        assert_eq!(result, vec!["notebooks/test.ipynb"]);
    }

    #[test]
    fn extract_paths_from_filesystem_search() {
        let result = extract_touched_paths(
            "filesystem::search_text",
            &args(&[("path", "/project/src")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src"]);
    }

    #[test]
    fn extract_paths_from_filesystem_find() {
        let result = extract_touched_paths(
            "filesystem::find",
            &args(&[("path", "/project/src/context")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/context"]);
    }

    #[test]
    fn extract_paths_from_filesystem_glob() {
        let result = extract_touched_paths(
            "filesystem::glob",
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
            &args(&[("path", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn process_capability_returns_empty() {
        let result = extract_touched_paths(
            "process::run",
            &args(&[("command", "ls -la")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn relative_path_resolved_against_wd() {
        let result = extract_touched_paths(
            "filesystem::read_file",
            &args(&[("path", "src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/foo.rs"]);
    }

    #[test]
    fn absolute_path_stripped_to_relative() {
        let result = extract_touched_paths(
            "filesystem::read_file",
            &args(&[("path", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["src/foo.rs"]);
    }

    #[test]
    fn path_outside_project_returns_empty() {
        let result = extract_touched_paths(
            "filesystem::read_file",
            &args(&[("path", "/other/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn missing_arg_returns_empty() {
        let result = extract_touched_paths(
            "filesystem::read_file",
            &args(&[("wrong_key", "/project/src/foo.rs")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn empty_path_returns_empty() {
        let result = extract_touched_paths(
            "filesystem::read_file",
            &args(&[("path", "")]),
            Path::new(WD),
            Path::new(PROJECT),
        );
        assert!(result.is_empty());
    }

    #[test]
    fn working_dir_different_from_project_root() {
        let result = extract_touched_paths(
            "filesystem::read_file",
            &args(&[("path", "foo.rs")]),
            Path::new("/project/packages/agent"),
            Path::new(PROJECT),
        );
        assert_eq!(result, vec!["packages/agent/foo.rs"]);
    }
}
