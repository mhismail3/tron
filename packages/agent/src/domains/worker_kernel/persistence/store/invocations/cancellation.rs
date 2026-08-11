//! Atomic worker-wide invocation cancellation for lifecycle transitions.

use super::super::*;

pub(in crate::domains::worker_kernel::persistence::store) fn cancel_worker_invocations_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    worker_id: &str,
    reason: &str,
) -> Result<Vec<String>, String> {
    let invocations = {
        let mut statement = transaction
            .prepare(
                "SELECT invocation_id,worker_version,origin_session_id,trace_id,
                        causal_depth,interaction_mode,parent_worker_invocation_id,trigger_kind
                 FROM worker_invocations
                 WHERE worker_id=?1 AND status IN ('queued','running')
                 ORDER BY causal_depth,created_at,invocation_id",
            )
            .map_err(|error| format!("prepare worker-wide invocation cancellation: {error}"))?;
        statement
            .query_map([worker_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, u32>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, String>(7)?,
                ))
            })
            .map_err(|error| format!("query worker-wide invocation cancellation: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker-wide invocation cancellation: {error}"))?
    };
    let completed_at = chrono::Utc::now().to_rfc3339();
    let mut cancelled = Vec::with_capacity(invocations.len());
    for (
        invocation_id,
        worker_version,
        origin_session_id,
        trace_id,
        causal_depth,
        interaction_mode,
        parent_worker_invocation_id,
        trigger_kind,
    ) in invocations
    {
        let changed = transaction
            .execute(
                "UPDATE worker_invocations SET status='cancelled',error=?2,completed_at=?3
                 WHERE invocation_id=?1 AND status IN ('queued','running')",
                params![invocation_id, reason, completed_at],
            )
            .map_err(|error| {
                format!("cancel worker invocation during lifecycle change: {error}")
            })?;
        if changed != 1 {
            continue;
        }
        super::super::agent_coordination::terminalize_direct_worker_assignment_in_tx(
            transaction,
            &invocation_id,
            AgentAssignmentStatus::Cancelled,
            reason,
            &completed_at,
        )?;
        transaction
            .execute(
                "UPDATE worker_attempts SET status='cancelled',completed_at=?2,error=?3
                 WHERE invocation_id=?1 AND status='running'",
                params![invocation_id, completed_at, reason],
            )
            .map_err(|error| format!("cancel lifecycle worker attempt: {error}"))?;
        transaction
            .execute(
                "UPDATE worker_dispatches SET state='cancelled',completed_at=?2
                 WHERE target_invocation_id=?1 AND state IN ('queued','running')",
                params![invocation_id, completed_at],
            )
            .map_err(|error| format!("cancel lifecycle worker dispatch: {error}"))?;
        transaction
            .execute(
                "INSERT INTO worker_inbox(
                    inbox_id,invocation_id,worker_id,severity,result_json,created_at
                 ) VALUES (?1,?2,?3,'info',?4,?5)",
                params![
                    format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                    invocation_id,
                    worker_id,
                    serde_json::to_string(&json!({"status":"cancelled","reason":reason}))
                        .map_err(|error| error.to_string())?,
                    completed_at,
                ],
            )
            .map_err(|error| format!("record lifecycle worker cancellation: {error}"))?;
        insert_audit(
            transaction,
            worker_id,
            "invocation_cancelled",
            &json!({"invocationId":invocation_id,"reason":reason}),
        )?;
        insert_run_event(
            transaction,
            &invocation_id,
            WorkerRunStage::Cancelled,
            "Worker invocation cancelled",
            &completed_at,
        )?;
        super::super::agent_delivery_outbox::insert_terminal_outbox(
            transaction,
            &invocation_id,
            worker_id,
            &json!({
                "invocationId":invocation_id,
                "workerId":worker_id,
                "workerVersion":worker_version,
                "status":"cancelled",
                "evidence":{"status":"cancelled","reason":reason},
                "originSessionId":origin_session_id,
                "traceId":trace_id,
                "causalDepth":causal_depth,
                "interactionMode":interaction_mode,
                "parentWorkerInvocationId":parent_worker_invocation_id,
                "triggerKind":trigger_kind,
                "automaticDeliveryEligible":
                    super::super::agent_delivery_outbox::automatic_agent_delivery_eligible(
                        origin_session_id.as_deref(),
                        &interaction_mode,
                        parent_worker_invocation_id.as_deref(),
                        &trigger_kind,
                    ),
            }),
            &completed_at,
        )?;
        cancelled.push(invocation_id);
    }
    Ok(cancelled)
}
