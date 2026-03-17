//! `BrowserProvider` trait — swappable browser automation backend.
//!
//! Implementors provide both action execution (for the `BrowseTheWeb` tool)
//! and viewport streaming (for the iOS floating browser preview).
//!
//! To add a new provider:
//! 1. Create a module under `providers/`
//! 2. Implement this trait
//! 3. Register discovery in `providers/mod.rs`

use async_trait::async_trait;
use tokio::sync::broadcast;

use crate::tools::errors::ToolError;
use crate::tools::traits::{BrowserAction, BrowserResult};
use super::types::{BrowserEvent, BrowserStatus};

/// Trait for swappable browser automation providers.
#[async_trait]
pub trait BrowserProvider: Send + Sync {
    /// Provider identifier (e.g., "agent-browser").
    fn name(&self) -> &str;

    /// Execute a browser action within a session.
    ///
    /// The provider should auto-create the session on first action.
    /// Element selectors may be CSS selectors or provider-specific refs.
    async fn execute_action(
        &self,
        session_id: &str,
        action: &BrowserAction,
    ) -> Result<BrowserResult, ToolError>;

    /// Close a browser session and release resources.
    /// No-op if session doesn't exist.
    async fn close_session(&self, session_id: &str) -> Result<(), ToolError>;

    /// Start viewport frame streaming for a session.
    /// Frames are delivered via the broadcast channel from `subscribe()`.
    async fn start_stream(&self, session_id: &str) -> Result<(), ToolError>;

    /// Stop viewport frame streaming for a session.
    /// No-op if session doesn't exist or isn't streaming.
    async fn stop_stream(&self, session_id: &str) -> Result<(), ToolError>;

    /// Get the current status of a browser session.
    /// Returns default status (all false/None) for unknown sessions.
    fn get_status(&self, session_id: &str) -> BrowserStatus;

    /// Subscribe to browser events (frames, closed).
    /// Each call returns an independent receiver.
    fn subscribe(&self) -> broadcast::Receiver<BrowserEvent>;

    /// Close all active sessions. Called on agent run completion.
    async fn close_all_sessions(&self);
}
