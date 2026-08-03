//! Closed asynchronous worker-to-worker handoff output.
//!
//! A source output selects only one immutable bundle-declared route and a
//! stable mutation key. Runtime preparation resolves the active target version
//! and validates its typed input before persistence atomically completes the
//! source and queues the child.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

use super::types::{WorkerBundle, WorkerDispatchResponseOwner};

pub(super) const MAX_WORKER_DISPATCHES_PER_INVOCATION: usize = 32;
pub(super) const MAX_WORKER_DISPATCH_INPUT_BYTES: usize = 64 * 1024;
pub(super) const MAX_WORKER_DISPATCH_TOTAL_INPUT_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug)]
pub(super) struct PreparedWorkerDispatch {
    pub(super) route: String,
    pub(super) deduplication_key: String,
    pub(super) input: Value,
    pub(super) target_worker_id: String,
    pub(super) target_worker_version: String,
    pub(super) response_owner: WorkerDispatchResponseOwner,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkerDispatchOutput {
    route: String,
    deduplication_key: String,
    input: Value,
}

pub(super) fn parse_worker_dispatches(
    bundle: &WorkerBundle,
    output: &Value,
) -> Result<Vec<(String, String, Value, String, WorkerDispatchResponseOwner)>, String> {
    let Some(raw) = output.get("workerDispatches") else {
        return Ok(Vec::new());
    };
    if bundle.worker_dispatch_routes.is_empty() {
        return Err(
            "worker output uses reserved workerDispatches without declaring workerDispatchRoutes"
                .to_owned(),
        );
    }
    let values = raw
        .as_array()
        .ok_or_else(|| "workerDispatches must be an array".to_owned())?;
    if values.len() > MAX_WORKER_DISPATCHES_PER_INVOCATION {
        return Err(format!(
            "workerDispatches may contain at most {MAX_WORKER_DISPATCHES_PER_INVOCATION} items"
        ));
    }
    let routes = bundle
        .worker_dispatch_routes
        .iter()
        .map(|route| (route.route.as_str(), route))
        .collect::<BTreeMap<_, _>>();
    let mut total_bytes = 0_usize;
    values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let dispatch: WorkerDispatchOutput = serde_json::from_value(value.clone())
                .map_err(|error| format!("workerDispatches[{index}] is invalid: {error}"))?;
            validate_key(&dispatch.route, "route", index)?;
            validate_key(
                &dispatch.deduplication_key,
                "deduplicationKey",
                index,
            )?;
            let route = routes.get(dispatch.route.as_str()).ok_or_else(|| {
                format!(
                    "workerDispatches[{index}].route '{}' is not declared by this worker version",
                    dispatch.route
                )
            })?;
            let input_bytes = serde_json::to_vec(&dispatch.input)
                .map_err(|error| format!("encode workerDispatches[{index}].input: {error}"))?
                .len();
            if input_bytes > MAX_WORKER_DISPATCH_INPUT_BYTES {
                return Err(format!(
                    "workerDispatches[{index}].input exceeds {MAX_WORKER_DISPATCH_INPUT_BYTES} bytes"
                ));
            }
            total_bytes = total_bytes.saturating_add(input_bytes);
            if total_bytes > MAX_WORKER_DISPATCH_TOTAL_INPUT_BYTES {
                return Err(format!(
                    "workerDispatches inputs exceed {MAX_WORKER_DISPATCH_TOTAL_INPUT_BYTES} total bytes"
                ));
            }
            Ok((
                dispatch.route,
                dispatch.deduplication_key,
                dispatch.input,
                route.target_worker_id.clone(),
                route.client_response_owner,
            ))
        })
        .collect()
}

fn validate_key(value: &str, field: &str, index: usize) -> Result<(), String> {
    if value.trim().is_empty() || value.len() > 64 {
        return Err(format!(
            "workerDispatches[{index}].{field} must contain 1 to 64 UTF-8 bytes"
        ));
    }
    if value
        .chars()
        .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(format!(
            "workerDispatches[{index}].{field} must not contain whitespace or control characters"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::domains::worker_kernel::types::{
        SourceProvenance, WorkerDispatchRoute, WorkerRunner,
    };

    fn bundle() -> WorkerBundle {
        WorkerBundle {
            schema_version: "tron.worker_bundle.v1".to_owned(),
            worker_id: Some("source".to_owned()),
            name: "Source".to_owned(),
            description: "Source".to_owned(),
            tool_name: None,
            model_exposure: Default::default(),
            tool_input_schema: Some(json!({"type":"object"})),
            agent_tools: None,
            input_schema: json!({"type":"object"}),
            output_schema: json!({
                "type":"object",
                "properties":{"workerDispatches":{"type":"array"}}
            }),
            runner: WorkerRunner::Command {
                command: vec!["true".to_owned()],
            },
            files: Default::default(),
            dependencies: Vec::new(),
            triggers: Vec::new(),
            secret_bindings: Vec::new(),
            smoke_tests: Vec::new(),
            health_checks: Vec::new(),
            provenance: vec![SourceProvenance {
                source: "test".to_owned(),
                revision: None,
                checksum: None,
            }],
            engine_hooks: Vec::new(),
            engine_deliveries: Vec::new(),
            client_actions: Vec::new(),
            client_deliveries: Vec::new(),
            worker_dispatch_routes: vec![WorkerDispatchRoute {
                route: "policy".to_owned(),
                target_worker_id: "notification-policy".to_owned(),
                client_response_owner: WorkerDispatchResponseOwner::Source,
            }],
            routing: Default::default(),
            execution_limits: Default::default(),
            presentation: None,
        }
    }

    #[test]
    fn parses_only_declared_routes() {
        let parsed = parse_worker_dispatches(
            &bundle(),
            &json!({"workerDispatches":[{
                "route":"policy",
                "deduplicationKey":"occurrence-1",
                "input":{"action":"deliver"}
            }]}),
        )
        .unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].3, "notification-policy");
        assert_eq!(parsed[0].4, WorkerDispatchResponseOwner::Source);
    }

    #[test]
    fn rejects_target_selection_and_oversize_input() {
        let arbitrary_target = parse_worker_dispatches(
            &bundle(),
            &json!({"workerDispatches":[{
                "route":"policy",
                "deduplicationKey":"occurrence-1",
                "targetWorkerId":"other",
                "input":{}
            }]}),
        )
        .unwrap_err();
        assert!(arbitrary_target.contains("unknown field"));

        let oversize = parse_worker_dispatches(
            &bundle(),
            &json!({"workerDispatches":[{
                "route":"policy",
                "deduplicationKey":"occurrence-1",
                "input":{"value":"x".repeat(MAX_WORKER_DISPATCH_INPUT_BYTES)}
            }]}),
        )
        .unwrap_err();
        assert!(oversize.contains("exceeds"));
    }
}
