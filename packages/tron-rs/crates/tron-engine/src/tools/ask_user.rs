use async_trait::async_trait;
use std::time::Instant;
use tokio::sync::oneshot;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

/// Callback type for AskUser responses — the server provides a sender
/// that the iOS client will eventually respond to.
pub type AskUserResponder = Box<dyn FnOnce(AskUserRequest) -> oneshot::Receiver<String> + Send>;

/// The question payload sent to the client.
#[derive(Debug, Clone, serde::Serialize)]
pub struct AskUserRequest {
    pub question: String,
    pub options: Vec<AskUserOption>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AskUserOption {
    pub label: String,
    pub description: Option<String>,
}

/// AskUser tool — sends a question to the iOS client and awaits the response.
///
/// The responder callback is injected by the server layer when the tool is
/// constructed. It creates a oneshot channel, sends the question to the client
/// via WebSocket, and returns the receiver so we can await the response.
/// Inner responder type alias for readability.
type ResponderFn = Box<dyn Fn(AskUserRequest) -> oneshot::Receiver<String> + Send>;

pub struct AskUserTool {
    /// Sends a question and returns a receiver for the answer.
    responder: std::sync::Arc<tokio::sync::Mutex<Option<ResponderFn>>>,
}

impl AskUserTool {
    pub fn new(
        responder: Box<dyn Fn(AskUserRequest) -> oneshot::Receiver<String> + Send>,
    ) -> Self {
        Self {
            responder: std::sync::Arc::new(tokio::sync::Mutex::new(Some(responder))),
        }
    }

    /// Create a tool that always returns an error (for testing or when no client is connected).
    pub fn disconnected() -> Self {
        Self {
            responder: std::sync::Arc::new(tokio::sync::Mutex::new(None)),
        }
    }
}

#[async_trait]
impl Tool for AskUserTool {
    fn name(&self) -> &str {
        "AskUser"
    }

    fn description(&self) -> &str {
        "Ask the user a question and wait for their response"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["question"],
            "properties": {
                "question": {
                    "type": "string",
                    "description": "The question to ask the user"
                },
                "options": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "label": { "type": "string" },
                            "description": { "type": "string" }
                        },
                        "required": ["label"]
                    },
                    "description": "Optional choices for the user"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Sequential
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        _ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let question = args["question"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("question is required".into()))?
            .to_string();

        let options = args["options"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|opt| {
                        Some(AskUserOption {
                            label: opt["label"].as_str()?.to_string(),
                            description: opt["description"].as_str().map(|s| s.to_string()),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        let request = AskUserRequest { question, options };

        let guard = self.responder.lock().await;
        let responder = guard.as_ref().ok_or_else(|| {
            ToolError::ExecutionFailed("No client connected to answer questions".into())
        })?;

        let rx = responder(request);
        drop(guard);

        let answer = rx.await.map_err(|_| {
            ToolError::ExecutionFailed("Client disconnected before answering".into())
        })?;

        Ok(ToolResult {
            content: answer,
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

    #[test]
    fn tool_metadata() {
        let tool = AskUserTool::disconnected();
        assert_eq!(tool.name(), "AskUser");
        assert_eq!(tool.execution_mode(), ExecutionMode::Sequential);
    }

    #[tokio::test]
    async fn missing_question() {
        let tool = AskUserTool::disconnected();
        let result = tool.execute(serde_json::json!({}), &test_ctx()).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn disconnected_returns_error() {
        let tool = AskUserTool::disconnected();
        let result = tool
            .execute(
                serde_json::json!({"question": "What color?"}),
                &test_ctx(),
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn ask_user_with_response() {
        let responder = Box::new(|req: AskUserRequest| {
            let (tx, rx) = oneshot::channel();
            assert_eq!(req.question, "Pick a color");
            assert_eq!(req.options.len(), 2);
            tx.send("Blue".to_string()).ok();
            rx
        });

        let tool = AskUserTool::new(responder);
        let result = tool
            .execute(
                serde_json::json!({
                    "question": "Pick a color",
                    "options": [
                        {"label": "Red", "description": "Warm"},
                        {"label": "Blue", "description": "Cool"}
                    ]
                }),
                &test_ctx(),
            )
            .await
            .unwrap();

        assert_eq!(result.content, "Blue");
        assert!(!result.is_error);
    }
}
