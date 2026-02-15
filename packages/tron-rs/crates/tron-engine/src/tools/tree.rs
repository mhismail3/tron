use async_trait::async_trait;
use std::path::Path;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

const MAX_ENTRIES: usize = 500;
const MAX_DEPTH: usize = 5;

const SKIP_DIRS: &[&str] = &[
    "node_modules", ".git", "target", "dist", "build", ".next",
    "__pycache__", "vendor", ".tox", ".mypy_cache", ".pytest_cache",
];

pub struct TreeTool;

#[async_trait]
impl Tool for TreeTool {
    fn name(&self) -> &str {
        "Tree"
    }

    fn description(&self) -> &str {
        "Display directory tree structure"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Directory to display (defaults to working directory)"
                },
                "depth": {
                    "type": "integer",
                    "description": "Maximum depth (default: 5)"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Concurrent
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let dir = match args["path"].as_str() {
            Some(p) => {
                let path = Path::new(p);
                if path.is_absolute() {
                    path.to_path_buf()
                } else {
                    ctx.working_directory.join(path)
                }
            }
            None => ctx.working_directory.clone(),
        };

        let max_depth = args["depth"].as_u64().unwrap_or(MAX_DEPTH as u64) as usize;

        let dir_clone = dir.clone();
        let output = tokio::task::spawn_blocking(move || build_tree(&dir_clone, max_depth))
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("Tree task failed: {e}")))?;

        Ok(ToolResult {
            content: output,
            is_error: false,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

fn build_tree(root: &Path, max_depth: usize) -> String {
    let mut lines = Vec::new();
    lines.push(root.display().to_string());

    let mut count = 0;
    walk_tree(root, "", 0, max_depth, &mut lines, &mut count);

    if count >= MAX_ENTRIES {
        lines.push(format!("\n... truncated at {MAX_ENTRIES} entries"));
    }

    lines.join("\n")
}

fn walk_tree(
    dir: &Path,
    prefix: &str,
    depth: usize,
    max_depth: usize,
    lines: &mut Vec<String>,
    count: &mut usize,
) {
    if depth >= max_depth || *count >= MAX_ENTRIES {
        return;
    }

    let mut entries: Vec<_> = match std::fs::read_dir(dir) {
        Ok(e) => e.flatten().collect(),
        Err(_) => return,
    };

    entries.sort_by(|a, b| {
        let a_is_dir = a.path().is_dir();
        let b_is_dir = b.path().is_dir();
        match (a_is_dir, b_is_dir) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.file_name().cmp(&b.file_name()),
        }
    });

    let total = entries.len();
    for (i, entry) in entries.iter().enumerate() {
        if *count >= MAX_ENTRIES {
            break;
        }

        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let path = entry.path();
        let is_last = i == total - 1;

        // Skip hidden and large dirs
        if path.is_dir() && SKIP_DIRS.contains(&name_str.as_ref()) {
            continue;
        }

        let connector = if is_last { "└── " } else { "├── " };
        let display_name = if path.is_dir() {
            format!("{name_str}/")
        } else {
            name_str.to_string()
        };

        lines.push(format!("{prefix}{connector}{display_name}"));
        *count += 1;

        if path.is_dir() {
            let child_prefix = if is_last {
                format!("{prefix}    ")
            } else {
                format!("{prefix}│   ")
            };
            walk_tree(&path, &child_prefix, depth + 1, max_depth, lines, count);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tron_core::ids::{AgentId, SessionId};
    use tokio_util::sync::CancellationToken;

    fn test_ctx(dir: &Path) -> ToolContext {
        ToolContext {
            session_id: SessionId::new(),
            working_directory: dir.to_path_buf(),
            agent_id: AgentId::new(),
            parent_agent_id: None,
            abort_signal: CancellationToken::new(),
        }
    }

    #[tokio::test]
    async fn tree_basic() {
        let dir = std::env::temp_dir().join(format!("tron_tree_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(dir.join("src")).unwrap();
        fs::write(dir.join("src/main.rs"), "fn main() {}").unwrap();
        fs::write(dir.join("Cargo.toml"), "[package]").unwrap();

        let tool = TreeTool;
        let result = tool
            .execute(serde_json::json!({}), &test_ctx(&dir))
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("src/"));
        assert!(result.content.contains("main.rs"));
        assert!(result.content.contains("Cargo.toml"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn tree_depth_limit() {
        let dir = std::env::temp_dir().join(format!("tron_tree_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(dir.join("a/b/c/d")).unwrap();
        fs::write(dir.join("a/b/c/d/deep.txt"), "deep").unwrap();

        let tool = TreeTool;
        let result = tool
            .execute(serde_json::json!({"depth": 2}), &test_ctx(&dir))
            .await
            .unwrap();

        assert!(result.content.contains("a/"));
        assert!(result.content.contains("b/"));
        // c/ should show but d/ should not (depth 2 from root → a, b)
        // Actually at depth=2: root(0) → a(1) → b(2) → stop
        assert!(!result.content.contains("deep.txt"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn tree_skips_node_modules() {
        let dir = std::env::temp_dir().join(format!("tron_tree_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(dir.join("node_modules/pkg")).unwrap();
        fs::write(dir.join("node_modules/pkg/index.js"), "").unwrap();
        fs::write(dir.join("index.js"), "").unwrap();

        let tool = TreeTool;
        let result = tool
            .execute(serde_json::json!({}), &test_ctx(&dir))
            .await
            .unwrap();

        assert!(result.content.contains("index.js"));
        assert!(!result.content.contains("pkg"));

        fs::remove_dir_all(&dir).ok();
    }
}
