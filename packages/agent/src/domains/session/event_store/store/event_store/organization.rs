//! Canonical, batch-atomic session organization mutations.
//!
//! Labels remain ordinary `sessions.tags` values. A group is represented by
//! exactly one reserved tag so the engine does not grow a shadow organization
//! model. Worker-owned policy never enters this module: callers supply one
//! already-validated closed mutation batch and this layer preserves system
//! tags, applies reversible archive state, and returns canonical snapshots.

use std::sync::MutexGuard;

use rusqlite::{TransactionBehavior, params};

use super::EventStore;
use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::sqlite::repositories::session::SessionRepo;

/// Reserved tag prefix used to encode exactly one canonical session group.
pub const SESSION_ORGANIZATION_GROUP_TAG_PREFIX: &str = "tron.organization.group:";
const SYSTEM_TAG_PREFIX: &str = "tron.system.";

/// Reversible archive transition admitted by the closed organization seam.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionOrganizationArchiveAction {
    /// Leave the current archive state unchanged.
    Preserve,
    /// Set the canonical session end timestamp when currently active.
    Archive,
    /// Clear the canonical session end timestamp.
    Restore,
}

/// One already-validated canonical session organization mutation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionOrganizationMutation {
    /// Canonical session identifier.
    pub session_id: String,
    /// Replacement ordinary labels; omission preserves the canonical value.
    pub labels: Option<Vec<String>>,
    /// Replacement single organization group. Omission preserves the
    /// canonical value, while `Some(None)` explicitly clears it.
    pub group: Option<Option<String>>,
    /// Reversible archive transition.
    pub archive_action: SessionOrganizationArchiveAction,
}

/// Canonical state returned after one mutation commits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionOrganizationSnapshot {
    /// Canonical session identifier.
    pub session_id: String,
    /// Committed ordinary labels.
    pub labels: Vec<String>,
    /// Committed single group.
    pub group: Option<String>,
    /// Whether the session is archived after commit.
    pub is_archived: bool,
    /// Whether this mutation changed archive state.
    pub archive_changed: bool,
}

/// Decode client-visible labels and the first valid group from canonical tags.
#[must_use]
pub fn session_organization_from_tags(tags_json: &str) -> (Vec<String>, Option<String>) {
    let tags = serde_json::from_str::<Vec<String>>(tags_json).unwrap_or_default();
    let mut labels = Vec::new();
    let mut group = None;
    for tag in tags {
        if tag.starts_with(SYSTEM_TAG_PREFIX) {
            continue;
        }
        if let Some(value) = tag.strip_prefix(SESSION_ORGANIZATION_GROUP_TAG_PREFIX) {
            if group.is_none() && !value.is_empty() {
                group = Some(value.to_owned());
            }
            continue;
        }
        labels.push(tag);
    }
    (labels, group)
}

