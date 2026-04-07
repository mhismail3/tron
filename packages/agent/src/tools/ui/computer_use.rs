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

impl ComputerUseTool {
    /// Generate a human-readable description of the action for confirmation.
    #[allow(clippy::unused_self)]
    fn describe_action(&self, action: &str, params: &Value) -> String {
        match action {
            "clickElement" => {
                let text = get_optional_string(params, "text").unwrap_or_default();
                let app = get_optional_string(params, "app");
                match app {
                    Some(a) => format!("Click element \"{text}\" in {a}"),
                    None => format!("Click element \"{text}\""),
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
    /// Output: `windowId\tonScreen\twidth\theight\tx\ty`
    /// On failure (no match): exit 1, available window names on stderr.
    fn build_screenshot_window_swift(search: &str) -> String {
        let escaped = search.replace('\\', "\\\\").replace('"', "\\\"");
        format!(
            r#"import Cocoa; let ws = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var names = [String](); var bestId = -1; var bestScore = -1; var bestOnScreen = false; var bestW = 0.0; var bestH = 0.0; var bestX = 0.0; var bestY = 0.0; for w in ws {{ let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; if !name.isEmpty {{ names.append("\(owner): \(name)") }}; guard owner.localizedCaseInsensitiveContains("{escaped}") || name.localizedCaseInsensitiveContains("{escaped}") else {{ continue }}; let layer = w[kCGWindowLayer as String] as? Int ?? 999; let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]; let bw = bounds["Width"] as? Double ?? 0; let bh = bounds["Height"] as? Double ?? 0; let bx = bounds["X"] as? Double ?? 0; let by = bounds["Y"] as? Double ?? 0; let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false; let area = Int(bw * bh); let score = (onScreen ? 1000000 : 0) + (layer == 0 ? 500000 : 0) + area; if score > bestScore {{ bestScore = score; bestId = w[kCGWindowNumber as String] as! Int; bestOnScreen = onScreen; bestW = bw; bestH = bh; bestX = bx; bestY = by }} }}; guard bestId >= 0 else {{ fputs(names.joined(separator: "\n"), stderr); Foundation.exit(1) }}; print("\(bestId)\t\(bestOnScreen)\t\(bestW)\t\(bestH)\t\(bestX)\t\(bestY)"); Foundation.exit(0)"#
        )
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
        let region = params.get("region").and_then(Value::as_object);

        // Window logical dimensions and position (set during window lookup below)
        let mut win_w: f64 = 0.0;
        let mut win_h: f64 = 0.0;
        let mut win_x: f64 = 0.0;
        let mut win_y: f64 = 0.0;

        // Region dimensions (set during region capture below)
        let mut region_x: f64 = 0.0;
        let mut region_y: f64 = 0.0;
        let mut region_w: f64 = 0.0;
        let mut region_h: f64 = 0.0;

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

            // Parse: "windowId\tonScreen\twidth\theight\tx\ty"
            let parts: Vec<&str> = wid_output.stdout.trim().splitn(6, '\t').collect();
            let window_id = parts.first().unwrap_or(&"").to_string();
            let on_screen = parts.get(1).map(|s| *s == "true").unwrap_or(true);
            win_w = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0.0);
            win_h = parts.get(3).and_then(|s| s.parse().ok()).unwrap_or(0.0);
            win_x = parts.get(4).and_then(|s| s.parse().ok()).unwrap_or(0.0);
            win_y = parts.get(5).and_then(|s| s.parse().ok()).unwrap_or(0.0);

            tracing::debug!(
                window = %w, id = %window_id, on_screen, width = win_w, height = win_h,
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
        } else if let Some(r) = region {
            // Region capture: use screencapture -R x,y,width,height
            region_x = r.get("x").and_then(Value::as_f64).unwrap_or(0.0);
            region_y = r.get("y").and_then(Value::as_f64).unwrap_or(0.0);
            region_w = r.get("width").and_then(Value::as_f64).unwrap_or(0.0);
            region_h = r.get("height").and_then(Value::as_f64).unwrap_or(0.0);

            if region_w <= 0.0 || region_h <= 0.0 {
                return Ok(error_result(
                    "Region width and height must be positive numbers.".to_string(),
                ));
            }

            // On Retina displays, screencapture -R uses screen points (logical coordinates),
            // which is what we want since the agent works in logical coordinates.
            #[allow(clippy::cast_possible_truncation)]
            let command = format!(
                "screencapture -x -t png -R {},{},{},{} {tmp_path}",
                region_x as i32, region_y as i32, region_w as i32, region_h as i32
            );
            let output = self.run_shell(&command, ctx).await?;
            if output.exit_code != 0 {
                return Ok(error_result(format!(
                    "Region screenshot failed: {}. Grant Screen Recording permission in System Settings > Privacy & Security.",
                    output.stderr
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
        let _raw_data = match tokio::fs::read(&tmp_path).await {
            Ok(data) => data,
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp_path).await;
                return Ok(error_result(format!("Failed to read screenshot: {e}")));
            }
        };

        // Step 1: Resize PNG to exact logical dimensions so that
        // 1 image pixel = 1 screen point. This eliminates all coordinate math —
        // the agent clicks exactly where it sees in the image.
        //
        // For window screenshots, resize to the window's logical dimensions.
        // For full screen, resize to the screen's logical dimensions.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let resize_target = if window.is_some() {
            // Use window logical dimensions (from CGWindowList metadata)
            (win_w as u32, win_h as u32)
        } else if region.is_some() {
            // Use region logical dimensions
            (region_w as u32, region_h as u32)
        } else {
            // Use screen logical dimensions
            self.screen_bounds().await
                .map(|(w, h)| (w as u32, h as u32))
                .unwrap_or((1280, 800))
        };

        let resize_cmd = format!(
            "sips --resampleWidth {} --resampleHeight {} '{tmp_path}'",
            resize_target.0, resize_target.1
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

        // Save to persistent screenshots directory so Display tool can reference the file.
        // In tests, ctx.working_directory is /tmp — we save there instead of polluting ~/.tron/.
        let ext = if mime_type == "image/jpeg" { "jpg" } else { "png" };
        let now = chrono::Local::now();
        let date = now.format("%Y-%m-%d");
        let time = now.format("%H%M%S");
        let rand_suffix: u16 = rand::random();
        let screenshot_filename = format!("{date}-{time}-screenshot-{rand_suffix:04x}.{ext}");
        let screenshots_dir = if cfg!(test) {
            std::path::PathBuf::from(&ctx.working_directory).join("screenshots")
        } else {
            crate::core::paths::screenshots_dir()
        };
        let _ = tokio::fs::create_dir_all(&screenshots_dir).await;
        let screenshot_path = screenshots_dir.join(&screenshot_filename);

        let saved_path = match tokio::fs::write(&screenshot_path, &image_data).await {
            Ok(()) => {
                tracing::debug!(path = %screenshot_path.display(), "Screenshot saved");
                Some(screenshot_path.to_string_lossy().to_string())
            }
            Err(e) => {
                tracing::warn!(error = %e, "Failed to persist screenshot — continuing without file");
                None
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
            "mimeType": mime_type,
        });
        if let Some((w, h)) = screen {
            details["screenWidth"] = json!(w);
            details["screenHeight"] = json!(h);
        }
        if window.is_some() {
            details["windowX"] = json!(win_x as i32);
            details["windowY"] = json!(win_y as i32);
        }
        if region.is_some() {
            details["regionX"] = json!(region_x as i32);
            details["regionY"] = json!(region_y as i32);
            details["regionWidth"] = json!(region_w as i32);
            details["regionHeight"] = json!(region_h as i32);
        }
        details["screenshotPath"] = json!(saved_path);

        let format_label = if mime_type == "image/jpeg" { "JPEG" } else { "PNG" };
        let mut text = format!(
            "Screenshot captured ({} bytes {format_label})",
            image_data.len()
        );

        // 1:1 coordinate guide — image pixels map directly to screen points
        if window.is_some() {
            #[allow(clippy::cast_possible_truncation)]
            {
                text.push_str(&format!(
                    "\nWindow at ({}, {}). Pixel (x,y) in this image = screen point ({} + x, {} + y).",
                    win_x as i32, win_y as i32, win_x as i32, win_y as i32
                ));
            }
        } else if region.is_some() {
            #[allow(clippy::cast_possible_truncation)]
            {
                text.push_str(&format!(
                    "\nRegion at ({}, {}), size {}x{}. Pixel (x,y) in this image = screen point ({} + x, {} + y).",
                    region_x as i32, region_y as i32, region_w as i32, region_h as i32,
                    region_x as i32, region_y as i32
                ));
            }
        } else if let Some((sw, sh)) = screen {
            text.push_str(&format!(
                "\nScreen is {sw}x{sh}. Image is 1:1 with screen — pixel (x,y) in this image = screen point (x,y)."
            ));
        }

        if !size_warning.is_empty() {
            text.push_str(size_warning);
        }

        if let Some(ref path) = saved_path {
            text.push_str(&format!("\nScreenshot saved to: {path}"));
            text.push_str(
                "\nUse Display(type: \"image\", path: \"<this path>\") to show it to the user.",
            );
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
        let direction = get_optional_string(params, "direction")
            .unwrap_or_else(|| "down".to_string());
        let amount = get_optional_u64(params, "amount").unwrap_or(100) as i32;

        // Validate direction before dispatching
        if !matches!(direction.as_str(), "up" | "down" | "left" | "right") {
            return Ok(error_result(format!("Unknown scroll direction: {direction}")));
        }

        // Scroll at current cursor position (x=0, y=0 means "don't reposition")
        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::input::scroll(&direction, amount, 0.0, 0.0).await
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
                        "Scrolled {direction} by {amount}px"
                    )),
                ]),
                details: Some(json!({
                    "action": "scroll",
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

    /// Build Swift code to resolve the target AXUIElement for a given app name.
    /// Returns Swift code that sets `let ax: AXUIElement` to the target app.
    /// If app_name is None, targets the frontmost app.
    fn swift_resolve_app(app_name: Option<&str>) -> String {
        match app_name {
            Some(name) if name.eq_ignore_ascii_case("dock") => {
                // Dock is a special process
                format!(r#"var ax: AXUIElement!; for a in NSWorkspace.shared.runningApplications {{ if a.bundleIdentifier == "com.apple.dock" {{ ax = AXUIElementCreateApplication(a.processIdentifier); break }} }}; guard ax != nil else {{ fputs("Dock process not found", stderr); Foundation.exit(1) }}"#)
            }
            Some(name) => {
                let escaped = name.replace('\\', "\\\\").replace('"', "\\\"");
                format!(r#"var ax: AXUIElement!; for a in NSWorkspace.shared.runningApplications {{ if a.activationPolicy == .regular, let n = a.localizedName, n.localizedCaseInsensitiveContains("{escaped}") {{ ax = AXUIElementCreateApplication(a.processIdentifier); break }} }}; guard ax != nil else {{ fputs("App '{escaped}' not found", stderr); Foundation.exit(1) }}"#)
            }
            None => {
                r#"let app = NSWorkspace.shared.frontmostApplication!; let ax = AXUIElementCreateApplication(app.processIdentifier)"#.to_string()
            }
        }
    }

    /// Common Swift functions for searching and listing AX elements.
    const AX_HELPERS: &'static str = r#"func find(_ e: AXUIElement, _ q: String, _ d: Int) -> AXUIElement? { if d > 15 { return nil }; for attr in ["AXTitle", "AXDescription", "AXValue", "AXLabel"] { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, attr as CFString, &v); if let s = v as? String, s.localizedCaseInsensitiveContains(q) { return e } }; var c: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &c); if let kids = c as? [AXUIElement] { for k in kids { if let r = find(k, q, d+1) { return r } } }; return nil }; func titles(_ e: AXUIElement, _ d: Int) -> [String] { if d > 8 { return [] }; var r = [String](); var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXTitle" as CFString, &v); var dv: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXDescription" as CFString, &dv); let t = v as? String ?? ""; let ds = dv as? String ?? ""; var rv: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXRole" as CFString, &rv); let role = rv as? String ?? ""; if !t.isEmpty { r.append("\(role): \(t)") } else if !ds.isEmpty { r.append("\(role): [\(ds)]") }; var c: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &c); if let kids = c as? [AXUIElement] { for k in kids { r += titles(k, d+1) } }; return r }"#;

    async fn click_element(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let text = match validate_required_string(params, "text", "text label of the element to click") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let app_name = get_optional_string(params, "app");
        let app_resolve = Self::swift_resolve_app(app_name.as_deref());
        let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");

        let script = format!(
            "import Cocoa; {helpers}; {resolve}; if let el = find(ax, \"{escaped}\", 0) {{ var rv: CFTypeRef?; AXUIElementCopyAttributeValue(el, \"AXRole\" as CFString, &rv); let role = rv as? String ?? \"\"; var tv: CFTypeRef?; AXUIElementCopyAttributeValue(el, \"AXTitle\" as CFString, &tv); let title = tv as? String ?? \"\"; let pressed = AXUIElementPerformAction(el, \"AXPress\" as CFString) == .success; if pressed {{ print(\"found\\tpressed\\t\\(role)\\t\\(title)\") }} else {{ var pv: CFTypeRef?; var sv: CFTypeRef?; AXUIElementCopyAttributeValue(el, \"AXPosition\" as CFString, &pv); AXUIElementCopyAttributeValue(el, \"AXSize\" as CFString, &sv); var pos = CGPoint.zero; var size = CGSize.zero; if let p = pv {{ AXValueGetValue(p as! AXValue, .cgPoint, &pos) }}; if let s = sv {{ AXValueGetValue(s as! AXValue, .cgSize, &size) }}; let cx = pos.x + size.width/2; let cy = pos.y + size.height/2; let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)!; e.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.05); let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)!; u.post(tap: .cghidEventTap); print(\"found\\tclicked\\t\\(role)\\t\\(title)\") }} }} else {{ let available = titles(ax, 0); fputs(available.joined(separator: \"\\n\"), stderr); Foundation.exit(1) }}",
            helpers = Self::AX_HELPERS,
            resolve = app_resolve
        );

        let cmd = format!("swift -e '{}'", script.replace('\'', "'\\''"));
        let output = self.run_shell(&cmd, ctx).await?;

        if output.exit_code != 0 {
            let stderr = output.stderr.trim();
            let target = app_name.as_deref().unwrap_or("the frontmost app");
            let list = if stderr.is_empty() {
                format!("No accessible elements found in {target}.")
            } else {
                format!("Available elements in {target}:\n{stderr}")
            };
            return Ok(error_result(format!(
                "Element '{text}' not found. {list}"
            )));
        }

        let parts: Vec<&str> = output.stdout.trim().splitn(4, '\t').collect();
        let method = parts.get(1).unwrap_or(&"unknown");
        let role = parts.get(2).unwrap_or(&"");
        let title = parts.get(3).unwrap_or(&"");

        tracing::debug!(
            search = %text, method = %method, role = %role, title = %title,
            app = ?app_name, "clickElement result"
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                format!("Clicked: \"{title}\" ({role}, {method})")
            )]),
            details: Some(json!({
                "action": "clickElement",
                "text": text,
                "app": app_name,
                "method": *method,
                "role": *role,
                "title": *title,
            })),
            is_error: None,
            stop_turn: None,
        })
    }

    async fn list_elements(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let app_name = get_optional_string(params, "app");
        let app_resolve = Self::swift_resolve_app(app_name.as_deref());

        let script = format!(
            "import Cocoa; {helpers}; {resolve}; let items = titles(ax, 0); print(items.joined(separator: \"\\n\"))",
            helpers = Self::AX_HELPERS,
            resolve = app_resolve
        );

        let cmd = format!("swift -e '{}'", script.replace('\'', "'\\''"));
        let output = self.run_shell(&cmd, ctx).await?;

        if output.exit_code != 0 {
            let target = app_name.as_deref().unwrap_or("the frontmost app");
            return Ok(error_result(format!(
                "Could not list elements in {target}: {}",
                output.stderr.trim()
            )));
        }

        let trimmed = output.stdout.trim();
        let target = app_name.as_deref().unwrap_or("frontmost app");
        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                if trimmed.is_empty() {
                    format!("No accessible elements found in {target}.")
                } else {
                    format!("Elements in {target}:\n{trimmed}")
                }
            )]),
            details: Some(json!({"action": "listElements", "app": app_name})),
            is_error: None,
            stop_turn: None,
        })
    }

}

