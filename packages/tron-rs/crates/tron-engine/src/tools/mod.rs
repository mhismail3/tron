pub mod ask_user;
pub mod bash;
pub mod edit;
pub mod glob;
pub mod grep;
pub mod notify_app;
pub mod open_url;
pub mod read;
pub mod remember;
pub mod task;
pub mod todo_write;
pub mod tree;
pub mod web_fetch;
pub mod web_search;
pub mod write;

use std::sync::Arc;

use tron_store::Database;

use crate::registry::{ToolRegistry, ToolSource};

/// Create a ToolRegistry with all built-in tools.
pub fn create_default_registry(db: Option<Database>) -> ToolRegistry {
    let mut registry = ToolRegistry::new();

    // File operations
    registry.register(Arc::new(read::ReadTool), ToolSource::BuiltIn);
    registry.register(Arc::new(write::WriteTool), ToolSource::BuiltIn);
    registry.register(Arc::new(edit::EditTool), ToolSource::BuiltIn);

    // Search
    registry.register(Arc::new(glob::GlobTool), ToolSource::BuiltIn);
    registry.register(Arc::new(grep::GrepTool), ToolSource::BuiltIn);
    registry.register(Arc::new(tree::TreeTool), ToolSource::BuiltIn);

    // Shell
    registry.register(Arc::new(bash::BashTool::new()), ToolSource::BuiltIn);

    // Web
    registry.register(Arc::new(web_fetch::WebFetchTool::new()), ToolSource::BuiltIn);
    registry.register(Arc::new(web_search::WebSearchTool::new()), ToolSource::BuiltIn);

    // User interaction
    registry.register(Arc::new(ask_user::AskUserTool::disconnected()), ToolSource::BuiltIn);
    registry.register(Arc::new(notify_app::NotifyAppTool), ToolSource::BuiltIn);
    registry.register(Arc::new(open_url::OpenUrlTool), ToolSource::BuiltIn);

    // Subagent
    registry.register(Arc::new(task::TaskTool::unavailable()), ToolSource::BuiltIn);

    // Task management
    registry.register(
        Arc::new(todo_write::TodoWriteTool::new(todo_write::TaskStore::new())),
        ToolSource::BuiltIn,
    );

    // Memory
    if let Some(db) = db {
        registry.register(
            Arc::new(remember::RememberTool::new(db)),
            ToolSource::BuiltIn,
        );
    }

    registry
}
