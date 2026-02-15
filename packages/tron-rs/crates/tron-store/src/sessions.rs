use chrono::Utc;
use serde::{Deserialize, Serialize};
use tracing::instrument;

use tron_core::ids::{EventId, SessionId, WorkspaceId};
use tron_core::tokens::AccumulatedTokens;

use crate::database::Database;
use crate::error::StoreError;
use crate::row_helpers;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Active,
    Archived,
    Deleted,
}

impl std::fmt::Display for SessionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Active => write!(f, "active"),
            Self::Archived => write!(f, "archived"),
            Self::Deleted => write!(f, "deleted"),
        }
    }
}

impl std::str::FromStr for SessionStatus {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "active" => Ok(Self::Active),
            "archived" => Ok(Self::Archived),
            "deleted" => Ok(Self::Deleted),
            other => Err(format!("unknown session status: {other}")),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionRow {
    pub id: SessionId,
    pub workspace_id: WorkspaceId,
    pub head_event_id: Option<EventId>,
    pub root_event_id: Option<EventId>,
    pub status: SessionStatus,
    pub model: String,
    pub provider: String,
    pub working_directory: String,
    pub title: Option<String>,
    pub tokens: AccumulatedTokens,
    pub created_at: String,
    pub updated_at: String,
}

pub struct SessionRepo {
    db: Database,
}

impl SessionRepo {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Create a new session.
    #[instrument(skip(self), fields(workspace_id = %workspace_id, model, provider))]
    pub fn create(
        &self,
        workspace_id: &WorkspaceId,
        model: &str,
        provider: &str,
        working_directory: &str,
    ) -> Result<SessionRow, StoreError> {
        let id = SessionId::new();
        let now = Utc::now().to_rfc3339();

        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO sessions (id, workspace_id, status, model, provider, working_directory, created_at, updated_at)
                 VALUES (?1, ?2, 'active', ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![
                    id.as_str(),
                    workspace_id.as_str(),
                    model,
                    provider,
                    working_directory,
                    now,
                    now,
                ],
            )?;

            Ok(SessionRow {
                id,
                workspace_id: workspace_id.clone(),
                head_event_id: None,
                root_event_id: None,
                status: SessionStatus::Active,
                model: model.to_string(),
                provider: provider.to_string(),
                working_directory: working_directory.to_string(),
                title: None,
                tokens: AccumulatedTokens::default(),
                created_at: now.clone(),
                updated_at: now,
            })
        })
    }

    /// Get a session by ID.
    #[instrument(skip(self), fields(session_id = %id))]
    pub fn get(&self, id: &SessionId) -> Result<SessionRow, StoreError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, workspace_id, head_event_id, root_event_id, status, model, provider,
                        working_directory, title,
                        total_input_tokens, total_output_tokens, total_cache_read_tokens,
                        total_cache_creation_tokens, last_turn_input_tokens, total_cost_cents,
                        turn_count, created_at, updated_at
                 FROM sessions WHERE id = ?1",
            )?;
            let mut rows = stmt.query([id.as_str()])?;
            match rows.next()? {
                Some(row) => row_to_session(row),
                None => Err(StoreError::NotFound(format!("session {id}"))),
            }
        })
    }

    /// List sessions for a workspace, ordered by creation time (newest first).
    #[instrument(skip(self), fields(workspace_id = %workspace_id))]
    pub fn list(
        &self,
        workspace_id: &WorkspaceId,
        status: Option<&SessionStatus>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<SessionRow>, StoreError> {
        self.db.with_conn(|conn| {
            let (sql, params) = match status {
                Some(s) => (
                    "SELECT id, workspace_id, head_event_id, root_event_id, status, model, provider,
                            working_directory, title,
                            total_input_tokens, total_output_tokens, total_cache_read_tokens,
                            total_cache_creation_tokens, last_turn_input_tokens, total_cost_cents,
                            turn_count, created_at, updated_at
                     FROM sessions WHERE workspace_id = ?1 AND status = ?2
                     ORDER BY created_at DESC LIMIT ?3 OFFSET ?4",
                    vec![
                        workspace_id.as_str().to_string(),
                        s.to_string(),
                        limit.to_string(),
                        offset.to_string(),
                    ],
                ),
                None => (
                    "SELECT id, workspace_id, head_event_id, root_event_id, status, model, provider,
                            working_directory, title,
                            total_input_tokens, total_output_tokens, total_cache_read_tokens,
                            total_cache_creation_tokens, last_turn_input_tokens, total_cost_cents,
                            turn_count, created_at, updated_at
                     FROM sessions WHERE workspace_id = ?1
                     ORDER BY created_at DESC LIMIT ?2 OFFSET ?3",
                    vec![
                        workspace_id.as_str().to_string(),
                        limit.to_string(),
                        offset.to_string(),
                    ],
                ),
            };

            let mut stmt = conn.prepare(sql)?;
            let params_refs: Vec<&dyn rusqlite::types::ToSql> =
                params.iter().map(|p| p as &dyn rusqlite::types::ToSql).collect();
            let mut rows = stmt.query(params_refs.as_slice())?;
            let mut results = Vec::new();
            while let Some(row) = rows.next()? {
                results.push(row_to_session(row)?);
            }
            Ok(results)
        })
    }

    /// Update session head event (called atomically with event insert).
    #[instrument(skip(self), fields(session_id = %session_id))]
    pub fn update_head(
        &self,
        session_id: &SessionId,
        head_event_id: &EventId,
        root_event_id: Option<&EventId>,
    ) -> Result<(), StoreError> {
        self.db.with_conn(|conn| {
            let now = Utc::now().to_rfc3339();
            if let Some(root_id) = root_event_id {
                conn.execute(
                    "UPDATE sessions SET head_event_id = ?1, root_event_id = ?2, updated_at = ?3 WHERE id = ?4",
                    rusqlite::params![head_event_id.as_str(), root_id.as_str(), now, session_id.as_str()],
                )?;
            } else {
                conn.execute(
                    "UPDATE sessions SET head_event_id = ?1, updated_at = ?2 WHERE id = ?3",
                    rusqlite::params![head_event_id.as_str(), now, session_id.as_str()],
                )?;
            }
            Ok(())
        })
    }

    /// Update session token accumulators.
    #[instrument(skip(self, tokens), fields(session_id = %session_id))]
    pub fn update_tokens(
        &self,
        session_id: &SessionId,
        tokens: &AccumulatedTokens,
    ) -> Result<(), StoreError> {
        self.db.with_conn(|conn| {
            let now = Utc::now().to_rfc3339();
            conn.execute(
                "UPDATE sessions SET
                    total_input_tokens = ?1,
                    total_output_tokens = ?2,
                    total_cache_read_tokens = ?3,
                    total_cache_creation_tokens = ?4,
                    last_turn_input_tokens = ?5,
                    total_cost_cents = ?6,
                    turn_count = ?7,
                    updated_at = ?8
                 WHERE id = ?9",
                rusqlite::params![
                    tokens.total_input_tokens as i64,
                    tokens.total_output_tokens as i64,
                    tokens.total_cache_read_tokens as i64,
                    tokens.total_cache_creation_tokens as i64,
                    tokens.last_turn_input_tokens as i64,
                    tokens.total_cost_cents,
                    tokens.turn_count,
                    now,
                    session_id.as_str(),
                ],
            )?;
            Ok(())
        })
    }

    /// Update session status (archive, delete, reactivate).
    #[instrument(skip(self), fields(session_id = %session_id, status = %status))]
    pub fn update_status(
        &self,
        session_id: &SessionId,
        status: SessionStatus,
    ) -> Result<(), StoreError> {
        self.db.with_conn(|conn| {
            let now = Utc::now().to_rfc3339();
            conn.execute(
                "UPDATE sessions SET status = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![status.to_string(), now, session_id.as_str()],
            )?;
            Ok(())
        })
    }

    /// Update session title.
    #[instrument(skip(self), fields(session_id = %session_id))]
    pub fn update_title(
        &self,
        session_id: &SessionId,
        title: &str,
    ) -> Result<(), StoreError> {
        self.db.with_conn(|conn| {
            let now = Utc::now().to_rfc3339();
            conn.execute(
                "UPDATE sessions SET title = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![title, now, session_id.as_str()],
            )?;
            Ok(())
        })
    }

    /// Delete a session (hard delete — also deletes events).
    #[instrument(skip(self), fields(session_id = %session_id))]
    pub fn delete(&self, session_id: &SessionId) -> Result<(), StoreError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "DELETE FROM events WHERE session_id = ?1",
                [session_id.as_str()],
            )?;
            conn.execute(
                "DELETE FROM sessions WHERE id = ?1",
                [session_id.as_str()],
            )?;
            Ok(())
        })
    }
}

