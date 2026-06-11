//! Streaming journal — per-turn append-only WAL for crash recovery.
//!
//! Each active LLM turn writes streaming deltas (text, thinking, capability invocations) to a
//! journal file at `~/.tron/internal/database/journals/{session_id}/turn_{n}.wal`.
//! On normal completion the journal is deleted. If the server crashes mid-turn,
//! orphaned journals are discovered on next startup and their content is persisted
//! as partial assistant messages.
//!
//! ## Format
//!
//! JSON lines with compact keys for write efficiency:
//! - `{"t":"text","c":"delta content"}`
//! - `{"t":"thinking","c":"delta content"}`
//! - `{"t":"capability_invocation","c":"{...}"}`  (JSON-encoded capability invocation)
//!
//! Each `append_delta` writes one line and flushes, providing crash safety to
//! line granularity.
//!
//! ## Invariants
//!
//! - Single writer per journal (one turn = one journal).
//! - `BufReader::lines()` naturally handles partial last line (crash mid-write).
//! - Journal directory is cleaned up when empty after finalize.

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tracing::{debug, trace, warn};

use crate::shared::foundation::paths;

/// Maximum bytes retained in one per-turn streaming journal WAL.
pub const MAX_STREAMING_JOURNAL_BYTES: u64 = 8 * 1024 * 1024;
const MAX_RECOVERED_TEXT_BYTES: usize = 4 * 1024 * 1024;
const MAX_RECOVERED_THINKING_BYTES: usize = 4 * 1024 * 1024;
const MAX_RECOVERED_CAPABILITY_INVOCATIONS: usize = 64;

/// A single delta entry in the journal WAL.
#[derive(Debug, Serialize, Deserialize)]
struct JournalEntry {
    /// Delta type: "text", "thinking", or "capability_invocation"
    t: String,
    /// Delta content
    c: String,
}

/// Recovered turn data from an orphaned journal.
#[derive(Debug)]
pub struct RecoveredTurn {
    /// Accumulated text content from all text deltas.
    pub accumulated_text: String,
    /// Accumulated thinking/reasoning content from all thinking deltas.
    pub accumulated_thinking: String,
    /// Partial capability invocation data recovered from the journal.
    pub capability_invocations: Vec<serde_json::Value>,
}

/// Append-only WAL for a single turn's streaming output.
pub struct StreamingJournal {
    file: File,
    path: PathBuf,
    session_id: String,
    turn: u32,
}

