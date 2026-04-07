use super::*;

// MARK: - Startup Permission Check

/// Result of probing a single macOS TCC permission.
#[derive(Debug, Clone, PartialEq)]
pub enum PermissionStatus {
    Granted,
    Denied { guidance: String },
    Unknown { reason: String },
}

// ─── Pure parsing functions (no I/O — fully unit-testable) ───

pub(crate) fn parse_accessibility_result(stdout: &str, success: bool) -> PermissionStatus {
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

pub(crate) fn parse_automation_result(_stdout: &str, stderr: &str, success: bool) -> PermissionStatus {
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

pub(crate) fn parse_screen_recording_result(success: bool, file_exists: bool, file_size: u64) -> PermissionStatus {
    if success && file_exists && file_size > 0 {
        PermissionStatus::Granted
    } else {
        PermissionStatus::Denied {
            guidance: "System Settings > Privacy & Security > Screen Recording".into(),
        }
    }
}

pub(crate) fn parse_fda_result(
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
