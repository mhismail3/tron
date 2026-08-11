//! Closed self-only durable wakeup output.
//!
//! A worker may ask the durable dispatcher to invoke the same immutable
//! version in the future. The worker owns the wake time and typed input; the
//! kernel owns only transactional custody and delivery after restart.

use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::Value;

use super::types::WorkerBundle;

pub(super) const MAX_WORKER_WAKEUP_INPUT_BYTES: usize = 64 * 1024;
const MAX_WORKER_WAKEUP_DELAY_DAYS: i64 = 366;

#[derive(Clone, Debug)]
pub(super) struct PreparedWorkerWakeup {
    pub(super) not_before: String,
    pub(super) deduplication_key: String,
    pub(super) input: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkerWakeupOutput {
    at: String,
    deduplication_key: String,
    input: Value,
}

pub(super) fn parse_worker_wakeup(
    bundle: &WorkerBundle,
    output: &Value,
    now: DateTime<Utc>,
) -> Result<Option<PreparedWorkerWakeup>, String> {
    let Some(raw) = output.get("workerWakeup") else {
        return Ok(None);
    };
    if bundle
        .output_schema
        .get("properties")
        .and_then(Value::as_object)
        .is_none_or(|properties| !properties.contains_key("workerWakeup"))
    {
        return Err(
            "worker output uses reserved workerWakeup without explicitly declaring it in outputSchema"
                .to_owned(),
        );
    }
    let wakeup: WorkerWakeupOutput = serde_json::from_value(raw.clone())
        .map_err(|error| format!("workerWakeup is invalid: {error}"))?;
    validate_key(&wakeup.deduplication_key)?;
    let input_bytes = serde_json::to_vec(&wakeup.input)
        .map_err(|error| format!("encode workerWakeup.input: {error}"))?
        .len();
    if input_bytes > MAX_WORKER_WAKEUP_INPUT_BYTES {
        return Err(format!(
            "workerWakeup.input exceeds {MAX_WORKER_WAKEUP_INPUT_BYTES} bytes"
        ));
    }
    let at = DateTime::parse_from_rfc3339(&wakeup.at)
        .map_err(|error| format!("workerWakeup.at must be an RFC 3339 timestamp: {error}"))?
        .with_timezone(&Utc);
    if at <= now {
        return Err("workerWakeup.at must be in the future".to_owned());
    }
    if at > now + Duration::days(MAX_WORKER_WAKEUP_DELAY_DAYS) {
        return Err(format!(
            "workerWakeup.at must be no more than {MAX_WORKER_WAKEUP_DELAY_DAYS} days in the future"
        ));
    }
    Ok(Some(PreparedWorkerWakeup {
        not_before: at.to_rfc3339(),
        deduplication_key: wakeup.deduplication_key,
        input: wakeup.input,
    }))
}

fn validate_key(value: &str) -> Result<(), String> {
    if value.trim().is_empty() || value.len() > 64 {
        return Err("workerWakeup.deduplicationKey must contain 1 to 64 UTF-8 bytes".to_owned());
    }
    if value
        .chars()
        .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(
            "workerWakeup.deduplicationKey must not contain whitespace or control characters"
                .to_owned(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::domains::worker_kernel::types::{
        SourceProvenance, WorkerExecutionLimits, WorkerRouting, WorkerRunner,
    };

    fn bundle() -> WorkerBundle {
        WorkerBundle {
            schema_version: "tron.worker_bundle.v1".to_owned(),
            worker_id: Some("scheduler".to_owned()),
            name: "Scheduler".to_owned(),
            description: "Scheduler".to_owned(),
            tool_name: None,
            model_exposure: Default::default(),
            tool_input_schema: Some(json!({"type":"object"})),
            agent_tools: None,
            agent_role: None,
            input_schema: json!({"type":"object"}),
            output_schema: json!({
                "type":"object",
                "properties":{"workerWakeup":{"type":"object"}}
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
            worker_dispatch_routes: Vec::new(),
            routing: WorkerRouting::default(),
            execution_limits: WorkerExecutionLimits::default(),
            presentation: None,
        }
    }

    #[test]
    fn accepts_only_one_bounded_self_wakeup_shape() {
        let now = Utc::now();
        let parsed = parse_worker_wakeup(
            &bundle(),
            &json!({"workerWakeup":{
                "at":(now + Duration::minutes(5)).to_rfc3339(),
                "deduplicationKey":"next-due-1",
                "input":{"action":"tick"}
            }}),
            now,
        )
        .unwrap()
        .unwrap();
        assert_eq!(parsed.deduplication_key, "next-due-1");
        assert_eq!(parsed.input, json!({"action":"tick"}));
    }

    #[test]
    fn rejects_arbitrary_targets_and_unbounded_timestamps() {
        let now = Utc::now();
        let target = parse_worker_wakeup(
            &bundle(),
            &json!({"workerWakeup":{
                "at":(now + Duration::minutes(5)).to_rfc3339(),
                "deduplicationKey":"next-due-1",
                "input":{},
                "workerId":"other"
            }}),
            now,
        )
        .unwrap_err();
        assert!(target.contains("unknown field"));

        let distant = parse_worker_wakeup(
            &bundle(),
            &json!({"workerWakeup":{
                "at":(now + Duration::days(367)).to_rfc3339(),
                "deduplicationKey":"next-due-2",
                "input":{}
            }}),
            now,
        )
        .unwrap_err();
        assert!(distant.contains("366 days"));
    }
}
