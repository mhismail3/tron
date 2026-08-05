//! Durable worker results and run evidence.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::types::InvocationRecord;
use super::Deps;

const DEFAULT_HISTORY_LIMIT: u32 = 20;
const MAX_SUMMARY_HISTORY_LIMIT: u32 = 20;
const MAX_FULL_HISTORY_LIMIT: u32 = 20;
const MAX_GRAPH_HISTORY_LIMIT: u32 = 10;
const SUMMARY_VALUE_BYTES: usize = 512;
const FULL_VALUE_BYTES: usize = 8_192;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HistoryDetail {
    Summary,
    Full,
    Graph,
}

impl HistoryDetail {
    fn parse(invocation: &Invocation) -> Result<Self, String> {
        match invocation
            .payload
            .get("detail")
            .and_then(Value::as_str)
            .unwrap_or("summary")
        {
            "summary" => Ok(Self::Summary),
            "full" => Ok(Self::Full),
            "graph" => Ok(Self::Graph),
            detail => Err(format!("unsupported worker history detail '{detail}'")),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Summary => "summary",
            Self::Full => "full",
            Self::Graph => "graph",
        }
    }

    const fn maximum(self) -> u32 {
        match self {
            Self::Summary => MAX_SUMMARY_HISTORY_LIMIT,
            Self::Full => MAX_FULL_HISTORY_LIMIT,
            Self::Graph => MAX_GRAPH_HISTORY_LIMIT,
        }
    }
}

fn history_limit(invocation: &Invocation, detail: HistoryDetail) -> (u32, bool) {
    let requested = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(u64::from(DEFAULT_HISTORY_LIMIT))
        .min(u64::from(MAX_SUMMARY_HISTORY_LIMIT)) as u32;
    (
        requested.min(detail.maximum()),
        requested > detail.maximum(),
    )
}

fn history_offset(invocation: &Invocation) -> u32 {
    invocation
        .payload
        .get("offset")
        .and_then(Value::as_u64)
        .unwrap_or_default()
        .min(u64::from(u32::MAX)) as u32
}

pub(super) async fn inbox(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let detail = HistoryDetail::parse(invocation)?;
    let (limit, request_truncated) = history_limit(invocation, detail);
    let offset = history_offset(invocation);
    let worker_id = optional_filter_string(invocation, "workerId");
    let context_attached = invocation
        .payload
        .get("contextAttached")
        .and_then(Value::as_bool);
    let attention_only = invocation
        .payload
        .get("attentionOnly")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let severity = optional_enum(invocation, "severity", &["info", "error"])?;
    let mut items = deps.runtime.store().inbox_filtered_page(
        worker_id,
        context_attached,
        severity,
        attention_only,
        limit.saturating_add(1),
        offset,
    )?;
    let has_more = items.len() > limit as usize;
    items.truncate(limit as usize);
    let mut content_truncated = false;
    for item in &mut items {
        let Some(result) = item.get("result").cloned() else {
            continue;
        };
        let (result, truncated) = project_history_value(&result, detail);
        item["result"] = result;
        content_truncated |= truncated;
    }
    let returned = items.len();
    let next_offset = has_more.then_some(offset.saturating_add(returned as u32));
    Ok(json!({
        "detail":detail.as_str(),
        "items":items,
        "returned":returned,
        "truncated":request_truncated || has_more,
        "nextOffset":next_offset,
        "contentTruncated":content_truncated,
    }))
}

pub(super) async fn runs(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let detail = HistoryDetail::parse(invocation)?;
    let (limit, request_truncated) = history_limit(invocation, detail);
    let offset = history_offset(invocation);
    let worker_id = optional_filter_string(invocation, "workerId");
    let origin_session_id = optional_filter_string(invocation, "originSessionId");
    let invocation_id = optional_filter_string(invocation, "invocationId");
    let model_tool_invocation_id = optional_filter_string(invocation, "modelToolInvocationId");
    let status = optional_enum(
        invocation,
        "status",
        &["queued", "running", "completed", "failed", "cancelled"],
    )?;
    let mut runs = if detail == HistoryDetail::Graph
        && invocation_id.is_none()
        && model_tool_invocation_id.is_none()
    {
        deps.runtime.store().run_roots_filtered_page(
            worker_id,
            status,
            origin_session_id,
            limit.saturating_add(1),
            offset,
        )?
    } else {
        deps.runtime.store().runs_filtered_page_exact(
            worker_id,
            status,
            origin_session_id,
            invocation_id,
            model_tool_invocation_id,
            limit.saturating_add(1),
            offset,
        )?
    };
    let has_more = runs.len() > limit as usize;
    runs.truncate(limit as usize);
    let mut attempts = serde_json::Map::new();
    let mut traces = serde_json::Map::new();
    if detail == HistoryDetail::Full {
        for run in &runs {
            let _ = attempts.insert(
                run.invocation_id.clone(),
                Value::Array(deps.runtime.store().attempts(&run.invocation_id)?),
            );
            if !traces.contains_key(&run.trace_id)
                && let Some(trace) = deps.runtime.store().trace(&run.trace_id)?
            {
                let _ = traces.insert(run.trace_id.clone(), trace);
            }
        }
    }
    let mut graphs = Vec::new();
    if detail == HistoryDetail::Graph {
        let mut projected_roots = BTreeSet::new();
        for run in &runs {
            let root_id = deps
                .runtime
                .store()
                .invocation_tree_root(&run.invocation_id)?;
            if projected_roots.insert(root_id) {
                graphs.push(deps.runtime.project_run_graph(run)?);
            }
        }
    }
    let (runs, content_truncated): (Vec<_>, Vec<_>) = runs
        .iter()
        .map(|run| project_invocation(run, detail))
        .unzip();
    let returned = runs.len();
    let next_offset = has_more.then_some(offset.saturating_add(returned as u32));
    Ok(json!({
        "detail":detail.as_str(),
        "runs":runs,
        "attempts":attempts,
        "traces":traces,
        "graphs":graphs,
        "returned":returned,
        "truncated":request_truncated || has_more,
        "nextOffset":next_offset,
        "contentTruncated":content_truncated.into_iter().any(|truncated| truncated),
    }))
}