impl StreamingJournal {
    /// Create a new journal for the given session/turn.
    /// Creates parent directories as needed.
    pub fn create(session_id: &str, turn: u32) -> io::Result<Self> {
        let path = Self::journal_path(session_id, turn);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&path)?;
        debug!(session_id, turn, path = %path.display(), "streaming journal created");
        Ok(Self {
            file,
            path,
            session_id: session_id.to_string(),
            turn,
        })
    }

    /// Append a streaming delta to the journal.
    /// Each call writes one JSON line and flushes.
    pub fn append_delta(&mut self, delta_type: &str, content: &str) -> io::Result<()> {
        let entry = JournalEntry {
            t: delta_type.to_string(),
            c: content.to_string(),
        };
        let mut line =
            serde_json::to_string(&entry).map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        line.push('\n');
        let current_len = self.file.metadata()?.len();
        ensure_journal_size_budget(current_len, line.len())?;
        self.file.write_all(line.as_bytes())?;
        self.file.flush()?;
        trace!(
            session_id = %self.session_id,
            turn = self.turn,
            delta_type,
            bytes = line.len(),
            "journal delta appended"
        );
        Ok(())
    }

    /// Turn completed normally. Delete the journal file and clean up empty session dir.
    pub fn finalize_and_delete(self) -> io::Result<()> {
        let session_dir = self.path.parent().map(|p| p.to_path_buf());
        fs::remove_file(&self.path)?;
        debug!(
            session_id = %self.session_id,
            turn = self.turn,
            path = %self.path.display(),
            "streaming journal finalized and deleted"
        );
        // Clean up empty session directory
        if let Some(dir) = session_dir {
            if dir.exists() {
                if let Ok(mut entries) = fs::read_dir(&dir) {
                    if entries.next().is_none() {
                        let _ = fs::remove_dir(&dir);
                        trace!(dir = %dir.display(), "empty session journal dir removed");
                    }
                }
            }
        }
        Ok(())
    }

    /// Read a journal for crash recovery. Returns None if no journal exists or file is empty.
    pub fn load_recovery(session_id: &str, turn: u32) -> io::Result<Option<RecoveredTurn>> {
        let path = Self::journal_path(session_id, turn);
        let file = match File::open(&path) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        };
        let metadata = file.metadata()?;
        if metadata.len() == 0 {
            debug!(session_id, turn, "empty journal found, skipping recovery");
            return Ok(None);
        }
        if metadata.len() > MAX_STREAMING_JOURNAL_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "streaming journal exceeds {} byte limit: {} bytes",
                    MAX_STREAMING_JOURNAL_BYTES,
                    metadata.len()
                ),
            ));
        }

        let reader = BufReader::new(file);
        let mut text = String::new();
        let mut thinking = String::new();
        let mut capability_invocations: Vec<serde_json::Value> = Vec::new();
        let mut recovered_lines = 0u64;

        for line_result in reader.lines() {
            let line = match line_result {
                Ok(l) => l,
                Err(e) => {
                    // Partial last line from crash mid-write — skip it
                    warn!(
                        session_id,
                        turn,
                        error = %e,
                        "skipping partial/corrupted journal line (likely crash mid-write)"
                    );
                    break;
                }
            };

            if line.is_empty() {
                continue;
            }

            let entry: JournalEntry = match serde_json::from_str(&line) {
                Ok(e) => e,
                Err(e) => {
                    warn!(
                        session_id,
                        turn,
                        error = %e,
                        line_preview = &line[..line.len().min(100)],
                        "skipping malformed journal entry"
                    );
                    continue;
                }
            };

            match entry.t.as_str() {
                "text" => {
                    ensure_recovered_size_budget(
                        text.len(),
                        entry.c.len(),
                        MAX_RECOVERED_TEXT_BYTES,
                        "text",
                    )?;
                    text.push_str(&entry.c);
                }
                "thinking" => {
                    ensure_recovered_size_budget(
                        thinking.len(),
                        entry.c.len(),
                        MAX_RECOVERED_THINKING_BYTES,
                        "thinking",
                    )?;
                    thinking.push_str(&entry.c);
                }
                "capability_invocation" => {
                    if capability_invocations.len() >= MAX_RECOVERED_CAPABILITY_INVOCATIONS {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            format!(
                                "streaming journal capability invocations exceed {} item limit",
                                MAX_RECOVERED_CAPABILITY_INVOCATIONS
                            ),
                        ));
                    }
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&entry.c) {
                        capability_invocations.push(val);
                    }
                }
                other => {
                    trace!(
                        session_id,
                        turn,
                        delta_type = other,
                        "unknown journal delta type, skipping"
                    );
                }
            }
            recovered_lines += 1;
        }

        if recovered_lines == 0 {
            return Ok(None);
        }

        debug!(
            session_id,
            turn,
            recovered_lines,
            text_len = text.len(),
            thinking_len = thinking.len(),
            capability_invocations = capability_invocations.len(),
            "journal recovery loaded"
        );

        Ok(Some(RecoveredTurn {
            accumulated_text: text,
            accumulated_thinking: thinking,
            capability_invocations,
        }))
    }

    /// Scan for all incomplete journals (orphaned after crash).
    /// Returns (session_id, turn) pairs for each orphaned journal found.
    pub fn scan_incomplete() -> io::Result<Vec<(String, u32)>> {
        let journals_dir = paths::journals_dir();
        if !journals_dir.exists() {
            return Ok(Vec::new());
        }

        let mut results = Vec::new();

        for session_entry in fs::read_dir(&journals_dir)? {
            let session_entry = session_entry?;
            let session_path = session_entry.path();
            if !session_path.is_dir() {
                continue;
            }
            let session_id = match session_path.file_name().and_then(|n| n.to_str()) {
                Some(name) => name.to_string(),
                None => continue,
            };

            for wal_entry in fs::read_dir(&session_path)? {
                let wal_entry = wal_entry?;
                let wal_name = match wal_entry.file_name().into_string() {
                    Ok(name) => name,
                    Err(_) => continue,
                };

                // Parse turn_{n}.wal
                if let Some(turn) = Self::parse_wal_filename(&wal_name) {
                    results.push((session_id.clone(), turn));
                }
            }
        }

        if !results.is_empty() {
            debug!(
                count = results.len(),
                "found incomplete journals for recovery"
            );
        }

        Ok(results)
    }

    /// Path for a specific journal: `~/.tron/internal/database/journals/{session_id}/turn_{n}.wal`
    pub fn journal_path(session_id: &str, turn: u32) -> PathBuf {
        paths::journals_dir()
            .join(session_id)
            .join(format!("turn_{turn}.wal"))
    }

    /// Parse a WAL filename like `turn_3.wal` into its turn number.
    fn parse_wal_filename(name: &str) -> Option<u32> {
        let name = name.strip_prefix("turn_")?;
        let name = name.strip_suffix(".wal")?;
        name.parse().ok()
    }
}

fn ensure_journal_size_budget(current_len: u64, additional_len: usize) -> io::Result<()> {
    let attempted = current_len.saturating_add(u64::try_from(additional_len).unwrap_or(u64::MAX));
    if attempted > MAX_STREAMING_JOURNAL_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "streaming journal exceeds {} byte limit (attempted {} bytes)",
                MAX_STREAMING_JOURNAL_BYTES, attempted
            ),
        ));
    }
    Ok(())
}

fn ensure_recovered_size_budget(
    current_len: usize,
    additional_len: usize,
    max_len: usize,
    field: &'static str,
) -> io::Result<()> {
    let attempted = current_len.saturating_add(additional_len);
    if attempted > max_len {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "streaming journal recovered {field} exceeds {max_len} byte limit (attempted {attempted} bytes)"
            ),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