// MARK: - Startup Permission Check

/// Result of probing a single macOS TCC permission.
#[derive(Debug, Clone, PartialEq)]
pub enum PermissionStatus {
    Granted,
    Denied { guidance: String },
    Unknown { reason: String },
}

// ─── Pure parsing functions (no I/O — fully unit-testable) ───

fn parse_accessibility_result(stdout: &str, success: bool) -> PermissionStatus {
    if !success {
        return PermissionStatus::Unknown {
            reason: "swift process failed".into(),
        };
    }
    match stdout.trim() {
        "granted" => PermissionStatus::Granted,
        "denied" => PermissionStatus::Denied {
            guidance: "System Settings > Privacy & Security > Accessibility".into(),
        },
        other => PermissionStatus::Unknown {
            reason: format!("unexpected output: {other}"),
        },
    }
}

fn parse_automation_result(_stdout: &str, stderr: &str, success: bool) -> PermissionStatus {
    if success {
        return PermissionStatus::Granted;
    }
    if stderr.contains("not allowed") || stderr.contains("1002") || stderr.contains("assistive") {
        PermissionStatus::Denied {
            guidance: "System Settings > Privacy & Security > Automation".into(),
        }
    } else {
        PermissionStatus::Unknown {
            reason: stderr.trim().to_string(),
        }
    }
}

