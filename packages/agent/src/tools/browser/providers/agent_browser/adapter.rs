//! `AgentBrowserProvider` — implements `BrowserProvider` via agent-browser CLI.

use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use dashmap::DashMap;
use serde_json::Value;
use tokio::sync::broadcast;

use crate::tools::browser::provider::BrowserProvider;
use crate::tools::browser::types::{BrowserEvent, BrowserStatus};
use crate::tools::errors::ToolError;
use crate::tools::traits::{BrowserAction, BrowserResult};

use super::cli::{
    self, CliRunner, ProcessCliRunner, TIMEOUT_CLOSE, TIMEOUT_INTERACT,
    TIMEOUT_NAVIGATE, TIMEOUT_OBSERVE, TIMEOUT_PDF, TIMEOUT_URL_FETCH,
};
use super::refs;
use super::stream::StreamBridge;

const VALID_DIRECTIONS: &[&str] = &["up", "down", "left", "right"];

/// Run a CLI command and check for non-zero exit, discarding stdout.
async fn run_checked(
    cli: &dyn CliRunner,
    session_id: &str,
    args: &[String],
    timeout: std::time::Duration,
) -> Result<(), ToolError> {
    let output = cli.run(session_id, args, timeout).await.map_err(ToolError::from)?;
    if output.exit_code != 0 {
        return Err(super::error::AgentBrowserError::CommandFailed {
            exit_code: output.exit_code,
            stderr: output.stderr,
        }
        .into());
    }
    Ok(())
}

/// Session state tracked per browser session.
#[derive(Debug)]
struct SessionState {
    current_url: Option<String>,
}

/// Browser provider backed by the agent-browser CLI.
pub struct AgentBrowserProvider {
    cli: Arc<dyn CliRunner>,
    stream: StreamBridge,
    sessions: DashMap<String, SessionState>,
    frame_tx: broadcast::Sender<BrowserEvent>,
}

impl AgentBrowserProvider {
    /// Create a new provider with a real CLI runner.
    pub fn new(binary_path: PathBuf, stream_port: u16, headed: bool) -> Self {
        let (frame_tx, _) = broadcast::channel(64);
        let stream = StreamBridge::new(stream_port, frame_tx.clone());
        Self {
            cli: Arc::new(ProcessCliRunner::new(binary_path, stream_port, headed)),
            stream,
            sessions: DashMap::new(),
            frame_tx,
        }
    }

    /// Create a provider with a custom CLI runner (for testing).
    #[cfg(test)]
    fn with_cli(cli: Arc<dyn CliRunner>) -> Self {
        let (frame_tx, _) = broadcast::channel(64);
        let stream = StreamBridge::new(0, frame_tx.clone());
        Self {
            cli,
            stream,
            sessions: DashMap::new(),
            frame_tx,
        }
    }

    fn ensure_session(&self, session_id: &str) {
        if !self.sessions.contains_key(session_id) {
            let _ = self.sessions.insert(
                session_id.to_string(),
                SessionState { current_url: None },
            );
            metrics::gauge!("browser_sessions_active").increment(1.0);
        }
    }

    async fn refresh_url(&self, session_id: &str) {
        match self
            .cli
            .run(
                session_id,
                &["get".into(), "url".into(), "--json".into()],
                TIMEOUT_URL_FETCH,
            )
            .await
        {
            Ok(output) if output.exit_code == 0 => {
                let url = output.stdout.trim().trim_matches('"').to_string();
                if let Some(mut state) = self.sessions.get_mut(session_id) {
                    state.current_url = Some(url);
                }
            }
            _ => {
                tracing::debug!(session_id, "failed to refresh URL (non-fatal)");
            }
        }
    }

    async fn execute_navigate(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let url = require_param(params, "url", "navigate")?;
        run_checked(&*self.cli, session_id, &["open".into(), url.to_string()], TIMEOUT_NAVIGATE).await?;
        self.refresh_url(session_id).await;
        Ok(BrowserResult {
            content: format!("Navigated to {url}"),
            details: None,
        })
    }

    async fn execute_back(&self, session_id: &str) -> Result<BrowserResult, ToolError> {
        run_checked(&*self.cli, session_id, &["back".into()], TIMEOUT_NAVIGATE).await?;
        self.refresh_url(session_id).await;
        Ok(BrowserResult {
            content: "Navigated back".into(),
            details: None,
        })
    }