fn project_invocation(record: &InvocationRecord, detail: HistoryDetail) -> (Value, bool) {
    let mut value = serde_json::to_value(record).unwrap_or_else(|_| json!({}));
    let (input, input_truncated) = project_history_value(&record.input, detail);
    value["input"] = input;
    let mut content_truncated = input_truncated;
    if let Some(output) = record.output.as_ref() {
        let (output, output_truncated) = project_history_value(output, detail);
        value["output"] = output;
        content_truncated |= output_truncated;
    }
    if let Some(error) = record.error.as_deref() {
        let maximum = match detail {
            HistoryDetail::Summary => SUMMARY_VALUE_BYTES,
            HistoryDetail::Full | HistoryDetail::Graph => FULL_VALUE_BYTES,
        };
        if error.len() > maximum {
            value["error"] = Value::String(crate::shared::foundation::text::truncate_with_suffix(
                error, maximum, "...",
            ));
            content_truncated = true;
        }
    }
    (value, content_truncated)
}

fn project_history_value(value: &Value, detail: HistoryDetail) -> (Value, bool) {
    if is_worker_result_reference(value)
        || value
            .get("reference")
            .is_some_and(is_worker_result_reference)
    {
        return (value.clone(), false);
    }
    let serialized = serde_json::to_string(value).unwrap_or_else(|_| "null".to_owned());
    let maximum = match detail {
        HistoryDetail::Summary => SUMMARY_VALUE_BYTES,
        HistoryDetail::Full | HistoryDetail::Graph => FULL_VALUE_BYTES,
    };
    let truncated = serialized.len() > maximum;
    if detail != HistoryDetail::Summary && !truncated {
        return (value.clone(), false);
    }
    (
        json!({
            "preview":crate::shared::foundation::text::truncate_with_suffix(
                &serialized,
                maximum,
                "...",
            ),
            "originalBytes":serialized.len(),
            "truncated":truncated,
        }),
        truncated,
    )
}

fn is_worker_result_reference(value: &Value) -> bool {
    value.get("kind").and_then(Value::as_str) == Some("worker_result_reference")
}

/// Provider tool calls can materialize omitted optional string fields as empty
/// strings. An empty exact-match filter means "not supplied"; treating it as a
/// real identifier makes otherwise exact run lookups silently return no rows.
fn optional_filter_string<'a>(invocation: &'a Invocation, field: &str) -> Option<&'a str> {
    invocation
        .payload
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
}

fn optional_enum<'a>(
    invocation: &'a Invocation,
    field: &str,
    admitted: &[&str],
) -> Result<Option<&'a str>, String> {
    let Some(value) = invocation.payload.get(field).and_then(Value::as_str) else {
        return Ok(None);
    };
    if admitted.contains(&value) {
        Ok(Some(value))
    } else {
        Err(format!("unsupported worker history {field} '{value}'"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_values_are_compact_observations_and_full_values_have_a_hard_ceiling() {
        let small = json!({"answer":42});
        let (summary, summary_truncated) = project_history_value(&small, HistoryDetail::Summary);
        assert_eq!(summary["preview"], "{\"answer\":42}");
        assert_eq!(summary["truncated"], false);
        assert!(!summary_truncated);

        let (full, full_truncated) = project_history_value(&small, HistoryDetail::Full);
        assert_eq!(full, small);
        assert!(!full_truncated);

        let large = json!({"body":"x".repeat(FULL_VALUE_BYTES * 2)});
        let (bounded, bounded_truncated) = project_history_value(&large, HistoryDetail::Full);
        assert!(bounded_truncated);
        assert_eq!(bounded["truncated"], true);
        assert!(bounded["preview"].as_str().unwrap().len() <= FULL_VALUE_BYTES);

        let reference = json!({
            "kind":"worker_result_reference",
            "invocationId":"run-1",
            "preview":"ready",
        });
        let receipt = json!({
            "status":"completed",
            "reference":reference,
            "preview":"ready",
        });
        for detail in [
            HistoryDetail::Summary,
            HistoryDetail::Full,
            HistoryDetail::Graph,
        ] {
            let (projected, truncated) = project_history_value(&receipt, detail);
            assert_eq!(projected, receipt);
            assert!(!truncated);
        }
    }

    #[test]
    fn empty_optional_filters_are_absent() {
        let invocation = Invocation::new_sync(
            crate::engine::FunctionId::new("worker_kernel::runs").unwrap(),
            json!({
                "workerId":"",
                "originSessionId":"   ",
                "invocationId":"worker_run_exact",
                "modelToolInvocationId":""
            }),
            crate::engine::CausalContext::new(
                crate::engine::ActorId::new("agent:filter-test").unwrap(),
                crate::engine::ActorKind::Agent,
                crate::engine::TraceId::new("trace-filter-test").unwrap(),
            ),
        );
        assert_eq!(optional_filter_string(&invocation, "workerId"), None);
        assert_eq!(optional_filter_string(&invocation, "originSessionId"), None);
        assert_eq!(
            optional_filter_string(&invocation, "invocationId"),
            Some("worker_run_exact")
        );
        assert_eq!(optional_filter_string(&invocation, "missing"), None);
    }
}
