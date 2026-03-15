//! LEDGER.jsonl import and memory embedding.
//!
//! Provides two operations:
//! - **Import**: Parse `~/.claude/LEDGER.jsonl` → `memory.ledger` events (idempotent)
//! - **Embed**: Generate vector embeddings for unembedded `memory.ledger` events
//!
//! Used by:
//! - `tron backfill-ledger` CLI subcommand (manual bulk operations)
//! - Server startup (auto-embeds unembedded events after ONNX model loads)

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use tracing::info;

use crate::events::{AppendOptions, EventStore, EventType};

// ─── LEDGER.jsonl types ──────────────────────────────────────────────────────

#[derive(serde::Deserialize)]
struct LedgerEntry {
    _meta: LedgerMeta,
    front: LedgerFront,
    body: LedgerBody,
    #[serde(rename = "history")]
    _history: Option<LedgerHistory>,
}

#[derive(serde::Deserialize)]
struct LedgerHistory {
    #[serde(rename = "embedded")]
    _embedded: Option<bool>,
}

#[derive(serde::Deserialize)]
struct LedgerMeta {
    id: String,
    ts: String,
    #[serde(rename = "v")]
    _v: u32,
}

#[derive(serde::Deserialize)]
struct LedgerFront {
    #[serde(rename = "project")]
    _project: Option<String>,
    path: Option<String>,
    title: Option<String>,
    #[serde(rename = "type")]
    entry_type: Option<String>,
    status: Option<String>,
    tags: Option<Vec<String>>,
}

#[derive(serde::Deserialize)]
struct LedgerBody {
    input: Option<String>,
    actions: Option<Vec<String>>,
    #[serde(rename = "files")]
    _files: Option<serde_json::Value>,
    decisions: Option<Vec<serde_json::Value>>,
    lessons: Option<Vec<String>>,
}

// ─── Database helpers ────────────────────────────────────────────────────────

fn default_db_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".tron")
        .join("database")
        .join("tron.db")
}

/// Open an event store, creating the database and running migrations if needed.
pub fn open_store(
    db_path_override: Option<PathBuf>,
) -> Result<(Arc<EventStore>, PathBuf)> {
    let db_path = db_path_override.unwrap_or_else(default_db_path);
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
    }
    let db_str = db_path.to_string_lossy();
    let pool = crate::events::new_file(&db_str, &crate::events::ConnectionConfig::default())
        .context("Failed to open database")?;
    {
        let conn = pool.get().context("Failed to get DB connection")?;
        let _ = crate::events::run_migrations(&conn).context("Failed to run migrations")?;
    }
    Ok((Arc::new(EventStore::new(pool)), db_path))
}

/// Check if a ledger entry with the given meta ID already exists.
fn has_ledger_entry(store: &EventStore, meta_id: &str) -> bool {
    let Ok(conn) = store.pool().get() else {
        return false;
    };
    let id_pattern = format!("%\"id\":\"{meta_id}\"%");
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM events WHERE type = 'memory.ledger' \
             AND payload LIKE '%\"source\":\"ledger.jsonl\"%' \
             AND payload LIKE ?1 \
             LIMIT 1",
            [&id_pattern],
            |r| r.get(0),
        )
        .unwrap_or(0);
    count > 0
}

// ─── Import ──────────────────────────────────────────────────────────────────

