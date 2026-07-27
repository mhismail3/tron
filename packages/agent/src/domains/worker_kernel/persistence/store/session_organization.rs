//! Durable session-organization mutation outbox.
//!
//! Admission occurs in the same `workers.sqlite` transaction as successful
//! invocation completion. The ordinary dispatcher claims and replays the exact
//! closed batch until canonical `tron.sqlite` custody is confirmed, avoiding
//! a false cross-database atomicity claim or a second job subsystem.

#[cfg(test)]
use rusqlite::OptionalExtension;
use rusqlite::params;

use super::*;
use crate::domains::worker_kernel::session_organization::{
    PreparedSessionOrganizationIntent, SessionOrganizationMutation,
};

#[derive(Clone, Debug)]
pub(in crate::domains::worker_kernel) struct SessionOrganizationDispatch {
    pub intent_id: String,
    pub source_invocation_id: String,
    pub worker_id: String,
    pub trace_id: String,
    pub mutations: Vec<SessionOrganizationMutation>,
}

impl WorkerStore {
    pub(super) fn insert_session_organization_intent(
        transaction: &rusqlite::Transaction<'_>,
        invocation_id: &str,
        worker_id: &str,
        worker_version: &str,
        trace_id: &str,
        intent: Option<&PreparedSessionOrganizationIntent>,
        created_at: &str,
    ) -> Result<(), String> {
        let Some(intent) = intent else {
            return Ok(());
        };
        transaction
            .execute(
                "INSERT INTO worker_session_organization_intents(
                    intent_id,source_invocation_id,worker_id,worker_version,trace_id,
                    mutations_json,state,attempt_count,next_attempt_at,created_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,'queued',0,?7,?7,?7)",
                params![
                    format!("session_organization_{invocation_id}"),
                    invocation_id,
                    worker_id,
                    worker_version,
                    trace_id,
                    serde_json::to_string(&intent.mutations).map_err(|error| error.to_string())?,
                    created_at,
                ],
            )
            .map_err(|error| format!("admit session organization intent: {error}"))?;
        Ok(())
    }

    pub(in crate::domains::worker_kernel) fn pending_session_organization_intents(
        &self,
        limit: usize,
    ) -> Result<Vec<SessionOrganizationDispatch>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT intent_id,source_invocation_id,worker_id,trace_id,mutations_json
                 FROM worker_session_organization_intents
                 WHERE state='queued' AND julianday(next_attempt_at) <= julianday('now')
                 ORDER BY next_attempt_at,created_at,intent_id LIMIT ?1",
            )
            .map_err(|error| format!("prepare session organization dispatch: {error}"))?;
        statement
            .query_map([i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })
            .map_err(|error| format!("query session organization dispatch: {error}"))?
            .map(|row| {
                let (intent_id, source_invocation_id, worker_id, trace_id, mutations_json) =
                    row.map_err(|error| error.to_string())?;
                let mutations = serde_json::from_str(&mutations_json)
                    .map_err(|error| format!("decode session organization intent: {error}"))?;
                Ok(SessionOrganizationDispatch {
                    intent_id,
                    source_invocation_id,
                    worker_id,
                    trace_id,
                    mutations,
                })
            })
            .collect()
    }

    pub(in crate::domains::worker_kernel) fn recover_stale_session_organization_intents(
        &self,
    ) -> Result<(), String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start stale session organization recovery: {error}"))?;
        let stale_attention = {
            let mut statement = transaction
                .prepare(
                    "SELECT intent_id,worker_id,attempt_count
                     FROM worker_session_organization_intents
                     WHERE state='applying'
                       AND julianday(updated_at) <= julianday('now','-30 seconds')",
                )
                .map_err(|error| format!("prepare stale session organization recovery: {error}"))?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, u32>(2)?,
                    ))
                })
                .map_err(|error| format!("query stale session organization recovery: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode stale session organization recovery: {error}"))?
        };
        transaction
            .execute(
                "UPDATE worker_session_organization_intents
                 SET state='queued',
                     error='canonical apply lost its in-process owner',
                     next_attempt_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                     updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                 WHERE state='applying'
                   AND julianday(updated_at) <= julianday('now','-30 seconds')",
                [],
            )
            .map_err(|error| format!("recover stale session organization custody: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit stale session organization recovery: {error}"))?;
        for (intent_id, worker_id, attempt_count) in stale_attention {
            if attempt_count == 3 {
                let _ = self.record_system_inbox(
                    &worker_id,
                    "session_organization_recovery",
                    &json!({
                        "status":"attention",
                        "phase":"session_organization",
                        "intentId":intent_id,
                        "error":"Canonical session mutation ownership was recovered repeatedly",
                        "recoveryCount":attempt_count,
                    }),
                );
            }
        }
        Ok(())
    }

    pub(in crate::domains::worker_kernel) fn claim_session_organization_intent(
        &self,
        intent_id: &str,
    ) -> Result<bool, String> {
        let connection = self.connection()?;
        connection
            .execute(
                "UPDATE worker_session_organization_intents
                 SET state='applying',attempt_count=attempt_count+1,
                     updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                 WHERE intent_id=?1 AND state='queued'",
                [intent_id],
            )
            .map(|changed| changed == 1)
            .map_err(|error| format!("claim session organization intent: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn complete_session_organization_intent(
        &self,
        intent_id: &str,
    ) -> Result<(), String> {
        let connection = self.connection()?;
        let changed = connection
            .execute(
                "UPDATE worker_session_organization_intents
                 SET state='applied',error=NULL,
                     applied_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                     updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                 WHERE intent_id=?1 AND state='applying'",
                [intent_id],
            )
            .map_err(|error| format!("complete session organization intent: {error}"))?;
        if changed != 1 {
            return Err(format!(
                "session organization intent '{intent_id}' was not applying"
            ));
        }
        Ok(())
    }

    pub(in crate::domains::worker_kernel) fn release_session_organization_intent(
        &self,
        intent_id: &str,
        error: &str,
        permanent: bool,
    ) -> Result<u32, String> {
        let connection = self.connection()?;
        let attempt_count = connection
            .query_row(
                "SELECT attempt_count FROM worker_session_organization_intents
                 WHERE intent_id=?1 AND state='applying'",
                [intent_id],
                |row| row.get::<_, u32>(0),
            )
            .map_err(|error| format!("load session organization attempt count: {error}"))?;
        let exponent = attempt_count.saturating_sub(1).min(8);
        let delay_seconds = 2_u64.saturating_pow(exponent).min(300);
        let next_attempt_at =
            (chrono::Utc::now() + chrono::Duration::seconds(delay_seconds as i64)).to_rfc3339();
        connection
            .execute(
                "UPDATE worker_session_organization_intents
                 SET state=?2,error=?3,next_attempt_at=?4,
                     updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                 WHERE intent_id=?1 AND state='applying'",
                params![
                    intent_id,
                    if permanent { "failed" } else { "queued" },
                    error,
                    next_attempt_at,
                ],
            )
            .map_err(|error| format!("release session organization intent: {error}"))?;
        Ok(attempt_count)
    }

    #[cfg(test)]
    pub(in crate::domains::worker_kernel) fn session_organization_intent_state(
        &self,
        invocation_id: &str,
    ) -> Result<Option<String>, String> {
        self.connection()?
            .query_row(
                "SELECT state FROM worker_session_organization_intents
                 WHERE source_invocation_id=?1",
                [invocation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| error.to_string())
    }
}
