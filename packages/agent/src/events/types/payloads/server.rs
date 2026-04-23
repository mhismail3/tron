//! Server lifecycle event payloads (Phase 5.5 — user-mode auto-updater).
//!
//! Emitted by `server::updater` when the GitHub Releases poller
//! observes a newer release, finishes downloading one, completes an
//! install, or the auto-degrade safety valve flips. iOS and the Mac
//! menu bar consume them through the normal event pipeline; no event
//! here is session-scoped (they're server-wide broadcasts tagged to
//! the current "system session" in the event store).

use serde::{Deserialize, Serialize};

/// Payload for `server.update_available` events.
///
/// Emitted after every check that resolved a newer release on the
/// user's configured channel. Fires once per transition from "no
/// update" to "update available" at the given version — duplicate
/// emissions for the same version are suppressed by the caller so iOS
/// doesn't show the same banner twice.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerUpdateAvailablePayload {
    /// Semver of the resolved release (e.g., `"0.5.1"`).
    pub latest_version: String,
    /// Direct DMG download URL, if the release exposes a `.dmg` asset.
    /// `None` on in-flight releases where the DMG hasn't been attached
    /// yet — iOS suppresses the "Download" CTA in that case.
    pub download_url: Option<String>,
    /// Markdown release notes, verbatim from GitHub. `None` when the
    /// release has no body.
    pub release_notes: Option<String>,
    /// The channel that resolved this release (`"stable"` or `"beta"`).
    /// Mirrored back so iOS can render "Beta channel" in the banner
    /// without re-reading settings.
    pub channel: String,
    /// ISO 8601 timestamp the event was emitted.
    pub timestamp: String,
}

/// Payload for `server.update_downloaded` events.
///
/// Emitted after the `download` action finishes verifying the DMG's
/// signature. The iOS/Mac UI promotes the "Update available" banner
/// to "Update ready — Install now" in response.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerUpdateDownloadedPayload {
    /// Semver of the downloaded release.
    pub latest_version: String,
    /// Absolute path under `~/.tron/system/updates/` where the DMG
    /// was staged. iOS receives this only for diagnostic display; the
    /// install flow runs entirely in the agent.
    pub local_path: String,
    /// Result of `codesign --verify --strict --deep`. `false` blocks
    /// any subsequent auto-install.
    pub signature_valid: bool,
    /// ISO 8601 timestamp the event was emitted.
    pub timestamp: String,
}

/// Payload for `server.update_installed` events.
///
/// Emitted after a successful auto-install and post-install ping
/// round-trip. The reconciled `fromVersion`/`toVersion` pair lets the
/// UI render "Updated to v0.5.1 from v0.5.0" even if the user never
/// saw the intermediate download event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerUpdateInstalledPayload {
    /// Version the binary was before the swap.
    pub from_version: String,
    /// Version of the newly installed binary (confirmed via post-install
    /// ping).
    pub to_version: String,
    /// Total wall-clock seconds spent in the install pipeline
    /// (download → verify → swap → restart → ping).
    pub duration_seconds: u64,
    /// ISO 8601 timestamp the event was emitted.
    pub timestamp: String,
}

/// Payload for `server.update_failed` events.
///
/// Emitted when any stage of the pipeline fails. `error` is a short
/// operator-facing sentence — iOS surfaces it in a toast, the Mac
/// menu bar appends it to the "View logs…" detail pane.
/// `consecutive_failures` tracks the state-file counter after this
/// failure so the UI can show progress toward the auto-degrade
/// threshold.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerUpdateFailedPayload {
    /// Version the updater was attempting to install.
    pub latest_version: String,
    /// Short error description (e.g., `"signature verification failed"`,
    /// `"post-install ping timed out"`).
    pub error: String,
    /// Post-install failure count including this failure. When this
    /// hits `AUTO_DEGRADE_FAILURE_THRESHOLD` the updater flips action
    /// back to `notify`.
    pub consecutive_failures: u32,
    /// ISO 8601 timestamp the event was emitted.
    pub timestamp: String,
}

/// Payload for `server.update_disabled_after_failures` events.
///
/// Emitted exactly once when the `consecutive_failures` counter
/// reaches the auto-degrade threshold. The `install` action has
/// already been flipped to `notify` in settings by the time this
/// fires. Surfaces as a persistent warning banner in iOS + menu bar.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerUpdateDisabledAfterFailuresPayload {
    /// Human-readable reason for disabling the auto-install action —
    /// always "3 consecutive post-install failures" in v1, but kept as
    /// a free-form string so a future implementation can surface
    /// richer detail.
    pub reason: String,
    /// Count of failures at the moment the degrade fired (always
    /// equals `AUTO_DEGRADE_FAILURE_THRESHOLD` at time of emission but
    /// the counter stays sticky until a manual reset / successful
    /// install, so this may grow if the user re-enables install and
    /// fails again before fixing).
    pub consecutive_failures: u32,
    /// ISO 8601 timestamp the event was emitted.
    pub timestamp: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn available_serializes_camel_case() {
        let p = ServerUpdateAvailablePayload {
            latest_version: "0.5.1".into(),
            download_url: Some("https://example/x.dmg".into()),
            release_notes: Some("* fix bug".into()),
            channel: "stable".into(),
            timestamp: "2026-04-23T12:00:00.000Z".into(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["latestVersion"], "0.5.1");
        assert_eq!(v["downloadUrl"], "https://example/x.dmg");
        assert_eq!(v["releaseNotes"], "* fix bug");
        assert_eq!(v["channel"], "stable");
    }

    #[test]
    fn downloaded_signature_invalid_is_serialized() {
        let p = ServerUpdateDownloadedPayload {
            latest_version: "0.5.1".into(),
            local_path: "/tmp/x.dmg".into(),
            signature_valid: false,
            timestamp: "2026-04-23T12:00:00.000Z".into(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["signatureValid"], false);
    }

    #[test]
    fn installed_reports_from_and_to() {
        let p = ServerUpdateInstalledPayload {
            from_version: "0.5.0".into(),
            to_version: "0.5.1".into(),
            duration_seconds: 42,
            timestamp: "t".into(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["fromVersion"], "0.5.0");
        assert_eq!(v["toVersion"], "0.5.1");
        assert_eq!(v["durationSeconds"], 42);
    }

    #[test]
    fn failed_includes_counter() {
        let p = ServerUpdateFailedPayload {
            latest_version: "0.5.1".into(),
            error: "ping timed out".into(),
            consecutive_failures: 2,
            timestamp: "t".into(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["latestVersion"], "0.5.1");
        assert_eq!(v["consecutiveFailures"], 2);
    }

    #[test]
    fn disabled_after_failures_shape() {
        let p = ServerUpdateDisabledAfterFailuresPayload {
            reason: "3 consecutive post-install failures".into(),
            consecutive_failures: 3,
            timestamp: "t".into(),
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["reason"], "3 consecutive post-install failures");
        assert_eq!(v["consecutiveFailures"], 3);
    }

    #[test]
    fn available_roundtrips() {
        let p = ServerUpdateAvailablePayload {
            latest_version: "0.5.1".into(),
            download_url: None,
            release_notes: None,
            channel: "beta".into(),
            timestamp: "t".into(),
        };
        let s = serde_json::to_string(&p).unwrap();
        let back: ServerUpdateAvailablePayload = serde_json::from_str(&s).unwrap();
        assert_eq!(p, back);
    }
}
