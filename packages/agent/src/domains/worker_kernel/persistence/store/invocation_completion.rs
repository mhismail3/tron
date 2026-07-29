//! Transactional worker invocation completion and client-delivery admission.

use rusqlite::params;
use serde_json::{Value, json};

use super::inbox::COMPLETED_ENGINE_HOOK_CONTEXT_ATTACHED_SQL;
use super::*;
use crate::domains::worker_kernel::session_organization::PreparedSessionOrganizationIntent;

impl WorkerStore {
    pub fn complete_invocation(
        &self,
        invocation_id: &str,
        worker_id: &str,
        result: Result<&Value, &str>,
    ) -> Result<InvocationRecord, String> {
        match result {
            Ok(output) => self.complete_invocation_with_effects(
                invocation_id,
                worker_id,
                output,
                &[],
                &[],
                &[],
                None,
            ),
            Err(error) => self.complete_invocation_inner(
                invocation_id,
                worker_id,
                Err(error),
                &[],
                &[],
                &[],
                &[],
                None,
                None,
            ),
        }
    }

    #[cfg(test)]
    pub(in crate::domains::worker_kernel) fn complete_invocation_with_notifications(
        &self,
        invocation_id: &str,
        worker_id: &str,
        output: &Value,
        notification_intents: &[crate::domains::worker_kernel::notifications::NotificationIntent],
    ) -> Result<InvocationRecord, String> {
        self.complete_invocation_with_effects(
            invocation_id,
            worker_id,
            output,
            notification_intents,
            &[],
            &[],
            None,
        )
    }

    pub(in crate::domains::worker_kernel) fn complete_invocation_with_effects(
        &self,
        invocation_id: &str,
        worker_id: &str,
        output: &Value,
        notification_intents: &[crate::domains::worker_kernel::notifications::NotificationIntent],
        artifact_intents: &[ArtifactIntent],
        worker_dispatches: &[PreparedWorkerDispatch],
        worker_wakeup: Option<&PreparedWorkerWakeup>,
    ) -> Result<InvocationRecord, String> {
        self.complete_invocation_with_effects_and_session_organization(
            invocation_id,
            worker_id,
            output,
            notification_intents,
            artifact_intents,
            &[],
            worker_dispatches,
            worker_wakeup,
            None,
        )
    }

    pub(in crate::domains::worker_kernel) fn complete_invocation_with_effects_and_session_organization(
        &self,
        invocation_id: &str,
        worker_id: &str,
        output: &Value,
        notification_intents: &[crate::domains::worker_kernel::notifications::NotificationIntent],
        artifact_intents: &[ArtifactIntent],
        agent_delivery_effects: &[PreparedAgentDeliveryEffect],
        worker_dispatches: &[PreparedWorkerDispatch],
        worker_wakeup: Option<&PreparedWorkerWakeup>,
        session_organization: Option<&PreparedSessionOrganizationIntent>,
    ) -> Result<InvocationRecord, String> {
        self.complete_invocation_inner(
            invocation_id,
            worker_id,
            Ok(output),
            notification_intents,
            artifact_intents,
            agent_delivery_effects,
            worker_dispatches,
            worker_wakeup,
            session_organization,
        )
    }

