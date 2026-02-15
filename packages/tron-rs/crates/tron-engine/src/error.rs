use std::time::Duration;

use tron_core::errors::GatewayError;
use tron_core::tools::ToolError;
use tron_store::StoreError;

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("gateway error: {0}")]
    Gateway(#[from] GatewayError),

    #[error("store error: {0}")]
    Store(#[from] StoreError),

    #[error("tool error: {0}")]
    Tool(#[from] ToolError),

    #[error("context error: {0}")]
    Context(String),

    #[error("hook blocked: {0}")]
    HookBlocked(String),

    #[error("session not found: {0}")]
    SessionNotFound(String),

    #[error("agent aborted")]
    Aborted,

    #[error("max turns exceeded: {0}")]
    MaxTurnsExceeded(u32),

    #[error("run timeout after {0:?}")]
    RunTimeout(Duration),

    #[error("{0}")]
    Internal(String),
}
