// MARK: - On-demand permission probes
//
// The Mac wrapper asks the already-installed launchd agent for a fast,
// non-prompting grant snapshot via `probe_wizard_permissions`, surfaced by
// `system.probePermissions` in `server::rpc::handlers::system`.
//
// The key design rule: probes must NEVER prompt. The Mac wrapper drives
// prompting via explicit user actions on the Permissions step; a probe
// that itself triggers a TCC dialog would race with that UX and confuse
// users. That's why `check_accessibility` uses `AXIsProcessTrusted()`
// (no options dict) rather than
// `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`,
// and why ordinary server startup never calls these probes.

/// Result of probing a single macOS TCC permission.
#[derive(Debug, Clone, PartialEq)]
pub enum PermissionStatus {
    /// The permission has been granted and the capability is available.
    Granted,
    /// The permission was explicitly denied; `guidance` is the System Settings path to fix it.
    Denied {
        /// The System Settings path the user should visit to grant this permission.
        guidance: String,
    },
    /// The permission state could not be determined; `reason` describes the failure.
    Unknown {
        /// Description of why the permission state could not be determined.
        reason: String,
    },
}

impl PermissionStatus {
    /// Lowercase wire-format token for RPC responses.
    /// - `Granted` → `"granted"`
    /// - `Denied`  → `"denied"`
    /// - `Unknown` → `"unknown"`
    ///
    /// The wrapper's `PermissionProbeRPC` decodes these three tokens; any
    /// other string is treated as `.probeUnavailable`.
    pub fn wire_token(&self) -> &'static str {
        match self {
            PermissionStatus::Granted => "granted",
            PermissionStatus::Denied { .. } => "denied",
            PermissionStatus::Unknown { .. } => "unknown",
        }
    }
}

// ─── Pure parsing functions (no I/O — fully unit-testable) ───

#[cfg(test)]
pub(crate) fn parse_automation_result(
    _stdout: &str,
    stderr: &str,
    success: bool,
) -> PermissionStatus {
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

// ─── Native macOS FFI (fast, non-prompting) ───
//
// Both symbols live in Apple frameworks that are linked into every
// macOS binary by default; the `#[link]` attributes below are
// belt-and-braces so the symbols resolve even under stripped/minimal
// link tables. Calling them is effectively a system-call-sized read
// of the current process's TCC state.

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    /// Returns `1` if the current process has been granted Accessibility
    /// access in the TCC database, `0` otherwise. Does NOT prompt —
    /// safe to poll on a short interval.
    fn AXIsProcessTrusted() -> u8;
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    /// Returns `1` if the current process has been granted Screen
    /// Recording access in the TCC database, `0` otherwise. Does NOT
    /// prompt, unlike `CGRequestScreenCaptureAccess`. macOS 10.15+.
    fn CGPreflightScreenCaptureAccess() -> u8;

    /// Prompts for Screen Recording access for the current process.
    /// This is intentionally NOT used by polling probes; the Mac
    /// wrapper calls it only after the user clicks the Screen Recording
    /// settings button so macOS creates the TCC row for Tron Server.
    fn CGRequestScreenCaptureAccess() -> u8;
}

// ─── Async check functions (thin wrappers with timeouts) ───

