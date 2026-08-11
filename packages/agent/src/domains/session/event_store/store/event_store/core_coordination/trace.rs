//! Durable autonomy provenance, ceiling enforcement, pause, and operator resume.

use super::*;

const TRACE_COLUMNS: &str = "
    trace_id,root_agent_id,root_session_id,state,reason,message_count,message_baseline,
    max_autonomous_hop,paused_agent_id,paused_assignment_id,created_at,
    updated_at,paused_at,resumed_at
";

impl EventStore {
    pub(crate) fn core_coordination_trace(
        &self,
        trace_id: &str,
    ) -> Result<Option<CoordinationTraceRecord>> {
        validate_identifier("coordination trace id", trace_id)?;
        let connection = self.conn()?;
        query_coordination_trace_in_tx(&connection, trace_id)
    }

    pub(crate) fn resume_core_coordination_trace(
        &self,
        trace_id: &str,
    ) -> Result<Option<WakeIntentRecord>> {
        validate_identifier("coordination trace id", trace_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let Some(trace) = query_coordination_trace_in_tx(&transaction, trace_id)? else {
                return Err(EventStoreError::InvalidOperation(format!(
                    "coordination trace '{trace_id}' was not found"
                )));
            };
            if trace.state == "active" {
                transaction.commit()?;
                return Ok(None);
            }
            let target_agent_id = trace
                .paused_agent_id
                .clone()
                .unwrap_or_else(|| trace.root_agent_id.clone());
            let target = require_open_agent(&transaction, &target_agent_id)?;
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE agent_coordination_traces
                 SET state='active',reason=NULL,updated_at=?2,resumed_at=?2,
                     message_baseline=message_count,
                     paused_at=NULL,paused_agent_id=NULL,paused_assignment_id=NULL
                 WHERE trace_id=?1 AND state='paused'",
                params![trace_id, now],
            )?;
            let pause_generation = trace.paused_at.as_deref().unwrap_or(&trace.updated_at);
            let cause_id = stable_id("agent_trace_resume", &[trace_id, pause_generation]);
            let wake = insert_wake_in_tx(
                &transaction,
                &target.agent_id,
                &target.transcript_session_id,
                trace.paused_assignment_id.as_deref(),
                "recovery",
                &cause_id,
                trace_id,
                0,
                10,
                None,
            )?;
            transaction.commit()?;
            Ok(Some(wake))
        })
    }
}

pub(super) fn ensure_coordination_trace_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    trace_id: &str,
    root_agent_id: &str,
    root_session_id: &str,
) -> Result<CoordinationTraceRecord> {
    let now = chrono::Utc::now().to_rfc3339();
    transaction.execute(
        "INSERT OR IGNORE INTO agent_coordination_traces(
            trace_id,root_agent_id,root_session_id,created_at,updated_at
         ) VALUES (?1,?2,?3,?4,?4)",
        params![trace_id, root_agent_id, root_session_id, now],
    )?;
    let trace = query_coordination_trace_in_tx(transaction, trace_id)?
        .ok_or_else(|| EventStoreError::Internal("coordination trace disappeared".to_owned()))?;
    if trace.root_agent_id != root_agent_id || trace.root_session_id != root_session_id {
        return Err(EventStoreError::InvalidOperation(
            "coordination trace ownership conflict".to_owned(),
        ));
    }
    Ok(trace)
}

/// Count durable semantic evidence and pause after (not before) the message
/// which crosses either ceiling. The caller still commits the message and any
/// assignment it admitted, but suppresses its wake while the trace is paused.
pub(super) fn record_coordination_message_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    trace_id: &str,
    autonomous_hop: u32,
    target_agent_id: &str,
    target_assignment_id: Option<&str>,
) -> Result<bool> {
    let now = chrono::Utc::now().to_rfc3339();
    let changed = transaction.execute(
        "UPDATE agent_coordination_traces
         SET message_count=(SELECT COUNT(*) FROM agent_message_metadata
                            WHERE trace_id=?1),
             max_autonomous_hop=MAX(max_autonomous_hop,?2),updated_at=?3
         WHERE trace_id=?1",
        params![trace_id, autonomous_hop, now],
    )?;
    if changed != 1 {
        return Err(EventStoreError::Internal(
            "semantic message has no coordination trace".to_owned(),
        ));
    }
    let trace = query_coordination_trace_in_tx(transaction, trace_id)?
        .ok_or_else(|| EventStoreError::Internal("coordination trace disappeared".to_owned()))?;
    let reason = if autonomous_hop > MAX_AUTONOMOUS_WAKE_HOPS {
        Some(format!(
            "AGENT_AUTONOMY_PAUSED: autonomous coordination exceeded the {MAX_AUTONOMOUS_WAKE_HOPS}-wake-hop ceiling"
        ))
    } else if trace.message_count.saturating_sub(trace.message_baseline) > MAX_COORDINATION_MESSAGES
    {
        Some(format!(
            "AGENT_AUTONOMY_PAUSED: coordination trace exceeded the {MAX_COORDINATION_MESSAGES}-message ceiling"
        ))
    } else {
        None
    };
    if let Some(reason) = reason.as_deref() {
        pause_coordination_trace_in_tx(
            transaction,
            trace_id,
            reason,
            target_agent_id,
            target_assignment_id,
            autonomous_hop,
            &now,
        )?;
        return Ok(true);
    }
    Ok(trace.state == "paused")
}

