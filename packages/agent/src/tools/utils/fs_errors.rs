//! Filesystem error formatting.
//!
//! Maps [`std::io::Error`] kinds (and high-level error messages) to
//! structured [`TronToolResult`] instances whose `tool.details` carry
//! `errorClass` + `error` fields. iOS classifies the error from the
//! structured fields — it never scans the text.

use std::io;

use serde_json::json;

use crate::core::content::ToolResultContent;
use crate::core::tools::{ToolResultBody, TronToolResult};

/// Structured error class for any filesystem tool (Read, Write, Edit).
///
/// Consumed by iOS via `tool.details.errorClass`. The string values are
/// pinned — changing any of them requires an iOS update in lockstep.
pub fn classify_fs_error(error: &io::Error, path: &str) -> &'static str {
    match error.kind() {
        io::ErrorKind::NotFound => "not_found",
        io::ErrorKind::PermissionDenied => "permission_denied",
        _ => {
            if let Some(os_code) = error.raw_os_error() {
                if os_code == libc_eisdir() {
                    return "is_a_directory";
                }
                if os_code == libc_enotdir() {
                    return "not_a_directory";
                }
                if os_code == libc_enospc() {
                    return "disk_full";
                }
            }
            let msg = error.to_string().to_lowercase();
            if msg.contains("is a directory") {
                return "is_a_directory";
            }
            if msg.contains("not a directory") {
                return "not_a_directory";
            }
            if msg.contains("no space") || msg.contains("disk full") {
                return "disk_full";
            }
            let _ = path;
            "other"
        }
    }
}

/// Build a structured fs error with `errorClass`, `error`, and `path` in
/// `tool.details`. The text body carries the same message the agent sees.
pub fn fs_error_result(error: &io::Error, path: &str, operation: &str) -> TronToolResult {
    let message = match error.kind() {
        io::ErrorKind::NotFound => format!("File not found: {path}"),
        io::ErrorKind::PermissionDenied => format!("Permission denied: {path}"),
        _ => {
            if let Some(os_code) = error.raw_os_error() {
                if os_code == libc_eisdir() {
                    format!("Is a directory: {path}")
                } else if os_code == libc_enotdir() {
                    format!("Not a directory: {path}")
                } else {
                    format!("Error {operation} {path}: {error}")
                }
            } else {
                let msg = error.to_string();
                if msg.contains("Is a directory") || msg.contains("is a directory") {
                    format!("Is a directory: {path}")
                } else if msg.contains("Not a directory") || msg.contains("not a directory") {
                    format!("Not a directory: {path}")
                } else {
                    format!("Error {operation} {path}: {error}")
                }
            }
        }
    };
    let class = classify_fs_error(error, path);
    fs_error_tool_result(&message, class, path)
}

/// Build a structured fs error without a backing `io::Error` — used when
/// the tool itself detects a bad parameter, traversal, or size limit.
pub fn fs_error_from_message(
    message: impl Into<String>,
    error_class: &'static str,
    path: &str,
) -> TronToolResult {
    let msg: String = message.into();
    fs_error_tool_result(&msg, error_class, path)
}

fn fs_error_tool_result(message: &str, error_class: &str, path: &str) -> TronToolResult {
    TronToolResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(message)]),
        details: Some(json!({
            "error": message,
            "errorClass": error_class,
            "path": path,
        })),
        is_error: Some(true),
        stop_turn: None,
    }
}

#[cfg(target_os = "macos")]
fn libc_eisdir() -> i32 {
    21 // EISDIR on macOS
}

#[cfg(target_os = "linux")]
fn libc_eisdir() -> i32 {
    21 // EISDIR on Linux
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn libc_eisdir() -> i32 {
    -1 // No match
}

#[cfg(target_os = "macos")]
fn libc_enotdir() -> i32 {
    20 // ENOTDIR on macOS
}

#[cfg(target_os = "linux")]
fn libc_enotdir() -> i32 {
    20 // ENOTDIR on Linux
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn libc_enotdir() -> i32 {
    -1 // No match
}

#[cfg(target_os = "macos")]
fn libc_enospc() -> i32 {
    28 // ENOSPC on macOS
}

#[cfg(target_os = "linux")]
fn libc_enospc() -> i32 {
    28 // ENOSPC on Linux
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn libc_enospc() -> i32 {
    -1
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::testutil::extract_text;

    #[test]
    fn enoent_classified_as_not_found() {
        let err = io::Error::new(io::ErrorKind::NotFound, "file gone");
        let result = fs_error_result(&err, "/tmp/missing.txt", "reading");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(extract_text(&result), "File not found: /tmp/missing.txt");
        let d = result.details.as_ref().unwrap();
        assert_eq!(d["errorClass"], "not_found");
        assert_eq!(d["path"], "/tmp/missing.txt");
        assert_eq!(d["error"], "File not found: /tmp/missing.txt");
    }

    #[test]
    fn eacces_classified_as_permission_denied() {
        let err = io::Error::new(io::ErrorKind::PermissionDenied, "no access");
        let result = fs_error_result(&err, "/etc/shadow", "reading");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(
            result.details.as_ref().unwrap()["errorClass"],
            "permission_denied"
        );
    }

    #[test]
    fn eisdir_classified_as_is_a_directory() {
        let err = io::Error::from_raw_os_error(libc_eisdir());
        let result = fs_error_result(&err, "/tmp", "reading");
        assert_eq!(
            result.details.as_ref().unwrap()["errorClass"],
            "is_a_directory"
        );
    }

    #[test]
    fn enotdir_classified_as_not_a_directory() {
        let err = io::Error::from_raw_os_error(libc_enotdir());
        let result = fs_error_result(&err, "/tmp/file.txt/sub", "reading");
        assert_eq!(
            result.details.as_ref().unwrap()["errorClass"],
            "not_a_directory"
        );
    }

    #[test]
    fn unknown_error_classified_as_other() {
        let err = io::Error::other("something broke");
        let result = fs_error_result(&err, "/tmp/file", "writing");
        assert_eq!(result.details.as_ref().unwrap()["errorClass"], "other");
        let text = extract_text(&result);
        assert!(text.contains("something broke"));
    }

    #[test]
    fn fs_error_from_message_carries_custom_class() {
        let result = fs_error_from_message(
            "File too large: 999 bytes (max 500)",
            "too_large",
            "/tmp/big.txt",
        );
        let d = result.details.as_ref().unwrap();
        assert_eq!(d["errorClass"], "too_large");
        assert_eq!(d["path"], "/tmp/big.txt");
    }
}
