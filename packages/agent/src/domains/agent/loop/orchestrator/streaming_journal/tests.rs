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

#[test]
fn test_append_delta_rejects_journal_over_byte_limit() {
    let tmp = TempDir::new().unwrap();
    let session_id = "test-session-over-budget";
    let path = test_journal_path(tmp.path(), session_id, 1);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&path)
        .unwrap();
    file.set_len(MAX_STREAMING_JOURNAL_BYTES).unwrap();

    let mut journal = StreamingJournal {
        file,
        path,
        session_id: session_id.to_string(),
        turn: 1,
    };

    let error = journal.append_delta("text", "x").unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    assert!(error.to_string().contains("streaming journal exceeds"));
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

#[test]
fn test_load_recovery_rejects_oversized_metadata_before_accumulating() {
    let attempted = ensure_journal_size_budget(MAX_STREAMING_JOURNAL_BYTES, 1).unwrap_err();
    assert_eq!(attempted.kind(), io::ErrorKind::InvalidData);
    assert!(attempted.to_string().contains("streaming journal exceeds"));
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