    fn complete_invocation_inner(
        &self,
        invocation_id: &str,
        worker_id: &str,
        result: Result<&Value, &str>,
        notification_intents: &[crate::domains::worker_kernel::notifications::NotificationIntent],
        artifact_intents: &[ArtifactIntent],
        agent_delivery_effects: &[PreparedAgentDeliveryEffect],
        worker_dispatches: &[PreparedWorkerDispatch],
        worker_wakeup: Option<&PreparedWorkerWakeup>,
        session_organization: Option<&PreparedSessionOrganizationIntent>,
    ) -> Result<InvocationRecord, String> {
        let mut connection = self.connection()?;
        let tx = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let (
            trace_id,
            origin_session_id,
            worker_version,
            causal_depth,
            interaction_mode,
            parent_worker_invocation_id,
            trigger_kind,
            root_invocation_id,
        ): (
            String,
            Option<String>,
            String,
            u32,
            String,
            Option<String>,
            String,
            Option<String>,
        ) = tx
            .query_row(
                "SELECT trace_id,origin_session_id,worker_version,causal_depth,
                        interaction_mode,parent_worker_invocation_id,trigger_kind,
                        (SELECT root_invocation_id FROM worker_causal_traces
                         WHERE trace_id=worker_invocations.trace_id)
                 FROM worker_invocations
                 WHERE invocation_id=?1 AND worker_id=?2 AND status='running'",
                params![invocation_id, worker_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                    ))
                },
            )
            .map_err(|error| format!("load completing worker invocation: {error}"))?;
        let (status, output, error, severity, inbox_result) = match result {
            Ok(output) => {
                let stored = Self::store_result_in_transaction(
                    &tx,
                    invocation_id,
                    output,
                    &trace_id,
                    origin_session_id.as_deref(),
                )?;
                ("completed", Some(stored), None, "info", Value::Null)
            }
            Err(error) => (
                "failed",
                None,
                Some(error.to_owned()),
                "error",
                json!({"status":"failed","error":error}),
            ),
        };
        let completed_at = chrono::Utc::now().to_rfc3339();
        let changed = tx
            .execute(
                "UPDATE worker_invocations SET status=?2,output_json=?3,error=?4,completed_at=?5
                 WHERE invocation_id=?1 AND status='running'",
                params![invocation_id, status, output, error, completed_at],
            )
            .map_err(|error| format!("complete worker invocation: {error}"))?;
        if changed != 1 {
            return Err(format!(
                "worker invocation '{invocation_id}' was not in a running state"
            ));
        }
        let inbox_result = if status == "completed" {
            results::completed_result_receipt(&results::result_reference_from_connection(
                &tx,
                invocation_id,
            )?)
        } else {
            inbox_result
        };
        tx.execute(
            "UPDATE worker_attempts SET status=?2,completed_at=?3,error=?4
             WHERE attempt_id=(SELECT attempt_id FROM worker_attempts
                WHERE invocation_id=?1 AND status='running' ORDER BY attempt_number DESC LIMIT 1)",
            params![invocation_id, status, completed_at, error],
        )
        .map_err(|error| format!("complete worker delivery attempt: {error}"))?;
        insert_run_event(
            &tx,
            invocation_id,
            WorkerRunStage::Publication,
            "Publishing the durable worker result",
            &completed_at,
        )?;
        insert_run_event(
            &tx,
            invocation_id,
            match status {
                "completed" => WorkerRunStage::Completed,
                _ => WorkerRunStage::Failed,
            },
            match status {
                "completed" => "Worker execution completed",
                _ => "Worker execution failed",
            },
            &completed_at,
        )?;
        tx.execute(
            &format!(
                "INSERT INTO worker_inbox(
                    inbox_id,invocation_id,worker_id,severity,result_json,context_attached,created_at
                 )
                 VALUES (?1,?2,?3,?4,?5,{COMPLETED_ENGINE_HOOK_CONTEXT_ATTACHED_SQL},?6)"
            ),
            params![
                format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                invocation_id,
                worker_id,
                severity,
                serde_json::to_string(&inbox_result).map_err(|error| error.to_string())?,
                completed_at,
            ],
        )
        .map_err(|error| format!("record worker inbox result: {error}"))?;
        super::agent_delivery_outbox::insert_terminal_outbox(
            &tx,
            invocation_id,
            worker_id,
            &json!({
                "invocationId":invocation_id,
                "workerId":worker_id,
                "workerVersion":&worker_version,
                "status":status,
                "evidence":&inbox_result,
                "originSessionId":&origin_session_id,
                "traceId":&trace_id,
                "rootInvocationId":&root_invocation_id,
                "causalDepth":causal_depth,
                "interactionMode":&interaction_mode,
                "parentWorkerInvocationId":&parent_worker_invocation_id,
                "triggerKind":&trigger_kind,
                "automaticDeliveryEligible":
                    super::agent_delivery_outbox::automatic_agent_delivery_eligible(
                        origin_session_id.as_deref(),
                        &interaction_mode,
                        parent_worker_invocation_id.as_deref(),
                        &trigger_kind,
                    ),
            }),
            &completed_at,
        )?;
        if status == "completed" {
            super::agent_delivery_outbox::insert_effect_outbox(
                &tx,
                invocation_id,
                worker_id,
                &origin_session_id,
                &trace_id,
                root_invocation_id.as_deref(),
                causal_depth,
                agent_delivery_effects,
                &completed_at,
            )?;
            Self::insert_notification_deliveries(
                &tx,
                invocation_id,
                worker_id,
                &worker_version,
                &trace_id,
                notification_intents,
                &completed_at,
            )?;
            Self::insert_artifacts(
                &tx,
                invocation_id,
                worker_id,
                &worker_version,
                &trace_id,
                artifact_intents,
                &completed_at,
            )?;
            Self::insert_worker_dispatches(
                &tx,
                invocation_id,
                worker_id,
                &worker_version,
                &trace_id,
                causal_depth,
                origin_session_id.as_deref(),
                worker_dispatches,
                &completed_at,
            )?;
            if let Some(wakeup) = worker_wakeup {
                Self::insert_self_wakeup(
                    &tx,
                    invocation_id,
                    worker_id,
                    &worker_version,
                    wakeup,
                    &completed_at,
                )?;
            }
            Self::insert_session_organization_intent(
                &tx,
                invocation_id,
                worker_id,
                &worker_version,
                &trace_id,
                session_organization,
                &completed_at,
            )?;
        }
        tx.execute(
            "UPDATE worker_dispatches
             SET state=?2,completed_at=?3
             WHERE target_invocation_id=?1 AND state IN ('queued','running')",
            params![invocation_id, status, completed_at],
        )
        .map_err(|error| format!("complete inbound worker dispatch evidence: {error}"))?;
        tx.commit().map_err(|error| error.to_string())?;
        self.invocation(invocation_id)?
            .ok_or_else(|| "completed worker invocation disappeared".to_owned())
    }

    fn insert_self_wakeup(
        transaction: &rusqlite::Transaction<'_>,
        source_invocation_id: &str,
        worker_id: &str,
        worker_version: &str,
        wakeup: &PreparedWorkerWakeup,
        created_at: &str,
    ) -> Result<(), String> {
        let target_invocation_id = format!("worker_run_{}", uuid::Uuid::now_v7());
        let trace_id = format!("worker-wakeup-{}", uuid::Uuid::now_v7());
        let internal_idempotency_key = format!("self_wakeup:{}", wakeup.deduplication_key);
        let inserted = transaction
            .execute(
                "INSERT OR IGNORE INTO worker_invocations(
                    invocation_id,worker_id,worker_version,status,input_json,
                    idempotency_key,trace_id,causal_depth,trigger_kind,
                    origin_session_id,interaction_mode,detached_at,
                    created_at,not_before,wake_source_invocation_id
                 )
                 VALUES (?1,?2,?3,'queued',?4,?5,?6,0,'self_wakeup',
                    NULL,'background',?7,?7,?8,?9)",
                params![
                    target_invocation_id,
                    worker_id,
                    worker_version,
                    serde_json::to_string(&wakeup.input).map_err(|error| error.to_string())?,
                    internal_idempotency_key,
                    trace_id,
                    created_at,
                    wakeup.not_before,
                    source_invocation_id,
                ],
            )
            .map_err(|error| format!("admit durable worker self-wakeup: {error}"))?;
        if inserted == 0 {
            insert_audit(
                transaction,
                worker_id,
                "self_wakeup_deduplicated",
                &json!({
                    "sourceInvocationId":source_invocation_id,
                    "deduplicationKey":wakeup.deduplication_key,
                    "notBefore":wakeup.not_before,
                }),
            )?;
            return Ok(());
        }
        upsert_causal_trace(
            transaction,
            &trace_id,
            Some(&target_invocation_id),
            0,
            false,
        )?;
        transaction
            .execute(
                "INSERT INTO worker_trace_deliveries(
                    trace_id,worker_id,trigger_kind,idempotency_key,invocation_id,created_at
                 ) VALUES (?1,?2,'self_wakeup',?3,?4,?5)",
                params![
                    trace_id,
                    worker_id,
                    internal_idempotency_key,
                    target_invocation_id,
                    created_at,
                ],
            )
            .map_err(|error| format!("record durable worker self-wakeup delivery: {error}"))?;
        insert_run_event(
            transaction,
            &target_invocation_id,
            WorkerRunStage::Queued,
            "Queued for a durable self-wakeup",
            created_at,
        )?;
        insert_run_event(
            transaction,
            &target_invocation_id,
            WorkerRunStage::Detached,
            "Waiting for its durable wake time",
            created_at,
        )?;
        insert_audit(
            transaction,
            worker_id,
            "self_wakeup_scheduled",
            &json!({
                "sourceInvocationId":source_invocation_id,
                "targetInvocationId":target_invocation_id,
                "deduplicationKey":wakeup.deduplication_key,
                "notBefore":wakeup.not_before,
            }),
        )
    }
}