pub(super) fn pause_coordination_trace_for_hop_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    trace_id: &str,
    autonomous_hop: u32,
    target_agent_id: &str,
    target_assignment_id: Option<&str>,
) -> Result<bool> {
    let Some(trace) = query_coordination_trace_in_tx(transaction, trace_id)? else {
        return Err(EventStoreError::Internal(
            "wake has no coordination trace".to_owned(),
        ));
    };
    if trace.state == "paused" {
        return Ok(true);
    }
    if autonomous_hop <= MAX_AUTONOMOUS_WAKE_HOPS {
        return Ok(false);
    }
    let now = chrono::Utc::now().to_rfc3339();
    let reason = format!(
        "AGENT_AUTONOMY_PAUSED: autonomous coordination exceeded the {MAX_AUTONOMOUS_WAKE_HOPS}-wake-hop ceiling"
    );
    pause_coordination_trace_in_tx(
        transaction,
        trace_id,
        &reason,
        target_agent_id,
        target_assignment_id,
        autonomous_hop,
        &now,
    )?;
    Ok(true)
}

fn pause_coordination_trace_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    trace_id: &str,
    reason: &str,
    target_agent_id: &str,
    target_assignment_id: Option<&str>,
    autonomous_hop: u32,
    now: &str,
) -> Result<()> {
    transaction.execute(
        "UPDATE agent_coordination_traces
         SET state='paused',reason=COALESCE(reason,?2),
             max_autonomous_hop=MAX(max_autonomous_hop,?3),updated_at=?4,
             paused_at=COALESCE(paused_at,?4),resumed_at=NULL,
             paused_agent_id=COALESCE(paused_agent_id,?5),
             paused_assignment_id=COALESCE(paused_assignment_id,?6)
         WHERE trace_id=?1",
        params![
            trace_id,
            reason,
            autonomous_hop,
            now,
            target_agent_id,
            target_assignment_id
        ],
    )?;
    Ok(())
}

pub(super) fn coordination_trace_is_paused_in_tx(
    connection: &rusqlite::Connection,
    trace_id: &str,
) -> Result<bool> {
    connection
        .query_row(
            "SELECT state='paused' FROM agent_coordination_traces WHERE trace_id=?1",
            [trace_id],
            |row| row.get(0),
        )
        .optional()
        .map(|paused| paused.unwrap_or(false))
        .map_err(EventStoreError::from)
}

pub(super) fn query_coordination_trace_in_tx(
    connection: &rusqlite::Connection,
    trace_id: &str,
) -> Result<Option<CoordinationTraceRecord>> {
    connection
        .query_row(
            &format!("SELECT {TRACE_COLUMNS} FROM agent_coordination_traces WHERE trace_id=?1"),
            [trace_id],
            map_trace,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn map_trace(row: &rusqlite::Row<'_>) -> rusqlite::Result<CoordinationTraceRecord> {
    Ok(CoordinationTraceRecord {
        trace_id: row.get(0)?,
        root_agent_id: row.get(1)?,
        root_session_id: row.get(2)?,
        state: row.get(3)?,
        reason: row.get(4)?,
        message_count: row.get(5)?,
        message_baseline: row.get(6)?,
        max_autonomous_hop: row.get(7)?,
        paused_agent_id: row.get(8)?,
        paused_assignment_id: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
        paused_at: row.get(12)?,
        resumed_at: row.get(13)?,
    })
}
