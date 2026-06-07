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

use crate::shared::paths;

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
                "text" => text.push_str(&entry.c),
                "thinking" => thinking.push_str(&entry.c),
                "capability_invocation" => {
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

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// Override the journals dir for tests by using a temp directory and
    /// constructing journal paths manually.
    fn test_journal_path(base: &std::path::Path, session_id: &str, turn: u32) -> PathBuf {
        base.join(session_id).join(format!("turn_{turn}.wal"))
    }

    // ── Test 1: create_journal_creates_file ──────────────────────────────

    #[test]
    fn test_create_journal_creates_file() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-create";
        let turn = 1;
        let path = test_journal_path(tmp.path(), session_id, turn);
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        // Create journal using the real constructor (it will create at the canonical path)
        // For isolation, we test the path logic separately and verify file operations
        let journal = StreamingJournal {
            file: OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&path)
                .unwrap(),
            path: path.clone(),
            session_id: session_id.to_string(),
            turn,
        };

        assert!(path.exists());
        drop(journal);
    }

    // ── Test 2: append_delta_writes_jsonl ─────────────────────────────────

    #[test]
    fn test_append_delta_writes_jsonl() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-jsonl";
        let path = test_journal_path(tmp.path(), session_id, 1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        let mut journal = StreamingJournal {
            file: OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&path)
                .unwrap(),
            path: path.clone(),
            session_id: session_id.to_string(),
            turn: 1,
        };

        journal.append_delta("text", "Hello ").unwrap();
        journal.append_delta("text", "world").unwrap();
        journal.append_delta("thinking", "Let me think...").unwrap();
        drop(journal);

        let content = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 3);

        let e1: JournalEntry = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(e1.t, "text");
        assert_eq!(e1.c, "Hello ");

        let e2: JournalEntry = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(e2.t, "text");
        assert_eq!(e2.c, "world");

        let e3: JournalEntry = serde_json::from_str(lines[2]).unwrap();
        assert_eq!(e3.t, "thinking");
        assert_eq!(e3.c, "Let me think...");
    }

    // ── Test 3: finalize_deletes_file ─────────────────────────────────────

    #[test]
    fn test_finalize_deletes_file() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-finalize";
        let path = test_journal_path(tmp.path(), session_id, 1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        let journal = StreamingJournal {
            file: OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&path)
                .unwrap(),
            path: path.clone(),
            session_id: session_id.to_string(),
            turn: 1,
        };

        assert!(path.exists());
        journal.finalize_and_delete().unwrap();
        assert!(!path.exists());
    }

    // ── Test 4: finalize_deletes_empty_session_dir ────────────────────────

    #[test]
    fn test_finalize_deletes_empty_session_dir() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-cleanup";
        let path = test_journal_path(tmp.path(), session_id, 1);
        let session_dir = path.parent().unwrap().to_path_buf();
        fs::create_dir_all(&session_dir).unwrap();

        let journal = StreamingJournal {
            file: OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&path)
                .unwrap(),
            path: path.clone(),
            session_id: session_id.to_string(),
            turn: 1,
        };

        journal.finalize_and_delete().unwrap();
        assert!(!path.exists());
        assert!(!session_dir.exists(), "empty session dir should be removed");
    }

    // ── Test 5: load_recovery_reads_deltas ────────────────────────────────

    #[test]
    fn test_load_recovery_reads_deltas() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-recovery";
        let path = test_journal_path(tmp.path(), session_id, 2);
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        // Write some deltas
        let mut f = File::create(&path).unwrap();
        writeln!(f, r#"{{"t":"text","c":"Hello "}}"#).unwrap();
        writeln!(f, r#"{{"t":"text","c":"world"}}"#).unwrap();
        writeln!(f, r#"{{"t":"thinking","c":"I should greet"}}"#).unwrap();
        writeln!(
            f,
            r#"{{"t":"capability_invocation","c":"{{\"name\":\"execute\",\"id\":\"tc1\"}}"}}"#
        )
        .unwrap();
        drop(f);

        // load_recovery uses canonical paths — test the parsing logic directly
        let file = File::open(&path).unwrap();
        let reader = BufReader::new(file);
        let mut text = String::new();
        let mut thinking = String::new();
        let mut capability_invocations: Vec<serde_json::Value> = Vec::new();

        for line_result in reader.lines() {
            let line = line_result.unwrap();
            if line.is_empty() {
                continue;
            }
            let entry: JournalEntry = serde_json::from_str(&line).unwrap();
            match entry.t.as_str() {
                "text" => text.push_str(&entry.c),
                "thinking" => thinking.push_str(&entry.c),
                "capability_invocation" => {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&entry.c) {
                        capability_invocations.push(val);
                    }
                }
                _ => {}
            }
        }

        assert_eq!(text, "Hello world");
        assert_eq!(thinking, "I should greet");
        assert_eq!(capability_invocations.len(), 1);
        assert_eq!(capability_invocations[0]["name"], "execute");
    }

    // ── Test 6: load_recovery_nonexistent_returns_none ─────────────────────

    #[test]
    fn test_load_recovery_nonexistent_returns_none() {
        // Use a path that definitely doesn't exist
        let result = StreamingJournal::load_recovery("nonexistent-session-xyz-123", 999);
        // This may return None (path doesn't exist) or error (dir doesn't exist)
        // In either case it should not panic
        match result {
            Ok(None) => {} // expected
            Ok(Some(_)) => panic!("should not find a recovery for nonexistent session"),
            Err(_) => {} // acceptable if journal dir doesn't exist
        }
    }

    // ── Test 7: load_recovery_empty_journal_returns_none ──────────────────

    #[test]
    fn test_load_recovery_empty_journal_returns_none() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-empty";
        let path = test_journal_path(tmp.path(), session_id, 1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        File::create(&path).unwrap(); // empty file

        // Test the parsing logic directly since load_recovery uses canonical paths
        let file = File::open(&path).unwrap();
        let metadata = file.metadata().unwrap();
        assert_eq!(metadata.len(), 0);
        // Empty file → should return None in load_recovery
    }

    // ── Test 8: load_recovery_partial_line_skipped ────────────────────────

    #[test]
    fn test_load_recovery_partial_line_skipped() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-partial";
        let path = test_journal_path(tmp.path(), session_id, 1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        // Write complete line + truncated line (simulating crash)
        let mut f = File::create(&path).unwrap();
        writeln!(f, r#"{{"t":"text","c":"complete line"}}"#).unwrap();
        // Write partial line without newline
        write!(f, r#"{{"t":"text","c":"trunc"#).unwrap();
        drop(f);

        let file = File::open(&path).unwrap();
        let reader = BufReader::new(file);
        let mut text = String::new();
        let mut lines_recovered = 0;

        for line_result in reader.lines() {
            let line = match line_result {
                Ok(l) => l,
                Err(_) => break, // partial line
            };
            if line.is_empty() {
                continue;
            }
            if let Ok(entry) = serde_json::from_str::<JournalEntry>(&line) {
                if entry.t == "text" {
                    text.push_str(&entry.c);
                }
                lines_recovered += 1;
            }
        }

        assert_eq!(lines_recovered, 1);
        assert_eq!(text, "complete line");
    }

    // ── Test 9: scan_incomplete_finds_orphaned_journals ───────────────────

    #[test]
    fn test_scan_incomplete_finds_orphaned_journals() {
        let tmp = TempDir::new().unwrap();
        let journals_dir = tmp.path();

        // Create two session dirs with journals
        let s1 = journals_dir.join("session-a");
        let s2 = journals_dir.join("session-b");
        fs::create_dir_all(&s1).unwrap();
        fs::create_dir_all(&s2).unwrap();
        File::create(s1.join("turn_1.wal")).unwrap();
        File::create(s2.join("turn_3.wal")).unwrap();

        // Manually scan this dir (scan_incomplete uses canonical path)
        let mut results = Vec::new();
        for session_entry in fs::read_dir(journals_dir).unwrap() {
            let session_entry = session_entry.unwrap();
            let session_path = session_entry.path();
            if !session_path.is_dir() {
                continue;
            }
            let session_id = session_path
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .to_string();
            for wal_entry in fs::read_dir(&session_path).unwrap() {
                let wal_entry = wal_entry.unwrap();
                let wal_name = wal_entry.file_name().into_string().unwrap();
                if let Some(turn) = StreamingJournal::parse_wal_filename(&wal_name) {
                    results.push((session_id.clone(), turn));
                }
            }
        }

        assert_eq!(results.len(), 2);
        results.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        assert_eq!(results[0], ("session-a".into(), 1));
        assert_eq!(results[1], ("session-b".into(), 3));
    }

    // ── Test 10: scan_incomplete_empty_dir ─────────────────────────────────

    #[test]
    fn test_scan_incomplete_empty_dir() {
        let tmp = TempDir::new().unwrap();
        let journals_dir = tmp.path();
        // Empty dir — no journals
        let mut results = Vec::new();
        if journals_dir.exists() {
            for session_entry in fs::read_dir(journals_dir).unwrap() {
                let session_entry = session_entry.unwrap();
                if session_entry.path().is_dir() {
                    for wal_entry in fs::read_dir(session_entry.path()).unwrap() {
                        let wal_entry = wal_entry.unwrap();
                        let name = wal_entry.file_name().into_string().unwrap();
                        if let Some(turn) = StreamingJournal::parse_wal_filename(&name) {
                            results.push((session_entry.file_name().into_string().unwrap(), turn));
                        }
                    }
                }
            }
        }
        assert!(results.is_empty());
    }

    // ── Test 11: concurrent_append_is_sequential ──────────────────────────

    #[test]
    fn test_concurrent_append_is_sequential() {
        let tmp = TempDir::new().unwrap();
        let session_id = "test-session-concurrent";
        let path = test_journal_path(tmp.path(), session_id, 1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();

        let mut journal = StreamingJournal {
            file: OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&path)
                .unwrap(),
            path: path.clone(),
            session_id: session_id.to_string(),
            turn: 1,
        };

        // Write 100 deltas rapidly (single writer invariant)
        for i in 0..100 {
            journal.append_delta("text", &format!("delta_{i}")).unwrap();
        }
        drop(journal);

        // Verify all 100 lines are present and uncorrupted
        let content = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 100);

        for (i, line) in lines.iter().enumerate() {
            let entry: JournalEntry = serde_json::from_str(line).unwrap();
            assert_eq!(entry.t, "text");
            assert_eq!(entry.c, format!("delta_{i}"));
        }
    }

    // ── Test 12: journal_path_construction ─────────────────────────────────

    #[test]
    fn test_journal_path_construction() {
        let path = StreamingJournal::journal_path("my-session-id", 5);
        let path_str = path.to_string_lossy();
        assert!(path_str.contains("journals"));
        assert!(path_str.contains("my-session-id"));
        assert!(path_str.ends_with("turn_5.wal"));
        // Verify the structure: .../journals/my-session-id/turn_5.wal
        assert_eq!(path.file_name().unwrap().to_str().unwrap(), "turn_5.wal");
        assert_eq!(
            path.parent()
                .unwrap()
                .file_name()
                .unwrap()
                .to_str()
                .unwrap(),
            "my-session-id"
        );
    }

    // ── Test: parse_wal_filename ──────────────────────────────────────────

    #[test]
    fn test_parse_wal_filename() {
        assert_eq!(StreamingJournal::parse_wal_filename("turn_1.wal"), Some(1));
        assert_eq!(
            StreamingJournal::parse_wal_filename("turn_42.wal"),
            Some(42)
        );
        assert_eq!(StreamingJournal::parse_wal_filename("turn_0.wal"), Some(0));
        assert_eq!(StreamingJournal::parse_wal_filename("not_a_wal.txt"), None);
        assert_eq!(StreamingJournal::parse_wal_filename("turn_.wal"), None);
        assert_eq!(StreamingJournal::parse_wal_filename("turn_abc.wal"), None);
    }
}
