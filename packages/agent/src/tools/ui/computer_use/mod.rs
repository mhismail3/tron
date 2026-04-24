//! `ComputerUse` tool — screenshot, click, type, keypress, scroll via macOS APIs.
//!
//! Provides GUI automation through `screencapture` CLI and `osascript` (`AppleScript`).
//! All mutating actions (click, type, keypress, scroll, `moveMouse`) are gated behind a
//! configurable confirmation flag. Read-only actions (screenshot, `getWindows`)
//! are always allowed.
//!
//! ## Submodules
//!
//! | Module        | Content |
//! |---------------|---------|
//! | `actions`     | Input actions: type, keypress, scroll, click, list, focus, get_windows |
//! | `screenshot`  | Screen/window/region capture with resize and compression |
//! | `permissions` | macOS TCC permission probing (accessibility, automation, screen recording, FDA) |
//! | `codegen`     | AppleScript/Swift code generation for UI automation |

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::errors::ToolError;
use crate::tools::traits::{ProcessRunner, ProcessOptions, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{
    get_optional_string, get_optional_u64, validate_required_string,
};

/// Actions that modify system state and require confirmation when enabled.
const MUTATING_ACTIONS: &[&str] = &["clickElement", "type", "keypress", "scroll"];

/// The `ComputerUse` tool provides GUI automation on macOS.
pub struct ComputerUseTool {
    runner: Arc<dyn ProcessRunner>,
    /// Whether mutating actions require confirmation (default: true in production).
    confirm_before_action: bool,
    /// Minimum interval between screenshots in milliseconds.
    screenshot_throttle_ms: u64,
    /// Timestamp (ms since epoch) of the last screenshot.
    last_screenshot_ms: AtomicU64,
    /// Use Rust-native enigo for input (true in production, false in tests for mocking).
    #[cfg(target_os = "macos")]
    use_native_input: bool,
}

impl ComputerUseTool {
    /// Create a new `ComputerUse` tool.
    pub fn new(
        runner: Arc<dyn ProcessRunner>,
        confirm_before_action: bool,
        screenshot_throttle_ms: u64,
    ) -> Self {
        Self {
            runner,
            confirm_before_action,
            screenshot_throttle_ms,
            last_screenshot_ms: AtomicU64::new(0),
            #[cfg(target_os = "macos")]
            use_native_input: true,
        }
    }

    /// Check if an action is mutating (click, type, keypress, scroll, moveMouse).
    fn is_mutating(action: &str) -> bool {
        MUTATING_ACTIONS.contains(&action)
    }

    /// Get current time in milliseconds since epoch.
    fn now_ms() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
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
            "GUI automation on macOS. Take screenshots, interact with UI elements, type, press keys, scroll, and manage windows.\n\n\
             **To interact with UI elements, use clickElement or keypress — never guess coordinates.**\n\
             - clickElement finds buttons, links, menu items, and controls by their text label via macOS Accessibility.\n\
             - listElements shows what's clickable in any app (including Dock items).\n\
             - keypress handles keyboard navigation (Tab, arrows, Enter, Escape, Cmd+shortcuts).\n\
             - screenshot is for visual verification only.\n\n\
             Actions:\n\
             - **clickElement**: Click a UI element by its text label. Works on buttons, links, menu items, \
             dock icons, text fields — anything with an accessibility label. Set `app` to target a specific \
             app (e.g. \"Dock\", \"Finder\", \"Safari\"). Defaults to the frontmost app.\n\
             - **listElements**: List clickable elements in an app. Set `app` to target a specific app \
             (e.g. \"Dock\", \"Safari\"). Defaults to frontmost app. Use before clickElement to see what's available.\n\
             - **screenshot**: Capture full screen, a specific window by name, or a screen region by coordinates.\n\
             - **keypress**: Press key combinations. Primary navigation method alongside clickElement.\n\
             - **type**: Type text into the focused input field.\n\
             - **scroll**: Scroll in a direction (up/down/left/right).\n\
             - **getWindows**: List all windows with position, size, and visibility.\n\
             - **focusWindow**: Bring a window to front by name. Works across Spaces.\n\n\
             NOTE: Mutating actions (clickElement, type, keypress, scroll) may require \
             calling GetConfirmation first if confirmation is enabled.\n\n\
             IMPORTANT: If you get a permission error, tell the user to grant the permission in \
             System Settings > Privacy & Security.",
        )
        .required_property("action", json!({
            "type": "string",
            "description": "The action to perform",
            "enum": ["screenshot", "clickElement", "listElements", "type", "keypress", "scroll", "getWindows", "focusWindow"]
        }))
        .property("text", json!({"type": "string", "description": "Text label of the element to click (for clickElement), or text to type (for type action)"}))
        .property("app", json!({"type": "string", "description": "Target app name for clickElement/listElements (e.g. 'Dock', 'Safari', 'Finder'). Defaults to frontmost app."}))
        .property("keys", json!({"type": "array", "items": {"type": "string"}, "description": "Keys to press (for keypress action), e.g. [\"cmd\", \"c\"]"}))
        .property("window", json!({"type": "string", "description": "Window name or title (for screenshot, focusWindow)"}))
        .property("region", json!({"type": "object", "description": "Screen region to capture (for screenshot). Specify x, y, width, height in screen points.", "properties": {"x": {"type": "number"}, "y": {"type": "number"}, "width": {"type": "number"}, "height": {"type": "number"}}, "required": ["x", "y", "width", "height"]}))
        .property("direction", json!({"type": "string", "description": "Scroll direction: up, down, left, right", "enum": ["up", "down", "left", "right"]}))
        .property("amount", json!({"type": "number", "description": "Scroll amount in pixels (default: 100)", "default": 100}))
        .property("confirmed", json!({"type": "boolean", "description": "Set to true after user has confirmed via GetConfirmation (bypasses confirmation gate)"}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "the action to perform") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        // Confirmation gate: mutating actions require GetConfirmation first
        if self.confirm_before_action && Self::is_mutating(&action) {
            let confirmed = params.get("confirmed").and_then(Value::as_bool).unwrap_or(false);
            if !confirmed {
                let desc = self.describe_action(&action, &params);
                return Ok(error_result(format!(
                    "Action '{action}' requires confirmation. Call GetConfirmation first with \
                     action='{desc}' and riskLevel='medium', then retry this ComputerUse call \
                     with confirmed=true."
                )));
            }
        }

        match action.as_str() {
            "screenshot" => self.take_screenshot(&params, ctx).await,
            "clickElement" => self.click_element(&params, ctx).await,
            "listElements" => self.list_elements(&params, ctx).await,
            "type" => self.type_text(&params, ctx).await,
            "keypress" => self.keypress(&params, ctx).await,
            "scroll" => self.scroll(&params, ctx).await,
            "getWindows" => self.get_windows(ctx).await,
            "focusWindow" => self.focus_window(&params, ctx).await,
            other => Ok(error_result(format!(
                "Unknown action: {other}. Valid actions: screenshot, clickElement, listElements, type, keypress, scroll, getWindows, focusWindow"
            ))),
        }
    }
}

mod actions;
mod screenshot;
mod permissions;
mod codegen;

pub use permissions::{
    PermissionStatus, WizardPermissions, check_permissions_on_startup,
    probe_wizard_permissions,
};

// Re-export parse functions for tests
#[cfg(test)]
pub(crate) use permissions::{parse_automation_result, parse_fda_result};

#[cfg(test)]
#[path = "../computer_use_tests.rs"]
mod tests;