/// Accessibility probe via `AXIsProcessTrusted()`. Returns a
/// non-prompting read of the current process's TCC Accessibility grant.
///
/// Historically this spawned a `swift -e` subprocess calling
/// `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`,
/// which both took ~500ms and triggered a macOS TCC prompt the first
/// time. The FFI path is ~microseconds and silent — important for the
/// wrapper's Permissions wizard step, which polls this every 2s.
#[allow(unsafe_code)]
pub async fn check_accessibility() -> PermissionStatus {
    #[cfg(target_os = "macos")]
    {
        let trusted = tokio::task::spawn_blocking(|| unsafe { AXIsProcessTrusted() } != 0)
            .await
            .unwrap_or(false);
        if trusted {
            PermissionStatus::Granted
        } else {
            PermissionStatus::Denied {
                guidance: "System Settings > Privacy & Security > Accessibility".into(),
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        PermissionStatus::Unknown {
            reason: "accessibility probe is macOS-only".into(),
        }
    }
}

/// Screen Recording probe via `CGPreflightScreenCaptureAccess()`.
/// Non-prompting, no subprocess, constant time.
#[allow(unsafe_code)]
pub async fn check_screen_recording() -> PermissionStatus {
    #[cfg(target_os = "macos")]
    {
        let granted =
            tokio::task::spawn_blocking(|| unsafe { CGPreflightScreenCaptureAccess() } != 0)
                .await
                .unwrap_or(false);
        if granted {
            PermissionStatus::Granted
        } else {
            PermissionStatus::Denied {
                guidance: "System Settings > Privacy & Security > Screen Recording".into(),
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        PermissionStatus::Unknown {
            reason: "screen-recording probe is macOS-only".into(),
        }
    }
}

/// Explicit Screen Recording request via `CGRequestScreenCaptureAccess()`.
///
/// macOS only adds an application to the Screen Recording list after
/// that exact process asks for the permission. Opening System Settings
/// from the wrapper is not enough, and asking from the wrapper would
/// add `TronMac.app`/`Tron.app` instead of the launchd server. This
/// prompt path exists so the wrapper can ask the already-installed
/// agent to create its own TCC row after the user clicks the Screen
/// Recording gear button.
#[allow(unsafe_code)]
pub async fn request_screen_recording_access() -> PermissionStatus {
    #[cfg(target_os = "macos")]
    {
        let granted =
            tokio::task::spawn_blocking(|| unsafe { CGRequestScreenCaptureAccess() } != 0)
                .await
                .unwrap_or(false);
        if granted {
            PermissionStatus::Granted
        } else {
            PermissionStatus::Denied {
                guidance: "System Settings > Privacy & Security > Screen Recording".into(),
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        PermissionStatus::Unknown {
            reason: "screen-recording request is macOS-only".into(),
        }
    }
}

/// Full Disk Access probe: tries an in-process read of `~/Library/Mail`
/// (FDA-protected on every modern macOS). Falls back to `~/Library/Safari`
/// when the user has never set up Mail. In-process so the TCC identity
/// matches the agent's own bundle ID.
pub async fn check_full_disk_access() -> PermissionStatus {
    let home = crate::core::paths::home_dir();

    let mail_result = tokio::fs::read_dir(format!("{home}/Library/Mail")).await;
    let mail_err = mail_result.err().map(|e| e.kind());

    let safari_result = tokio::fs::read_dir(format!("{home}/Library/Safari")).await;
    let safari_err = safari_result.err().map(|e| e.kind());

    parse_fda_result(mail_err, safari_err)
}

/// Snapshot of the three wizard-surfaced permission grants. Feeds the
/// `system.probePermissions` RPC that the Mac wrapper polls during the
/// Permissions wizard step.
///
/// Automation is intentionally omitted: the wrapper doesn't surface an
/// Automation card (we use CGEvent for mouse/keyboard, not AppleScript),
/// and the probe itself is slower because it spawns `osascript`.
#[derive(Debug, Clone, PartialEq)]
pub struct WizardPermissions {
    /// FDA grant state — probed via `~/Library/Mail` read (FDA-gated).
    pub full_disk_access: PermissionStatus,
    /// Screen Recording grant state — probed via `CGPreflightScreenCaptureAccess`.
    pub screen_recording: PermissionStatus,
    /// Accessibility grant state — probed via `AXIsProcessTrusted`.
    pub accessibility: PermissionStatus,
}

/// Runs all three wizard-surfaced probes concurrently. Non-prompting;
/// safe to call from an RPC handler that the Mac wrapper polls every
/// few seconds during the Permissions step.
pub async fn probe_wizard_permissions() -> WizardPermissions {
    let (fda, screen, ax) = tokio::join!(
        check_full_disk_access(),
        check_screen_recording(),
        check_accessibility(),
    );
    WizardPermissions {
        full_disk_access: fda,
        screen_recording: screen,
        accessibility: ax,
    }
}
