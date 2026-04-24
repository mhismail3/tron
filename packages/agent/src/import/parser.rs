//! Claude Code session file discovery and parsing.

use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;

use crate::import::errors::ImportError;
use crate::import::types::{ClaudeRecord, RecordKind};

/// Metadata for a Claude Code project directory.
#[derive(Debug, Clone)]
pub struct ClaudeProject {
    /// Decoded working directory path.
    pub project_path: String,
    /// The encoded directory name under `~/.claude/projects/`.
    pub encoded_dir: String,
    /// Number of session JSONL files.
    pub session_count: usize,
}

/// Lightweight metadata for a session extracted via full parse.
#[derive(Debug, Clone)]
pub struct ClaudeSessionMeta {
    /// Absolute path to the `.jsonl` file.
    pub file_path: String,
    /// Session UUID (filename without `.jsonl`).
    pub session_uuid: String,
    /// Session title from a `custom-title` record.
    pub title: Option<String>,
    /// Human-readable slug from assistant records.
    pub slug: Option<String>,
    /// Model ID from the first assistant message.
    pub model: Option<String>,
    /// Timestamp of the first record.
    pub first_timestamp: Option<String>,
    /// Timestamp of the last record.
    pub last_timestamp: Option<String>,
    /// Number of user + assistant records.
    pub message_count: usize,
    /// Total input tokens across all assistant messages.
    pub input_tokens: i64,
    /// Total output tokens across all assistant messages.
    pub output_tokens: i64,
}

/// Decode a Claude Code project directory name to a filesystem path.
///
/// Claude Code encodes paths by replacing every `/` with `-`, producing
/// names like `-Users-alice-projects-myapp`. The naive decode (replace all
/// `-` with `/`) is lossy when directory names contain hyphens. We resolve
/// ambiguity by checking the filesystem: starting from the full naive
/// decode, we walk up the path to find the deepest real directory, then
/// treat the remainder as the final component name with hyphens.
pub fn decode_project_dir(encoded: &str) -> String {
    let naive = encoded.replace('-', "/");

    // Try to find the real path by checking the filesystem.
    // The naive decode is ambiguous when a real directory name contains a
    // hyphen (e.g. `my-project`): we can't tell whether `-my-project` meant
    // `/my-project` or `/my/project` without consulting the filesystem.
    let naive_path = Path::new(&naive);
    if naive_path.exists() {
        return naive;
    }

    // Walk up until we find a real parent, then rejoin the tail with hyphens.
    let components: Vec<&str> = naive.split('/').filter(|s| !s.is_empty()).collect();
    for i in (1..components.len()).rev() {
        let parent = format!("/{}", components[..i].join("/"));
        if Path::new(&parent).is_dir() {
            let tail = components[i..].join("-");
            return format!("{parent}/{tail}");
        }
    }

    naive
}

/// Scan a Claude Code projects directory and return project directories.
///
/// `claude_projects_dir` should be `~/.claude/projects/`.
pub fn discover_projects(claude_projects_dir: &Path) -> Result<Vec<ClaudeProject>, ImportError> {
    if !claude_projects_dir.is_dir() {
        return Err(ImportError::NoClaudeDirectory {
            path: claude_projects_dir.to_path_buf(),
        });
    }

    let mut projects = Vec::new();
    let entries = fs::read_dir(claude_projects_dir).map_err(|e| ImportError::Io {
        path: claude_projects_dir.to_path_buf(),
        source: e,
    })?;

    for entry in entries {
        let entry = entry.map_err(|e| ImportError::Io {
            path: claude_projects_dir.to_path_buf(),
            source: e,
        })?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let dir_name = entry.file_name().to_string_lossy().to_string();
        let session_count = count_jsonl_files(&path);
        if session_count > 0 {
            projects.push(ClaudeProject {
                project_path: decode_project_dir(&dir_name),
                encoded_dir: dir_name,
                session_count,
            });
        }
    }

    projects.sort_by(|a, b| b.session_count.cmp(&a.session_count));
    Ok(projects)
}

/// List sessions in a project directory with metadata.
pub fn discover_sessions(project_dir: &Path) -> Result<Vec<ClaudeSessionMeta>, ImportError> {
    if !project_dir.is_dir() {
        return Err(ImportError::SessionNotFound {
            path: project_dir.to_path_buf(),
        });
    }

    let mut sessions = Vec::new();
    let entries = fs::read_dir(project_dir).map_err(|e| ImportError::Io {
        path: project_dir.to_path_buf(),
        source: e,
    })?;

    for entry in entries {
        let entry = entry.map_err(|e| ImportError::Io {
            path: project_dir.to_path_buf(),
            source: e,
        })?;
        let path = entry.path();
        let Some(ext) = path.extension() else {
            continue;
        };
        if ext != "jsonl" {
            continue;
        }
        let session_uuid = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();

        if let Ok(meta) = extract_session_meta(&path, &session_uuid) {
            sessions.push(meta);
        }
    }

    // Sort by last activity descending
    sessions.sort_by(|a, b| b.last_timestamp.cmp(&a.last_timestamp));
    Ok(sessions)
}

