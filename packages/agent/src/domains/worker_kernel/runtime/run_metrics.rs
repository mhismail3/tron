//! Compact requested-invocation worker metrics.
//!
//! This projection shares durable timing and descendant-usage calculations
//! with run graphs while deliberately avoiding graph nodes, attempts, run
//! events, and agent event payloads. It exists for bounded evaluation and
//! operational reads that need measurements rather than a causal narrative.

use std::collections::HashMap;

use super::run_projection::{invocation_timing, subtree_usage};
use super::*;

const MAX_METRICS_INVOCATIONS: u32 = 128;

impl WorkerRuntime {
    /// Project one requested invocation's closed measurement envelope.
    pub(crate) fn project_run_metrics(
        &self,
        requested: &InvocationRecord,
    ) -> Result<Value, String> {
        let invocations = self.store.invocation_tree(
            &requested.invocation_id,
            MAX_METRICS_INVOCATIONS.saturating_add(1),
        )?;
        if invocations.len() > MAX_METRICS_INVOCATIONS as usize {
            return Err(format!(
                "worker invocation '{}' exceeds the bounded metrics projection",
                requested.invocation_id
            ));
        }

        let mut sessions_by_invocation = HashMap::new();
        for record in &invocations {
            if let Some(session_id) = record.agent_session_id.as_deref()
                && let Some(session) = self
                    .event_store
                    .get_session(session_id)
                    .map_err(|error| format!("load worker agent session: {error}"))?
            {
                sessions_by_invocation.insert(record.invocation_id.clone(), session);
            }
        }
        let worker_name = self
            .store
            .load_version(&requested.worker_id, &requested.worker_version)
            .map_or_else(
                |_| requested.worker_id.clone(),
                |worker| worker.summary.name,
            );
        let timing = invocation_timing(requested, chrono::Utc::now());
        let usage = subtree_usage(
            &requested.invocation_id,
            &invocations,
            &sessions_by_invocation,
        );
        Ok(json!({
            "invocationId":requested.invocation_id,
            "workerId":requested.worker_id,
            "workerName":worker_name,
            "workerVersion":requested.worker_version,
            "status":requested.status,
            "requestedModel":requested.requested_model,
            "requestedReasoningLevel":requested.requested_reasoning_level,
            "effectiveModel":requested.effective_model,
            "effectiveReasoningLevel":requested.effective_reasoning_level,
            "timing":{
                "queueMs":timing.queue_ms,
                "executionMs":timing.execution_ms,
                "wallMs":timing.wall_ms,
            },
            "usage":{
                "inputTokens":usage.input_tokens,
                "outputTokens":usage.output_tokens,
                "cacheReadTokens":usage.cache_read_tokens,
                "cacheCreationTokens":usage.cache_creation_tokens,
                "cost":usage.cost,
                "includesDescendants":true,
            },
        }))
    }
}
