//! Transactional worker invocation completion and client-delivery admission.

use rusqlite::params;
use serde_json::{Value, json};

use super::invocations::COMPLETED_ENGINE_HOOK_CONTEXT_ATTACHED_SQL;
use super::*;

impl WorkerStore {
    pub fn complete_invocation(
        &self,
        invocation_id: &str,
        worker_id: &str,
        result: Result<&Value, &str>,
    ) -> Result<InvocationRecord, String> {
        match result {
            Ok(output) => {
                self.complete_invocation_with_effects(invocation_id, worker_id, output, &[], &[])
            }
            Err(error) => {
                self.complete_invocation_inner(invocation_id, worker_id, Err(error), &[], &[])
            }
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
        )
    }

    pub(in crate::domains::worker_kernel) fn complete_invocation_with_effects(
        &self,
        invocation_id: &str,
        worker_id: &str,
        output: &Value,
        notification_intents: &[crate::domains::worker_kernel::notifications::NotificationIntent],
        worker_dispatches: &[PreparedWorkerDispatch],
    ) -> Result<InvocationRecord, String> {
        self.complete_invocation_inner(
            invocation_id,
            worker_id,
            Ok(output),
            notification_intents,
            worker_dispatches,
        )
    }

    fn complete_invocation_inner(
        &self,
        invocation_id: &str,
        worker_id: &str,
        result: Result<&Value, &str>,
        notification_intents: &[crate::domains::worker_kernel::notifications::NotificationIntent],
        worker_dispatches: &[PreparedWorkerDispatch],
    ) -> Result<InvocationRecord, String> {
        let mut connection = self.connection()?;
        let tx = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let (trace_id, origin_session_id, worker_version, causal_depth): (
            String,
            Option<String>,
            String,
            u32,
        ) = tx
            .query_row(
                "SELECT trace_id,origin_session_id,worker_version,causal_depth
                 FROM worker_invocations
                 WHERE invocation_id=?1 AND worker_id=?2 AND status='running'",
                params![invocation_id, worker_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
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
        if status == "completed" {
            Self::insert_notification_deliveries(
                &tx,
                invocation_id,
                worker_id,
                &worker_version,
                &trace_id,
                notification_intents,
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
}