    async fn execute_forward(&self, session_id: &str) -> Result<BrowserResult, ToolError> {
        run_checked(&*self.cli, session_id, &["forward".into()], TIMEOUT_NAVIGATE).await?;
        self.refresh_url(session_id).await;
        Ok(BrowserResult {
            content: "Navigated forward".into(),
            details: None,
        })
    }

    async fn execute_reload(&self, session_id: &str) -> Result<BrowserResult, ToolError> {
        run_checked(&*self.cli, session_id, &["reload".into()], TIMEOUT_NAVIGATE).await?;
        self.refresh_url(session_id).await;
        Ok(BrowserResult {
            content: "Page reloaded".into(),
            details: None,
        })
    }

    async fn execute_snapshot(&self, session_id: &str) -> Result<BrowserResult, ToolError> {
        let output = self
            .cli
            .run(
                session_id,
                &["snapshot".into(), "-i".into(), "--json".into()],
                TIMEOUT_OBSERVE,
            )
            .await
            .map_err(ToolError::from)?;
        if output.exit_code != 0 {
            return Err(super::error::AgentBrowserError::CommandFailed {
                exit_code: output.exit_code,
                stderr: output.stderr,
            }
            .into());
        }
        Ok(BrowserResult {
            content: output.stdout,
            details: None,
        })
    }

    async fn execute_screenshot(&self, session_id: &str) -> Result<BrowserResult, ToolError> {
        let temp_path = format!(
            "{}/tron_screenshot_{}.png",
            std::env::temp_dir().display(),
            uuid::Uuid::now_v7()
        );
        run_checked(&*self.cli, session_id, &["screenshot".into(), temp_path.clone(), "--json".into()], TIMEOUT_OBSERVE).await?;

        let data = tokio::fs::read(&temp_path).await.map_err(|e| {
            ToolError::from(super::error::AgentBrowserError::ScreenshotReadFailed(e))
        })?;

        if let Err(e) = tokio::fs::remove_file(&temp_path).await {
            tracing::warn!(path = %temp_path, error = %e, "failed to clean up screenshot temp file");
        }

        let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
        Ok(BrowserResult {
            content: "Screenshot taken".into(),
            details: Some(serde_json::json!({
                "screenshot": b64,
                "format": "png",
            })),
        })
    }

    async fn execute_click(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let selector = require_selector(params)?;
        run_checked(&*self.cli, session_id, &["click".into(), selector.clone()], TIMEOUT_INTERACT).await?;
        Ok(BrowserResult {
            content: format!("Clicked {selector}"),
            details: None,
        })
    }

    async fn execute_fill(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let selector = require_selector(params)?;
        let value = require_param(params, "value", "fill")?;
        run_checked(&*self.cli, session_id, &["fill".into(), selector.clone(), value.to_string()], TIMEOUT_INTERACT).await?;
        Ok(BrowserResult {
            content: format!("Filled {selector}"),
            details: None,
        })
    }

    async fn execute_type(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let selector = require_selector(params)?;
        let text = require_param(params, "text", "type")?;
        let slowly = params
            .get("slowly")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);

