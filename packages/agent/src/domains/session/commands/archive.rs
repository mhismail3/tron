use super::SessionCommandService;
use super::{BaseEvent, TronEvent};
use crate::domains::session::Deps;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

impl SessionCommandService {
    pub(crate) async fn archive(deps: &Deps, session_id: String) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_archive = session_id.clone();
        run_blocking_task("session.archive", move || {
            session_manager
                .archive_session(&session_id_for_archive)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        deps.orchestrator.remove_sequence_counter(&session_id);
        deps.orchestrator.remove_compaction_handler(&session_id);

        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionArchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "archived": true }))
    }

    pub(crate) async fn unarchive(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_unarchive = session_id.clone();
        run_blocking_task("session.unarchive", move || {
            session_manager
                .unarchive_session(&session_id_for_unarchive)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionUnarchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "unarchived": true }))
    }

    /// Archive every active session whose `last_activity_at` is older than
    /// `days` days ago.
    ///
    /// Scope semantics:
    ///   - only non-archived sessions (`ended_at IS NULL`)
    ///   - `days == 0` archives every currently-active session (equivalent to
    ///     "archive all"), provided on request so batch cleanup has one entry
    ///     point.
    ///
    /// Each candidate is archived one-at-a-time via the existing
    /// `SessionCommandService::archive` path so sequence-counter cleanup and
    /// broadcast semantics stay identical to single-session archive.
    ///
    /// Returns `{ archivedCount, archivedSessionIds, skipped, cutoff }`.
    /// `skipped` captures any candidates that failed mid-batch so the caller
    /// can surface them to the user and retry — partial success is explicit
    /// rather than rolled back.
    pub(crate) async fn archive_older_than(
        deps: &Deps,
        days: u32,
    ) -> Result<Value, CapabilityError> {
        let cutoff = chrono::Utc::now() - chrono::Duration::days(i64::from(days));
        let cutoff_rfc = cutoff.to_rfc3339();

        // Gather candidate session IDs inside a blocking task.
        let session_manager = deps.session_manager.clone();
        let cutoff_for_filter = cutoff_rfc.clone();
        let candidates: Vec<String> =
            run_blocking_task("session.archiveOlderThan.list", move || {
                let filter = crate::domains::agent::runner::SessionFilter {
                    include_archived: false,
                    ..Default::default()
                };
                let sessions = session_manager.list_sessions(&filter).map_err(|error| {
                    CapabilityError::Internal {
                        message: error.to_string(),
                    }
                })?;
                // RFC3339 strings are lexicographically sortable, so a
                // string comparison correctly implements "older than cutoff".
                let ids: Vec<String> = sessions
                    .into_iter()
                    .filter(|s| s.last_activity_at.as_str() < cutoff_for_filter.as_str())
                    .map(|s| s.id)
                    .collect();
                Ok(ids)
            })
            .await?;

        let mut archived: Vec<String> = Vec::with_capacity(candidates.len());
        let mut skipped: Vec<Value> = Vec::new();

        for session_id in candidates {
            match Self::archive(deps, session_id.clone()).await {
                Ok(_) => archived.push(session_id),
                Err(err) => skipped.push(json!({
                    "sessionId": session_id,
                    "error": err.to_string(),
                })),
            }
        }

        #[allow(clippy::cast_possible_truncation)]
        let archived_count = archived.len() as u64;

        Ok(json!({
            "archivedCount": archived_count,
            "archivedSessionIds": archived,
            "skipped": skipped,
            "cutoff": cutoff_rfc,
        }))
    }
}
