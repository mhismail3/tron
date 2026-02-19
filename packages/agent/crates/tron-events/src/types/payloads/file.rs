//! File event payloads: read, write, edit.

use serde::{Deserialize, Serialize};

/// Payload for `file.read` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileReadPayload {
    /// File path.
    pub path: String,
    /// Line range read.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines: Option<LineRange>,
}

/// Line range for file read.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LineRange {
    /// Start line (1-based).
    pub start: i64,
    /// End line (inclusive).
    pub end: i64,
}

/// Payload for `file.write` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileWritePayload {
    /// File path.
    pub path: String,
    /// File size in bytes.
    pub size: i64,
    /// Content hash.
    pub content_hash: String,
}

/// Payload for `file.edit` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEditPayload {
    /// File path.
    pub path: String,
    /// Old string replaced.
    pub old_string: String,
    /// New string inserted.
    pub new_string: String,
    /// Diff output.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diff: Option<String>,
}
