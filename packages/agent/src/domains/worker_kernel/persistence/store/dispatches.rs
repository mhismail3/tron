//! Atomic asynchronous worker handoff persistence and evidence.

use rusqlite::{Transaction, params};

use super::*;
use crate::domains::worker_kernel::types::MAX_CAUSAL_DEPTH;

impl WorkerStore {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn insert_worker_dispatches(
        transaction: &Transaction<'_>,
        source_invocation_id: &str,
        source_worker_id: &str,
        source_worker_version: &str,
        trace_id: &str,
        causal_depth: u32,
        origin_session_id: Option<&str>,
        dispatches: &[PreparedWorkerDispatch],
        created_at: &str,
    ) -> Result<(), String> {
        let child_depth = causal_depth.saturating_add(1);
        if !dispatches.is_empty() && child_depth > MAX_CAUSAL_DEPTH {
            return Err(format!(
                "workerDispatches would exceed causal depth {}",
                MAX_CAUSAL_DEPTH
            ));
        }
        for dispatch in dispatches {
            let existing = transaction
                .query_row(
                    "SELECT target_invocation_id FROM worker_dispatches
                     WHERE source_worker_id=?1 AND route=?2 AND deduplication_key=?3",
                    params![source_worker_id, dispatch.route, dispatch.deduplication_key],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| format!("load worker dispatch replay: {error}"))?;
            if existing.is_some() {
                continue;
            }

            let target_invocation_id = format!("worker_run_{}", uuid::Uuid::now_v7());
            let dispatch_id = format!("worker_dispatch_{}", uuid::Uuid::now_v7());
            let idempotency_key = dispatch_idempotency_key(
                source_worker_id,
                &dispatch.route,
                &dispatch.deduplication_key,
            );
            transaction
                .execute(
                    "INSERT INTO worker_invocations(
                        invocation_id,worker_id,worker_version,status,input_json,
                        idempotency_key,trace_id,causal_depth,trigger_kind,
                        origin_session_id,interaction_mode,detached_at,
                        parent_worker_invocation_id,created_at
                     ) VALUES (?1,?2,?3,'queued',?4,?5,?6,?7,'worker_dispatch',
                        ?8,'background',?9,?10,?9)",
                    params![
                        target_invocation_id,
                        dispatch.target_worker_id,
                        dispatch.target_worker_version,
                        serde_json::to_string(&dispatch.input)
                            .map_err(|error| format!("encode worker dispatch input: {error}"))?,
                        idempotency_key,
                        trace_id,
                        child_depth,
                        origin_session_id,
                        created_at,
                        source_invocation_id,
                    ],
                )
                .map_err(|error| format!("queue worker dispatch target: {error}"))?;
            transaction
                .execute(
                    "INSERT INTO worker_dispatches(
                        dispatch_id,source_invocation_id,source_worker_id,
                        source_worker_version,route,deduplication_key,
                        target_worker_id,target_worker_version,target_invocation_id,
                        response_binding,state,created_at
                     ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,'queued',?11)",
                    params![
                        dispatch_id,
                        source_invocation_id,
                        source_worker_id,
                        source_worker_version,
                        dispatch.route,
                        dispatch.deduplication_key,
                        dispatch.target_worker_id,
                        dispatch.target_worker_version,
                        target_invocation_id,
                        dispatch.response_owner.as_str(),
                        created_at,
                    ],
                )
                .map_err(|error| format!("persist worker dispatch evidence: {error}"))?;
            upsert_causal_trace(transaction, trace_id, None, child_depth, false)?;
            transaction
                .execute(
                    "INSERT INTO worker_trace_deliveries(
                        trace_id,worker_id,trigger_kind,idempotency_key,invocation_id,created_at
                     ) VALUES (?1,?2,'worker_dispatch',?3,?4,?5)",
                    params![
                        trace_id,
                        dispatch.target_worker_id,
                        idempotency_key,
                        target_invocation_id,
                        created_at
                    ],
                )
                .map_err(|error| format!("record worker dispatch trace delivery: {error}"))?;
            insert_run_event(
                transaction,
                &target_invocation_id,
                WorkerRunStage::Queued,
                "Queued from a durable worker dispatch",
                created_at,
            )?;
            insert_run_event(
                transaction,
                &target_invocation_id,
                WorkerRunStage::Detached,
                "Asynchronous worker dispatch continues durably",
                created_at,
            )?;
        }
        Ok(())
    }

    pub(in crate::domains::worker_kernel) fn worker_dispatches_for_source(
        &self,
        source_invocation_id: &str,
    ) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT dispatch_id,route,target_worker_id,target_worker_version,
                        target_invocation_id,response_binding,state,created_at,completed_at
                 FROM worker_dispatches
                 WHERE source_invocation_id=?1
                 ORDER BY created_at,dispatch_id",
            )
            .map_err(|error| format!("prepare worker dispatch evidence: {error}"))?;
        statement
            .query_map([source_invocation_id], |row| {
                Ok(json!({
                    "dispatchId":row.get::<_, String>(0)?,
                    "route":row.get::<_, String>(1)?,
                    "targetWorkerId":row.get::<_, String>(2)?,
                    "targetWorkerVersion":row.get::<_, String>(3)?,
                    "targetInvocationId":row.get::<_, String>(4)?,
                    "responseBinding":row.get::<_, String>(5)?,
                    "state":row.get::<_, String>(6)?,
                    "createdAt":row.get::<_, String>(7)?,
                    "completedAt":row.get::<_, Option<String>>(8)?,
                }))
            })
            .map_err(|error| format!("query worker dispatch evidence: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker dispatch evidence: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn worker_dispatch_for_target(
        &self,
        target_invocation_id: &str,
    ) -> Result<Option<Value>, String> {
        self.connection()?
            .query_row(
                "SELECT dispatch_id,source_invocation_id,source_worker_id,route,
                        target_worker_id,target_worker_version,response_binding,state,
                        completed_at
                 FROM worker_dispatches WHERE target_invocation_id=?1",
                [target_invocation_id],
                |row| {
                    Ok(json!({
                        "dispatchId":row.get::<_, String>(0)?,
                        "sourceInvocationId":row.get::<_, String>(1)?,
                        "sourceWorkerId":row.get::<_, String>(2)?,
                        "route":row.get::<_, String>(3)?,
                        "targetWorkerId":row.get::<_, String>(4)?,
                        "targetWorkerVersion":row.get::<_, String>(5)?,
                        "targetInvocationId":target_invocation_id,
                        "responseBinding":row.get::<_, String>(6)?,
                        "state":row.get::<_, String>(7)?,
                        "completedAt":row.get::<_, Option<String>>(8)?,
                    }))
                },
            )
            .optional()
            .map_err(|error| format!("load target worker dispatch evidence: {error}"))
    }
}

fn dispatch_idempotency_key(source_worker_id: &str, route: &str, key: &str) -> String {
    let digest = hex::encode(Sha256::digest(
        format!("{source_worker_id}\n{route}\n{key}").as_bytes(),
    ));
    format!("worker_dispatch:{digest}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dispatch_idempotency_is_stable_and_does_not_embed_domain_keys() {
        let key = dispatch_idempotency_key(
            "automation-reminders",
            "notification-policy",
            "private-occurrence",
        );
        assert_eq!(
            key,
            dispatch_idempotency_key(
                "automation-reminders",
                "notification-policy",
                "private-occurrence"
            )
        );
        assert!(!key.contains("private"));
    }
}