fn row_to_session(row: &rusqlite::Row<'_>) -> Result<SessionRow, StoreError> {
    let status_str: String = row_helpers::get(row, 4, "sessions", "status")?;

    Ok(SessionRow {
        id: SessionId::from_raw(row_helpers::get::<String>(row, 0, "sessions", "id")?),
        workspace_id: WorkspaceId::from_raw(row_helpers::get::<String>(row, 1, "sessions", "workspace_id")?),
        head_event_id: row_helpers::get_opt::<String>(row, 2, "sessions", "head_event_id")?
            .map(EventId::from_raw),
        root_event_id: row_helpers::get_opt::<String>(row, 3, "sessions", "root_event_id")?
            .map(EventId::from_raw),
        status: row_helpers::parse_enum(&status_str, "sessions", "status")?,
        model: row_helpers::get(row, 5, "sessions", "model")?,
        provider: row_helpers::get(row, 6, "sessions", "provider")?,
        working_directory: row_helpers::get(row, 7, "sessions", "working_directory")?,
        title: row_helpers::get_opt(row, 8, "sessions", "title")?,
        tokens: AccumulatedTokens {
            total_input_tokens: row_helpers::get::<i64>(row, 9, "sessions", "total_input_tokens")? as u64,
            total_output_tokens: row_helpers::get::<i64>(row, 10, "sessions", "total_output_tokens")? as u64,
            total_cache_read_tokens: row_helpers::get::<i64>(row, 11, "sessions", "total_cache_read_tokens")? as u64,
            total_cache_creation_tokens: row_helpers::get::<i64>(row, 12, "sessions", "total_cache_creation_tokens")? as u64,
            last_turn_input_tokens: row_helpers::get::<i64>(row, 13, "sessions", "last_turn_input_tokens")? as u32,
            total_cost_cents: row_helpers::get(row, 14, "sessions", "total_cost_cents")?,
            turn_count: row_helpers::get::<u32>(row, 15, "sessions", "turn_count")?,
        },
        created_at: row_helpers::get(row, 16, "sessions", "created_at")?,
        updated_at: row_helpers::get(row, 17, "sessions", "updated_at")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspaces::WorkspaceRepo;

    fn setup() -> (Database, WorkspaceId) {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        (db, ws.id)
    }

    #[test]
    fn create_session() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let session = repo.create(&ws_id, "claude-opus-4-6", "anthropic", "/tmp").unwrap();
        assert!(session.id.as_str().starts_with("sess_"));
        assert_eq!(session.model, "claude-opus-4-6");
        assert_eq!(session.status, SessionStatus::Active);
        assert!(session.head_event_id.is_none());
    }

    #[test]
    fn get_session() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let session = repo.create(&ws_id, "claude-opus-4-6", "anthropic", "/tmp").unwrap();
        let fetched = repo.get(&session.id).unwrap();
        assert_eq!(fetched.id, session.id);
        assert_eq!(fetched.model, "claude-opus-4-6");
    }

    #[test]
    fn get_nonexistent_fails() {
        let (db, _) = setup();
        let repo = SessionRepo::new(db);
        let result = repo.get(&SessionId::from_raw("sess_nonexistent"));
        assert!(result.is_err());
    }

    #[test]
    fn list_sessions() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        repo.create(&ws_id, "model-a", "anthropic", "/tmp").unwrap();
        repo.create(&ws_id, "model-b", "anthropic", "/tmp").unwrap();
        let all = repo.list(&ws_id, None, 100, 0).unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn list_sessions_with_status_filter() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let s1 = repo.create(&ws_id, "model-a", "anthropic", "/tmp").unwrap();
        repo.create(&ws_id, "model-b", "anthropic", "/tmp").unwrap();
        repo.update_status(&s1.id, SessionStatus::Archived).unwrap();

        let active = repo.list(&ws_id, Some(&SessionStatus::Active), 100, 0).unwrap();
        assert_eq!(active.len(), 1);

        let archived = repo.list(&ws_id, Some(&SessionStatus::Archived), 100, 0).unwrap();
        assert_eq!(archived.len(), 1);
    }

    #[test]
    fn list_sessions_pagination() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        for i in 0..5 {
            repo.create(&ws_id, &format!("model-{i}"), "anthropic", "/tmp").unwrap();
        }
        let page1 = repo.list(&ws_id, None, 2, 0).unwrap();
        assert_eq!(page1.len(), 2);
        let page2 = repo.list(&ws_id, None, 2, 2).unwrap();
        assert_eq!(page2.len(), 2);
        let page3 = repo.list(&ws_id, None, 2, 4).unwrap();
        assert_eq!(page3.len(), 1);
    }

    #[test]
    fn update_head_event() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let session = repo.create(&ws_id, "model", "anthropic", "/tmp").unwrap();

        let evt_id = EventId::new();
        repo.update_head(&session.id, &evt_id, Some(&evt_id)).unwrap();

        let fetched = repo.get(&session.id).unwrap();
        assert_eq!(fetched.head_event_id.as_ref().unwrap(), &evt_id);
        assert_eq!(fetched.root_event_id.as_ref().unwrap(), &evt_id);
    }

    #[test]
    fn update_tokens() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let session = repo.create(&ws_id, "model", "anthropic", "/tmp").unwrap();

        let tokens = AccumulatedTokens {
            total_input_tokens: 1000,
            total_output_tokens: 500,
            total_cache_read_tokens: 200,
            total_cache_creation_tokens: 100,
            last_turn_input_tokens: 1300,
            total_cost_cents: 0.05,
            turn_count: 3,
        };
        repo.update_tokens(&session.id, &tokens).unwrap();

        let fetched = repo.get(&session.id).unwrap();
        assert_eq!(fetched.tokens.total_input_tokens, 1000);
        assert_eq!(fetched.tokens.total_output_tokens, 500);
        assert_eq!(fetched.tokens.turn_count, 3);
    }

    #[test]
    fn update_title() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let session = repo.create(&ws_id, "model", "anthropic", "/tmp").unwrap();
        repo.update_title(&session.id, "My Session").unwrap();
        let fetched = repo.get(&session.id).unwrap();
        assert_eq!(fetched.title.as_deref(), Some("My Session"));
    }

    #[test]
    fn update_status() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let session = repo.create(&ws_id, "model", "anthropic", "/tmp").unwrap();

        repo.update_status(&session.id, SessionStatus::Archived).unwrap();
        let fetched = repo.get(&session.id).unwrap();
        assert_eq!(fetched.status, SessionStatus::Archived);

        repo.update_status(&session.id, SessionStatus::Active).unwrap();
        let fetched = repo.get(&session.id).unwrap();
        assert_eq!(fetched.status, SessionStatus::Active);
    }

    #[test]
    fn delete_session() {
        let (db, ws_id) = setup();
        let repo = SessionRepo::new(db);
        let session = repo.create(&ws_id, "model", "anthropic", "/tmp").unwrap();
        repo.delete(&session.id).unwrap();
        assert!(repo.get(&session.id).is_err());
    }

    #[test]
    fn invalid_session_status_returns_error() {
        let (db, ws_id) = setup();
        let session_id = SessionId::new();
        let now = chrono::Utc::now().to_rfc3339();
        db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO sessions (id, workspace_id, status, model, provider, working_directory, created_at, updated_at)
                 VALUES (?1, ?2, 'INVALID_STATUS', 'model', 'anthropic', '/tmp', ?3, ?3)",
                rusqlite::params![session_id.as_str(), ws_id.as_str(), now],
            )?;
            Ok(())
        })
        .unwrap();

        let repo = SessionRepo::new(db);
        let result = repo.get(&session_id);
        assert!(matches!(result, Err(StoreError::CorruptRow { .. })));
    }
}