        if slowly {
            run_checked(&*self.cli, session_id, &["focus".into(), selector.clone()], TIMEOUT_INTERACT).await?;
            run_checked(&*self.cli, session_id, &["keyboard".into(), "type".into(), text.to_string()], TIMEOUT_INTERACT).await?;
        } else {
            run_checked(&*self.cli, session_id, &["type".into(), selector.clone(), text.to_string()], TIMEOUT_INTERACT).await?;
        }
        Ok(BrowserResult {
            content: format!("Typed into {selector}"),
            details: None,
        })
    }

    async fn execute_select(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let selector = require_selector(params)?;
        let value = require_param(params, "value", "select")?;
        run_checked(&*self.cli, session_id, &["select".into(), selector.clone(), value.to_string()], TIMEOUT_INTERACT).await?;
        Ok(BrowserResult {
            content: format!("Selected '{value}' in {selector}"),
            details: None,
        })
    }

    async fn execute_hover(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let selector = require_selector(params)?;
        run_checked(&*self.cli, session_id, &["hover".into(), selector.clone()], TIMEOUT_INTERACT).await?;
        Ok(BrowserResult {
            content: format!("Hovered over {selector}"),
            details: None,
        })
    }

    async fn execute_press_key(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let key = require_param(params, "key", "pressKey")?;
        run_checked(&*self.cli, session_id, &["press".into(), key.to_string()], TIMEOUT_INTERACT).await?;
        Ok(BrowserResult {
            content: format!("Pressed key '{key}'"),
            details: None,
        })
    }

    async fn execute_wait(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        if let Some(selector) = params.get("selector").and_then(|v| v.as_str()) {
            let norm = refs::normalize_selector(selector);
            run_checked(&*self.cli, session_id, &["wait".into(), norm.clone()], TIMEOUT_NAVIGATE).await?;
            Ok(BrowserResult {
                content: format!("Element {norm} found"),
                details: None,
            })
        } else {
            let timeout_ms = params
                .get("timeout")
                .and_then(serde_json::Value::as_u64)
                .unwrap_or(30000);
            run_checked(&*self.cli, session_id, &["wait".into(), timeout_ms.to_string()], TIMEOUT_NAVIGATE).await?;
            Ok(BrowserResult {
                content: format!("Waited {timeout_ms}ms"),
                details: None,
            })
        }
    }

    async fn execute_scroll(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let direction = params
            .get("direction")
            .and_then(|v| v.as_str())
            .unwrap_or("down");
        if !VALID_DIRECTIONS.contains(&direction) {
            return Err(ToolError::Validation {
                message: format!(
                    "Invalid scroll direction: '{direction}'. Must be one of: {}",
                    VALID_DIRECTIONS.join(", ")
                ),
            });
        }
        let amount = params
            .get("amount")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(500);
        run_checked(&*self.cli, session_id, &["scroll".into(), direction.into(), amount.to_string()], TIMEOUT_INTERACT).await?;
        Ok(BrowserResult {
            content: format!("Scrolled {direction} by {amount}px"),
            details: None,
        })
    }

    async fn execute_get_text(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let selector = require_selector(params)?;
        let output = self
            .cli
            .run(
                session_id,
                &["get".into(), "text".into(), selector, "--json".into()],
                TIMEOUT_OBSERVE,
            )
            .await
            .map_err(ToolError::from)?;
        let parsed = cli::parse_json_output(&output)?;
        let text = parsed.as_str().unwrap_or("").to_string();
        Ok(BrowserResult {
            content: text,
            details: None,
        })
    }

    async fn execute_get_attribute(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let selector = require_selector(params)?;
        let attribute = require_param(params, "attribute", "getAttribute")?;
        let output = self
            .cli
            .run(
                session_id,
                &[
                    "get".into(),
                    "attr".into(),
                    selector,
                    attribute.to_string(),
                    "--json".into(),
                ],
                TIMEOUT_OBSERVE,
            )
            .await
            .map_err(ToolError::from)?;
        let parsed = cli::parse_json_output(&output)?;
        let value = if parsed.is_null() {
            String::new()
        } else {
            parsed.as_str().unwrap_or("").to_string()
        };
        Ok(BrowserResult {
            content: value,
            details: None,
        })
    }

    async fn execute_pdf(
        &self,
        session_id: &str,
        params: &Value,
    ) -> Result<BrowserResult, ToolError> {
        let path = require_param(params, "path", "pdf")?;
        run_checked(&*self.cli, session_id, &["pdf".into(), path.to_string()], TIMEOUT_PDF).await?;
        Ok(BrowserResult {
            content: format!("PDF saved to {path}"),
            details: None,
        })
    }
}

use base64::Engine;

#[async_trait]
impl BrowserProvider for AgentBrowserProvider {
    fn name(&self) -> &str {
        "agent-browser"
    }

    async fn execute_action(
        &self,
        session_id: &str,
        action: &BrowserAction,
    ) -> Result<BrowserResult, ToolError> {
        self.ensure_session(session_id);

        // Auto-start streaming on first action (for iOS preview)
        if !self.stream.is_streaming(session_id) {
            self.stream.start_stream(session_id);
        }

        let start = std::time::Instant::now();
        let result = match action.action.as_str() {
            "navigate" => self.execute_navigate(session_id, &action.params).await,
            "goBack" => self.execute_back(session_id).await,
            "goForward" => self.execute_forward(session_id).await,
            "reload" => self.execute_reload(session_id).await,
            "snapshot" => self.execute_snapshot(session_id).await,
            "screenshot" => self.execute_screenshot(session_id).await,
            "click" => self.execute_click(session_id, &action.params).await,
            "fill" => self.execute_fill(session_id, &action.params).await,
            "type" => self.execute_type(session_id, &action.params).await,
            "select" => self.execute_select(session_id, &action.params).await,
            "hover" => self.execute_hover(session_id, &action.params).await,
            "pressKey" => self.execute_press_key(session_id, &action.params).await,
            "wait" => self.execute_wait(session_id, &action.params).await,
            "scroll" => self.execute_scroll(session_id, &action.params).await,
            "getText" => self.execute_get_text(session_id, &action.params).await,
            "getAttribute" => self.execute_get_attribute(session_id, &action.params).await,
            "pdf" => self.execute_pdf(session_id, &action.params).await,
            other => Err(ToolError::Validation {
                message: format!("Unknown browser action: '{other}'"),
            }),
        };

        let elapsed_ms = start.elapsed().as_millis() as f64;
        metrics::histogram!("browser_action_duration_ms", "action" => action.action.clone())
            .record(elapsed_ms);

        result
    }