fn parse_screen_recording_result(success: bool, file_exists: bool, file_size: u64) -> PermissionStatus {
    if success && file_exists && file_size > 0 {
        PermissionStatus::Granted
    } else {
        PermissionStatus::Denied {
            guidance: "System Settings > Privacy & Security > Screen Recording".into(),
        }
    }
}

fn parse_fda_result(
    mail_err: Option<std::io::ErrorKind>,
    safari_err: Option<std::io::ErrorKind>,
) -> PermissionStatus {
    // None = read_dir succeeded = FDA granted
    match (mail_err, safari_err) {
        (None, _) => PermissionStatus::Granted,
        (Some(std::io::ErrorKind::PermissionDenied), _) => PermissionStatus::Denied {
            guidance: "System Settings > Privacy & Security > Full Disk Access".into(),
        },
        // Mail dir doesn't exist — try Safari
        (Some(_), None) => PermissionStatus::Granted,
        (Some(_), Some(std::io::ErrorKind::PermissionDenied)) => PermissionStatus::Denied {
            guidance: "System Settings > Privacy & Security > Full Disk Access".into(),
        },
        // Both dirs missing (no Mail.app, no Safari) — can't test, assume granted
        (Some(_), Some(_)) => PermissionStatus::Granted,
    }
}

// ─── Async check functions (thin wrappers with timeouts) ───

