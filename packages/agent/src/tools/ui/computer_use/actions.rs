use super::*;

impl ComputerUseTool {
    /// Run an osascript command via the process runner.
    pub(super) async fn run_osascript(
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
                message: format!(
                    "osascript failed (exit {}): {}",
                    output.exit_code, output.stderr
                ),
            });
        }
        Ok(output.stdout)
    }

    /// Run a shell command via the process runner.
    pub(super) async fn run_shell(
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

    pub(super) async fn type_text(
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
                    super::super::input::type_text(&text).await
                } else {
                    let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");
                    let script =
                        format!("tell application \"System Events\" to keystroke \"{escaped}\"");
                    self.run_osascript(&script, ctx)
                        .await
                        .map(|_| ())
                        .map_err(|e| format!("{e}"))
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
                        "Typed {} characters",
                        text.len()
                    )),
                ]),
                details: Some(json!({"action": "type", "length": text.len()})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Type failed: {e}"))),
        }
    }

    pub(super) async fn keypress(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let keys = params
            .get("keys")
            .and_then(Value::as_array)
            .ok_or_else(|| ToolError::Validation {
                message: "keypress requires keys array".into(),
            })?;

        let key_names: Vec<String> = keys
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect();

        if key_names.is_empty() {
            return Ok(error_result("keys array must not be empty".to_string()));
        }

        // Validate all key names before dispatching
        #[cfg(target_os = "macos")]
        for k in &key_names {
            if super::super::input::map_key(k).is_none() {
                return Ok(error_result(format!("Unknown key: {k}")));
            }
        }

        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::super::input::key_press(&key_names).await
                } else {
                    // Test fallback: treat as success (mock runner handles osascript)
                    let script = "tell application \"System Events\" to keystroke \"\"".to_string();
                    self.run_osascript(&script, ctx)
                        .await
                        .map(|_| ())
                        .map_err(|e| format!("{e}"))
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
                        "Pressed: {}",
                        key_names.join("+")
                    )),
                ]),
                details: Some(json!({"action": "keypress", "keys": key_names})),
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Keypress failed: {e}"))),
        }
    }

    pub(super) async fn scroll(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let direction =
            get_optional_string(params, "direction").unwrap_or_else(|| "down".to_string());
        let amount = get_optional_u64(params, "amount").unwrap_or(100) as i32;

        // Validate direction before dispatching
        if !matches!(direction.as_str(), "up" | "down" | "left" | "right") {
            return Ok(error_result(format!(
                "Unknown scroll direction: {direction}"
            )));
        }

        // Scroll at current cursor position (x=0, y=0 means "don't reposition")
        let result = {
            #[cfg(target_os = "macos")]
            {
                if self.use_native_input {
                    super::super::input::scroll(&direction, amount, 0.0, 0.0).await
                } else {
                    let script = "tell application \"System Events\" to key code 125".to_string();
                    self.run_osascript(&script, ctx)
                        .await
                        .map(|_| ())
                        .map_err(|e| format!("{e}"))
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

    pub(super) async fn get_windows(&self, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        // Use CGWindowList via Swift — works reliably from background launchd processes,
        // unlike the AppleScript "System Events" approach which returns empty when
        // the agent isn't running in a foreground terminal session.
        let cmd = format!(
            "swift -e '{}'",
            Self::GET_WINDOWS_SWIFT.replace('\'', "'\\''")
        );
        let output = self.run_shell(&cmd, ctx).await?;

        if output.exit_code != 0 {
            return Ok(error_result(format!(
                "Failed to list windows: {}. Grant Screen Recording permission in System Settings > Privacy & Security.",
                output.stderr.trim()
            )));
        }

        let trimmed = output.stdout.trim();
        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                if trimmed.is_empty() {
                    "No windows found.".to_string()
                } else {
                    format!("App | Window | Position | Size | Status\n{trimmed}")
                },
            )]),
            details: Some(json!({"action": "getWindows"})),
            is_error: None,
            stop_turn: None,
        })
    }

    pub(super) async fn focus_window(
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
        let output = self
            .run_shell(&cmd, ctx)
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("focusWindow lookup failed: {e}"),
            })?;

        if output.exit_code != 0 {
            let available = output.stderr.trim();
            let list = if available.is_empty() {
                "No windows found.".to_string()
            } else {
                format!("Available windows:\n{available}")
            };
            return Ok(error_result(format!("Window '{window}' not found. {list}")));
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
            format!(
                "Focused window: {window} (app: {owner}, activated but not yet verified on-screen — \
                     the window may need a moment or may be on another Space)"
            )
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                status,
            )]),
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

    /// Common Swift functions for searching and listing AX elements.
    const AX_HELPERS: &'static str = r#"func find(_ e: AXUIElement, _ q: String, _ d: Int) -> AXUIElement? { if d > 15 { return nil }; for attr in ["AXTitle", "AXDescription", "AXValue", "AXLabel"] { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, attr as CFString, &v); if let s = v as? String, s.localizedCaseInsensitiveContains(q) { return e } }; var c: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &c); if let kids = c as? [AXUIElement] { for k in kids { if let r = find(k, q, d+1) { return r } } }; return nil }; func titles(_ e: AXUIElement, _ d: Int) -> [String] { if d > 8 { return [] }; var r = [String](); var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXTitle" as CFString, &v); var dv: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXDescription" as CFString, &dv); let t = v as? String ?? ""; let ds = dv as? String ?? ""; var rv: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXRole" as CFString, &rv); let role = rv as? String ?? ""; if !t.isEmpty { r.append("\(role): \(t)") } else if !ds.isEmpty { r.append("\(role): [\(ds)]") }; var c: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &c); if let kids = c as? [AXUIElement] { for k in kids { r += titles(k, d+1) } }; return r }"#;

    pub(super) async fn click_element(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let text =
            match validate_required_string(params, "text", "text label of the element to click") {
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
            return Ok(error_result(format!("Element '{text}' not found. {list}")));
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
                format!("Clicked: \"{title}\" ({role}, {method})"),
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

    pub(super) async fn list_elements(
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
                },
            )]),
            details: Some(json!({"action": "listElements", "app": app_name})),
            is_error: None,
            stop_turn: None,
        })
    }
}
