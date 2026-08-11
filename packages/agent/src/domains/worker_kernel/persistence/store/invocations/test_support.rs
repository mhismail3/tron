//! Test-only concise admission constructors.

use super::super::*;

impl WorkerStore {
    pub fn begin_invocation(
        &self,
        worker_id: &str,
        worker_version: &str,
        input: &Value,
        idempotency_key: &str,
        trace_id: &str,
        causal_depth: u32,
        trigger_kind: &str,
        origin_session_id: Option<&str>,
    ) -> Result<(InvocationRecord, bool), String> {
        self.begin_invocation_with_model_context(
            worker_id,
            worker_version,
            input,
            idempotency_key,
            trace_id,
            causal_depth,
            trigger_kind,
            origin_session_id,
            WorkerInteractionMode::Foreground,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            64,
            64,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn begin_invocation_with_context(
        &self,
        worker_id: &str,
        worker_version: &str,
        input: &Value,
        idempotency_key: &str,
        trace_id: &str,
        causal_depth: u32,
        trigger_kind: &str,
        origin_session_id: Option<&str>,
        interaction_mode: WorkerInteractionMode,
        model_tool_invocation_id: Option<&str>,
        parent_worker_invocation_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
        retry_of_invocation_id: Option<&str>,
        max_sibling_invocations: Option<u32>,
    ) -> Result<(InvocationRecord, bool), String> {
        self.begin_invocation_with_model_context(
            worker_id,
            worker_version,
            input,
            idempotency_key,
            trace_id,
            causal_depth,
            trigger_kind,
            origin_session_id,
            interaction_mode,
            model_tool_invocation_id,
            parent_worker_invocation_id,
            None,
            parent_worker_tool_ordinal,
            retry_of_invocation_id,
            None,
            None,
            None,
            None,
            max_sibling_invocations,
            64,
            64,
        )
    }
}
