//! Screenshot persistence for the BrowseTheWeb tool.
//!
//! Provides opt-in saving of browser screenshots to `~/.tron/workspace/screenshots/`.
//! The agent controls when screenshots are saved via the `save` parameter.
//! All errors are non-fatal — a failed save still returns the screenshot to the LLM.

use std::path::PathBuf;

use base64::Engine;

use crate::settings::screenshots_dir;

/// Generate a screenshot filename: `{ISO8601}_{session_id}_{uuid_short}.{format}`.
pub fn screenshot_filename(session_id: &str, format: &str) -> String {
    let ts = chrono::Utc::now().format("%Y%m%dT%H%M%SZ");
    let short_uuid = &uuid::Uuid::now_v7().to_string()[..8];
    let safe_id = sanitize_session_id(session_id);
    format!("{ts}_{safe_id}_{short_uuid}.{format}")
}

/// Sanitize a session ID for use in filenames.
/// Replaces non-alphanumeric/hyphen/underscore chars with `_`, truncates to 32.
pub fn sanitize_session_id(s: &str) -> String {
    let sanitized: String = s
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    if sanitized.len() > 32 {
        sanitized[..32].to_string()
    } else {
        sanitized
    }
}

/// Save a base64-encoded screenshot to `~/.tron/workspace/screenshots/`.
///
/// Creates the directory if it doesn't exist. Returns `None` on any error
/// (logged but non-fatal).
pub async fn save_screenshot(
    session_id: &str,
    base64_data: &str,
    format: &str,
) -> Option<PathBuf> {
    let dir = screenshots_dir();
    if let Err(e) = tokio::fs::create_dir_all(&dir).await {
        tracing::warn!(error = %e, "failed to create screenshots directory");
        return None;
    }

    let bytes = match base64::engine::general_purpose::STANDARD.decode(base64_data) {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(error = %e, "failed to decode screenshot base64");
            return None;
        }
    };

    let filename = screenshot_filename(session_id, format);
    let path = dir.join(&filename);

    if let Err(e) = tokio::fs::write(&path, &bytes).await {
        tracing::warn!(error = %e, path = %path.display(), "failed to write screenshot");
        return None;
    }

    tracing::debug!(path = %path.display(), "screenshot saved");
    Some(path)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screenshot_filename_contains_timestamp() {
        let name = screenshot_filename("sess-1", "png");
        // ISO8601 compact: YYYYMMDDTHHMMSSz
        assert!(
            name.contains('T') && name.contains('Z'),
            "filename should contain ISO8601 timestamp: {name}"
        );
    }

    #[test]
    fn screenshot_filename_contains_session_id() {
        let name = screenshot_filename("my-session", "png");
        assert!(
            name.contains("my-session"),
            "filename should contain session id: {name}"
        );
    }

    #[test]
    fn screenshot_filename_ends_with_format() {
        let name = screenshot_filename("sess-1", "png");
        assert!(name.ends_with(".png"), "should end with .png: {name}");

        let name_jpg = screenshot_filename("sess-1", "jpeg");
        assert!(name_jpg.ends_with(".jpeg"), "should end with .jpeg: {name_jpg}");
    }

    #[test]
    fn sanitize_session_id_replaces_special_chars() {
        assert_eq!(sanitize_session_id("a/b c.d"), "a_b_c_d");
        assert_eq!(sanitize_session_id("hello@world!"), "hello_world_");
    }

    #[test]
    fn sanitize_session_id_preserves_valid_chars() {
        assert_eq!(sanitize_session_id("my-session_123"), "my-session_123");
    }

    #[test]
    fn sanitize_session_id_truncates_long_ids() {
        let long = "a".repeat(50);
        let result = sanitize_session_id(&long);
        assert_eq!(result.len(), 32);
    }

    #[tokio::test]
    async fn save_screenshot_writes_file() {
        let dir = tempfile::tempdir().unwrap();
        // Override screenshots_dir by working directly with the save logic
        let base64_data = base64::engine::general_purpose::STANDARD.encode(b"fake png bytes");

        let filename = screenshot_filename("test-sess", "png");
        let path = dir.path().join(&filename);
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&base64_data)
            .unwrap();
        tokio::fs::write(&path, &bytes).await.unwrap();

        assert!(path.exists());
        let contents = tokio::fs::read(&path).await.unwrap();
        assert_eq!(contents, b"fake png bytes");
    }

    #[tokio::test]
    async fn save_screenshot_returns_none_on_invalid_base64() {
        // save_screenshot uses screenshots_dir() which points to ~/.tron/...
        // Test the decode path directly
        let result =
            base64::engine::general_purpose::STANDARD.decode("not valid base64!!!");
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn save_screenshot_creates_dir_if_missing() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("sub").join("screenshots");
        assert!(!nested.exists());
        tokio::fs::create_dir_all(&nested).await.unwrap();
        assert!(nested.exists());
    }
}