impl EventStore {
    /// Apply one closed organization batch in one canonical SQLite transaction.
    ///
    /// INVARIANT: every targeted session lock is acquired in sorted ID order
    /// before the transaction begins. This prevents local session writers from
    /// interleaving while retaining one all-or-nothing `tron.sqlite` commit.
    pub fn apply_session_organization(
        &self,
        mutations: &[SessionOrganizationMutation],
    ) -> Result<Vec<SessionOrganizationSnapshot>> {
        let mut session_ids = mutations
            .iter()
            .map(|mutation| mutation.session_id.clone())
            .collect::<Vec<_>>();
        session_ids.sort_unstable();
        session_ids.dedup();
        if session_ids.len() != mutations.len() {
            return Err(EventStoreError::Internal(
                "session organization batch contains duplicate session IDs".to_owned(),
            ));
        }

        let locks = session_ids
            .iter()
            .map(|session_id| self.acquire_session_write_lock(session_id))
            .collect::<Result<Vec<_>>>()?;
        let _guards = locks
            .iter()
            .map(|lock| {
                lock.lock().map_err(|_| {
                    EventStoreError::Internal("session organization write lock poisoned".to_owned())
                })
            })
            .collect::<Result<Vec<MutexGuard<'_, ()>>>>()?;

        self.retry_on_sqlite_busy(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let now = chrono::Utc::now().to_rfc3339();
            let mut snapshots = Vec::with_capacity(mutations.len());

            for mutation in mutations {
                let Some(session) = SessionRepo::get_by_id(&transaction, &mutation.session_id)?
                else {
                    return Err(EventStoreError::SessionNotFound(
                        mutation.session_id.clone(),
                    ));
                };
                let (existing_labels, existing_group) =
                    session_organization_from_tags(&session.tags);
                let labels = mutation.labels.clone().unwrap_or(existing_labels);
                let group = mutation.group.clone().unwrap_or(existing_group);
                let existing_tags =
                    serde_json::from_str::<Vec<String>>(&session.tags).unwrap_or_default();
                let mut tags = existing_tags
                    .into_iter()
                    .filter(|tag| tag.starts_with(SYSTEM_TAG_PREFIX))
                    .collect::<Vec<_>>();
                tags.extend(labels.iter().cloned());
                if let Some(group) = &group {
                    tags.push(format!("{SESSION_ORGANIZATION_GROUP_TAG_PREFIX}{group}"));
                }
                let tags_json = serde_json::to_string(&tags).map_err(|error| {
                    EventStoreError::Internal(format!(
                        "serialize canonical session organization tags: {error}"
                    ))
                })?;
                let was_archived = session.ended_at.is_some();
                let ended_at = match mutation.archive_action {
                    SessionOrganizationArchiveAction::Preserve => session.ended_at,
                    SessionOrganizationArchiveAction::Archive => {
                        Some(session.ended_at.unwrap_or_else(|| now.clone()))
                    }
                    SessionOrganizationArchiveAction::Restore => None,
                };
                let is_archived = ended_at.is_some();
                transaction.execute(
                    "UPDATE sessions SET tags=?2,ended_at=?3 WHERE id=?1",
                    params![mutation.session_id, tags_json, ended_at],
                )?;
                snapshots.push(SessionOrganizationSnapshot {
                    session_id: mutation.session_id.clone(),
                    labels,
                    group,
                    is_archived,
                    archive_changed: was_archived != is_archived,
                });
            }
            transaction.commit()?;
            Ok(snapshots)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::session::event_store::EventStore;
    use crate::domains::session::event_store::sqlite::connection::{
        ConnectionConfig, new_in_memory,
    };
    use crate::domains::session::event_store::sqlite::schema::ensure_schema;

    #[test]
    fn batch_preserves_system_tags_and_rolls_back_when_any_session_is_missing() {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        ensure_schema(&pool.get().unwrap()).unwrap();
        let store = EventStore::new(pool);
        let created = store
            .create_worker_session("model", "/workspace", None, None)
            .unwrap();
        store
            .apply_session_organization(&[SessionOrganizationMutation {
                session_id: created.session.id.clone(),
                labels: Some(vec!["old-label".to_owned()]),
                group: Some(Some("Old".to_owned())),
                archive_action: SessionOrganizationArchiveAction::Preserve,
            }])
            .unwrap();

        let error = store
            .apply_session_organization(&[
                SessionOrganizationMutation {
                    session_id: created.session.id.clone(),
                    labels: Some(vec!["New".to_owned()]),
                    group: Some(Some("Work".to_owned())),
                    archive_action: SessionOrganizationArchiveAction::Archive,
                },
                SessionOrganizationMutation {
                    session_id: "missing".to_owned(),
                    labels: None,
                    group: None,
                    archive_action: SessionOrganizationArchiveAction::Preserve,
                },
            ])
            .unwrap_err();
        assert!(matches!(error, EventStoreError::SessionNotFound(_)));
        let unchanged = store.get_session(&created.session.id).unwrap().unwrap();
        assert_eq!(unchanged.ended_at, None);
        assert_eq!(
            serde_json::from_str::<Vec<String>>(&unchanged.tags).unwrap(),
            vec![
                "tron.system.worker-session",
                "old-label",
                "tron.organization.group:Old"
            ]
        );

        let snapshots = store
            .apply_session_organization(&[SessionOrganizationMutation {
                session_id: created.session.id.clone(),
                labels: Some(vec!["New".to_owned()]),
                group: Some(Some("Work".to_owned())),
                archive_action: SessionOrganizationArchiveAction::Archive,
            }])
            .unwrap();
        assert!(snapshots[0].is_archived);
        let updated = store.get_session(&created.session.id).unwrap().unwrap();
        assert_eq!(
            serde_json::from_str::<Vec<String>>(&updated.tags).unwrap(),
            vec![
                "tron.system.worker-session",
                "New",
                "tron.organization.group:Work"
            ]
        );

        let preserved = store
            .apply_session_organization(&[SessionOrganizationMutation {
                session_id: created.session.id.clone(),
                labels: None,
                group: None,
                archive_action: SessionOrganizationArchiveAction::Restore,
            }])
            .unwrap();
        assert_eq!(preserved[0].labels, vec!["New"]);
        assert_eq!(preserved[0].group.as_deref(), Some("Work"));

        let cleared = store
            .apply_session_organization(&[SessionOrganizationMutation {
                session_id: created.session.id.clone(),
                labels: None,
                group: Some(None),
                archive_action: SessionOrganizationArchiveAction::Preserve,
            }])
            .unwrap();
        assert_eq!(cleared[0].labels, vec!["New"]);
        assert_eq!(cleared[0].group, None);
    }
}