/// Import LEDGER.jsonl entries as `memory.ledger` events. Idempotent.
pub fn run_import(
    store: &EventStore,
    ledger_path: &Path,
    project_filter: Option<&str>,
    dry_run: bool,
) -> Result<()> {
    use std::io::BufRead;

    let file = std::fs::File::open(ledger_path)
        .with_context(|| format!("Failed to open {}", ledger_path.display()))?;
    let reader = std::io::BufReader::new(file);

    let mut total = 0u64;
    let mut imported = 0u64;
    let mut skipped_filter = 0u64;
    let mut skipped_exists = 0u64;
    let mut parse_errors = 0u64;

    let mut workspace_sessions: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();

    for line in reader.lines() {
        let line = line.context("Failed to read LEDGER line")?;
        if line.trim().is_empty() {
            continue;
        }
        total += 1;

        let entry: LedgerEntry = match serde_json::from_str(&line) {
            Ok(e) => e,
            Err(e) => {
                parse_errors += 1;
                eprintln!("[backfill] parse error on line {total}: {e}");
                continue;
            }
        };

        if let Some(filter) = project_filter {
            let path = entry.front.path.as_deref().unwrap_or("");
            if !path.starts_with(filter) {
                skipped_filter += 1;
                continue;
            }
        }

        if !dry_run && has_ledger_entry(store, &entry._meta.id) {
            skipped_exists += 1;
            continue;
        }

        if dry_run {
            imported += 1;
            continue;
        }

        let workspace_path = entry
            .front
            .path
            .as_deref()
            .unwrap_or("/tmp/backfill")
            .to_string();
        let session_id = if let Some(sid) = workspace_sessions.get(&workspace_path) {
            sid.clone()
        } else {
            let title = format!(
                "Backfill: {}",
                entry.front.path.as_deref().unwrap_or("unknown")
            );
            let result = store
                .create_session("backfill", &workspace_path, Some(&title), None, None)
                .context("Failed to create backfill session")?;
            let sid = result.session.id.clone();
            let _ = workspace_sessions.insert(workspace_path, sid.clone());
            sid
        };

        let payload = serde_json::json!({
            "title": entry.front.title,
            "input": entry.body.input,
            "actions": entry.body.actions,
            "lessons": entry.body.lessons,
            "decisions": entry.body.decisions,
            "tags": entry.front.tags,
            "entryType": entry.front.entry_type,
            "status": entry.front.status,
            "timestamp": entry._meta.ts,
            "_meta": {
                "source": "ledger.jsonl",
                "id": entry._meta.id
            }
        });

        let _ = store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::MemoryLedger,
                payload,
                parent_id: None,
            })
            .with_context(|| format!("Failed to append ledger entry {}", entry._meta.id))?;

        imported += 1;
    }

    // End all backfill sessions so they don't appear in the session list.
    for sid in workspace_sessions.values() {
        let _ = store.end_session(sid);
    }

    println!(
        "Import complete: {imported} imported, {skipped_filter} filtered, \
         {skipped_exists} already existed, {parse_errors} parse errors (of {total} total)"
    );

    if dry_run {
        println!("(dry run — no changes written)");
    }

    Ok(())
}

// ─── Embed ───────────────────────────────────────────────────────────────────

/// Find unembedded `memory.ledger` events in the database.
pub fn find_unembedded(store: &EventStore) -> Vec<(String, String, String)> {
    let Ok(conn) = store.pool().get() else {
        return Vec::new();
    };
    let Ok(mut stmt) = conn.prepare(
        "SELECT e.id, e.payload, COALESCE(w.path, '') as workspace_path \
         FROM events e \
         LEFT JOIN sessions s ON e.session_id = s.id \
         LEFT JOIN workspaces w ON s.workspace_id = w.id \
         LEFT JOIN memory_vectors mv ON e.id = mv.event_id \
         WHERE e.type = 'memory.ledger' AND mv.id IS NULL",
    ) else {
        return Vec::new();
    };
    stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })
    .map(|iter| iter.filter_map(std::result::Result::ok).collect())
    .unwrap_or_default()
}

/// Convert raw DB rows to `BackfillEntry` values for the embedding controller.
pub fn to_backfill_entries(
    rows: Vec<(String, String, String)>,
) -> Vec<crate::embeddings::BackfillEntry> {
    rows.into_iter()
        .filter_map(|(event_id, payload_str, workspace_id)| {
            let payload: serde_json::Value = serde_json::from_str(&payload_str).ok()?;
            Some(crate::embeddings::BackfillEntry {
                event_id,
                workspace_id,
                payload,
            })
        })
        .collect()
}

