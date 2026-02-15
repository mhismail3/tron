use chrono::Utc;
use serde::{Deserialize, Serialize};

use tron_core::ids::{SessionId, WorkspaceId};

use crate::database::Database;
use crate::error::StoreError;

/// A memory ledger entry.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MemoryEntry {
    pub id: String,
    pub workspace_id: WorkspaceId,
    pub session_id: Option<SessionId>,
    pub title: String,
    pub content: String,
    pub tokens: i64,
    pub created_at: String,
    pub source: MemorySource,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemorySource {
    Auto,
    Manual,
    Backfill,
}

impl std::fmt::Display for MemorySource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Auto => write!(f, "auto"),
            Self::Manual => write!(f, "manual"),
            Self::Backfill => write!(f, "backfill"),
        }
    }
}

impl std::str::FromStr for MemorySource {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "auto" => Ok(Self::Auto),
            "manual" => Ok(Self::Manual),
            "backfill" => Ok(Self::Backfill),
            other => Err(format!("unknown memory source: {other}")),
        }
    }
}

pub struct MemoryRepo {
    db: Database,
}

impl MemoryRepo {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Add a memory entry.
    pub fn add(
        &self,
        workspace_id: &WorkspaceId,
        session_id: Option<&SessionId>,
        title: &str,
        content: &str,
        tokens: i64,
        source: MemorySource,
    ) -> Result<MemoryEntry, StoreError> {
        let id = uuid::Uuid::now_v7().to_string();
        let now = Utc::now().to_rfc3339();

        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO memory_entries (id, workspace_id, session_id, title, content, tokens, created_at, source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                rusqlite::params![
                    id,
                    workspace_id.as_str(),
                    session_id.map(|s| s.as_str().to_string()),
                    title,
                    content,
                    tokens,
                    now,
                    source.to_string(),
                ],
            )?;

            Ok(MemoryEntry {
                id,
                workspace_id: workspace_id.clone(),
                session_id: session_id.cloned(),
                title: title.to_string(),
                content: content.to_string(),
                tokens,
                created_at: now,
                source,
            })
        })
    }

    /// Get a memory entry by ID.
    pub fn get(&self, id: &str) -> Result<MemoryEntry, StoreError> {
        self.db.with_conn(|conn| {
            conn.query_row(
                "SELECT id, workspace_id, session_id, title, content, tokens, created_at, source
                 FROM memory_entries WHERE id = ?1",
                [id],
                |row| Ok(row_to_entry(row)),
            )
            .map_err(|_| StoreError::NotFound(format!("memory entry {id}")))
        })
    }

    /// List all memory entries for a workspace.
    pub fn list_for_workspace(
        &self,
        workspace_id: &WorkspaceId,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<MemoryEntry>, StoreError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, workspace_id, session_id, title, content, tokens, created_at, source
                 FROM memory_entries WHERE workspace_id = ?1
                 ORDER BY created_at DESC
                 LIMIT ?2 OFFSET ?3",
            )?;
            let rows = stmt
                .query_map(
                    rusqlite::params![workspace_id.as_str(), limit, offset],
                    |row| Ok(row_to_entry(row)),
                )?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }

    /// List memory entries for a specific session.
    pub fn list_for_session(
        &self,
        session_id: &SessionId,
    ) -> Result<Vec<MemoryEntry>, StoreError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, workspace_id, session_id, title, content, tokens, created_at, source
                 FROM memory_entries WHERE session_id = ?1
                 ORDER BY created_at ASC",
            )?;
            let rows = stmt
                .query_map([session_id.as_str()], |row| Ok(row_to_entry(row)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }

    /// Keyword search across memory entries for a workspace.
    pub fn search(
        &self,
        workspace_id: &WorkspaceId,
        query: &str,
        limit: u32,
    ) -> Result<Vec<MemoryEntry>, StoreError> {
        self.db.with_conn(|conn| {
            let pattern = format!("%{query}%");
            let mut stmt = conn.prepare(
                "SELECT id, workspace_id, session_id, title, content, tokens, created_at, source
                 FROM memory_entries
                 WHERE workspace_id = ?1 AND (title LIKE ?2 OR content LIKE ?2)
                 ORDER BY created_at DESC
                 LIMIT ?3",
            )?;
            let rows = stmt
                .query_map(
                    rusqlite::params![workspace_id.as_str(), pattern, limit],
                    |row| Ok(row_to_entry(row)),
                )?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }

    /// Delete a memory entry.
    pub fn delete(&self, id: &str) -> Result<(), StoreError> {
        self.db.with_conn(|conn| {
            let rows = conn.execute("DELETE FROM memory_entries WHERE id = ?1", [id])?;
            if rows == 0 {
                return Err(StoreError::NotFound(format!("memory entry {id}")));
            }
            Ok(())
        })
    }

    /// Count memory entries for a workspace.
    pub fn count(&self, workspace_id: &WorkspaceId) -> Result<i64, StoreError> {
        self.db.with_conn(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM memory_entries WHERE workspace_id = ?1",
                [workspace_id.as_str()],
                |row| row.get(0),
            )
            .map_err(|e| StoreError::Database(e.to_string()))
        })
    }

    /// Compose memory content for context injection.
    /// Combines all workspace memories + session-specific memories.
    pub fn compose_for_context(
        &self,
        workspace_id: &WorkspaceId,
        session_id: Option<&SessionId>,
    ) -> Result<String, StoreError> {
        let workspace_entries = self.list_for_workspace(workspace_id, 100, 0)?;

        let session_entries = match session_id {
            Some(sid) => self.list_for_session(sid)?,
            None => vec![],
        };

        let mut parts = Vec::new();

        // Workspace-level memories
        for entry in &workspace_entries {
            // Skip session-specific entries (they'll be in the session section)
            if entry.session_id.is_some() {
                continue;
            }
            parts.push(format!("### {}\n{}", entry.title, entry.content));
        }

        // Session-specific memories
        if !session_entries.is_empty() {
            parts.push("\n## New memories from this session\n".to_string());
            for entry in &session_entries {
                parts.push(format!("### {}\n{}", entry.title, entry.content));
            }
        }

        Ok(parts.join("\n\n"))
    }
}