    async fn close_session(&self, session_id: &str) -> Result<(), ToolError> {
        self.stream.close_session(session_id);
        if self.sessions.remove(session_id).is_some() {
            metrics::gauge!("browser_sessions_active").decrement(1.0);
        }
        // Best-effort close via CLI
        let _ = self
            .cli
            .run(session_id, &["close".into()], TIMEOUT_CLOSE)
            .await;
        Ok(())
    }

    async fn start_stream(&self, session_id: &str) -> Result<(), ToolError> {
        self.stream.start_stream(session_id);
        Ok(())
    }

    async fn stop_stream(&self, session_id: &str) -> Result<(), ToolError> {
        self.stream.stop_stream(session_id);
        Ok(())
    }

    fn get_status(&self, session_id: &str) -> BrowserStatus {
        let has_browser = self.sessions.contains_key(session_id);
        let is_streaming = self.stream.is_streaming(session_id);
        let current_url = self
            .sessions
            .get(session_id)
            .and_then(|s| s.current_url.clone());
        BrowserStatus {
            has_browser,
            is_streaming,
            current_url,
        }
    }

    fn subscribe(&self) -> broadcast::Receiver<BrowserEvent> {
        self.frame_tx.subscribe()
    }

    async fn close_all_sessions(&self) {
        let session_ids: Vec<String> = self.sessions.iter().map(|e| e.key().clone()).collect();
        for session_id in session_ids {
            if let Err(e) = self.close_session(&session_id).await {
                tracing::warn!(session_id = %session_id, error = %e, "failed to close session during cleanup");
            }
        }
        self.stream.shutdown();
    }
}

fn require_param<'a>(params: &'a Value, key: &str, action: &str) -> Result<&'a str, ToolError> {
    params
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| ToolError::Validation {
            message: format!("{action} requires '{key}' parameter"),
        })
}

