//! Domain-owned SQLite revision and transient-surface store.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};

use super::model::{DefinitionRevision, NativeUIDefinition, SurfaceSnapshot, ValidationDiagnostic};

#[derive(Clone)]
pub(crate) struct NativeUIStore {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum StoreError {
    #[error("native UI store lock is poisoned")]
    LockPoisoned,
    #[error("native UI storage failed: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("native UI revision serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error(
        "active revision conflict for {definition_id}: expected {expected:?}, current {current:?}"
    )]
    RevisionConflict {
        definition_id: String,
        expected: Option<u64>,
        current: Option<u64>,
    },
    #[error("native UI definition {0} has no revision {1}")]
    RevisionNotFound(String, u64),
}

impl NativeUIStore {
    pub(crate) fn open(path: Option<&Path>) -> Result<Self, StoreError> {
        let connection = match path {
            Some(path) => Connection::open(path)?,
            None => Connection::open_in_memory()?,
        };
        crate::shared::storage::apply_runtime_pragmas(&connection)
            .map_err(|error| rusqlite::Error::InvalidParameterName(error.to_string()))?;
        let store = Self {
            connection: Arc::new(Mutex::new(connection)),
        };
        store.ensure_schema()?;
        Ok(store)
    }

    pub(crate) fn ensure_schema(&self) -> Result<(), StoreError> {
        self.connection()?.execute_batch(
            "CREATE TABLE IF NOT EXISTS native_ui_definition_revisions (
               definition_id    TEXT    NOT NULL,
               revision         INTEGER NOT NULL,
               parent_revision  INTEGER,
               content_hash     TEXT    NOT NULL,
               catalog_id       TEXT    NOT NULL,
               catalog_revision INTEGER NOT NULL,
               lifecycle        TEXT    NOT NULL CHECK(lifecycle IN ('persistent','transient')),
               status           TEXT    NOT NULL CHECK(status IN ('preview','active','superseded','rolled_back')),
               definition_json  TEXT    NOT NULL,
               diagnostics_json TEXT    NOT NULL,
               created_at       TEXT    NOT NULL,
               PRIMARY KEY(definition_id, revision),
               UNIQUE(definition_id, content_hash)
             );
             CREATE TABLE IF NOT EXISTS native_ui_active_definitions (
               definition_id TEXT PRIMARY KEY,
               revision      INTEGER NOT NULL,
               updated_at    TEXT    NOT NULL,
               FOREIGN KEY(definition_id, revision)
                 REFERENCES native_ui_definition_revisions(definition_id, revision)
             );
             CREATE TABLE IF NOT EXISTS native_ui_transient_surfaces (
               surface_id          TEXT PRIMARY KEY,
               definition_id       TEXT    NOT NULL,
               definition_revision INTEGER NOT NULL,
               session_id          TEXT    NOT NULL,
               event_id            TEXT    NOT NULL,
               state               TEXT    NOT NULL CHECK(state IN ('active','dismissed','expired')),
               snapshot_json       TEXT    NOT NULL,
               updated_at          TEXT    NOT NULL,
               dismissed_at        TEXT,
               UNIQUE(session_id, event_id, definition_id)
             );
             CREATE INDEX IF NOT EXISTS idx_native_ui_revisions_history
               ON native_ui_definition_revisions(definition_id, revision DESC);
             CREATE INDEX IF NOT EXISTS idx_native_ui_transient_session
               ON native_ui_transient_surfaces(session_id, state, updated_at DESC);",
        )?;
        self.verify_schema()
    }

    pub(crate) fn save_preview(
        &self,
        definition: &NativeUIDefinition,
        content_hash: &str,
        diagnostics: &[ValidationDiagnostic],
    ) -> Result<DefinitionRevision, StoreError> {
        let mut connection = self.connection()?;
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let parent_revision = active_revision_in(&tx, &definition.definition_id)?;
        let revision = find_hash_revision(&tx, &definition.definition_id, content_hash)?
            .unwrap_or(next_revision(&tx, &definition.definition_id)?);
        if revision_exists(&tx, &definition.definition_id, revision)? {
            tx.commit()?;
            drop(connection);
            return self
                .revision(&definition.definition_id, revision)?
                .ok_or_else(|| {
                    StoreError::RevisionNotFound(definition.definition_id.clone(), revision)
                });
        }
        insert_revision(
            &tx,
            definition,
            revision,
            parent_revision,
            content_hash,
            diagnostics,
            "preview",
        )?;
        tx.commit()?;
        drop(connection);
        self.revision(&definition.definition_id, revision)?
            .ok_or_else(|| StoreError::RevisionNotFound(definition.definition_id.clone(), revision))
    }

    pub(crate) fn activate(
        &self,
        definition: &NativeUIDefinition,
        content_hash: &str,
        diagnostics: &[ValidationDiagnostic],
        expected_active_revision: Option<u64>,
    ) -> Result<DefinitionRevision, StoreError> {
        let mut connection = self.connection()?;
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = active_revision_in(&tx, &definition.definition_id)?;
        if current != expected_active_revision {
            return Err(StoreError::RevisionConflict {
                definition_id: definition.definition_id.clone(),
                expected: expected_active_revision,
                current,
            });
        }
        let revision = find_hash_revision(&tx, &definition.definition_id, content_hash)?
            .unwrap_or(next_revision(&tx, &definition.definition_id)?);
        if !revision_exists(&tx, &definition.definition_id, revision)? {
            insert_revision(
                &tx,
                definition,
                revision,
                current,
                content_hash,
                diagnostics,
                "preview",
            )?;
        }
        if let Some(current) = current {
            let _ = tx.execute(
                "UPDATE native_ui_definition_revisions
                 SET status = 'superseded'
                 WHERE definition_id = ?1 AND revision = ?2",
                params![definition.definition_id, current],
            )?;
        }
        let _ = tx.execute(
            "UPDATE native_ui_definition_revisions
             SET status = 'active'
             WHERE definition_id = ?1 AND revision = ?2",
            params![definition.definition_id, revision],
        )?;
        let _ = tx.execute(
            "INSERT INTO native_ui_active_definitions(definition_id, revision, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(definition_id) DO UPDATE SET
               revision = excluded.revision,
               updated_at = excluded.updated_at",
            params![definition.definition_id, revision, Utc::now().to_rfc3339()],
        )?;
        tx.commit()?;
        drop(connection);
        self.revision(&definition.definition_id, revision)?
            .ok_or_else(|| StoreError::RevisionNotFound(definition.definition_id.clone(), revision))
    }

    pub(crate) fn rollback(
        &self,
        definition_id: &str,
        target_revision: u64,
        expected_active_revision: Option<u64>,
    ) -> Result<DefinitionRevision, StoreError> {
        let mut connection = self.connection()?;
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = active_revision_in(&tx, definition_id)?;
        if current != expected_active_revision {
            return Err(StoreError::RevisionConflict {
                definition_id: definition_id.to_owned(),
                expected: expected_active_revision,
                current,
            });
        }
        if !revision_exists(&tx, definition_id, target_revision)? {
            return Err(StoreError::RevisionNotFound(
                definition_id.to_owned(),
                target_revision,
            ));
        }
        if let Some(current) = current {
            let _ = tx.execute(
                "UPDATE native_ui_definition_revisions
                 SET status = 'rolled_back'
                 WHERE definition_id = ?1 AND revision = ?2",
                params![definition_id, current],
            )?;
        }
        let _ = tx.execute(
            "UPDATE native_ui_definition_revisions
             SET status = 'active'
             WHERE definition_id = ?1 AND revision = ?2",
            params![definition_id, target_revision],
        )?;
        let _ = tx.execute(
            "INSERT INTO native_ui_active_definitions(definition_id, revision, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(definition_id) DO UPDATE SET
               revision = excluded.revision,
               updated_at = excluded.updated_at",
            params![definition_id, target_revision, Utc::now().to_rfc3339()],
        )?;
        tx.commit()?;
        drop(connection);
        self.revision(definition_id, target_revision)?
            .ok_or_else(|| StoreError::RevisionNotFound(definition_id.to_owned(), target_revision))
    }

    pub(crate) fn active_revision(
        &self,
        definition_id: &str,
    ) -> Result<Option<DefinitionRevision>, StoreError> {
        let revision = active_revision_in(&*self.connection()?, definition_id)?;
        match revision {
            Some(revision) => self.revision(definition_id, revision),
            None => Ok(None),
        }
    }

    pub(crate) fn revision(
        &self,
        definition_id: &str,
        revision: u64,
    ) -> Result<Option<DefinitionRevision>, StoreError> {
        self.connection()?
            .query_row(
                "SELECT definition_id, revision, parent_revision, content_hash,
                        catalog_id, catalog_revision, lifecycle, status,
                        definition_json, diagnostics_json, created_at
                 FROM native_ui_definition_revisions
                 WHERE definition_id = ?1 AND revision = ?2",
                params![definition_id, revision],
                row_to_revision,
            )
            .optional()
            .map_err(StoreError::from)
    }

    pub(crate) fn history(
        &self,
        definition_id: &str,
        limit: usize,
    ) -> Result<Vec<DefinitionRevision>, StoreError> {
        let connection = self.connection()?;
        let mut statement = connection.prepare(
            "SELECT definition_id, revision, parent_revision, content_hash,
                    catalog_id, catalog_revision, lifecycle, status,
                    definition_json, diagnostics_json, created_at
             FROM native_ui_definition_revisions
             WHERE definition_id = ?1
             ORDER BY revision DESC
             LIMIT ?2",
        )?;
        let rows = statement.query_map(params![definition_id, limit.min(100)], row_to_revision)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    pub(crate) fn save_transient(
        &self,
        snapshot: &SurfaceSnapshot,
        session_id: &str,
        event_id: &str,
    ) -> Result<(), StoreError> {
        let snapshot_json = serde_json::to_string(snapshot)?;
        let _ = self.connection()?.execute(
            "INSERT INTO native_ui_transient_surfaces(
               surface_id, definition_id, definition_revision, session_id,
               event_id, state, snapshot_json, updated_at, dismissed_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6, ?7, NULL)
             ON CONFLICT(session_id, event_id, definition_id) DO UPDATE SET
               surface_id = excluded.surface_id,
               definition_revision = excluded.definition_revision,
               state = 'active',
               snapshot_json = excluded.snapshot_json,
               updated_at = excluded.updated_at,
               dismissed_at = NULL",
            params![
                snapshot.surface_id,
                snapshot.definition_id,
                snapshot.definition_revision,
                session_id,
                event_id,
                snapshot_json,
                Utc::now().to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub(crate) fn transient(
        &self,
        surface_id: &str,
    ) -> Result<Option<(String, SurfaceSnapshot)>, StoreError> {
        let row = self
            .connection()?
            .query_row(
                "SELECT state, snapshot_json
                 FROM native_ui_transient_surfaces
                 WHERE surface_id = ?1",
                params![surface_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        row.map(|(state, json)| Ok((state, serde_json::from_str(&json)?)))
            .transpose()
    }

    /// Atomically tombstone an active transient and return the exact snapshot
    /// whose canonical logical surface must be deleted from clients.
    pub(crate) fn dismiss_transient(
        &self,
        surface_id: &str,
    ) -> Result<Option<SurfaceSnapshot>, StoreError> {
        let mut connection = self.connection()?;
        let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let row = tx
            .query_row(
                "SELECT state, snapshot_json
                 FROM native_ui_transient_surfaces
                 WHERE surface_id = ?1",
                params![surface_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        let Some((state, snapshot_json)) = row else {
            tx.commit()?;
            return Ok(None);
        };
        if state != "active" {
            tx.commit()?;
            return Ok(None);
        }
        let snapshot = serde_json::from_str(&snapshot_json)?;
        let now = Utc::now().to_rfc3339();
        let changed = tx.execute(
            "UPDATE native_ui_transient_surfaces
             SET state = 'dismissed', updated_at = ?2, dismissed_at = ?2
             WHERE surface_id = ?1 AND state = 'active'",
            params![surface_id, now],
        )?;
        debug_assert_eq!(
            changed, 1,
            "immediate transaction owns this state transition"
        );
        tx.commit()?;
        Ok((changed == 1).then_some(snapshot))
    }

    pub(crate) fn expire_transient(&self, surface_id: &str) -> Result<bool, StoreError> {
        let changed = self.connection()?.execute(
            "UPDATE native_ui_transient_surfaces
             SET state = 'expired', updated_at = ?2
             WHERE surface_id = ?1 AND state = 'active'",
            params![surface_id, Utc::now().to_rfc3339()],
        )?;
        Ok(changed > 0)
    }

    fn connection(&self) -> Result<MutexGuard<'_, Connection>, StoreError> {
        self.connection.lock().map_err(|_| StoreError::LockPoisoned)
    }

    fn verify_schema(&self) -> Result<(), StoreError> {
        for table in [
            "native_ui_definition_revisions",
            "native_ui_active_definitions",
            "native_ui_transient_surfaces",
        ] {
            let exists: i64 = self.connection()?.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                params![table],
                |row| row.get(0),
            )?;
            if exists != 1 {
                return Err(StoreError::Sqlite(rusqlite::Error::InvalidParameterName(
                    format!("native UI schema missing table {table}"),
                )));
            }
        }
        Ok(())
    }
}

fn active_revision_in(
    connection: &Connection,
    definition_id: &str,
) -> Result<Option<u64>, rusqlite::Error> {
    connection
        .query_row(
            "SELECT revision FROM native_ui_active_definitions WHERE definition_id = ?1",
            params![definition_id],
            |row| row.get(0),
        )
        .optional()
}

fn next_revision(tx: &Transaction<'_>, definition_id: &str) -> Result<u64, rusqlite::Error> {
    let current: u64 = tx.query_row(
        "SELECT COALESCE(MAX(revision), 0) FROM native_ui_definition_revisions WHERE definition_id = ?1",
        params![definition_id],
        |row| row.get(0),
    )?;
    Ok(current.saturating_add(1))
}

fn find_hash_revision(
    tx: &Transaction<'_>,
    definition_id: &str,
    content_hash: &str,
) -> Result<Option<u64>, rusqlite::Error> {
    tx.query_row(
        "SELECT revision FROM native_ui_definition_revisions
         WHERE definition_id = ?1 AND content_hash = ?2",
        params![definition_id, content_hash],
        |row| row.get(0),
    )
    .optional()
}

fn revision_exists(
    connection: &Connection,
    definition_id: &str,
    revision: u64,
) -> Result<bool, rusqlite::Error> {
    connection.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM native_ui_definition_revisions
           WHERE definition_id = ?1 AND revision = ?2
         )",
        params![definition_id, revision],
        |row| row.get(0),
    )
}

fn insert_revision(
    tx: &Transaction<'_>,
    definition: &NativeUIDefinition,
    revision: u64,
    parent_revision: Option<u64>,
    content_hash: &str,
    diagnostics: &[ValidationDiagnostic],
    status: &str,
) -> Result<(), StoreError> {
    let definition_json = serde_json::to_string(definition)?;
    let diagnostics_json = serde_json::to_string(diagnostics)?;
    let _ = tx.execute(
        "INSERT INTO native_ui_definition_revisions(
           definition_id, revision, parent_revision, content_hash, catalog_id,
           catalog_revision, lifecycle, status, definition_json,
           diagnostics_json, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            definition.definition_id,
            revision,
            parent_revision,
            content_hash,
            definition.catalog_id,
            definition.catalog_revision,
            definition.lifecycle.as_str(),
            status,
            definition_json,
            diagnostics_json,
            Utc::now().to_rfc3339(),
        ],
    )?;
    Ok(())
}

fn row_to_revision(row: &rusqlite::Row<'_>) -> rusqlite::Result<DefinitionRevision> {
    let lifecycle: String = row.get(6)?;
    let definition_json: String = row.get(8)?;
    let diagnostics_json: String = row.get(9)?;
    Ok(DefinitionRevision {
        definition_id: row.get(0)?,
        revision: row.get(1)?,
        parent_revision: row.get(2)?,
        content_hash: row.get(3)?,
        catalog_id: row.get(4)?,
        catalog_revision: row.get(5)?,
        lifecycle: match lifecycle.as_str() {
            "persistent" => super::model::SurfaceLifecycle::Persistent,
            "transient" => super::model::SurfaceLifecycle::Transient,
            other => {
                return Err(rusqlite::Error::FromSqlConversionFailure(
                    6,
                    rusqlite::types::Type::Text,
                    format!("unknown native UI lifecycle {other}").into(),
                ));
            }
        },
        status: row.get(7)?,
        definition: serde_json::from_str(&definition_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                8,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?,
        diagnostics: serde_json::from_str(&diagnostics_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                9,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?,
        created_at: row.get(10)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::native_ui::{builtins, validation};

    #[test]
    fn activation_is_compare_and_swap_and_rollback_is_durable() {
        let store = NativeUIStore::open(None).unwrap();
        let definition = builtins::definition("settings.engine").unwrap();
        let report = validation::validate_structure(&definition);
        let first = store
            .activate(&definition, &report.content_hash, &[], None)
            .unwrap();
        assert_eq!(first.revision, 1);

        let conflict = store
            .activate(&definition, &report.content_hash, &[], None)
            .unwrap_err();
        assert!(matches!(conflict, StoreError::RevisionConflict { .. }));

        let mut changed = definition.clone();
        changed.presentation.title = "Engine Override".to_owned();
        let report = validation::validate_structure(&changed);
        let second = store
            .activate(&changed, &report.content_hash, &[], Some(1))
            .unwrap();
        assert_eq!(second.revision, 2);

        let rolled_back = store.rollback("settings.engine", 1, Some(2)).unwrap();
        assert_eq!(rolled_back.revision, 1);
        assert_eq!(store.history("settings.engine", 10).unwrap().len(), 2);
    }

    #[test]
    fn transient_dismissal_atomically_returns_the_tombstoned_snapshot() {
        let store = NativeUIStore::open(None).unwrap();
        let definition = builtins::definition("session.compaction_detail").unwrap();
        let snapshot = SurfaceSnapshot {
            surface_id: "session.compaction_detail:session:event".to_owned(),
            definition_id: definition.definition_id.clone(),
            definition_revision: 0,
            surface_sequence: 0,
            catalog_id: definition.catalog_id.clone(),
            catalog_revision: definition.catalog_revision,
            lifecycle: definition.lifecycle,
            source: "test".to_owned(),
            presentation: definition.presentation.clone(),
            messages: definition.messages.clone(),
            diagnostics: Vec::new(),
            session_id: Some("session".to_owned()),
            event_id: Some("event".to_owned()),
        };
        store.save_transient(&snapshot, "session", "event").unwrap();

        assert_eq!(
            store
                .dismiss_transient(&snapshot.surface_id)
                .unwrap()
                .as_ref(),
            Some(&snapshot)
        );
        assert!(
            store
                .dismiss_transient(&snapshot.surface_id)
                .unwrap()
                .is_none()
        );
        assert_eq!(
            store.transient(&snapshot.surface_id).unwrap().unwrap().0,
            "dismissed"
        );
    }
}