/// Embed all unembedded `memory.ledger` events. Optionally force-recreate vectors.
pub async fn run_embed(
    store: &EventStore,
    db_path: &Path,
    force: bool,
) -> Result<()> {
    let settings = crate::settings::get_settings();
    let config =
        crate::embeddings::EmbeddingConfig::from_settings(&settings.context.memory.embedding);

    let conn = rusqlite::Connection::open(db_path).context("Failed to open DB for vector repo")?;
    conn.execute_batch("PRAGMA busy_timeout = 5000;")
        .context("Failed to set busy timeout")?;
    let repo = crate::embeddings::VectorRepository::new(conn, config.dimensions);
    repo.ensure_table()?;

    if force {
        info!("Force mode: dropping and recreating memory_vectors table");
        repo.drop_and_recreate()?;
    }

    let unembedded = find_unembedded(store);

    if unembedded.is_empty() {
        println!("No unembedded memory.ledger events found.");
        return Ok(());
    }

    println!(
        "Found {} unembedded events. Initializing ONNX model...",
        unembedded.len()
    );

    let ort_service = Arc::new(crate::embeddings::OnnxEmbeddingService::new(config.clone()));
    ort_service.initialize().await?;

    let repo = Arc::new(parking_lot::Mutex::new(repo));
    let mut controller = crate::embeddings::EmbeddingController::new(config);
    controller.set_service(ort_service);
    controller.set_vector_repo(repo);

    let entries = to_backfill_entries(unembedded);

    println!("Embedding {} entries...", entries.len());
    let result = controller.backfill(entries).await?;

    println!(
        "Embed complete: {} succeeded, {} skipped, {} failed",
        result.succeeded, result.skipped, result.failed
    );

    Ok(())
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ledger_entry() {
        let json = r#"{"_meta":{"id":"abc-123","ts":"2026-01-01T00:00:00Z","v":1},"front":{"project":"tron","path":"/tmp/tron","title":"Test entry","type":"feature","status":"completed","tags":["test"]},"body":{"input":"do something","actions":["did it"],"files":[],"decisions":[],"lessons":["learned thing"]},"history":{"embedded":false}}"#;
        let entry: LedgerEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry._meta.id, "abc-123");
        assert_eq!(entry.front.title.as_deref(), Some("Test entry"));
        assert_eq!(entry.body.lessons.as_ref().unwrap()[0], "learned thing");
    }

    #[tokio::test]
    async fn import_dry_run_no_writes() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("tron.db");
        let ledger_path = dir.path().join("LEDGER.jsonl");
        std::fs::write(
            &ledger_path,
            r#"{"_meta":{"id":"id-1","ts":"2026-01-01T00:00:00Z","v":1},"front":{"project":"test","path":"/tmp","title":"Entry 1","type":"feature","status":"completed","tags":[]},"body":{"input":"req","actions":["did"],"files":[],"decisions":[],"lessons":["lesson"]},"history":{"embedded":false}}"#,
        )
        .unwrap();

        let (store, _) = open_store(Some(db_path)).unwrap();
        run_import(&store, &ledger_path, None, true).unwrap();

        let conn = store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE type = 'memory.ledger'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn import_entries() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("tron.db");
        let ledger_path = dir.path().join("LEDGER.jsonl");
        std::fs::write(
            &ledger_path,
            concat!(
                r#"{"_meta":{"id":"id-1","ts":"2026-01-01T00:00:00Z","v":1},"front":{"project":"test","path":"/tmp/proj","title":"Entry 1","type":"feature","status":"completed","tags":["a"]},"body":{"input":"req1","actions":["a1"],"files":[],"decisions":[],"lessons":["l1"]},"history":{"embedded":false}}"#,
                "\n",
                r#"{"_meta":{"id":"id-2","ts":"2026-01-02T00:00:00Z","v":1},"front":{"project":"test","path":"/tmp/proj","title":"Entry 2","type":"bugfix","status":"completed","tags":["b"]},"body":{"input":"req2","actions":["a2"],"files":[],"decisions":[],"lessons":["l2"]},"history":{"embedded":false}}"#,
            ),
        )
        .unwrap();

        let (store, _) = open_store(Some(db_path)).unwrap();
        run_import(&store, &ledger_path, None, false).unwrap();

        let conn = store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE type = 'memory.ledger'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);
    }

    #[tokio::test]
    async fn import_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("tron.db");
        let ledger_path = dir.path().join("LEDGER.jsonl");
        let entry = r#"{"_meta":{"id":"id-unique","ts":"2026-01-01T00:00:00Z","v":1},"front":{"project":"test","path":"/tmp","title":"Test","type":"feature","status":"completed","tags":[]},"body":{"input":"req","actions":["a"],"files":[],"decisions":[],"lessons":["l"]},"history":{"embedded":false}}"#;
        std::fs::write(&ledger_path, entry).unwrap();

        let (store, _) = open_store(Some(db_path)).unwrap();
        run_import(&store, &ledger_path, None, false).unwrap();
        run_import(&store, &ledger_path, None, false).unwrap();

        let conn = store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE type = 'memory.ledger'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "second run should skip existing entry");
    }

    #[tokio::test]
    async fn import_project_filter() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("tron.db");
        let ledger_path = dir.path().join("LEDGER.jsonl");
        std::fs::write(
            &ledger_path,
            concat!(
                r#"{"_meta":{"id":"id-a","ts":"2026-01-01T00:00:00Z","v":1},"front":{"project":"tron","path":"/Users/moose/tron","title":"Match","type":"feature","status":"completed","tags":[]},"body":{"input":"r","actions":["a"],"files":[],"decisions":[],"lessons":["l"]},"history":{"embedded":false}}"#,
                "\n",
                r#"{"_meta":{"id":"id-b","ts":"2026-01-02T00:00:00Z","v":1},"front":{"project":"other","path":"/Users/moose/other","title":"No match","type":"feature","status":"completed","tags":[]},"body":{"input":"r","actions":["a"],"files":[],"decisions":[],"lessons":["l"]},"history":{"embedded":false}}"#,
            ),
        )
        .unwrap();

        let (store, _) = open_store(Some(db_path)).unwrap();
        run_import(&store, &ledger_path, Some("/Users/moose/tron"), false).unwrap();

        let conn = store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE type = 'memory.ledger'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "only matching entry should be imported");
    }
}
