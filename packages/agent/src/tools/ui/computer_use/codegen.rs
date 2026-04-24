use super::*;

impl ComputerUseTool {
    /// Generate a human-readable description of the action for confirmation.
    #[allow(clippy::unused_self)]
    pub(super) fn describe_action(&self, action: &str, params: &Value) -> String {
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
                let keys: Vec<String> = params
                    .get("keys")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect()
                    })
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
    pub(super) fn build_screenshot_window_swift(search: &str) -> String {
        let escaped = search.replace('\\', "\\\\").replace('"', "\\\"");
        format!(
            r#"import Cocoa; let ws = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var names = [String](); var bestId = -1; var bestScore = -1; var bestOnScreen = false; var bestW = 0.0; var bestH = 0.0; var bestX = 0.0; var bestY = 0.0; for w in ws {{ let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; if !name.isEmpty {{ names.append("\(owner): \(name)") }}; guard owner.localizedCaseInsensitiveContains("{escaped}") || name.localizedCaseInsensitiveContains("{escaped}") else {{ continue }}; let layer = w[kCGWindowLayer as String] as? Int ?? 999; let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]; let bw = bounds["Width"] as? Double ?? 0; let bh = bounds["Height"] as? Double ?? 0; let bx = bounds["X"] as? Double ?? 0; let by = bounds["Y"] as? Double ?? 0; let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false; let area = Int(bw * bh); let score = (onScreen ? 1000000 : 0) + (layer == 0 ? 500000 : 0) + area; if score > bestScore {{ bestScore = score; bestId = w[kCGWindowNumber as String] as! Int; bestOnScreen = onScreen; bestW = bw; bestH = bh; bestX = bx; bestY = by }} }}; guard bestId >= 0 else {{ fputs(names.joined(separator: "\n"), stderr); Foundation.exit(1) }}; print("\(bestId)\t\(bestOnScreen)\t\(bestW)\t\(bestH)\t\(bestX)\t\(bestY)"); Foundation.exit(0)"#
        )
    }

    /// Build a Swift script that finds a window by name, activates the app via
    /// `NSRunningApplication.activate`, and verifies the window became on-screen.
    ///
    /// Output: `owner\tname\tpid\tactivated\tverified`
    pub(super) fn build_focus_window_swift(search: &str) -> String {
        let escaped = search.replace('\\', "\\\\").replace('"', "\\\"");
        format!(
            r#"import Cocoa; let ws = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var names = [String](); var bestScore = -1; var bestOwner = ""; var bestName = ""; var bestPid: pid_t = 0; for w in ws {{ let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0; if !name.isEmpty {{ names.append("\(owner): \(name)") }}; guard owner.localizedCaseInsensitiveContains("{escaped}") || name.localizedCaseInsensitiveContains("{escaped}") else {{ continue }}; let layer = w[kCGWindowLayer as String] as? Int ?? 999; let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]; let bw = bounds["Width"] as? Double ?? 0; let bh = bounds["Height"] as? Double ?? 0; let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false; let area = Int(bw * bh); let score = (onScreen ? 1000000 : 0) + (layer == 0 ? 500000 : 0) + area; if score > bestScore {{ bestScore = score; bestOwner = owner; bestName = name; bestPid = pid_t(pid) }} }}; guard bestPid > 0 else {{ fputs(names.joined(separator: "\n"), stderr); Foundation.exit(1) }}; guard let app = NSRunningApplication(processIdentifier: bestPid) else {{ print("\(bestOwner)\t\(bestName)\t\(bestPid)\tno_process\tfalse"); Foundation.exit(0) }}; let ok = app.activate(options: .activateIgnoringOtherApps); Thread.sleep(forTimeInterval: 0.3); let ws2 = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; var verified = false; for w in ws2 {{ let p = w[kCGWindowOwnerPID as String] as? Int ?? 0; if p == Int(bestPid), let on = w[kCGWindowIsOnscreen as String] as? Bool, on {{ verified = true; break }} }}; print("\(bestOwner)\t\(bestName)\t\(bestPid)\t\(ok ? "activated" : "failed")\t\(verified)"); Foundation.exit(0)"#
        )
    }

    /// Build Swift code to resolve the target AXUIElement for a given app name.
    /// Returns Swift code that sets `let ax: AXUIElement` to the target app.
    /// If app_name is None, targets the frontmost app.
    pub(super) fn swift_resolve_app(app_name: Option<&str>) -> String {
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
                r"let app = NSWorkspace.shared.frontmostApplication!; let ax = AXUIElementCreateApplication(app.processIdentifier)".to_string()
            }
        }
    }
}
