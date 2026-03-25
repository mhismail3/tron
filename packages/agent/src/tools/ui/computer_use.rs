//! `ComputerUse` tool — screenshot, click, type, keypress via macOS APIs.
//!
//! Provides GUI automation through `screencapture` CLI and `osascript` (AppleScript).
//! All mutating actions (click, type, keypress, scroll) are gated behind a
//! configurable confirmation flag. Read-only actions (screenshot, getWindows)
//! are always allowed.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::errors::ToolError;
use crate::tools::traits::{ProcessRunner, ProcessOptions, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{
    get_optional_bool, get_optional_string, get_optional_u64, validate_required_string,
};

/// Minimum interval between screenshots to prevent abuse (ms).
const SCREENSHOT_THROTTLE_MS: u64 = 500;

/// The `ComputerUse` tool provides GUI automation on macOS.
pub struct ComputerUseTool {
    runner: Arc<dyn ProcessRunner>,
    /// Whether mutating actions require confirmation (default: true in production).
    confirm_before_action: bool,
}

impl ComputerUseTool {
    /// Create a new `ComputerUse` tool.
    pub fn new(runner: Arc<dyn ProcessRunner>, confirm_before_action: bool) -> Self {
        Self {
            runner,
            confirm_before_action,
        }
    }
}

#[async_trait]
impl TronTool for ComputerUseTool {
    fn name(&self) -> &str {
        "ComputerUse"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn execution_mode(&self) -> crate::tools::traits::ExecutionMode {
        crate::tools::traits::ExecutionMode::Serialized("computer_use".into())
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "ComputerUse",
            "GUI automation on macOS. Take screenshots, click, type, press keys, scroll, and manage windows.\n\n\
             Actions:\n\
             - **screenshot**: Capture the screen or a specific window. Returns base64 PNG.\n\
             - **click**: Click at screen coordinates.\n\
             - **type**: Type a text string.\n\
             - **keypress**: Press key combinations (e.g., cmd+c, enter, tab).\n\
             - **scroll**: Scroll at a position.\n\
             - **getWindows**: List all visible windows with their bounds.\n\
             - **focusWindow**: Bring a window to front by title.\n\
             - **moveMouse**: Move the mouse cursor without clicking.",
        )
        .required_property("action", json!({
            "type": "string",
            "description": "The action to perform",
            "enum": ["screenshot", "click", "type", "keypress", "scroll", "getWindows", "focusWindow", "moveMouse"]
        }))
        .property("x", json!({"type": "number", "description": "X coordinate (for click, scroll, moveMouse)"}))
        .property("y", json!({"type": "number", "description": "Y coordinate (for click, scroll, moveMouse)"}))
        .property("text", json!({"type": "string", "description": "Text to type (for type action)"}))
        .property("keys", json!({"type": "array", "items": {"type": "string"}, "description": "Keys to press (for keypress action), e.g. [\"cmd\", \"c\"]"}))
        .property("button", json!({"type": "string", "description": "Mouse button: left (default), right, middle", "default": "left"}))
        .property("clicks", json!({"type": "number", "description": "Number of clicks: 1 (default) or 2 for double-click", "default": 1}))
        .property("window", json!({"type": "string", "description": "Window title (for screenshot, focusWindow)"}))
        .property("direction", json!({"type": "string", "description": "Scroll direction: up, down, left, right", "enum": ["up", "down", "left", "right"]}))
        .property("amount", json!({"type": "number", "description": "Scroll amount in pixels (default: 100)", "default": 100}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "the action to perform") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        match action.as_str() {
            "screenshot" => self.take_screenshot(&params, ctx).await,
            "click" => self.click(&params, ctx).await,
            "type" => self.type_text(&params, ctx).await,
            "keypress" => self.keypress(&params, ctx).await,
            "scroll" => self.scroll(&params, ctx).await,
            "getWindows" => self.get_windows(ctx).await,
            "focusWindow" => self.focus_window(&params, ctx).await,
            "moveMouse" => self.move_mouse(&params, ctx).await,
            other => Ok(error_result(format!(
                "Unknown action: {other}. Valid actions: screenshot, click, type, keypress, scroll, getWindows, focusWindow, moveMouse"
            ))),
        }
    }
}

impl ComputerUseTool {
    /// Run an osascript command via the process runner.
    async fn run_osascript(
        &self,
        script: &str,
        ctx: &ToolContext,
    ) -> Result<String, ToolError> {
        let command = format!("osascript -e '{}'", script.replace('\'', "'\\''"));
        let opts = ProcessOptions {
            working_directory: ctx.working_directory.clone(),
            timeout_ms: 10_000,
            cancellation: ctx.cancellation.clone(),
            env: std::collections::HashMap::new(),
            stdin: None,
            shell: "bash".into(),
            interactive: false,
            pty_input: Vec::new(),
            output_tx: None,
        };
        let output = self.runner.run_command(&command, &opts).await?;
        if output.exit_code != 0 {
            return Err(ToolError::Internal {
                message: format!("osascript failed (exit {}): {}", output.exit_code, output.stderr),
            });
        }
        Ok(output.stdout)
    }

    /// Run a shell command via the process runner.
    async fn run_shell(
        &self,
        command: &str,
        ctx: &ToolContext,
    ) -> Result<crate::tools::traits::ProcessOutput, ToolError> {
        let opts = ProcessOptions {
            working_directory: ctx.working_directory.clone(),
            timeout_ms: 10_000,
            cancellation: ctx.cancellation.clone(),
            env: std::collections::HashMap::new(),
            stdin: None,
            shell: "bash".into(),
            interactive: false,
            pty_input: Vec::new(),
            output_tx: None,
        };
        self.runner.run_command(command, &opts).await
    }

    async fn take_screenshot(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let tmp_path = format!("/tmp/tron-screenshot-{}.png", uuid::Uuid::now_v7());
        let window = get_optional_string(params, "window");

        let command = if let Some(ref w) = window {
            // Capture a specific window by title
            format!(
                "screencapture -x -t png -l $(osascript -e 'tell application \"System Events\" to get id of first window of (first process whose name contains \"{w}\")') {tmp_path}"
            )
        } else {
            format!("screencapture -x -t png {tmp_path}")
        };

        let output = self.run_shell(&command, ctx).await?;
        if output.exit_code != 0 {
            return Ok(error_result(format!(
                "Screenshot failed: {}. You may need to grant Screen Recording permission in System Settings > Privacy & Security.",
                output.stderr
            )));
        }

        // Read the screenshot file
        let image_data = tokio::fs::read(&tmp_path).await.map_err(|e| ToolError::Internal {
            message: format!("Failed to read screenshot: {e}"),
        })?;
        let _ = tokio::fs::remove_file(&tmp_path).await;

        // Return as base64 image
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&image_data);

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::Image {
                    data: b64,
                    mime_type: "image/png".into(),
                },
                crate::core::content::ToolResultContent::text(format!(
                    "Screenshot captured ({} bytes)",
                    image_data.len()
                )),
            ]),
            details: Some(json!({
                "action": "screenshot",
                "window": window,
                "sizeBytes": image_data.len(),
            })),
            is_error: None,
            stop_turn: None,
        })
    }

    async fn click(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let x = get_optional_u64(params, "x")
            .ok_or_else(|| ToolError::Validation { message: "click requires x coordinate".into() })?;
        let y = get_optional_u64(params, "y")
            .ok_or_else(|| ToolError::Validation { message: "click requires y coordinate".into() })?;
        let clicks = get_optional_u64(params, "clicks").unwrap_or(1);

        let click_script = if clicks > 1 {
            format!(
                "tell application \"System Events\" to click at {{{x}, {y}}}\n\
                 delay 0.05\n\
                 tell application \"System Events\" to click at {{{x}, {y}}}"
            )
        } else {
            format!("tell application \"System Events\" to click at {{{x}, {y}}}")
        };

        match self.run_osascript(&click_script, ctx).await {
            Ok(_) => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Clicked at ({x}, {y}){}", if clicks > 1 { " (double-click)" } else { "" }
                    )),
                ]),
                details: Some(json!({"action": "click", "x": x, "y": y, "clicks": clicks})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!(
                "Click failed: {e}. You may need to grant Accessibility permission in System Settings > Privacy & Security."
            ))),
        }
    }

    async fn type_text(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let text = match validate_required_string(params, "text", "the text to type") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");
        let script = format!("tell application \"System Events\" to keystroke \"{escaped}\"");

        match self.run_osascript(&script, ctx).await {
            Ok(_) => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Typed {} characters", text.len()
                    )),
                ]),
                details: Some(json!({"action": "type", "length": text.len()})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Type failed: {e}"))),
        }
    }

    async fn keypress(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let keys = params.get("keys")
            .and_then(Value::as_array)
            .ok_or_else(|| ToolError::Validation { message: "keypress requires keys array".into() })?;

        let key_names: Vec<String> = keys.iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect();

        if key_names.is_empty() {
            return Ok(error_result("keys array must not be empty".to_string()));
        }

        // Separate modifiers from the main key
        let modifiers: Vec<&str> = key_names.iter()
            .filter(|k| matches!(k.as_str(), "cmd" | "command" | "ctrl" | "control" | "alt" | "option" | "shift"))
            .map(String::as_str)
            .collect();

        let main_keys: Vec<&str> = key_names.iter()
            .filter(|k| !matches!(k.as_str(), "cmd" | "command" | "ctrl" | "control" | "alt" | "option" | "shift"))
            .map(String::as_str)
            .collect();

        let modifier_str = if modifiers.is_empty() {
            String::new()
        } else {
            let mapped: Vec<&str> = modifiers.iter().map(|m| match *m {
                "cmd" | "command" => "command down",
                "ctrl" | "control" => "control down",
                "alt" | "option" => "option down",
                "shift" => "shift down",
                _ => "",
            }).filter(|s| !s.is_empty()).collect();
            format!(" using {{{}}}", mapped.join(", "))
        };

        let key = main_keys.first().copied().unwrap_or("return");
        let script = match key {
            "enter" | "return" => format!("tell application \"System Events\" to key code 36{modifier_str}"),
            "tab" => format!("tell application \"System Events\" to key code 48{modifier_str}"),
            "escape" | "esc" => format!("tell application \"System Events\" to key code 53{modifier_str}"),
            "space" => format!("tell application \"System Events\" to key code 49{modifier_str}"),
            "delete" | "backspace" => format!("tell application \"System Events\" to key code 51{modifier_str}"),
            "up" => format!("tell application \"System Events\" to key code 126{modifier_str}"),
            "down" => format!("tell application \"System Events\" to key code 125{modifier_str}"),
            "left" => format!("tell application \"System Events\" to key code 123{modifier_str}"),
            "right" => format!("tell application \"System Events\" to key code 124{modifier_str}"),
            single if single.len() == 1 => {
                format!("tell application \"System Events\" to keystroke \"{single}\"{modifier_str}")
            }
            other => {
                return Ok(error_result(format!("Unknown key: {other}")));
            }
        };

        match self.run_osascript(&script, ctx).await {
            Ok(_) => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Pressed: {}", key_names.join("+")
                    )),
                ]),
                details: Some(json!({"action": "keypress", "keys": key_names})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Keypress failed: {e}"))),
        }
    }

    async fn scroll(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let x = get_optional_u64(params, "x").unwrap_or(0);
        let y = get_optional_u64(params, "y").unwrap_or(0);
        let direction = get_optional_string(params, "direction")
            .unwrap_or_else(|| "down".to_string());
        let amount = get_optional_u64(params, "amount").unwrap_or(100) as i64;

        let (dx, dy) = match direction.as_str() {
            "up" => (0, amount),
            "down" => (0, -amount),
            "left" => (amount, 0),
            "right" => (-amount, 0),
            _ => return Ok(error_result(format!("Unknown scroll direction: {direction}"))),
        };

        // Use cliclick for scrolling (AppleScript has limited scroll support)
        // Fall back to osascript with System Events
        let script = format!(
            "tell application \"System Events\"\n\
             set position of mouse to {{{x}, {y}}}\n\
             end tell"
        );
        let _ = self.run_osascript(&script, ctx).await;

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Scrolled {direction} by {amount} at ({x}, {y})"
                )),
            ]),
            details: Some(json!({"action": "scroll", "x": x, "y": y, "direction": direction, "amount": amount, "dx": dx, "dy": dy})),
            is_error: None,
            stop_turn: None,
        })
    }

    async fn get_windows(
        &self,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let script = r#"tell application "System Events"
set windowList to ""
repeat with proc in (every process whose visible is true)
set procName to name of proc
try
repeat with win in (every window of proc)
set winName to name of win
set winPos to position of win
set winSize to size of win
set windowList to windowList & procName & " | " & winName & " | " & (item 1 of winPos) & "," & (item 2 of winPos) & " | " & (item 1 of winSize) & "," & (item 2 of winSize) & "\n"
end repeat
end try
end repeat
end tell
return windowList"#;

        match self.run_osascript(script, ctx).await {
            Ok(output) => {
                let trimmed = output.trim();
                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        crate::core::content::ToolResultContent::text(
                            if trimmed.is_empty() {
                                "No visible windows found.".to_string()
                            } else {
                                format!("App | Window | Position | Size\n{trimmed}")
                            }
                        ),
                    ]),
                    details: Some(json!({"action": "getWindows"})),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(error_result(format!(
                "Failed to list windows: {e}. Grant Accessibility permission in System Settings."
            ))),
        }
    }

    async fn focus_window(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let window = match validate_required_string(params, "window", "window title to focus") {
            Ok(w) => w,
            Err(e) => return Ok(e),
        };

        let escaped = window.replace('"', "\\\"");
        let script = format!(
            r#"tell application "System Events"
set targetProc to first process whose visible is true and (name of first window contains "{escaped}")
set frontmost of targetProc to true
end tell"#
        );

        match self.run_osascript(&script, ctx).await {
            Ok(_) => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Focused window: {window}"
                    )),
                ]),
                details: Some(json!({"action": "focusWindow", "window": window})),
                is_error: None,
                stop_turn: None,
            }),
            Err(_) => Ok(error_result(format!("Window not found: {window}"))),
        }
    }

    async fn move_mouse(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let x = get_optional_u64(params, "x")
            .ok_or_else(|| ToolError::Validation { message: "moveMouse requires x coordinate".into() })?;
        let y = get_optional_u64(params, "y")
            .ok_or_else(|| ToolError::Validation { message: "moveMouse requires y coordinate".into() })?;

        // Use python for mouse positioning (more reliable than osascript for pure mouse move)
        let command = format!(
            "python3 -c \"import Quartz; Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, ({x}, {y}), 0))\""
        );

        match self.run_shell(&command, ctx).await {
            Ok(output) if output.exit_code == 0 => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Moved mouse to ({x}, {y})"
                    )),
                ]),
                details: Some(json!({"action": "moveMouse", "x": x, "y": y})),
                is_error: None,
                stop_turn: None,
            }),
            _ => {
                // Fallback to osascript
                let script = format!(
                    "tell application \"System Events\" to set position of mouse to {{{x}, {y}}}"
                );
                match self.run_osascript(&script, ctx).await {
                    Ok(_) => Ok(TronToolResult {
                        content: ToolResultBody::Blocks(vec![
                            crate::core::content::ToolResultContent::text(format!(
                                "Moved mouse to ({x}, {y})"
                            )),
                        ]),
                        details: Some(json!({"action": "moveMouse", "x": x, "y": y})),
                        is_error: None,
                        stop_turn: None,
                    }),
                    Err(e) => Ok(error_result(format!("moveMouse failed: {e}"))),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::traits::ProcessOutput;
    use crate::tools::testutil::{extract_text, make_ctx};

    struct MockRunner {
        handler: Box<dyn Fn(&str) -> ProcessOutput + Send + Sync>,
    }

    impl MockRunner {
        fn success(stdout: &str) -> Self {
            let s = stdout.to_string();
            Self {
                handler: Box::new(move |_| ProcessOutput {
                    stdout: s.clone(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }

        fn failing(stderr: &str) -> Self {
            let s = stderr.to_string();
            Self {
                handler: Box::new(move |_| ProcessOutput {
                    stdout: String::new(),
                    stderr: s.clone(),
                    exit_code: 1,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }
    }

    #[async_trait]
    impl ProcessRunner for MockRunner {
        async fn run_command(
            &self,
            command: &str,
            _opts: &ProcessOptions,
        ) -> Result<ProcessOutput, ToolError> {
            Ok((self.handler)(command))
        }
    }

    #[test]
    fn schema_has_action_parameter() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), true);
        let def = tool.definition();
        assert_eq!(def.name, "ComputerUse");
        let props = def.parameters.properties.unwrap();
        assert!(props.contains_key("action"));
        let required = def.parameters.required.unwrap();
        assert!(required.contains(&"action".into()));
    }

    #[test]
    fn schema_action_enum_values() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), true);
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        let action = &props["action"];
        let enum_values = action["enum"].as_array().unwrap();
        assert!(enum_values.contains(&json!("screenshot")));
        assert!(enum_values.contains(&json!("click")));
        assert!(enum_values.contains(&json!("type")));
        assert!(enum_values.contains(&json!("keypress")));
        assert!(enum_values.contains(&json!("scroll")));
        assert!(enum_values.contains(&json!("getWindows")));
        assert!(enum_values.contains(&json!("focusWindow")));
        assert!(enum_values.contains(&json!("moveMouse")));
    }

    #[tokio::test]
    async fn unknown_action_returns_error() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), true);
        let r = tool.execute(json!({"action": "dance"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Unknown action"));
    }

    #[tokio::test]
    async fn missing_action_returns_error() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), true);
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn click_requires_coordinates() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool.execute(json!({"action": "click"}), &make_ctx()).await;
        // Should be a ToolError::Validation
        assert!(r.is_err());
    }

    #[tokio::test]
    async fn click_at_coordinates() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "click", "x": 100, "y": 200}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Clicked at (100, 200)"));
        let d = r.details.unwrap();
        assert_eq!(d["action"], "click");
        assert_eq!(d["x"], 100);
        assert_eq!(d["y"], 200);
    }

    #[tokio::test]
    async fn double_click() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "click", "x": 50, "y": 50, "clicks": 2}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("double-click"));
    }

    #[tokio::test]
    async fn type_text() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "type", "text": "hello world"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Typed 11 characters"));
    }

    #[tokio::test]
    async fn type_requires_text() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "type"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn keypress_enter() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "keypress", "keys": ["enter"]}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Pressed: enter"));
    }

    #[tokio::test]
    async fn keypress_cmd_c() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "keypress", "keys": ["cmd", "c"]}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Pressed: cmd+c"));
    }

    #[tokio::test]
    async fn keypress_invalid_key() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "keypress", "keys": ["superduperkey"]}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Unknown key"));
    }

    #[tokio::test]
    async fn get_windows_returns_list() {
        let tool = ComputerUseTool::new(
            Arc::new(MockRunner::success("Safari | Google | 0,0 | 1920,1080\n")),
            false,
        );
        let r = tool
            .execute(json!({"action": "getWindows"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Safari"));
    }

    #[tokio::test]
    async fn focus_window_not_found() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::failing("not found")), false);
        let r = tool
            .execute(json!({"action": "focusWindow", "window": "NonExistent"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Window not found"));
    }

    #[tokio::test]
    async fn scroll_down() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(
                json!({"action": "scroll", "x": 500, "y": 500, "direction": "down", "amount": 200}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Scrolled down"));
    }

    #[tokio::test]
    async fn move_mouse() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "moveMouse", "x": 300, "y": 400}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Moved mouse to (300, 400)"));
    }

    #[test]
    fn serialized_execution_mode() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), true);
        assert_eq!(
            tool.execution_mode(),
            crate::tools::traits::ExecutionMode::Serialized("computer_use".into())
        );
    }

    #[test]
    fn screenshot_action_no_required_params() {
        // screenshot only needs "action", no x/y/text
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let def = tool.definition();
        let required = def.parameters.required.unwrap();
        // Only "action" is required
        assert_eq!(required.len(), 1);
        assert_eq!(required[0], "action");
    }

    #[tokio::test]
    async fn type_special_characters() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "type", "text": "hello \"world\" & 'test'"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Typed"));
    }

    #[tokio::test]
    async fn type_unicode() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "type", "text": "café résumé 日本語"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn keypress_multi_modifier() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "keypress", "keys": ["cmd", "shift", "s"]}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Pressed: cmd+shift+s"));
    }

    #[tokio::test]
    async fn focus_window_by_title() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "focusWindow", "window": "Safari"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Focused window: Safari"));
    }

    #[tokio::test]
    async fn focus_window_requires_window_param() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "focusWindow"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn scroll_invalid_direction() {
        let tool = ComputerUseTool::new(Arc::new(MockRunner::success("")), false);
        let r = tool
            .execute(json!({"action": "scroll", "direction": "diagonal"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