async fn check_accessibility() -> PermissionStatus {
    use std::time::Duration;
    // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt triggers
    // the native macOS Accessibility permission dialog when not yet granted.
    let result = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::task::spawn_blocking(|| {
            std::process::Command::new("swift")
                .args(["-e", concat!(
                    "import ApplicationServices\n",
                    "let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary\n",
                    "print(AXIsProcessTrustedWithOptions(opts) ? \"granted\" : \"denied\")",
                )])
                .output()
        }).await
    }).await;

    match result {
        Ok(Ok(Ok(output))) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            parse_accessibility_result(&stdout, output.status.success())
        }
        _ => PermissionStatus::Unknown {
            reason: "check timed out or failed to spawn".into(),
        },
    }
}

async fn check_automation() -> PermissionStatus {
    use std::time::Duration;
    let result = tokio::time::timeout(Duration::from_secs(5), {
        tokio::process::Command::new("osascript")
            .args(["-e", r#"tell application "System Events" to return name of first process"#])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output()
    }).await;

    match result {
        Ok(Ok(output)) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            parse_automation_result(&stdout, &stderr, output.status.success())
        }
        _ => PermissionStatus::Unknown {
            reason: "check timed out or failed to spawn".into(),
        },
    }
}

async fn check_screen_recording() -> PermissionStatus {
    use std::time::Duration;
    let tmp = format!("/tmp/tron-permission-check-{}.png", std::process::id());
    let result = tokio::time::timeout(Duration::from_secs(5), {
        tokio::process::Command::new("screencapture")
            .args(["-x", "-t", "png", &tmp])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .output()
    }).await;

    let (success, file_exists, file_size) = match result {
        Ok(Ok(output)) => {
            let meta = tokio::fs::metadata(&tmp).await;
            let exists = meta.is_ok();
            let size = meta.map(|m| m.len()).unwrap_or(0);
            let _ = tokio::fs::remove_file(&tmp).await;
            (output.status.success(), exists, size)
        }
        _ => {
            let _ = tokio::fs::remove_file(&tmp).await;
            return PermissionStatus::Unknown {
                reason: "check timed out or failed to spawn".into(),
            };
        }
    };

    parse_screen_recording_result(success, file_exists, file_size)
}

async fn check_full_disk_access() -> PermissionStatus {
    let home = crate::core::paths::home_dir();

    let mail_result = tokio::fs::read_dir(format!("{home}/Library/Mail")).await;
    let mail_err = mail_result.err().map(|e| e.kind());

    let safari_result = tokio::fs::read_dir(format!("{home}/Library/Safari")).await;
    let safari_err = safari_result.err().map(|e| e.kind());

    parse_fda_result(mail_err, safari_err)
}

/// Check macOS permissions at server startup.
///
/// Probes four capabilities concurrently and logs results:
/// 1. **Accessibility** — needed for CGEvent-based mouse/keyboard input (enigo).
/// 2. **Automation** — needed for osascript to System Events.
/// 3. **Screen Recording** — needed for screencapture.
/// 4. **Full Disk Access** — needed for reading/writing protected locations.
///
/// No-op on non-macOS platforms.
pub async fn check_permissions_on_startup() {
    if std::env::consts::OS != "macos" {
        return;
    }

    tracing::info!("checking macOS permissions...");

    let (ax, auto, screen, fda) = tokio::join!(
        check_accessibility(),
        check_automation(),
        check_screen_recording(),
        check_full_disk_access(),
    );

    for (name, status) in [
        ("Accessibility", &ax),
        ("Automation", &auto),
        ("Screen Recording", &screen),
        ("Full Disk Access", &fda),
    ] {
        match status {
            PermissionStatus::Granted => tracing::info!("{name}: granted"),
            PermissionStatus::Denied { guidance } => {
                tracing::warn!("{name}: denied — grant via {guidance}");
            }
            PermissionStatus::Unknown { reason } => {
                tracing::warn!("{name}: could not check ({reason})");
            }
        }
    }

    // FDA is the only permission without a native prompt — open System Settings directly
    if matches!(fda, PermissionStatus::Denied { .. }) {
        let _ = tokio::process::Command::new("open")
            .args(["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;
    }
}


#[cfg(test)]
#[path = "computer_use_tests.rs"]
mod tests;
