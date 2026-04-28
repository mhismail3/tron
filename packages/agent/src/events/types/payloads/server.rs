//! Server lifecycle event payloads for user-mode update checks.
//!
//! Emitted by `server::updater` when the GitHub Releases poller
//! observes a newer release. iOS and the Mac menu bar consume it through
//! the normal event pipeline; no event here is session-scoped.

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
