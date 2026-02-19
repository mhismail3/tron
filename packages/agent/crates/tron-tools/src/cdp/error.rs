//! Browser-specific error types.

use crate::errors::ToolError;
use thiserror::Error;

/// Errors from browser automation operations.
#[derive(Debug, Error)]
pub enum BrowserError {
    /// Failed to launch the Chrome browser process.
    #[error("failed to launch browser: {context}")]
    LaunchFailed {
        /// What went wrong during launch.
        context: String,
    },

    /// Navigation to a URL failed.
    #[error("navigation failed for {url}: {reason}")]
    NavigationFailed {
        /// The URL that failed to load.
        url: String,
        /// Why it failed.
        reason: String,
    },

    /// A browser action failed.
    #[error("{action} failed: {reason}")]
    ActionFailed {
        /// The action that failed (e.g., "click", "fill").
        action: String,
        /// Why it failed.
        reason: String,
    },

    /// Screencast operations failed.
    #[error("screencast failed: {0}")]
    ScreencastFailed(String),

    /// No browser session found for the given session ID.
    #[error("no browser session for '{session_id}'")]
    SessionNotFound {
        /// The missing session ID.
        session_id: String,
    },

    /// Chrome executable not found on the system.
    #[error("Chrome not found — install Google Chrome or set CHROME_PATH")]
    ChromeNotFound,

    /// Element not found on the page.
    #[error("element not found: {selector}")]
    ElementNotFound {
        /// The CSS selector that matched nothing.
        selector: String,
    },

    /// Operation timed out.
    #[error("timed out after {timeout_ms}ms: {context}")]
    Timeout {
        /// How long we waited.
        timeout_ms: u64,
        /// What we were waiting for.
        context: String,
    },

    /// CDP protocol error.
    #[error("CDP error: {0}")]
    Cdp(String),
}

impl From<BrowserError> for ToolError {
    fn from(err: BrowserError) -> Self {
        ToolError::Internal {
            message: err.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_failed_display() {
        let err = BrowserError::LaunchFailed {
            context: "binary not executable".into(),
        };
        assert_eq!(
            err.to_string(),
            "failed to launch browser: binary not executable"
        );
    }

    #[test]
    fn navigation_failed_display() {
        let err = BrowserError::NavigationFailed {
            url: "https://example.com".into(),
            reason: "timeout".into(),
        };
        assert!(err.to_string().contains("https://example.com"));
        assert!(err.to_string().contains("timeout"));
    }

    #[test]
    fn action_failed_display() {
        let err = BrowserError::ActionFailed {
            action: "click".into(),
            reason: "no matching element".into(),
        };
        assert!(err.to_string().contains("click"));
        assert!(err.to_string().contains("no matching element"));
    }

    #[test]
    fn screencast_failed_display() {
        let err = BrowserError::ScreencastFailed("already running".into());
        assert_eq!(err.to_string(), "screencast failed: already running");
    }

    #[test]
    fn session_not_found_display() {
        let err = BrowserError::SessionNotFound {
            session_id: "sess_123".into(),
        };
        assert!(err.to_string().contains("sess_123"));
    }

    #[test]
    fn chrome_not_found_display() {
        let err = BrowserError::ChromeNotFound;
        assert!(err.to_string().contains("Chrome not found"));
    }

    #[test]
    fn browser_error_to_tool_error() {
        let browser_err = BrowserError::ActionFailed {
            action: "screenshot".into(),
            reason: "page crashed".into(),
        };
        let tool_err: ToolError = browser_err.into();
        match tool_err {
            ToolError::Internal { message } => {
                assert!(message.contains("screenshot"));
                assert!(message.contains("page crashed"));
            }
            other => panic!("expected Internal, got: {other:?}"),
        }
    }

    #[test]
    fn element_not_found_display() {
        let err = BrowserError::ElementNotFound {
            selector: "#missing".into(),
        };
        assert!(err.to_string().contains("#missing"));
    }

    #[test]
    fn timeout_display() {
        let err = BrowserError::Timeout {
            timeout_ms: 5000,
            context: "waiting for selector".into(),
        };
        assert!(err.to_string().contains("5000ms"));
        assert!(err.to_string().contains("waiting for selector"));
    }

    #[test]
    fn cdp_error_display() {
        let err = BrowserError::Cdp("connection refused".into());
        assert_eq!(err.to_string(), "CDP error: connection refused");
    }
}
