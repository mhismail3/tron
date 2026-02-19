//! Filesystem error formatting.
//!
//! Maps [`std::io::Error`] kinds to user-friendly tool result messages matching
//! the TypeScript implementation's error format.

use std::io;

use tron_core::tools::{TronToolResult, error_result};

/// Format a filesystem error into a user-friendly [`TronToolResult`].
///
/// Maps common I/O error kinds to specific messages:
/// - `NotFound` → "File not found: {path}"
/// - `PermissionDenied` → "Permission denied: {path}"
/// - Other errors include the error description.
///
/// The `operation` parameter is used for context in the generic case.
pub fn format_fs_error(error: &io::Error, path: &str, operation: &str) -> TronToolResult {
    match error.kind() {
        io::ErrorKind::NotFound => error_result(format!("File not found: {path}")),
        io::ErrorKind::PermissionDenied => error_result(format!("Permission denied: {path}")),
        _ => {
            // Check raw OS error for EISDIR / ENOTDIR
            if let Some(os_code) = error.raw_os_error() {
                if os_code == libc_eisdir() {
                    return error_result(format!("Is a directory: {path}"));
                }
                if os_code == libc_enotdir() {
                    return error_result(format!("Not a directory: {path}"));
                }
            }
            // Check the error message for directory indicators
            let msg = error.to_string();
            if msg.contains("Is a directory") || msg.contains("is a directory") {
                return error_result(format!("Is a directory: {path}"));
            }
            if msg.contains("Not a directory") || msg.contains("not a directory") {
                return error_result(format!("Not a directory: {path}"));
            }
            error_result(format!("Error {operation} {path}: {error}"))
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::extract_text;

    #[test]
    fn enoent_file_not_found() {
        let err = io::Error::new(io::ErrorKind::NotFound, "file gone");
        let result = format_fs_error(&err, "/tmp/missing.txt", "reading");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(extract_text(&result), "File not found: /tmp/missing.txt");
    }

    #[test]
    fn eacces_permission_denied() {
        let err = io::Error::new(io::ErrorKind::PermissionDenied, "no access");
        let result = format_fs_error(&err, "/etc/shadow", "reading");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(extract_text(&result), "Permission denied: /etc/shadow");
    }

    #[test]
    fn eisdir_is_a_directory() {
        let err = io::Error::from_raw_os_error(libc_eisdir());
        let result = format_fs_error(&err, "/tmp", "reading");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(extract_text(&result), "Is a directory: /tmp");
    }

    #[test]
    fn enotdir_not_a_directory() {
        let err = io::Error::from_raw_os_error(libc_enotdir());
        let result = format_fs_error(&err, "/tmp/file.txt/sub", "reading");
        assert_eq!(result.is_error, Some(true));
        assert_eq!(extract_text(&result), "Not a directory: /tmp/file.txt/sub");
    }

    #[test]
    fn unknown_error_generic_message() {
        let err = io::Error::new(io::ErrorKind::Other, "something broke");
        let result = format_fs_error(&err, "/tmp/file", "writing");
        assert_eq!(result.is_error, Some(true));
        let text = extract_text(&result);
        assert!(text.contains("something broke"));
        assert!(text.contains("/tmp/file"));
    }
}