fn row_to_entry(row: &rusqlite::Row<'_>) -> MemoryEntry {
    MemoryEntry {
        id: row.get(0).unwrap(),
        workspace_id: WorkspaceId::from_raw(row.get::<_, String>(1).unwrap()),
        session_id: row
            .get::<_, Option<String>>(2)
            .unwrap()
            .map(SessionId::from_raw),
        title: row.get(3).unwrap(),
        content: row.get(4).unwrap(),
        tokens: row.get(5).unwrap(),
        created_at: row.get(6).unwrap(),
        source: row
            .get::<_, String>(7)
            .unwrap()
            .parse()
            .unwrap_or(MemorySource::Auto),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::SessionRepo;
    use crate::workspaces::WorkspaceRepo;

    fn setup() -> (Database, WorkspaceId) {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        (db, ws.id)
    }

    fn setup_with_session() -> (Database, WorkspaceId, SessionId) {
        let (db, ws_id) = setup();
        let sess_repo = SessionRepo::new(db.clone());
        let session = sess_repo
            .create(&ws_id, "claude-opus-4-6", "anthropic", "/tmp")
            .unwrap();
        (db, ws_id, session.id)
    }

    #[test]
    fn add_and_get_memory() {
        let (db, ws_id) = setup();
        let repo = MemoryRepo::new(db);

        let entry = repo
            .add(&ws_id, None, "Test Pattern", "Always use X for Y", 10, MemorySource::Auto)
            .unwrap();

        let fetched = repo.get(&entry.id).unwrap();
        assert_eq!(fetched.title, "Test Pattern");
        assert_eq!(fetched.content, "Always use X for Y");
        assert_eq!(fetched.source, MemorySource::Auto);
        assert!(fetched.session_id.is_none());
    }

    #[test]
    fn add_with_session() {
        let (db, ws_id, sess_id) = setup_with_session();
        let repo = MemoryRepo::new(db);

        let entry = repo
            .add(
                &ws_id,
                Some(&sess_id),
                "Session Memory",
                "Learned X during this session",
                15,
                MemorySource::Manual,
            )
            .unwrap();

        assert_eq!(entry.session_id.as_ref().unwrap(), &sess_id);
    }

    #[test]
    fn list_for_workspace() {
        let (db, ws_id) = setup();
        let repo = MemoryRepo::new(db);

        repo.add(&ws_id, None, "A", "content a", 5, MemorySource::Auto).unwrap();
        repo.add(&ws_id, None, "B", "content b", 5, MemorySource::Auto).unwrap();
        repo.add(&ws_id, None, "C", "content c", 5, MemorySource::Manual).unwrap();

        let entries = repo.list_for_workspace(&ws_id, 100, 0).unwrap();
        assert_eq!(entries.len(), 3);
    }

    #[test]
    fn list_for_workspace_pagination() {
        let (db, ws_id) = setup();
        let repo = MemoryRepo::new(db);

        for i in 0..5 {
            repo.add(&ws_id, None, &format!("Entry {i}"), "content", 5, MemorySource::Auto)
                .unwrap();
        }

        let page1 = repo.list_for_workspace(&ws_id, 2, 0).unwrap();
        assert_eq!(page1.len(), 2);
        let page2 = repo.list_for_workspace(&ws_id, 2, 2).unwrap();
        assert_eq!(page2.len(), 2);
        let page3 = repo.list_for_workspace(&ws_id, 2, 4).unwrap();
        assert_eq!(page3.len(), 1);
    }

    #[test]
    fn list_for_session() {
        let (db, ws_id, sess_id) = setup_with_session();
        let repo = MemoryRepo::new(db);

        // Workspace-level entry
        repo.add(&ws_id, None, "Global", "global content", 5, MemorySource::Auto)
            .unwrap();
        // Session-level entries
        repo.add(&ws_id, Some(&sess_id), "Session A", "session a", 5, MemorySource::Auto)
            .unwrap();
        repo.add(&ws_id, Some(&sess_id), "Session B", "session b", 5, MemorySource::Auto)
            .unwrap();

        let session_entries = repo.list_for_session(&sess_id).unwrap();
        assert_eq!(session_entries.len(), 2);
    }

    #[test]
    fn keyword_search() {
        let (db, ws_id) = setup();
        let repo = MemoryRepo::new(db);

        repo.add(&ws_id, None, "Rust Pattern", "Use Arc<Mutex> for shared state", 10, MemorySource::Auto)
            .unwrap();
        repo.add(&ws_id, None, "Python Tip", "Use dataclasses for DTOs", 10, MemorySource::Auto)
            .unwrap();
        repo.add(&ws_id, None, "Rust Error", "Use thiserror for custom errors", 10, MemorySource::Auto)
            .unwrap();

        // Search by title keyword
        let results = repo.search(&ws_id, "Rust", 10).unwrap();
        assert_eq!(results.len(), 2);

        // Search by content keyword
        let results = repo.search(&ws_id, "dataclasses", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "Python Tip");

        // Search with no matches
        let results = repo.search(&ws_id, "nonexistent", 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn delete_memory() {
        let (db, ws_id) = setup();
        let repo = MemoryRepo::new(db);

        let entry = repo
            .add(&ws_id, None, "To Delete", "content", 5, MemorySource::Auto)
            .unwrap();
        repo.delete(&entry.id).unwrap();
        assert!(repo.get(&entry.id).is_err());
    }

    #[test]
    fn delete_nonexistent_fails() {
        let (db, _) = setup();
        let repo = MemoryRepo::new(db);
        assert!(repo.delete("nonexistent-id").is_err());
    }

    #[test]
    fn count_memories() {
        let (db, ws_id) = setup();
        let repo = MemoryRepo::new(db);

        assert_eq!(repo.count(&ws_id).unwrap(), 0);

        repo.add(&ws_id, None, "A", "a", 5, MemorySource::Auto).unwrap();
        repo.add(&ws_id, None, "B", "b", 5, MemorySource::Manual).unwrap();

        assert_eq!(repo.count(&ws_id).unwrap(), 2);
    }

    #[test]
    fn compose_for_context() {
        let (db, ws_id, sess_id) = setup_with_session();
        let repo = MemoryRepo::new(db);

        // Workspace-level memories
        repo.add(&ws_id, None, "Global Pattern", "Use X for Y", 10, MemorySource::Auto)
            .unwrap();

        // Session-level memories
        repo.add(
            &ws_id,
            Some(&sess_id),
            "Session Discovery",
            "Found that Z works best",
            10,
            MemorySource::Auto,
        )
        .unwrap();

        let context = repo.compose_for_context(&ws_id, Some(&sess_id)).unwrap();
        assert!(context.contains("Global Pattern"));
        assert!(context.contains("Use X for Y"));
        assert!(context.contains("New memories from this session"));
        assert!(context.contains("Session Discovery"));
        assert!(context.contains("Found that Z works best"));
    }

    #[test]
    fn compose_without_session() {
        let (db, ws_id) = setup();
        let repo = MemoryRepo::new(db);

        repo.add(&ws_id, None, "Pattern", "content", 10, MemorySource::Auto)
            .unwrap();

        let context = repo.compose_for_context(&ws_id, None).unwrap();
        assert!(context.contains("Pattern"));
        assert!(!context.contains("New memories from this session"));
    }

    #[test]
    fn memory_source_serde() {
        for source in [MemorySource::Auto, MemorySource::Manual, MemorySource::Backfill] {
            let s = source.to_string();
            let parsed: MemorySource = s.parse().unwrap();
            assert_eq!(source, parsed);
        }
    }
}