fn require_selector(params: &Value) -> Result<String, ToolError> {
    let raw = require_param(params, "selector", "action")?;
    Ok(refs::normalize_selector(raw))
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::cli::{CliOutput, MockCliRunner};
    use super::super::error::AgentBrowserError;
    use serde_json::json;

    fn ok_output(stdout: &str) -> Result<CliOutput, AgentBrowserError> {
        Ok(CliOutput {
            stdout: stdout.into(),
            stderr: String::new(),
            exit_code: 0,
        })
    }

    fn err_output(
        exit_code: i32,
        stderr: &str,
    ) -> Result<CliOutput, AgentBrowserError> {
        Ok(CliOutput {
            stdout: String::new(),
            stderr: stderr.into(),
            exit_code,
        })
    }

    fn make_provider(
        responses: Vec<Result<CliOutput, AgentBrowserError>>,
    ) -> (AgentBrowserProvider, Arc<MockCliRunner>) {
        let mock = Arc::new(MockCliRunner::new(responses));
        let provider = AgentBrowserProvider::with_cli(mock.clone());
        (provider, mock)
    }

    // === Action mapping tests ===

    #[tokio::test]
    async fn navigate_calls_open_with_url() {
        let (provider, mock) = make_provider(vec![
            ok_output(""),                   // open
            ok_output("\"https://e.com\""),   // get url
        ]);
        let action = BrowserAction {
            action: "navigate".into(),
            params: json!({"url": "https://e.com"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Navigated to"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[0], "open");
        assert_eq!(calls[0].1[1], "https://e.com");
    }

    #[tokio::test]
    async fn navigate_missing_url_returns_validation_error() {
        let (provider, _) = make_provider(vec![]);
        let action = BrowserAction {
            action: "navigate".into(),
            params: json!({}),
        };
        let err = provider.execute_action("s1", &action).await.unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    #[tokio::test]
    async fn go_back_calls_back() {
        let (provider, mock) = make_provider(vec![
            ok_output(""),                 // back
            ok_output("\"https://a.com\""), // get url
        ]);
        let action = BrowserAction {
            action: "goBack".into(),
            params: json!({}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert_eq!(result.content, "Navigated back");
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[0], "back");
    }

    #[tokio::test]
    async fn go_forward_calls_forward() {
        let (provider, mock) = make_provider(vec![
            ok_output(""),
            ok_output("\"https://a.com\""),
        ]);
        let action = BrowserAction {
            action: "goForward".into(),
            params: json!({}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert_eq!(result.content, "Navigated forward");
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[0], "forward");
    }

    #[tokio::test]
    async fn reload_calls_reload() {
        let (provider, mock) = make_provider(vec![
            ok_output(""),
            ok_output("\"https://a.com\""),
        ]);
        let action = BrowserAction {
            action: "reload".into(),
            params: json!({}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert_eq!(result.content, "Page reloaded");
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[0], "reload");
    }

    #[tokio::test]
    async fn snapshot_returns_stdout_as_content() {
        let (provider, _) = make_provider(vec![ok_output("@e1 button\n@e2 input")]);
        let action = BrowserAction {
            action: "snapshot".into(),
            params: json!({}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("@e1"));
    }

    #[tokio::test]
    async fn click_normalizes_element_ref() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "click".into(),
            params: json!({"selector": "e1"}),
        };
        let _ = provider.execute_action("s1", &action).await.unwrap();
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[1], "@e1");
    }

    #[tokio::test]
    async fn click_passes_css_selector_through() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "click".into(),
            params: json!({"selector": "#btn"}),
        };
        let _ = provider.execute_action("s1", &action).await.unwrap();
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[1], "#btn");
    }

    #[tokio::test]
    async fn click_missing_selector_returns_error() {
        let (provider, _) = make_provider(vec![]);
        let action = BrowserAction {
            action: "click".into(),
            params: json!({}),
        };
        let err = provider.execute_action("s1", &action).await.unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    #[tokio::test]
    async fn fill_with_selector_and_value() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "fill".into(),
            params: json!({"selector": "#name", "value": "test"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Filled"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1, vec!["fill", "#name", "test"]);
    }

    #[tokio::test]
    async fn type_normal_calls_type_command() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "type".into(),
            params: json!({"selector": "#search", "text": "hello"}),
        };
        let _ = provider.execute_action("s1", &action).await.unwrap();
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[0], "type");
    }

    #[tokio::test]
    async fn type_slowly_calls_focus_then_keyboard_type() {
        let (provider, mock) = make_provider(vec![
            ok_output(""), // focus
            ok_output(""), // keyboard type
        ]);
        let action = BrowserAction {
            action: "type".into(),
            params: json!({"selector": "#search", "text": "hello", "slowly": true}),
        };
        let _ = provider.execute_action("s1", &action).await.unwrap();
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].1[0], "focus");
        assert_eq!(calls[1].1[0], "keyboard");
    }

    #[tokio::test]
    async fn select_with_selector_and_value() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "select".into(),
            params: json!({"selector": "#country", "value": "US"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Selected"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1, vec!["select", "#country", "US"]);
    }

    #[tokio::test]
    async fn hover_normalizes_selector() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "hover".into(),
            params: json!({"selector": "e5"}),
        };
        let _ = provider.execute_action("s1", &action).await.unwrap();
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[1], "@e5");
    }

    #[tokio::test]
    async fn press_key_calls_press() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "pressKey".into(),
            params: json!({"key": "Enter"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Pressed key"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1, vec!["press", "Enter"]);
    }

    #[tokio::test]
    async fn press_key_missing_key_returns_error() {
        let (provider, _) = make_provider(vec![]);
        let action = BrowserAction {
            action: "pressKey".into(),
            params: json!({}),
        };
        let err = provider.execute_action("s1", &action).await.unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    #[tokio::test]
    async fn wait_with_selector_calls_wait() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "wait".into(),
            params: json!({"selector": "#loading"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("found"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1[0], "wait");
        assert_eq!(calls[0].1[1], "#loading");
    }

    #[tokio::test]
    async fn wait_timeout_only() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "wait".into(),
            params: json!({"timeout": 5000}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("5000"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1, vec!["wait", "5000"]);
    }

    #[tokio::test]
    async fn scroll_down_500() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "scroll".into(),
            params: json!({"direction": "down", "amount": 500}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("down"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1, vec!["scroll", "down", "500"]);
    }

    #[tokio::test]
    async fn scroll_invalid_direction_returns_error() {
        let (provider, _) = make_provider(vec![]);
        let action = BrowserAction {
            action: "scroll".into(),
            params: json!({"direction": "sideways"}),
        };
        let err = provider.execute_action("s1", &action).await.unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    #[tokio::test]
    async fn get_text_parses_json_response() {
        let (provider, _) = make_provider(vec![ok_output("\"Hello World\"")]);
        let action = BrowserAction {
            action: "getText".into(),
            params: json!({"selector": "h1"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert_eq!(result.content, "Hello World");
    }

    #[tokio::test]
    async fn get_attribute_null_returns_empty_string() {
        let (provider, _) = make_provider(vec![ok_output("null")]);
        let action = BrowserAction {
            action: "getAttribute".into(),
            params: json!({"selector": "img", "attribute": "alt"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert_eq!(result.content, "");
    }

    #[tokio::test]
    async fn pdf_calls_pdf_with_path() {
        let (provider, mock) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "pdf".into(),
            params: json!({"path": "/tmp/out.pdf"}),
        };
        let result = provider.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("PDF saved"));
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].1, vec!["pdf", "/tmp/out.pdf"]);
    }

    #[tokio::test]
    async fn unknown_action_returns_validation_error() {
        let (provider, _) = make_provider(vec![]);
        let action = BrowserAction {
            action: "fly".into(),
            params: json!({}),
        };
        let err = provider.execute_action("s1", &action).await.unwrap_err();
        assert!(matches!(err, ToolError::Validation { .. }));
    }

    // === Session lifecycle tests ===

    #[tokio::test]
    async fn first_action_creates_session_state() {
        let (provider, _) = make_provider(vec![ok_output("")]);
        let action = BrowserAction {
            action: "snapshot".into(),
            params: json!({}),
        };
        let _ = provider.execute_action("s1", &action).await;
        assert!(provider.sessions.contains_key("s1"));
    }

    #[tokio::test]
    async fn close_session_removes_state() {
        let (provider, _) = make_provider(vec![
            ok_output(""), // snapshot
            ok_output(""), // close
        ]);
        let action = BrowserAction {
            action: "snapshot".into(),
            params: json!({}),
        };
        let _ = provider.execute_action("s1", &action).await;
        provider.close_session("s1").await.unwrap();
        assert!(!provider.sessions.contains_key("s1"));
    }

    #[tokio::test]
    async fn close_nonexistent_session_is_noop() {
        let (provider, _) = make_provider(vec![ok_output("")]);
        assert!(provider.close_session("nonexistent").await.is_ok());
    }

    #[tokio::test]
    async fn close_all_sessions_closes_each() {
        let (provider, _) = make_provider(vec![
            ok_output(""), // action s1
            ok_output(""), // action s2
            ok_output(""), // close s1
            ok_output(""), // close s2
        ]);
        let action = BrowserAction {
            action: "snapshot".into(),
            params: json!({}),
        };
        let _ = provider.execute_action("s1", &action).await;
        let _ = provider.execute_action("s2", &action).await;
        provider.close_all_sessions().await;
        assert!(provider.sessions.is_empty());
    }

    // === Status tests ===

    #[test]
    fn get_status_unknown_session_returns_defaults() {
        let (provider, _) = make_provider(vec![]);
        let status = provider.get_status("unknown");
        assert!(!status.has_browser);
        assert!(!status.is_streaming);
        assert!(status.current_url.is_none());
    }

    #[test]
    fn provider_name_is_agent_browser() {
        let (provider, _) = make_provider(vec![]);
        assert_eq!(provider.name(), "agent-browser");
    }

    #[test]
    fn subscribe_returns_independent_receivers() {
        let (provider, _) = make_provider(vec![]);
        let _rx1 = provider.subscribe();
        let _rx2 = provider.subscribe();
    }

    // === Error handling tests ===

    #[tokio::test]
    async fn cli_nonzero_exit_returns_tool_error() {
        let (provider, _) = make_provider(vec![err_output(1, "boom")]);
        let action = BrowserAction {
            action: "snapshot".into(),
            params: json!({}),
        };
        let err = provider.execute_action("s1", &action).await.unwrap_err();
        assert!(matches!(err, ToolError::Internal { .. }));
    }
}