/// A line that failed to parse during [`parse_session_detailed`].
///
/// Surfaced so a dry-run validation (see [`crate::import::validator`]) can
/// report silent skips to the user instead of burying them in a debug log.
#[derive(Debug, Clone)]
pub struct ParseWarning {
    /// 1-indexed source line number.
    pub line_number: usize,
    /// Human-readable reason (usually the serde_json error message).
    pub reason: String,
    /// First 120 characters of the offending line for context.
    pub snippet: String,
}

/// Detailed parse result: both the records and the warnings.
///
/// `parse_session` keeps the original API by discarding warnings. Callers
/// that want dry-run visibility (the validator, the `import.previewSession`
/// RPC) use [`parse_session_detailed`] directly.
#[derive(Debug)]
pub struct ParseOutcome {
    /// Records that parsed successfully.
    pub records: Vec<ClaudeRecord>,
    /// Warnings for every line that failed to parse.
    pub warnings: Vec<ParseWarning>,
    /// Total non-blank lines inspected (parsed + skipped).
    pub total_non_blank_lines: usize,
}

/// Parse a full session file into records, discarding parse warnings.
///
/// Skips lines that fail to parse (handles partial writes at tail of
/// in-progress sessions). For the dry-run API that surfaces those skips,
/// call [`parse_session_detailed`] instead.
pub fn parse_session(path: &Path) -> Result<Vec<ClaudeRecord>, ImportError> {
    Ok(parse_session_detailed(path)?.records)
}

/// Parse a full session file, tracking line numbers and collecting a
/// [`ParseWarning`] for every line that failed to parse.
///
/// Invariants:
/// - `records` and `warnings` together account for every non-blank line in
///   the file; `total_non_blank_lines == records.len() + warnings.len()`.
/// - Line numbers are 1-indexed and reflect the physical line in the source
///   file (blank lines count toward the number, just not toward the total).
pub fn parse_session_detailed(path: &Path) -> Result<ParseOutcome, ImportError> {
    if !path.is_file() {
        return Err(ImportError::SessionNotFound {
            path: path.to_path_buf(),
        });
    }

    let file = fs::File::open(path).map_err(|e| ImportError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;
    let reader = BufReader::new(file);
    let mut records = Vec::new();
    let mut warnings = Vec::new();
    let mut total_non_blank_lines = 0usize;

    for (idx, line) in reader.lines().enumerate() {
        let line = line.map_err(|e| ImportError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        total_non_blank_lines += 1;
        match serde_json::from_str::<ClaudeRecord>(trimmed) {
            Ok(record) => records.push(record),
            Err(err) => {
                let snippet = if trimmed.len() > 120 {
                    format!("{}…", &trimmed[..120])
                } else {
                    trimmed.to_string()
                };
                tracing::debug!(
                    path = %path.display(),
                    line = idx + 1,
                    error = %err,
                    "skipping unparseable JSONL line"
                );
                warnings.push(ParseWarning {
                    line_number: idx + 1,
                    reason: err.to_string(),
                    snippet,
                });
            }
        }
    }

    Ok(ParseOutcome {
        records,
        warnings,
        total_non_blank_lines,
    })
}

// ── Helpers ──

fn count_jsonl_files(dir: &Path) -> usize {
    fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
                .count()
        })
        .unwrap_or(0)
}

fn extract_session_meta(path: &Path, session_uuid: &str) -> Result<ClaudeSessionMeta, ImportError> {
    let records = parse_session(path)?;

    let mut title = None;
    let mut slug = None;
    let mut model = None;
    let mut first_timestamp = None;
    let mut last_timestamp = None;
    let mut message_count = 0usize;
    let mut input_tokens = 0i64;
    let mut output_tokens = 0i64;

    for record in &records {
        // Timestamps
        if let Some(ts) = &record.timestamp {
            if first_timestamp.is_none() {
                first_timestamp = Some(ts.clone());
            }
            last_timestamp = Some(ts.clone());
        }

        match record.kind() {
            RecordKind::CustomTitle => {
                if let Some(t) = &record.custom_title {
                    title = Some(t.clone());
                }
            }
            RecordKind::Assistant => {
                message_count += 1;
                if slug.is_none()
                    && let Some(s) = &record.slug
                {
                    slug = Some(s.clone());
                }
                if let Some(msg) = &record.message {
                    if model.is_none()
                        && let Some(m) = &msg.model
                    {
                        model = Some(m.clone());
                    }
                    let usage = msg.usage.clone().unwrap_or_default();
                    input_tokens += usage.input_tokens;
                    output_tokens += usage.output_tokens;
                }
            }
            RecordKind::User => {
                if record.is_meta != Some(true) && !record.is_tool_result() {
                    message_count += 1;
                }
            }
            _ => {}
        }
    }

    Ok(ClaudeSessionMeta {
        file_path: path.to_string_lossy().to_string(),
        session_uuid: session_uuid.to_string(),
        title,
        slug,
        model,
        first_timestamp,
        last_timestamp,
        message_count,
        input_tokens,
        output_tokens,
    })
}

#[cfg(test)]
#[path = "parser_tests.rs"]
mod tests;
