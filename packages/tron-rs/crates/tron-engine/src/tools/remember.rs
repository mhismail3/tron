use async_trait::async_trait;
use std::time::Instant;
use tron_core::ids::WorkspaceId;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};
use tron_store::memory::{MemoryRepo, MemorySource};
use tron_store::Database;

pub struct RememberTool {
    repo: MemoryRepo,
}

impl RememberTool {
    pub fn new(db: Database) -> Self {
        Self {
            repo: MemoryRepo::new(db),
        }
    }
}

#[async_trait]
impl Tool for RememberTool {
    fn name(&self) -> &str {
        "Remember"
    }

    fn description(&self) -> &str {
        "Store a memory entry for future reference"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["title", "content"],
            "properties": {
                "title": {
                    "type": "string",
                    "description": "Short title for the memory entry"
                },
                "content": {
                    "type": "string",
                    "description": "Content to remember"
                },
                "workspace_id": {
                    "type": "string",
                    "description": "Workspace ID to associate with"
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

        let title = args["title"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("title is required".into()))?;
        let content = args["content"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("content is required".into()))?;

        let workspace_id = args["workspace_id"]
            .as_str()
            .map(WorkspaceId::from_raw)
            .unwrap_or_else(|| WorkspaceId::from_raw("default"));

        // Estimate tokens (chars / 4)
        let tokens = content.len().div_ceil(4) as i64;

        let entry = self
            .repo
            .add(
                &workspace_id,
                Some(&ctx.session_id),
                title,
                content,
                tokens,
                MemorySource::Auto,
            )
            .map_err(|e| ToolError::ExecutionFailed(format!("Failed to store memory: {e}")))?;

        Ok(ToolResult {
            content: format!("Memory stored: \"{}\" (id: {})", entry.title, entry.id),
            is_error: false,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::ids::{AgentId, SessionId};
    use tron_store::workspaces::WorkspaceRepo;
    use tokio_util::sync::CancellationToken;

    fn test_ctx() -> ToolContext {
        ToolContext {
            session_id: SessionId::new(),
            working_directory: std::env::temp_dir(),
            agent_id: AgentId::new(),
            parent_agent_id: None,
            abort_signal: CancellationToken::new(),
        }
    }

    #[tokio::test]
    async fn remember_stores_entry() {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();

        let tool = RememberTool::new(db.clone());
        let result = tool
            .execute(
                serde_json::json!({
                    "title": "Rust Pattern",
                    "content": "Use Arc<Mutex> for shared state",
                    "workspace_id": ws.id.as_str()
                }),
                &test_ctx(),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("Memory stored"));
        assert!(result.content.contains("Rust Pattern"));

        // Verify it's in the database
        let mem_repo = MemoryRepo::new(db);
        let entries = mem_repo.list_for_workspace(&ws.id, 100, 0).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title, "Rust Pattern");
    }

    #[tokio::test]
    async fn remember_missing_title() {
        let db = Database::in_memory().unwrap();
        let tool = RememberTool::new(db);
        let result = tool
            .execute(serde_json::json!({"content": "something"}), &test_ctx())
            .await;

        assert!(result.is_err());
    }
}
