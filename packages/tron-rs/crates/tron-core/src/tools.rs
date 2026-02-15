use std::path::PathBuf;
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;

use crate::ids::{AgentId, SessionId};

/// Tools declare whether they can run in parallel with others.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionMode {
    /// Safe to run in parallel (Read, Glob, Grep, WebFetch).
    Concurrent,
    /// Must run alone (Bash, Write, Edit — filesystem mutations).
    Sequential,
}

/// Context available to tools during execution.
pub struct ToolContext {
    pub session_id: SessionId,
    pub working_directory: PathBuf,
    pub agent_id: AgentId,
    pub parent_agent_id: Option<AgentId>,
    pub abort_signal: CancellationToken,
}

/// Result returned by a tool execution.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolResult {
    pub content: String,
    pub is_error: bool,
    pub content_type: ContentType,
    #[serde(with = "duration_ms")]
    pub duration: Duration,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ContentType {
    Text,
    Image,
    Html,
}

/// Tool definition sent to the LLM as part of the context.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters_schema: serde_json::Value,
}

/// Trait implemented by each tool.
#[async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn parameters_schema(&self) -> serde_json::Value;

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Concurrent
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError>;

    fn to_definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: self.name().to_string(),
            description: self.description().to_string(),
            parameters_schema: self.parameters_schema(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ToolError {
    #[error("invalid arguments: {0}")]
    InvalidArguments(String),
    #[error("execution failed: {0}")]
    ExecutionFailed(String),
    #[error("blocked by hook: {0}")]
    BlockedByHook(String),
    #[error("timeout after {0:?}")]
    Timeout(Duration),
    #[error("cancelled")]
    Cancelled,
}

/// Serde helper for Duration as milliseconds.
mod duration_ms {
    use serde::{Deserialize, Deserializer, Serializer};
    use std::time::Duration;

    pub fn serialize<S: Serializer>(d: &Duration, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_u64(d.as_millis() as u64)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Duration, D::Error> {
        let ms = u64::deserialize(d)?;
        Ok(Duration::from_millis(ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn execution_mode_serde() {
        let json = serde_json::to_string(&ExecutionMode::Concurrent).unwrap();
        assert_eq!(json, r#""concurrent""#);
        let json = serde_json::to_string(&ExecutionMode::Sequential).unwrap();
        assert_eq!(json, r#""sequential""#);
    }

    #[test]
    fn tool_result_duration_serializes_as_ms() {
        let result = ToolResult {
            content: "ok".into(),
            is_error: false,
            content_type: ContentType::Text,
            duration: Duration::from_millis(1234),
        };
        let json = serde_json::to_value(&result).unwrap();
        assert_eq!(json["duration"], 1234);

        let parsed: ToolResult = serde_json::from_value(json).unwrap();
        assert_eq!(parsed.duration, Duration::from_millis(1234));
    }

    #[test]
    fn content_type_serde() {
        let types = vec![ContentType::Text, ContentType::Image, ContentType::Html];
        for ct in &types {
            let json = serde_json::to_string(ct).unwrap();
            let parsed: ContentType = serde_json::from_str(&json).unwrap();
            assert_eq!(*ct, parsed);
        }
    }

    #[test]
    fn tool_error_display() {
        let err = ToolError::InvalidArguments("missing path".into());
        assert_eq!(err.to_string(), "invalid arguments: missing path");

        let err = ToolError::Timeout(Duration::from_secs(60));
        assert!(err.to_string().contains("60"));
    }
}
