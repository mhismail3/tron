//! `ComputerUse` tool — screenshot, click, type, keypress, scroll via macOS APIs.
//!
//! Provides GUI automation through `screencapture` CLI and `osascript` (`AppleScript`).
//! All mutating actions (click, type, keypress, scroll, `moveMouse`) are gated behind a
//! configurable confirmation flag. Read-only actions (screenshot, `getWindows`)
//! are always allowed.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::errors::ToolError;
use crate::tools::traits::{ProcessRunner, ProcessOptions, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{
    get_optional_f64, get_optional_string, get_optional_u64, validate_required_string,
};

/// Actions that modify system state and require confirmation when enabled.
const MUTATING_ACTIONS: &[&str] = &["click", "type", "keypress", "scroll", "moveMouse"];

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
            "GUI automation on macOS. Take screenshots, click, type, press keys, scroll, and manage windows.\n\n\
             Actions:\n\
             - **screenshot**: Capture the full screen, or a specific window by name/title. Returns base64 image with screen resolution in details. Attempts capture regardless of window visibility state.\n\
             - **click**: Click at screen coordinates. Needs Accessibility permission.\n\
             - **type**: Type a text string. Needs Accessibility permission.\n\
             - **keypress**: Press key combinations (e.g., cmd+c, enter, tab). Needs Accessibility permission.\n\
             - **scroll**: Scroll at a position. Uses Quartz scroll wheel events.\n\
             - **getWindows**: List all windows (including off-screen) with process name, title, position, size, and visibility status. Works from background processes.\n\
             - **focusWindow**: Bring a window to front by title using native activation. Verifies the window is on-screen after activation. If the app is on another Space, it will be brought to the current one.\n\
             - **moveMouse**: Move the mouse cursor without clicking.\n\n\
             NOTE: Mutating actions (click, type, keypress, scroll, moveMouse) may require \
             calling GetConfirmation first if confirmation is enabled.\n\n\
             IMPORTANT: If you get a permission error, tell the user to grant the permission in \
             System Settings > Privacy & Security. Do NOT attempt workarounds — the tool handles window management internally.",
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
    /// Generate a human-readable description of the action for confirmation.
    #[allow(clippy::unused_self)]
    fn describe_action(&self, action: &str, params: &Value) -> String {
        match action {
            "click" => {
                let x = get_optional_f64(params, "x").unwrap_or(0.0);
                let y = get_optional_f64(params, "y").unwrap_or(0.0);
                let clicks = get_optional_u64(params, "clicks").unwrap_or(1);
                if clicks > 1 {
                    format!("Double-click at ({x}, {y})")
                } else {
                    format!("Click at ({x}, {y})")
                }
            }
            "type" => {
                let text = get_optional_string(params, "text").unwrap_or_default();
                let preview = if text.len() > 30 {
                    format!("{}...", &text[..27])
                } else {
                    text
                };
                format!("Type text: \"{preview}\"")
            }
            "keypress" => {
                let keys: Vec<String> = params.get("keys")
                    .and_then(Value::as_array)
                    .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                    .unwrap_or_default();
                format!("Press keys: {}", keys.join("+"))
            }
            "scroll" => {
                let dir = get_optional_string(params, "direction").unwrap_or_else(|| "down".into());
                let amount = get_optional_u64(params, "amount").unwrap_or(100);
                format!("Scroll {dir} by {amount}px")
            }
            "moveMouse" => {
                let x = get_optional_f64(params, "x").unwrap_or(0.0);
                let y = get_optional_f64(params, "y").unwrap_or(0.0);
                format!("Move mouse to ({x}, {y})")
            }
            _ => action.to_string(),
        }
    }

    /// Build a Swift script that finds the best matching window for screenshot capture.
    ///
    /// Scores all matching windows by:
    /// - +1,000,000 if on-screen (`kCGWindowIsOnscreen`)
    /// - +500,000 if normal layer (`kCGWindowLayer == 0`)
    /// - +area (width * height) — prefers larger content windows
    ///
    /// Output: `windowId\tonScreen\twidth\theight`
    /// On failure (no match): exit 1, available window names on stderr.
    fn build_screenshot_window_swift(search: &str) -> String {
        let escaped = search.replace('\\', "\\\\").replace('"', "\\\"");
        format!(
            r#"import Cocoa; let ws = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var names = [String](); var bestId = -1; var bestScore = -1; var bestOnScreen = false; var bestW = 0.0; var bestH = 0.0; for w in ws {{ let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; if !name.isEmpty {{ names.append("\(owner): \(name)") }}; guard owner.localizedCaseInsensitiveContains("{escaped}") || name.localizedCaseInsensitiveContains("{escaped}") else {{ continue }}; let layer = w[kCGWindowLayer as String] as? Int ?? 999; let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]; let bw = bounds["Width"] as? Double ?? 0; let bh = bounds["Height"] as? Double ?? 0; let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false; let area = Int(bw * bh); let score = (onScreen ? 1000000 : 0) + (layer == 0 ? 500000 : 0) + area; if score > bestScore {{ bestScore = score; bestId = w[kCGWindowNumber as String] as! Int; bestOnScreen = onScreen; bestW = bw; bestH = bh }} }}; guard bestId >= 0 else {{ fputs(names.joined(separator: "\n"), stderr); Foundation.exit(1) }}; print("\(bestId)\t\(bestOnScreen)\t\(bestW)\t\(bestH)"); Foundation.exit(0)"#
        )
    }

    /// Parse width and height from a PNG file's IHDR chunk (bytes 16-23).
    fn png_dimensions(data: &[u8]) -> Option<(u32, u32)> {
        if data.len() < 24 {
            return None;
        }
        let w = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
        let h = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
        if w > 0 && h > 0 { Some((w, h)) } else { None }
    }

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

    /// Get screen resolution (width, height) via enigo (CGEvent-based, no subprocess).
    async fn screen_bounds(&self) -> Option<(f64, f64)> {
        #[cfg(target_os = "macos")]
        {
            match super::input::screen_size().await {
                Ok((w, h)) => Some((f64::from(w), f64::from(h))),
                Err(_) => None,
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            None
        }
    }

    /// Validate coordinates are within screen bounds.
    /// Returns an error result if coordinates are out of bounds.
    async fn validate_coordinates(
        &self,
        x: f64,
        y: f64,
    ) -> Option<TronToolResult> {
        if x < 0.0 || y < 0.0 {
            return Some(error_result(format!(
                "Invalid coordinates ({x}, {y}): coordinates must be non-negative"
            )));
        }

        if let Some((max_x, max_y)) = self.screen_bounds().await
            && (x > max_x || y > max_y)
        {
            return Some(error_result(format!(
                "Coordinates ({x}, {y}) are outside screen bounds ({max_x}x{max_y}). \
                 Use getWindows to see where windows are positioned."
            )));
        }
        None
    }

    async fn take_screenshot(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        use base64::Engine;

        // Screenshot throttle
        let now = Self::now_ms();
        let last = self.last_screenshot_ms.load(Ordering::Relaxed);
        if last > 0 && now.saturating_sub(last) < self.screenshot_throttle_ms {
            let wait = self.screenshot_throttle_ms - (now - last);
            return Ok(error_result(format!(
                "Screenshot throttled. Please wait {wait}ms before taking another screenshot."
            )));
        }

        let tmp_path = format!("/tmp/tron-screenshot-{}.png", uuid::Uuid::now_v7());
        let window = get_optional_string(params, "window");

        if let Some(ref w) = window {
            // Window-specific capture: use scored CGWindowList lookup via Swift to find
            // the best matching window ID, then screencapture -l <id>.
            // Scoring prefers on-screen, layer-0, largest-area windows to avoid
            // matching non-capturable system/accessory windows.
            let swift_script = Self::build_screenshot_window_swift(w);
            let wid_command = format!("swift -e '{}'", swift_script.replace('\'', "'\\''"));
            let wid_output = self.run_shell(&wid_command, ctx).await?;

            if wid_output.exit_code != 0 {
                let available = wid_output.stderr.trim();
                let window_list = if available.is_empty() {
                    String::new()
                } else {
                    format!(" Available windows:\n{available}")
                };
                return Ok(error_result(format!(
                    "Window '{w}' not found.{window_list}",
                )));
            }

            // Parse: "windowId\tonScreen\twidth\theight"
            let parts: Vec<&str> = wid_output.stdout.trim().splitn(4, '\t').collect();
            let window_id = parts.first().unwrap_or(&"").to_string();
            let on_screen = parts.get(1).map(|s| *s == "true").unwrap_or(true);
            let _win_w: f64 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(1.0);
            let _win_h: f64 = parts.get(3).and_then(|s| s.parse().ok()).unwrap_or(1.0);

            tracing::debug!(
                window = %w, id = %window_id, on_screen, width = _win_w, height = _win_h,
                "Window lookup result for screenshot"
            );

            // Always attempt capture — kCGWindowIsOnscreen is unreliable (reports false
            // for windows on other Spaces or when running from a background launchd process,
            // but screencapture -l can still capture them successfully).
            let capture_command = format!("screencapture -x -t png -l {window_id} {tmp_path}");
            let output = self.run_shell(&capture_command, ctx).await?;
            if output.exit_code != 0 {
                tracing::debug!(
                    window = %w, id = %window_id, on_screen, stderr = %output.stderr.trim(),
                    "screencapture failed for window"
                );
                let hint = if on_screen {
                    "Grant Screen Recording permission in System Settings > Privacy & Security."
                } else {
                    "The window may be minimized or off-screen. Try focusWindow first, or grant Screen Recording permission."
                };
                return Ok(error_result(format!(
                    "Window screenshot failed: {}. {hint}",
                    output.stderr.trim()
                )));
            }
        } else {
            // Full screen capture
            let command = format!("screencapture -x -t png {tmp_path}");
            let output = self.run_shell(&command, ctx).await?;
            if output.exit_code != 0 {
                return Ok(error_result(format!(
                    "Screenshot failed: {}. Grant Screen Recording permission in System Settings > Privacy & Security.",
                    output.stderr
                )));
            }
        }

        // Read the raw PNG screenshot
        let raw_data = match tokio::fs::read(&tmp_path).await {
            Ok(data) => data,
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp_path).await;
                return Ok(error_result(format!("Failed to read screenshot: {e}")));
            }
        };

        // Step 1: Resize PNG to max 1280px (consistent dimensions regardless of
        // Retina scaling). This ensures the image the LLM sees always has a known
        // relationship to the screen coordinate system.
        let resize_cmd = format!(
            "sips --resampleHeightWidthMax 1280 '{tmp_path}'",
        );
        let _ = self.run_shell(&resize_cmd, ctx).await;

        // Read the resized PNG
        let resized_png = match tokio::fs::read(&tmp_path).await {
            Ok(data) => data,
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp_path).await;
                return Ok(error_result(format!("Failed to read resized screenshot: {e}")));
            }
        };
        let original_size = resized_png.len();

        // Parse image dimensions from PNG header (bytes 16-23 of IHDR chunk)
        let (img_w, img_h) = Self::png_dimensions(&resized_png).unwrap_or((0, 0));

        // Step 2: Try JPEG compression on the resized PNG.
        let jpg_path = format!("{}.jpg", &tmp_path[..tmp_path.len() - 4]);
        let sips_cmd = format!(
            "sips --setProperty format jpeg --setProperty formatOptions 70 '{tmp_path}' --out '{jpg_path}'",
        );
        let sips_result = self.run_shell(&sips_cmd, ctx).await;
        let _ = tokio::fs::remove_file(&tmp_path).await;

        let (image_data, mime_type) = match sips_result {
            Ok(output) if output.exit_code == 0 => {
                match tokio::fs::read(&jpg_path).await {
                    Ok(data) if !data.is_empty() && data.len() < resized_png.len() => {
                        tracing::debug!(
                            jpeg_bytes = data.len(), png_bytes = original_size,
                            "Using JPEG (smaller than PNG)"
                        );
                        let _ = tokio::fs::remove_file(&jpg_path).await;
                        (data, "image/jpeg")
                    }
                    Ok(data) => {
                        tracing::debug!(
                            jpeg_bytes = data.len(), png_bytes = original_size,
                            "Skipping JPEG (not smaller than PNG), using PNG"
                        );
                        let _ = tokio::fs::remove_file(&jpg_path).await;
                        (resized_png, "image/png")
                    }
                    _ => {
                        tracing::debug!("JPEG read failed, falling back to PNG");
                        let _ = tokio::fs::remove_file(&jpg_path).await;
                        (resized_png, "image/png")
                    }
                }
            }
            _ => {
                tracing::debug!("sips compression failed, using original PNG");
                let _ = tokio::fs::remove_file(&jpg_path).await;
                (resized_png, "image/png")
            }
        };

        // Update throttle timestamp
        self.last_screenshot_ms.store(Self::now_ms(), Ordering::Relaxed);

        let b64 = base64::engine::general_purpose::STANDARD.encode(&image_data);

        // Include screen resolution and image dimensions for coordinate mapping
        let screen = self.screen_bounds().await;

        // Size guard: if a window capture is suspiciously small, it's likely
        // blank/minimized/off-screen. Warn the agent so it can focus the window first.
        let size_warning = if window.is_some() && image_data.len() < 10_000 {
            "\nWARNING: Screenshot appears blank or very small — the window may be minimized or on another desktop. Try using focusWindow first to bring it to the current screen, then retry the screenshot."
        } else {
            ""
        };

        let mut details = json!({
            "action": "screenshot",
            "window": window,
            "sizeBytes": image_data.len(),
            "originalSizeBytes": original_size,
            "mimeType": mime_type,
            "imageWidth": img_w,
            "imageHeight": img_h,
        });
        if let Some((w, h)) = screen {
            details["screenWidth"] = json!(w);
            details["screenHeight"] = json!(h);
        }

        // Build informative text with coordinate mapping guide
        let format_label = if mime_type == "image/jpeg" { "JPEG" } else { "PNG" };
        let mut text = format!(
            "Screenshot captured ({img_w}x{img_h} image, {} bytes {format_label})",
            image_data.len()
        );

        // Coordinate mapping guide — this is critical for click accuracy
        if let Some((sw, sh)) = screen {
            if img_w > 0 && img_h > 0 {
                #[allow(clippy::cast_precision_loss)]
                let scale_x = sw / img_w as f64;
                #[allow(clippy::cast_precision_loss)]
                let scale_y = sh / img_h as f64;

                if window.is_some() {
                    text.push_str(&format!(
                        "\nCoordinate mapping: this is a WINDOW screenshot. \
                         Use getWindows to find the window's screen position, then: \
                         screen_x = window_x + (image_x * {scale_x:.2}), \
                         screen_y = window_y + (image_y * {scale_y:.2})"
                    ));
                } else {
                    text.push_str(&format!(
                        "\nCoordinate mapping: screen is {sw}x{sh} points, image is {img_w}x{img_h}px. \
                         To click where you see pixel (x,y) in the image: \
                         screen_x = image_x * {scale_x:.2}, screen_y = image_y * {scale_y:.2}"
                    ));
                }
            }
        }

        if !size_warning.is_empty() {
            text.push_str(size_warning);
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::Image {
                    data: b64,
                    mime_type: mime_type.into(),
                },
                crate::core::content::ToolResultContent::text(text),
            ]),
            details: Some(details),
            is_error: None,
            stop_turn: None,
        })
    }

    async fn click(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let x = get_optional_f64(params, "x")
            .ok_or_else(|| ToolError::Validation { message: "click requires x coordinate".into() })?;
        let y = get_optional_f64(params, "y")
            .ok_or_else(|| ToolError::Validation { message: "click requires y coordinate".into() })?;

        if let Some(err) = self.validate_coordinates(x, y).await {
            return Ok(err);
        }

        let clicks = get_optional_u64(params, "clicks").unwrap_or(1);
        let button = get_optional_string(params, "button").unwrap_or_else(|| "left".into());

        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::input::click(x, y, &button, clicks).await
                } else {
                    // Test/fallback path: use osascript
                    let xi = x as i64;
                    let yi = y as i64;
                    let script = format!("tell application \"System Events\" to click at {{{xi}, {yi}}}");
                    self.run_osascript(&script, ctx).await.map(|_| ())
                        .map_err(|e| format!("{e}"))
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                Err::<(), String>("ComputerUse click is only supported on macOS".into())
            }
        };

        match result {
            Ok(()) => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Clicked at ({x}, {y}){}", if clicks > 1 { " (double-click)" } else { "" }
                    )),
                ]),
                details: Some(json!({"action": "click", "x": x, "y": y, "clicks": clicks, "button": button})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Click failed: {e}"))),
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

        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::input::type_text(&text).await
                } else {
                    let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");
                    let script = format!("tell application \"System Events\" to keystroke \"{escaped}\"");
                    self.run_osascript(&script, ctx).await.map(|_| ()).map_err(|e| format!("{e}"))
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                let _ = ctx;
                Err::<(), String>("ComputerUse type is only supported on macOS".into())
            }
        };

        match result {
            Ok(()) => Ok(TronToolResult {
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

        // Validate all key names before dispatching
        #[cfg(target_os = "macos")]
        for k in &key_names {
            if super::input::map_key(k).is_none() {
                return Ok(error_result(format!("Unknown key: {k}")));
            }
        }

        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::input::key_press(&key_names).await
                } else {
                    // Test fallback: treat as success (mock runner handles osascript)
                    let script = "tell application \"System Events\" to keystroke \"\"".to_string();
                    self.run_osascript(&script, ctx).await.map(|_| ()).map_err(|e| format!("{e}"))
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                Err::<(), String>("ComputerUse keypress is only supported on macOS".into())
            }
        };

        match result {
            Ok(()) => Ok(TronToolResult {
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
        let x = get_optional_f64(params, "x").unwrap_or(0.0);
        let y = get_optional_f64(params, "y").unwrap_or(0.0);

        if (x != 0.0 || y != 0.0)
            && let Some(err) = self.validate_coordinates(x, y).await
        {
            return Ok(err);
        }

        let direction = get_optional_string(params, "direction")
            .unwrap_or_else(|| "down".to_string());
        let amount = get_optional_u64(params, "amount").unwrap_or(100) as i32;

        // Validate direction before dispatching
        if !matches!(direction.as_str(), "up" | "down" | "left" | "right") {
            return Ok(error_result(format!("Unknown scroll direction: {direction}")));
        }

        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::input::scroll(&direction, amount, x, y).await
                } else {
                    let script = "tell application \"System Events\" to key code 125".to_string();
                    self.run_osascript(&script, ctx).await.map(|_| ()).map_err(|e| format!("{e}"))
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                Err::<(), String>("ComputerUse scroll is only supported on macOS".into())
            }
        };

        match result {
            Ok(()) => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Scrolled {direction} by {amount}px at ({x}, {y})"
                    )),
                ]),
                details: Some(json!({
                    "action": "scroll", "x": x, "y": y,
                    "direction": direction, "amount": amount,
                })),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Scroll failed: {e}"))),
        }
    }

    /// Swift script for listing windows via CGWindowList (works from background processes).
    const GET_WINDOWS_SWIFT: &'static str = r#"import Cocoa; let ws = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var lines = [String](); for w in ws { let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; if name.isEmpty { continue }; let layer = w[kCGWindowLayer as String] as? Int ?? 999; if layer != 0 { continue }; let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]; let x = Int(bounds["X"] as? Double ?? 0); let y = Int(bounds["Y"] as? Double ?? 0); let bw = Int(bounds["Width"] as? Double ?? 0); let bh = Int(bounds["Height"] as? Double ?? 0); let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false; lines.append("\(owner) | \(name) | \(x),\(y) | \(bw),\(bh) | \(onScreen ? "visible" : "off-screen")") }; print(lines.joined(separator: "\n"))"#;

    async fn get_windows(
        &self,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        // Use CGWindowList via Swift — works reliably from background launchd processes,
        // unlike the AppleScript "System Events" approach which returns empty when
        // the agent isn't running in a foreground terminal session.
        let cmd = format!("swift -e '{}'", Self::GET_WINDOWS_SWIFT.replace('\'', "'\\''"));
        let output = self.run_shell(&cmd, ctx).await?;

        if output.exit_code != 0 {
            return Ok(error_result(format!(
                "Failed to list windows: {}. Grant Screen Recording permission in System Settings > Privacy & Security.",
                output.stderr.trim()
            )));
        }

        let trimmed = output.stdout.trim();
        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(
                    if trimmed.is_empty() {
                        "No windows found.".to_string()
                    } else {
                        format!("App | Window | Position | Size | Status\n{trimmed}")
                    }
                ),
            ]),
            details: Some(json!({"action": "getWindows"})),
            is_error: None,
            stop_turn: None,
        })
    }

    /// Build a Swift script that finds a window by name, activates the app via
    /// `NSRunningApplication.activate`, and verifies the window became on-screen.
    ///
    /// Output: `owner\tname\tpid\tactivated\tverified`
    fn build_focus_window_swift(search: &str) -> String {
        let escaped = search.replace('\\', "\\\\").replace('"', "\\\"");
        format!(
            r#"import Cocoa; let ws = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var names = [String](); var bestScore = -1; var bestOwner = ""; var bestName = ""; var bestPid: pid_t = 0; for w in ws {{ let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0; if !name.isEmpty {{ names.append("\(owner): \(name)") }}; guard owner.localizedCaseInsensitiveContains("{escaped}") || name.localizedCaseInsensitiveContains("{escaped}") else {{ continue }}; let layer = w[kCGWindowLayer as String] as? Int ?? 999; let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]; let bw = bounds["Width"] as? Double ?? 0; let bh = bounds["Height"] as? Double ?? 0; let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false; let area = Int(bw * bh); let score = (onScreen ? 1000000 : 0) + (layer == 0 ? 500000 : 0) + area; if score > bestScore {{ bestScore = score; bestOwner = owner; bestName = name; bestPid = pid_t(pid) }} }}; guard bestPid > 0 else {{ fputs(names.joined(separator: "\n"), stderr); Foundation.exit(1) }}; guard let app = NSRunningApplication(processIdentifier: bestPid) else {{ print("\(bestOwner)\t\(bestName)\t\(bestPid)\tno_process\tfalse"); Foundation.exit(0) }}; let ok = app.activate(options: .activateIgnoringOtherApps); Thread.sleep(forTimeInterval: 0.3); let ws2 = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var verified = false; for w in ws2 {{ let p = w[kCGWindowOwnerPID as String] as? Int ?? 0; if p == Int(bestPid), let on = w[kCGWindowIsOnscreen as String] as? Bool, on {{ verified = true; break }} }}; print("\(bestOwner)\t\(bestName)\t\(bestPid)\t\(ok ? "activated" : "failed")\t\(verified)"); Foundation.exit(0)"#
        )
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

        // Single Swift call: find window → activate via NSRunningApplication → verify
        let swift_script = Self::build_focus_window_swift(&window);
        let cmd = format!("swift -e '{}'", swift_script.replace('\'', "'\\''"));
        let output = self.run_shell(&cmd, ctx).await.map_err(|e| {
            ToolError::Internal { message: format!("focusWindow lookup failed: {e}") }
        })?;

        if output.exit_code != 0 {
            let available = output.stderr.trim();
            let list = if available.is_empty() {
                "No windows found.".to_string()
            } else {
                format!("Available windows:\n{available}")
            };
            return Ok(error_result(format!(
                "Window '{window}' not found. {list}"
            )));
        }

        // Parse: "owner\tname\tpid\tactivated|failed|no_process\tverified"
        let parts: Vec<&str> = output.stdout.trim().splitn(5, '\t').collect();
        let owner = parts.first().unwrap_or(&"").to_string();
        let _name = parts.get(1).unwrap_or(&"").to_string();
        let pid: u64 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
        let activation = parts.get(3).unwrap_or(&"unknown");
        let verified = parts.get(4).map(|s| *s == "true").unwrap_or(false);

        tracing::debug!(
            search = %window, owner = %owner, pid, activation = %activation, verified,
            "focusWindow result"
        );

        if *activation == "failed" || *activation == "no_process" {
            return Ok(error_result(format!(
                "Found window '{window}' (app: {owner}, pid: {pid}) but activation failed. \
                 Try opening the app with Bash: open -a \"{owner}\""
            )));
        }

        let status = if verified {
            format!("Focused window: {window} (app: {owner}, verified on-screen)")
        } else {
            format!("Focused window: {window} (app: {owner}, activated but not yet verified on-screen — \
                     the window may need a moment or may be on another Space)")
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(status),
            ]),
            details: Some(json!({
                "action": "focusWindow",
                "window": window,
                "app": owner,
                "pid": pid,
                "activated": *activation == "activated",
                "verified": verified,
            })),
            is_error: None,
            stop_turn: None,
        })
    }

    async fn move_mouse(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let x = get_optional_f64(params, "x")
            .ok_or_else(|| ToolError::Validation { message: "moveMouse requires x coordinate".into() })?;
        let y = get_optional_f64(params, "y")
            .ok_or_else(|| ToolError::Validation { message: "moveMouse requires y coordinate".into() })?;

        if let Some(err) = self.validate_coordinates(x, y).await {
            return Ok(err);
        }

        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::input::move_mouse(x, y).await
                } else {
                    let xi = x as i64;
                    let yi = y as i64;
                    let script = format!("tell application \"System Events\" to set position of mouse to {{{xi}, {yi}}}");
                    self.run_osascript(&script, ctx).await.map(|_| ()).map_err(|e| format!("{e}"))
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                Err::<(), String>("ComputerUse moveMouse is only supported on macOS".into())
            }
        };

        match result {
            Ok(()) => Ok(TronToolResult {
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

// MARK: - Startup Permission Check

/// Check macOS permissions needed by the agent at server startup.
///
/// Probes two capabilities and logs results:
/// 1. **Screen Recording** — needed for screencapture.
///    Tested with a silent capture. Triggers the native OS prompt on first run.
/// 2. **Full Disk Access** — needed for reading/writing protected locations.
///    No native prompt exists for FDA, so we open System Settings on first detection.
///
/// Note: Accessibility for input simulation is handled by the enigo crate, which
/// auto-prompts via `Settings::open_prompt_to_get_permissions = true` on first use.
///
/// No-op on non-macOS platforms.
pub async fn check_permissions_on_startup() {
    if std::env::consts::OS != "macos" {
        return;
    }

    tracing::info!("checking macOS permissions...");

    // 2. Screen Recording: test with a silent screencapture. On first run, macOS
    //    shows its native Screen Recording permission dialog.
    let tmp = format!("/tmp/tron-permission-check-{}.png", std::process::id());
    let screen_recording = tokio::process::Command::new("screencapture")
        .args(["-x", "-t", "png", &tmp])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .output()
        .await;

    let file_ok = tokio::fs::metadata(&tmp).await.map(|m| m.len() > 0).unwrap_or(false);
    let _ = tokio::fs::remove_file(&tmp).await;

    match screen_recording {
        Ok(output) if output.status.success() && file_ok => {
            tracing::info!("Screen Recording permission: granted");
        }
        Ok(_) => {
            tracing::warn!(
                "Screen Recording permission not granted. \
                 ComputerUse screenshots will not work. \
                 Grant via: System Settings > Privacy & Security > Screen Recording \
                 (add your terminal app)"
            );
        }
        Err(e) => {
            tracing::warn!("could not check Screen Recording permission: {e}");
        }
    }

    // 3. Full Disk Access: test by reading a protected path. Unlike Accessibility
    //    and Screen Recording, FDA has NO native prompt — the only way to grant it
    //    is via System Settings. We use a sentinel file so we only prompt once.
    let sentinel = format!("{}/.tron/system/.fda-granted", crate::core::paths::home_dir());
    if tokio::fs::metadata(&sentinel).await.is_ok() {
        tracing::info!("Full Disk Access: previously granted (sentinel exists)");
        return;
    }

    // Try reading a protected path to check FDA status
    let fda_check = tokio::fs::read_dir(
        format!("{}/Library/Mail", crate::core::paths::home_dir())
    ).await;

    match fda_check {
        Ok(_) => {
            tracing::info!("Full Disk Access: granted");
            // Write sentinel so we don't check again
            let _ = tokio::fs::write(&sentinel, "granted").await;
        }
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            tracing::warn!(
                "Full Disk Access not granted. The agent may hang when accessing \
                 protected system locations. Opening System Settings to grant FDA..."
            );
            // FDA has no native prompt — System Settings is the only way.
            // Open directly to the Full Disk Access pane.
            let _ = tokio::process::Command::new("open")
                .args(["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .await;
        }
        Err(_) => {
            // Path doesn't exist or other non-permission error — FDA likely granted
            // or Mail.app not installed. Check an alternative path.
            let alt_check = tokio::fs::read_dir(
                format!("{}/Library/Safari", crate::core::paths::home_dir())
            ).await;
            match alt_check {
                Ok(_) => {
                    tracing::info!("Full Disk Access: granted");
                    let _ = tokio::fs::write(&sentinel, "granted").await;
                }
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                    tracing::warn!(
                        "Full Disk Access not granted. Opening System Settings..."
                    );
                    let _ = tokio::process::Command::new("open")
                        .args(["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .status()
                        .await;
                }
                Err(_) => {
                    tracing::info!("Full Disk Access: likely granted (no protected paths to test)");
                    let _ = tokio::fs::write(&sentinel, "granted").await;
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

    /// Mock runner that captures commands and returns configurable output.
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

        /// Runner that responds differently based on command content.
        fn with_handler<F>(handler: F) -> Self
        where
            F: Fn(&str) -> ProcessOutput + Send + Sync + 'static,
        {
            Self { handler: Box::new(handler) }
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

    fn tool(confirm: bool) -> ComputerUseTool {
        let mut t = ComputerUseTool::new(Arc::new(MockRunner::success("")), confirm, 500);
        #[cfg(target_os = "macos")]
        { t.use_native_input = false; }
        t
    }

    fn tool_with_runner(runner: MockRunner, confirm: bool) -> ComputerUseTool {
        let mut t = ComputerUseTool::new(Arc::new(runner), confirm, 500);
        #[cfg(target_os = "macos")]
        { t.use_native_input = false; }
        t
    }

    // ─── Schema tests ───

    #[test]
    fn schema_has_action_parameter() {
        let t = tool(true);
        let def = t.definition();
        assert_eq!(def.name, "ComputerUse");
        let props = def.parameters.properties.unwrap();
        assert!(props.contains_key("action"));
        let required = def.parameters.required.unwrap();
        assert!(required.contains(&"action".into()));
    }

    #[test]
    fn schema_action_enum_values() {
        let t = tool(true);
        let def = t.definition();
        let props = def.parameters.properties.unwrap();
        let action = &props["action"];
        let enum_values = action["enum"].as_array().unwrap();
        for expected in ["screenshot", "click", "type", "keypress", "scroll", "getWindows", "focusWindow", "moveMouse"] {
            assert!(enum_values.contains(&json!(expected)), "missing: {expected}");
        }
    }

    #[test]
    fn schema_has_confirmed_property() {
        let t = tool(true);
        let def = t.definition();
        let props = def.parameters.properties.unwrap();
        assert!(props.contains_key("confirmed"), "should have confirmed property for confirmation bypass");
    }

    #[test]
    fn serialized_execution_mode() {
        let t = tool(true);
        assert_eq!(
            t.execution_mode(),
            crate::tools::traits::ExecutionMode::Serialized("computer_use".into())
        );
    }

    #[test]
    fn screenshot_action_no_required_params() {
        let t = tool(false);
        let def = t.definition();
        let required = def.parameters.required.unwrap();
        assert_eq!(required.len(), 1);
        assert_eq!(required[0], "action");
    }

    // ─── Confirmation gating tests ───

    #[tokio::test]
    async fn mutating_action_requires_confirmation_when_enabled() {
        let t = tool(true);
        for action in MUTATING_ACTIONS {
            let mut params = json!({"action": action});
            // Add required params for each action
            match *action {
                "click" | "moveMouse" => {
                    params["x"] = json!(100);
                    params["y"] = json!(200);
                }
                "type" => { params["text"] = json!("hello"); }
                "keypress" => { params["keys"] = json!(["enter"]); }
                _ => {}
            }
            let r = t.execute(params, &make_ctx()).await.unwrap();
            assert_eq!(r.is_error, Some(true), "action '{action}' should require confirmation");
            assert!(
                extract_text(&r).contains("requires confirmation"),
                "action '{action}' error should mention confirmation"
            );
        }
    }

    #[tokio::test]
    async fn mutating_action_proceeds_with_confirmed_flag() {
        let t = tool(true);
        let r = t.execute(
            json!({"action": "type", "text": "hello", "confirmed": true}),
            &make_ctx(),
        ).await.unwrap();
        assert!(r.is_error.is_none(), "should proceed when confirmed=true");
    }

    #[tokio::test]
    async fn mutating_action_proceeds_when_confirmation_disabled() {
        let t = tool(false);
        let r = t.execute(
            json!({"action": "type", "text": "hello"}),
            &make_ctx(),
        ).await.unwrap();
        assert!(r.is_error.is_none(), "should proceed when confirm_before_action=false");
    }

    #[tokio::test]
    async fn readonly_actions_skip_confirmation() {
        let t = tool(true);
        // screenshot is read-only
        // Note: screenshot will fail with mock since there's no file, but it shouldn't hit confirmation
        let r = t.execute(json!({"action": "getWindows"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "getWindows should not require confirmation");
    }

    // ─── Action tests ───

    #[tokio::test]
    async fn unknown_action_returns_error() {
        let t = tool(false);
        let r = t.execute(json!({"action": "dance"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Unknown action"));
    }

    #[tokio::test]
    async fn missing_action_returns_error() {
        let t = tool(false);
        let r = t.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn click_requires_coordinates() {
        let t = tool(false);
        let r = t.execute(json!({"action": "click"}), &make_ctx()).await;
        assert!(r.is_err());
    }

    #[tokio::test]
    async fn click_at_coordinates() {
        let t = tool(false);
        let r = t.execute(json!({"action": "click", "x": 100, "y": 200}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Clicked at (100, 200)"));
        let d = r.details.unwrap();
        assert_eq!(d["action"], "click");
        assert_eq!(d["x"], 100.0);
        assert_eq!(d["y"], 200.0);
    }

    #[tokio::test]
    async fn click_accepts_float_coordinates() {
        let t = tool(false);
        let r = t.execute(json!({"action": "click", "x": 100.5, "y": 200.7}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["x"], 100.5);
        assert_eq!(d["y"], 200.7);
    }

    #[tokio::test]
    async fn click_negative_coordinates_rejected() {
        let t = tool(false);
        let r = t.execute(json!({"action": "click", "x": -10, "y": 200}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("non-negative"));
    }

    #[tokio::test]
    async fn double_click() {
        let t = tool(false);
        let r = t.execute(json!({"action": "click", "x": 50, "y": 50, "clicks": 2}), &make_ctx()).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("double-click"));
    }

    #[tokio::test]
    async fn type_text() {
        let t = tool(false);
        let r = t.execute(json!({"action": "type", "text": "hello world"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Typed 11 characters"));
    }

    #[tokio::test]
    async fn type_requires_text() {
        let t = tool(false);
        let r = t.execute(json!({"action": "type"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn type_special_characters() {
        let t = tool(false);
        let r = t.execute(json!({"action": "type", "text": "hello \"world\" & 'test'"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn type_unicode() {
        let t = tool(false);
        let r = t.execute(json!({"action": "type", "text": "café résumé 日本語"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn keypress_enter() {
        let t = tool(false);
        let r = t.execute(json!({"action": "keypress", "keys": ["enter"]}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Pressed: enter"));
    }

    #[tokio::test]
    async fn keypress_cmd_c() {
        let t = tool(false);
        let r = t.execute(json!({"action": "keypress", "keys": ["cmd", "c"]}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Pressed: cmd+c"));
    }

    #[tokio::test]
    async fn keypress_multi_modifier() {
        let t = tool(false);
        let r = t.execute(json!({"action": "keypress", "keys": ["cmd", "shift", "s"]}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Pressed: cmd+shift+s"));
    }

    #[tokio::test]
    async fn keypress_invalid_key() {
        let t = tool(false);
        let r = t.execute(json!({"action": "keypress", "keys": ["superduperkey"]}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Unknown key"));
    }

    #[tokio::test]
    async fn keypress_empty_keys() {
        let t = tool(false);
        let r = t.execute(json!({"action": "keypress", "keys": []}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn get_windows_returns_list() {
        let t = tool_with_runner(
            MockRunner::success("Safari | Google | 0,0 | 1920,1080 | visible\n"),
            false,
        );
        let r = t.execute(json!({"action": "getWindows"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Safari"), "should list Safari: {text}");
        assert!(text.contains("Status"), "header should include Status column: {text}");
    }

    #[tokio::test]
    async fn get_windows_includes_visibility_status() {
        let t = tool_with_runner(
            MockRunner::success("Safari | Google | 0,0 | 1920,1080 | visible\nTextEdit | Untitled | 100,100 | 800,600 | off-screen\n"),
            false,
        );
        let r = t.execute(json!({"action": "getWindows"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("visible"), "should show visible state: {text}");
        assert!(text.contains("off-screen"), "should show off-screen state: {text}");
    }

    #[tokio::test]
    async fn get_windows_empty() {
        let t = tool(false);
        let r = t.execute(json!({"action": "getWindows"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("No windows found"));
    }

    #[tokio::test]
    async fn focus_window_by_title() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: "Safari\tApple\t12345\tactivated\ttrue".into(),
                    stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "focusWindow", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Focused window: Safari"));
    }

    #[tokio::test]
    async fn focus_window_not_found() {
        let t = tool_with_runner(MockRunner::failing("not found"), false);
        let r = t.execute(json!({"action": "focusWindow", "window": "NonExistent"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("not found"), "error should mention not found: {text}");
    }

    #[tokio::test]
    async fn focus_window_requires_window_param() {
        let t = tool(false);
        let r = t.execute(json!({"action": "focusWindow"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn scroll_down() {
        let t = tool(false);
        let r = t.execute(
            json!({"action": "scroll", "x": 500, "y": 500, "direction": "down", "amount": 200}),
            &make_ctx(),
        ).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Scrolled down"));
    }

    #[tokio::test]
    async fn scroll_invalid_direction() {
        let t = tool(false);
        let r = t.execute(json!({"action": "scroll", "direction": "diagonal"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn scroll_defaults_to_down() {
        let t = tool(false);
        let r = t.execute(json!({"action": "scroll"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Scrolled down"));
    }

    #[tokio::test]
    async fn scroll_negative_coordinates_rejected() {
        let t = tool(false);
        let r = t.execute(
            json!({"action": "scroll", "x": -10, "y": 100, "direction": "down"}),
            &make_ctx(),
        ).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("non-negative"));
    }

    #[tokio::test]
    async fn scroll_out_of_bounds_rejected() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("bounds of window of desktop") {
                ProcessOutput {
                    stdout: "0, 0, 1920, 1080\n".into(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });

        let t = tool_with_runner(runner, false);
        let r = t.execute(
            json!({"action": "scroll", "x": 5000, "y": 500, "direction": "down"}),
            &make_ctx(),
        ).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("outside screen bounds"));
    }

    #[tokio::test]
    async fn scroll_zero_coordinates_skip_validation() {
        // Default (0, 0) should skip validation entirely
        let t = tool(false);
        let r = t.execute(json!({"action": "scroll", "direction": "up"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn move_mouse() {
        let t = tool(false);
        let r = t.execute(json!({"action": "moveMouse", "x": 300, "y": 400}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Moved mouse to (300, 400)"));
    }

    #[tokio::test]
    async fn move_mouse_negative_rejected() {
        let t = tool(false);
        let r = t.execute(json!({"action": "moveMouse", "x": -5, "y": 100}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("non-negative"));
    }

    #[tokio::test]
    async fn move_mouse_requires_coordinates() {
        let t = tool(false);
        let r = t.execute(json!({"action": "moveMouse"}), &make_ctx()).await;
        assert!(r.is_err());
    }

    // ─── Screenshot throttle tests ───

    #[tokio::test]
    async fn screenshot_throttle_blocks_rapid_calls() {
        // Use a runner that returns a valid PNG-ish file for screenshots
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("screencapture") {
                // Create a tiny fake file at the path
                // The actual file creation is handled by the runner, but in tests
                // the file won't exist. The tool will fail at read, which is fine
                // for throttle testing.
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });

        let t = ComputerUseTool::new(Arc::new(runner), false, 500);

        // Simulate that a screenshot was just taken
        t.last_screenshot_ms.store(ComputerUseTool::now_ms(), Ordering::Relaxed);

        // Immediate second call should be throttled
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("throttled"));
    }

    #[tokio::test]
    async fn screenshot_throttle_allows_after_interval() {
        let t = ComputerUseTool::new(Arc::new(MockRunner::success("")), false, 500);

        // Set last screenshot to well in the past
        let past = ComputerUseTool::now_ms() - 1000;
        t.last_screenshot_ms.store(past, Ordering::Relaxed);

        // This call should NOT be throttled (but will fail at file read, which is OK)
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        // It shouldn't be a throttle error (it may fail for other reasons in test env)
        if r.is_error == Some(true) {
            assert!(!extract_text(&r).contains("throttled"));
        }
    }

    #[tokio::test]
    async fn screenshot_custom_throttle_value() {
        let t = ComputerUseTool::new(Arc::new(MockRunner::success("")), false, 2000);

        // Set last screenshot to 1 second ago — should still be throttled with 2000ms setting
        let past = ComputerUseTool::now_ms() - 1000;
        t.last_screenshot_ms.store(past, Ordering::Relaxed);

        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("throttled"));
    }

    // ─── Screenshot compression tests ───

    /// Helper: create a MockRunner that simulates the full screenshot pipeline.
    /// `png_size` controls how many bytes the "PNG" file will be.
    /// `jpg_size` controls how many bytes the "JPEG" file will be (None = sips fails).
    fn screenshot_runner(png_size: usize, jpg_size: Option<usize>) -> MockRunner {
        MockRunner::with_handler(move |cmd| {
            if cmd.contains("screencapture") {
                let path = cmd.rsplit(' ').next().unwrap_or("/tmp/test.png");
                // Write a fake PNG with valid IHDR header so png_dimensions() works.
                // PNG: 8-byte sig + 4-byte IHDR len + 4-byte "IHDR" + 4-byte W + 4-byte H
                let mut data = Vec::with_capacity(png_size.max(24));
                data.extend_from_slice(b"\x89PNG\r\n\x1a\n"); // PNG signature (8 bytes)
                data.extend_from_slice(&13u32.to_be_bytes()); // IHDR data length (9-12)
                data.extend_from_slice(b"IHDR");              // chunk type (13-16)
                data.extend_from_slice(&1280u32.to_be_bytes()); // width (17-20)
                data.extend_from_slice(&960u32.to_be_bytes());  // height (21-24)
                // Pad to the requested size
                if png_size > data.len() {
                    data.resize(png_size, 0);
                }
                std::fs::write(path, &data).ok();
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else if cmd.contains("sips") && cmd.contains("--out") {
                // JPEG conversion step (has --out flag)
                match jpg_size {
                    Some(size) => {
                        let out_path = cmd
                            .rfind("--out '")
                            .map(|i| {
                                let start = i + 7;
                                let end = cmd[start..].find('\'').map(|j| start + j).unwrap_or(cmd.len());
                                &cmd[start..end]
                            })
                            .unwrap_or("/tmp/test.jpg");
                        let data = vec![0xFFu8; size];
                        std::fs::write(out_path, &data).ok();
                        ProcessOutput {
                            stdout: String::new(),
                            stderr: String::new(),
                            exit_code: 0,
                            duration_ms: 10,
                            timed_out: false,
                            interrupted: false,
                        }
                    }
                    None => ProcessOutput {
                        stdout: String::new(),
                        stderr: "sips failed".into(),
                        exit_code: 1,
                        duration_ms: 10,
                        timed_out: false,
                        interrupted: false,
                    },
                }
            } else if cmd.contains("sips") && cmd.contains("resampleHeightWidthMax") {
                // Resize step — succeeds (file already written by screencapture handler)
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        })
    }

    #[tokio::test]
    async fn screenshot_compression_prefers_smaller_format() {
        // JPEG (500 bytes) smaller than PNG (1000 bytes) → use JPEG
        let t = tool_with_runner(screenshot_runner(1000, Some(500)), false);
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let text = extract_text(&r);
        assert!(text.contains("JPEG"), "text should say JPEG: {text}");
        let d = r.details.unwrap();
        assert_eq!(d["mimeType"], "image/jpeg");
        assert_eq!(d["sizeBytes"], 500);
        assert_eq!(d["originalSizeBytes"], 1000);
    }

    #[tokio::test]
    async fn screenshot_compression_skips_larger_jpeg() {
        // JPEG (2000 bytes) LARGER than PNG (1000 bytes) → use PNG
        let t = tool_with_runner(screenshot_runner(1000, Some(2000)), false);
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let text = extract_text(&r);
        assert!(text.contains("bytes PNG"), "text should say PNG when JPEG is larger: {text}");
        let d = r.details.unwrap();
        assert_eq!(d["mimeType"], "image/png");
        assert_eq!(d["sizeBytes"], 1000);
    }

    #[tokio::test]
    async fn screenshot_text_includes_image_dimensions() {
        let t = tool_with_runner(screenshot_runner(1000, Some(500)), false);
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let text = extract_text(&r);
        // Must include image pixel dimensions
        assert!(text.contains("1280x960 image"), "should have image dimensions: {text}");
        // On macOS, should include coordinate mapping guide
        #[cfg(target_os = "macos")]
        {
            assert!(text.contains("Coordinate mapping"), "should have coord guide: {text}");
            assert!(text.contains("screen_x"), "should show formula: {text}");
        }
        // Details should also have imageWidth/imageHeight
        let d = r.details.unwrap();
        assert_eq!(d["imageWidth"], 1280);
        assert_eq!(d["imageHeight"], 960);
    }

    #[tokio::test]
    async fn screenshot_window_text_includes_window_mapping() {
        let runner = window_screenshot_runner("42\ttrue\t1187\t1100", 0, 0, "");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let text = extract_text(&r);
        // Window screenshots should explain they need getWindows for position
        #[cfg(target_os = "macos")]
        assert!(text.contains("WINDOW screenshot"), "should say it's a window screenshot: {text}");
    }

    #[tokio::test]
    async fn screenshot_compression_skips_same_size_jpeg() {
        // JPEG same size as PNG → prefer PNG (no benefit from lossy)
        let t = tool_with_runner(screenshot_runner(1000, Some(1000)), false);
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let d = r.details.unwrap();
        assert_eq!(d["mimeType"], "image/png");
    }

    #[tokio::test]
    async fn screenshot_compression_fallback_on_sips_failure() {
        // sips fails → use PNG
        let t = tool_with_runner(screenshot_runner(1000, None), false);
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let text = extract_text(&r);
        assert!(text.contains("bytes PNG"), "text should say PNG on sips failure: {text}");
        let d = r.details.unwrap();
        assert_eq!(d["mimeType"], "image/png");
    }

    #[tokio::test]
    async fn screenshot_compression_empty_jpeg_falls_back() {
        // sips succeeds but produces empty JPEG → use PNG
        let t = tool_with_runner(screenshot_runner(1000, Some(0)), false);
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let d = r.details.unwrap();
        assert_eq!(d["mimeType"], "image/png");
    }

    // ─── Coordinate bounds tests ───

    #[tokio::test]
    async fn click_out_of_bounds_rejected() {
        // Mock runner that returns screen bounds for Finder query
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("bounds of window of desktop") {
                ProcessOutput {
                    stdout: "0, 0, 1920, 1080\n".into(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });

        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "click", "x": 3000, "y": 500}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("outside screen bounds"));
    }

    #[tokio::test]
    async fn click_within_bounds_succeeds() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("bounds of window of desktop") {
                ProcessOutput {
                    stdout: "0, 0, 1920, 1080\n".into(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });

        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "click", "x": 960, "y": 540}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn move_mouse_out_of_bounds_rejected() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("bounds of window of desktop") {
                ProcessOutput {
                    stdout: "0, 0, 1920, 1080\n".into(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });

        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "moveMouse", "x": 100, "y": 2000}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("outside screen bounds"));
    }

    // ─── Window selection scoring tests ───

    #[tokio::test]
    async fn screenshot_window_swift_uses_scoring() {
        // The Swift script should use scoring logic, not first-match-wins.
        // Capture the command string and verify it contains scoring keywords.
        use std::sync::{Arc as StdArc, Mutex};
        let commands: StdArc<Mutex<Vec<String>>> = StdArc::new(Mutex::new(Vec::new()));
        let cmds = commands.clone();
        let runner = MockRunner::with_handler(move |cmd| {
            cmds.lock().unwrap().push(cmd.to_string());
            // Swift script should fail (no real CGWindowList in test)
            ProcessOutput {
                stdout: String::new(),
                stderr: "Safari: Start Page".into(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        });
        let t = tool_with_runner(runner, false);
        let _ = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await;
        let cmds = commands.lock().unwrap();
        let swift_cmd = cmds.iter().find(|c| c.contains("swift")).expect("should run swift");
        assert!(swift_cmd.contains("kCGWindowLayer"), "script should check window layer");
        assert!(swift_cmd.contains("kCGWindowIsOnscreen"), "script should check on-screen state");
        assert!(swift_cmd.contains("kCGWindowBounds"), "script should check window bounds");
    }

    #[tokio::test]
    async fn screenshot_window_not_found_lists_available() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: "Safari: Start Page\nArc: Tab1".into(),
                    exit_code: 1,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "NonexistentApp"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("not found"), "should say not found: {text}");
        assert!(text.contains("Available windows"), "should list available: {text}");
    }

    #[tokio::test]
    async fn screenshot_window_not_found_empty_list() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 1,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Nothing"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("not found"), "should say not found: {text}");
    }

    #[tokio::test]
    async fn focus_window_uses_nsrunningapplication() {
        // Verify the Swift script uses NSRunningApplication.activate, not osascript
        use std::sync::{Arc as StdArc, Mutex};
        let commands: StdArc<Mutex<Vec<String>>> = StdArc::new(Mutex::new(Vec::new()));
        let cmds = commands.clone();
        let runner = MockRunner::with_handler(move |cmd| {
            cmds.lock().unwrap().push(cmd.to_string());
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: "Safari\tApple\t12345\tactivated\ttrue".into(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let _ = t.execute(json!({"action": "focusWindow", "window": "Safari"}), &make_ctx()).await;
        let cmds = commands.lock().unwrap();
        let swift_cmd = cmds.iter().find(|c| c.contains("swift")).expect("should run swift");
        assert!(swift_cmd.contains("NSRunningApplication"), "should use NSRunningApplication");
        assert!(swift_cmd.contains("activate"), "should call activate");
        assert!(swift_cmd.contains("activateIgnoringOtherApps"), "should use activateIgnoringOtherApps");
        // Should NOT use osascript "set frontmost"
        assert!(!cmds.iter().any(|c| c.contains("osascript") && c.contains("frontmost")),
            "should not use osascript set frontmost");
    }

    #[tokio::test]
    async fn focus_window_not_found_lists_available() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: "Xcode: Project\nFinder: Downloads".into(),
                    exit_code: 1,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "focusWindow", "window": "NonexistentApp"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("not found"), "should say not found: {text}");
        assert!(text.contains("Available windows"), "should list available: {text}");
    }

    #[tokio::test]
    async fn focus_window_activated_and_verified() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: "Safari\tApple\t12345\tactivated\ttrue".into(),
                    stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "focusWindow", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let text = extract_text(&r);
        assert!(text.contains("verified on-screen"), "should say verified: {text}");
        let d = r.details.unwrap();
        assert_eq!(d["verified"], true);
        assert_eq!(d["activated"], true);
    }

    #[tokio::test]
    async fn focus_window_activated_but_unverified() {
        // App activated but no window became onScreen (e.g., other Space issue)
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: "Safari\tApple\t12345\tactivated\tfalse".into(),
                    stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "focusWindow", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should still succeed (activation worked): {}", extract_text(&r));
        let text = extract_text(&r);
        assert!(text.contains("not yet verified"), "should warn about unverified: {text}");
        let d = r.details.unwrap();
        assert_eq!(d["verified"], false);
    }

    #[tokio::test]
    async fn focus_window_activation_failed() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: "Safari\tApple\t12345\tfailed\tfalse".into(),
                    stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "focusWindow", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("activation failed"), "should say failed: {text}");
    }

    #[tokio::test]
    async fn focus_window_no_process() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: "Safari\tApple\t99999\tno_process\tfalse".into(),
                    stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "focusWindow", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("activation failed"), "should say failed: {text}");
    }

    // ─── Window visibility diagnosis tests ───

    /// Helper: create a MockRunner for window screenshot tests.
    /// `swift_stdout`: what the Swift script returns on stdout (e.g., "42\ttrue\t1920\t1080")
    /// `swift_exit`: exit code of Swift script (0=found, 1=not found)
    /// `capture_exit`: exit code of screencapture (0=success, 1=failure)
    /// `capture_stderr`: stderr from screencapture
    fn window_screenshot_runner(
        swift_stdout: &str,
        swift_exit: i32,
        capture_exit: i32,
        capture_stderr: &str,
    ) -> MockRunner {
        let swift_out = swift_stdout.to_string();
        let cap_stderr = capture_stderr.to_string();
        MockRunner::with_handler(move |cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: swift_out.clone(),
                    stderr: String::new(),
                    exit_code: swift_exit,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else if cmd.contains("screencapture") {
                if capture_exit == 0 {
                    // Create a fake PNG with valid IHDR header
                    let path = cmd.rsplit(' ').next().unwrap_or("/tmp/test.png");
                    let mut data = Vec::with_capacity(5000);
                    data.extend_from_slice(b"\x89PNG\r\n\x1a\n"); // signature
                    data.extend_from_slice(&13u32.to_be_bytes()); // IHDR length
                    data.extend_from_slice(b"IHDR");
                    data.extend_from_slice(&1280u32.to_be_bytes()); // width
                    data.extend_from_slice(&960u32.to_be_bytes());  // height
                    data.resize(5000, 0);
                    std::fs::write(path, &data).ok();
                }
                ProcessOutput {
                    stdout: String::new(),
                    stderr: cap_stderr.clone(),
                    exit_code: capture_exit,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else if cmd.contains("sips") {
                // sips fails in test (no real image) — fallback to PNG
                ProcessOutput {
                    stdout: String::new(),
                    stderr: "not a valid image".into(),
                    exit_code: 1,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        })
    }

    #[tokio::test]
    async fn screenshot_offscreen_window_capture_succeeds() {
        // kCGWindowIsOnscreen=false but screencapture succeeds (the common case:
        // window on another Space, or background launchd reports false).
        // Must NOT block — should attempt capture and succeed.
        let runner = window_screenshot_runner("42\tfalse\t1187\t1100", 0, 0, "");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed despite onScreen=false: {}", extract_text(&r));
        let d = r.details.unwrap();
        assert_eq!(d["action"], "screenshot");
        assert_eq!(d["window"], "Safari");
    }

    #[tokio::test]
    async fn screenshot_offscreen_zero_size_capture_succeeds() {
        // Even with zero-size metadata, attempt capture (metadata can be wrong)
        let runner = window_screenshot_runner("42\tfalse\t0\t0", 0, 0, "");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should attempt capture regardless: {}", extract_text(&r));
    }

    #[tokio::test]
    async fn screenshot_capture_failure_includes_diagnostics() {
        // screencapture fails → error should include stderr and suggest permission
        let runner = window_screenshot_runner("42\ttrue\t1187\t1100", 0, 1, "could not create image from window");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("could not create image"), "should include stderr: {text}");
    }

    #[tokio::test]
    async fn screenshot_capture_failure_offscreen_suggests_focus() {
        // screencapture fails AND window was off-screen → suggest focusWindow
        let runner = window_screenshot_runner("42\tfalse\t1187\t1100", 0, 1, "could not create image from window");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("focusWindow") || text.contains("off-screen"), "should mention off-screen context: {text}");
    }

    #[tokio::test]
    async fn screenshot_onscreen_window_succeeds() {
        // Window on-screen, capture succeeds → should return image
        let runner = window_screenshot_runner("42\ttrue\t1187\t1100", 0, 0, "");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let d = r.details.unwrap();
        assert_eq!(d["action"], "screenshot");
        assert_eq!(d["window"], "Safari");
    }

    #[tokio::test]
    async fn screenshot_window_metadata_only_id() {
        // Swift returns only window ID (no metadata) → should proceed to capture
        let runner = window_screenshot_runner("42", 0, 0, "");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed with partial metadata: {}", extract_text(&r));
    }

    #[tokio::test]
    async fn screenshot_details_include_screen_resolution() {
        // Full-screen screenshot should include screen dimensions in details
        let runner = screenshot_runner(5000, None);
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let d = r.details.unwrap();
        // On macOS test environment, screen_bounds() should return real values
        // On non-macOS or test, these may be absent — that's OK
        #[cfg(target_os = "macos")]
        {
            assert!(d.get("screenWidth").is_some(), "should have screenWidth");
            assert!(d.get("screenHeight").is_some(), "should have screenHeight");
        }
    }

    #[tokio::test]
    async fn screenshot_window_details_include_screen_resolution() {
        // Window screenshot should also include screen dimensions
        let runner = window_screenshot_runner("42\ttrue\t1187\t1100", 0, 0, "");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
        let d = r.details.unwrap();
        #[cfg(target_os = "macos")]
        {
            assert!(d.get("screenWidth").is_some(), "should have screenWidth");
            assert!(d.get("screenHeight").is_some(), "should have screenHeight");
        }
    }

    #[tokio::test]
    async fn screenshot_window_metadata_partial() {
        // Swift returns "42\ttrue" (missing width/height) → should proceed to capture
        let runner = window_screenshot_runner("42\ttrue", 0, 0, "");
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "screenshot", "window": "Safari"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none(), "should succeed with partial metadata: {}", extract_text(&r));
    }

    #[tokio::test]
    async fn screenshot_window_special_chars_escaped() {
        // Verify window names with quotes/backslashes are properly escaped
        use std::sync::{Arc as StdArc, Mutex};
        let commands: StdArc<Mutex<Vec<String>>> = StdArc::new(Mutex::new(Vec::new()));
        let cmds = commands.clone();
        let runner = MockRunner::with_handler(move |cmd| {
            cmds.lock().unwrap().push(cmd.to_string());
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 1,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let _ = t.execute(json!({"action": "screenshot", "window": "App \"with\" quotes"}), &make_ctx()).await;
        let cmds = commands.lock().unwrap();
        let swift_cmd = cmds.iter().find(|c| c.contains("swift")).expect("should run swift");
        // The escaped double quotes should appear as \" in the Swift string
        assert!(swift_cmd.contains(r#"\""#), "quotes should be escaped in swift: {swift_cmd}");
    }

    // ─── Confirmation describe_action tests ───

    #[test]
    fn describe_click_action() {
        let t = tool(true);
        let desc = t.describe_action("click", &json!({"x": 100, "y": 200}));
        assert_eq!(desc, "Click at (100, 200)");
    }

    #[test]
    fn describe_double_click_action() {
        let t = tool(true);
        let desc = t.describe_action("click", &json!({"x": 100, "y": 200, "clicks": 2}));
        assert_eq!(desc, "Double-click at (100, 200)");
    }

    #[test]
    fn describe_type_action_truncated() {
        let t = tool(true);
        let desc = t.describe_action("type", &json!({"text": "This is a very long string that should be truncated in the description"}));
        assert!(desc.contains("..."));
        assert!(desc.len() < 60);
    }

    #[test]
    fn describe_keypress_action() {
        let t = tool(true);
        let desc = t.describe_action("keypress", &json!({"keys": ["cmd", "c"]}));
        assert_eq!(desc, "Press keys: cmd+c");
    }

    // ─── is_mutating tests ───

    #[test]
    fn mutating_actions_identified() {
        assert!(ComputerUseTool::is_mutating("click"));
        assert!(ComputerUseTool::is_mutating("type"));
        assert!(ComputerUseTool::is_mutating("keypress"));
        assert!(ComputerUseTool::is_mutating("scroll"));
        assert!(ComputerUseTool::is_mutating("moveMouse"));
    }

    #[test]
    fn readonly_actions_not_mutating() {
        assert!(!ComputerUseTool::is_mutating("screenshot"));
        assert!(!ComputerUseTool::is_mutating("getWindows"));
        assert!(!ComputerUseTool::is_mutating("focusWindow"));
    }

    // ─── Details/audit logging tests ───

    #[tokio::test]
    async fn click_details_include_coordinates() {
        let t = tool(false);
        let r = t.execute(json!({"action": "click", "x": 42, "y": 99}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["action"], "click");
        assert_eq!(d["x"], 42.0);
        assert_eq!(d["y"], 99.0);
        assert_eq!(d["clicks"], 1);
    }

    #[tokio::test]
    async fn scroll_details_include_direction() {
        let t = tool(false);
        let r = t.execute(
            json!({"action": "scroll", "direction": "up", "amount": 50}),
            &make_ctx(),
        ).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["action"], "scroll");
        assert_eq!(d["direction"], "up");
        assert_eq!(d["amount"], 50);
    }

    #[tokio::test]
    async fn type_details_include_length() {
        let t = tool(false);
        let r = t.execute(json!({"action": "type", "text": "test"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["action"], "type");
        assert_eq!(d["length"], 4);
    }

    #[tokio::test]
    async fn keypress_details_include_keys() {
        let t = tool(false);
        let r = t.execute(json!({"action": "keypress", "keys": ["cmd", "v"]}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["action"], "keypress");
        let keys = d["keys"].as_array().unwrap();
        assert_eq!(keys.len(), 2);
    }

    #[tokio::test]
    async fn get_windows_details() {
        let t = tool(false);
        let r = t.execute(json!({"action": "getWindows"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["action"], "getWindows");
    }

    #[tokio::test]
    async fn focus_window_details() {
        let runner = MockRunner::with_handler(|cmd| {
            if cmd.contains("swift") {
                ProcessOutput {
                    stdout: "Xcode\tProject\t5678\tactivated\ttrue".into(),
                    stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            } else {
                ProcessOutput {
                    stdout: String::new(), stderr: String::new(), exit_code: 0,
                    duration_ms: 10, timed_out: false, interrupted: false,
                }
            }
        });
        let t = tool_with_runner(runner, false);
        let r = t.execute(json!({"action": "focusWindow", "window": "Xcode"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["action"], "focusWindow");
        assert_eq!(d["window"], "Xcode");
        assert_eq!(d["app"], "Xcode");
        assert_eq!(d["pid"], 5678);
        assert_eq!(d["activated"], true);
        assert_eq!(d["verified"], true);
    }
}
