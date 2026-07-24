//! Authoritative bounded worker-run graph projection.
//!
//! The projection joins the existing invocation, attempt, stage-evidence,
//! child-session, model-turn, and inbox ledgers. It never owns execution state:
//! reconnecting clients receive the same reconstruction from persisted server
//! truth, while domain-specific wording remains in immutable worker metadata.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use super::run_projection_format::*;
use super::*;
use crate::domains::session::event_store::{EventRow, SessionRow};

const MAX_GRAPH_INVOCATIONS: u32 = 128;
const MAX_GRAPH_NODES: usize = 512;
const MAX_GRAPH_TIMELINE: usize = 1_000;
const MAX_AGENT_EVENTS: i64 = 500;

impl WorkerRuntime {
    /// Reconstruct one causal run tree from durable kernel and session facts.
    pub(crate) fn project_run_graph(&self, requested: &InvocationRecord) -> Result<Value, String> {
        let root_id = self.store.invocation_tree_root(&requested.invocation_id)?;
        let mut invocations = self
            .store
            .invocation_tree(&root_id, MAX_GRAPH_INVOCATIONS.saturating_add(1))?;
        let invocation_truncated = invocations.len() > MAX_GRAPH_INVOCATIONS as usize;
        invocations.truncate(MAX_GRAPH_INVOCATIONS as usize);
        let root = invocations
            .first()
            .ok_or_else(|| format!("worker invocation '{root_id}' disappeared"))?;
        let invocation_ids = invocations
            .iter()
            .map(|record| record.invocation_id.clone())
            .collect::<Vec<_>>();
        let run_events = self.store.run_events(&invocation_ids)?;
        let worker_info = invocations
            .iter()
            .map(|record| {
                let active = self
                    .store
                    .load_version(&record.worker_id, &record.worker_version)
                    .ok();
                let name = active.as_ref().map_or_else(
                    || record.worker_id.clone(),
                    |worker| worker.summary.name.clone(),
                );
                let runner = active
                    .as_ref()
                    .map_or("unknown", |worker| worker.bundle.runner.kind())
                    .to_owned();
                let presentation = active
                    .as_ref()
                    .and_then(|worker| worker.bundle.presentation.clone());
                (
                    record.invocation_id.clone(),
                    WorkerProjectionInfo {
                        name,
                        runner,
                        presentation,
                    },
                )
            })
            .collect::<HashMap<_, _>>();

        let now = chrono::Utc::now();
        let mut nodes = Vec::new();
        let mut timeline = Vec::new();
        let mut model_duration_ms = 0_u64;
        let mut usage = UsageTotals::default();
        let child_model_tool_ids = invocations
            .iter()
            .filter_map(|record| record.model_tool_invocation_id.as_deref())
            .collect::<BTreeSet<_>>();

        for record in &invocations {
            let info = worker_info
                .get(&record.invocation_id)
                .expect("projection metadata exists");
            let stage = invocation_stage(record, &run_events);
            nodes.push(invocation_node(record, info, stage, now));
            for attempt in self.store.attempts(&record.invocation_id)? {
                nodes.push(attempt_node(record, &attempt, now));
                append_attempt_timeline(record, &attempt, &mut timeline);
            }
            if let Some(session_id) = record.agent_session_id.as_deref()
                && let Some(session) = self
                    .event_store
                    .get_session(session_id)
                    .map_err(|error| format!("load worker agent session: {error}"))?
            {
                let rows = self
                    .event_store
                    .get_latest_events(session_id, Some(MAX_AGENT_EVENTS))
                    .map_err(|error| format!("load worker agent events: {error}"))?;
                let payloads = self
                    .event_store
                    .resolve_event_payloads(&rows)
                    .map_err(|error| format!("resolve worker agent events: {error}"))?;
                nodes.push(agent_node(record, &session, now));
                append_session_projection(
                    &session,
                    &rows,
                    &payloads,
                    &child_model_tool_ids,
                    &mut nodes,
                    &mut timeline,
                    &mut model_duration_ms,
                    &mut usage,
                    now,
                );
            }
        }
        append_run_event_timeline(&run_events, &mut timeline);
        append_invocation_fact_timeline(&invocations, &run_events, &worker_info, &mut timeline);
        append_derived_synthesis_timeline(&invocations, &worker_info, &mut timeline);
        timeline.sort_by(timeline_order);
        timeline.truncate(MAX_GRAPH_TIMELINE);
        nodes.truncate(MAX_GRAPH_NODES);

        let (stage, stage_label) = graph_stage(&invocations, &run_events, &worker_info);
        let counts = status_counts(&invocations);
        let critical_path_node_ids = critical_path(&invocations, now);
        let root_timing = invocation_timing(root, now);
        let child_critical_path_ms = invocations
            .iter()
            .skip(1)
            .map(|record| invocation_timing(record, now).wall_ms)
            .max()
            .unwrap_or_default();

        Ok(json!({
            "rootInvocationId":root.invocation_id,
            "requestedInvocationId":requested.invocation_id,
            "modelToolInvocationId":root.model_tool_invocation_id,
            "originSessionId":root.origin_session_id,
            "workerId":root.worker_id,
            "workerName":worker_info.get(&root.invocation_id).map(|info| info.name.as_str()).unwrap_or(root.worker_id.as_str()),
            "requestPreview":preview_request(&root.input),
            "status":root.status,
            "mode":root.interaction_mode.as_str(),
            "stage":stage.as_str(),
            "stageLabel":stage_label,
            "expectedNextTransition":expected_next_transition(stage),
            "createdAt":root.created_at,
            "startedAt":root.started_at,
            "completedAt":root.completed_at,
            "elapsedMs":root_timing.wall_ms,
            "counts":counts,
            "timing":{
                "queueMs":root_timing.queue_ms,
                "executionMs":root_timing.execution_ms,
                "wallMs":root_timing.wall_ms,
                "modelMs":model_duration_ms,
                "childCriticalPathMs":child_critical_path_ms,
                "criticalPathMs":root_timing.wall_ms,
                "criticalPathNodeIds":critical_path_node_ids,
            },
            "usage":{
                "inputTokens":usage.input_tokens,
                "outputTokens":usage.output_tokens,
                "cacheReadTokens":usage.cache_read_tokens,
                "cacheCreationTokens":usage.cache_creation_tokens,
                "cost":usage.cost,
            },
            "nodes":nodes,
            "timeline":timeline,
            "resultPreview":root.output.as_ref().map(preview_result),
            "errorPreview":root.error.as_deref().map(preview_text),
            "truncated":invocation_truncated
                || nodes.len() >= MAX_GRAPH_NODES
                || timeline.len() >= MAX_GRAPH_TIMELINE,
        }))
    }
}

#[derive(Clone)]
struct WorkerProjectionInfo {
    name: String,
    runner: String,
    presentation: Option<super::super::types::WorkerPresentation>,
}

#[derive(Clone, Copy, Default)]
struct Timing {
    queue_ms: u64,
    execution_ms: u64,
    wall_ms: u64,
}

#[derive(Default)]
struct UsageTotals {
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_creation_tokens: i64,
    cost: f64,
}

fn invocation_node(
    record: &InvocationRecord,
    info: &WorkerProjectionInfo,
    stage: WorkerRunStage,
    now: chrono::DateTime<chrono::Utc>,
) -> Value {
    let timing = invocation_timing(record, now);
    json!({
        "id":invocation_node_id(&record.invocation_id),
        "kind":"invocation",
        "parentId":record.parent_worker_invocation_id.as_deref().map(invocation_node_id),
        "invocationId":record.invocation_id,
        "workerId":record.worker_id,
        "workerName":info.name,
        "workerVersion":record.worker_version,
        "runner":info.runner,
        "status":record.status,
        "mode":record.interaction_mode.as_str(),
        "stage":stage.as_str(),
        "createdAt":record.created_at,
        "startedAt":record.started_at,
        "completedAt":record.completed_at,
        "elapsedMs":timing.wall_ms,
        "queueMs":timing.queue_ms,
        "executionMs":timing.execution_ms,
        "attemptCount":record.attempt_count,
        "sessionId":record.agent_session_id,
        "modelToolInvocationId":record.model_tool_invocation_id,
        "retryOfInvocationId":record.retry_of_invocation_id,
        "resultPreview":record.output.as_ref().map(preview_result),
        "errorPreview":record.error.as_deref().map(preview_text),
        "presentation":info.presentation,
    })
}

fn attempt_node(
    record: &InvocationRecord,
    attempt: &Value,
    now: chrono::DateTime<chrono::Utc>,
) -> Value {
    let started = attempt["startedAt"].as_str();
    let completed = attempt["completedAt"].as_str();
    json!({
        "id":format!("attempt:{}",attempt["attemptId"].as_str().unwrap_or_default()),
        "kind":"attempt",
        "parentId":invocation_node_id(&record.invocation_id),
        "invocationId":record.invocation_id,
        "attemptNumber":attempt["attemptNumber"],
        "status":attempt["status"],
        "startedAt":attempt["startedAt"],
        "completedAt":attempt["completedAt"],
        "elapsedMs":duration_between(started, completed, now),
        "errorPreview":attempt["error"].as_str().map(preview_text),
    })
}

fn agent_node(
    record: &InvocationRecord,
    session: &SessionRow,
    now: chrono::DateTime<chrono::Utc>,
) -> Value {
    json!({
        "id":agent_node_id(&session.id),
        "kind":"agent",
        "parentId":invocation_node_id(&record.invocation_id),
        "sessionId":session.id,
        "model":session.latest_model,
        "status":record.status,
        "startedAt":session.created_at,
        "completedAt":record.completed_at,
        "elapsedMs":duration_between(Some(&session.created_at), record.completed_at.as_deref(), now),
        "inputTokens":session.total_input_tokens,
        "outputTokens":session.total_output_tokens,
        "cacheReadTokens":session.total_cache_read_tokens,
        "cacheCreationTokens":session.total_cache_creation_tokens,
        "cost":session.total_cost,
    })
}

#[allow(clippy::too_many_arguments)]
fn append_session_projection(
    session: &SessionRow,
    rows: &[EventRow],
    payloads: &[Value],
    child_model_tool_ids: &BTreeSet<&str>,
    nodes: &mut Vec<Value>,
    timeline: &mut Vec<Value>,
    model_duration_ms: &mut u64,
    usage: &mut UsageTotals,
    now: chrono::DateTime<chrono::Utc>,
) {
    usage.input_tokens += session.total_input_tokens;
    usage.output_tokens += session.total_output_tokens;
    usage.cache_read_tokens += session.total_cache_read_tokens;
    usage.cache_creation_tokens += session.total_cache_creation_tokens;
    usage.cost += session.total_cost;

    let mut turn_starts = BTreeMap::<i64, &EventRow>::new();
    for (row, payload) in rows.iter().zip(payloads) {
        match row.event_type.as_str() {
            "stream.turn_start" => {
                if let Some(turn) = row.turn.or_else(|| payload["turn"].as_i64()) {
                    let _ = turn_starts.insert(turn, row);
                }
            }
            "stream.turn_end" | "turn.failed" => {
                let turn = row
                    .turn
                    .or_else(|| payload["turn"].as_i64())
                    .unwrap_or_default();
                let started = turn_starts.get(&turn).map(|event| event.timestamp.as_str());
                let duration = row
                    .latency_ms
                    .and_then(|value| u64::try_from(value).ok())
                    .unwrap_or_else(|| duration_between(started, Some(&row.timestamp), now));
                *model_duration_ms = model_duration_ms.saturating_add(duration);
                nodes.push(json!({
                    "id":model_node_id(&session.id, turn),
                    "kind":"model",
                    "parentId":agent_node_id(&session.id),
                    "sessionId":session.id,
                    "turn":turn,
                    "model":row.model.as_deref().unwrap_or(session.latest_model.as_str()),
                    "status":if row.event_type=="turn.failed" {"failed"} else {"completed"},
                    "startedAt":started,
                    "completedAt":row.timestamp,
                    "elapsedMs":duration,
                    "inputTokens":row.input_tokens.unwrap_or_default(),
                    "outputTokens":row.output_tokens.unwrap_or_default(),
                    "cacheReadTokens":row.cache_read_tokens.unwrap_or_default(),
                    "cacheCreationTokens":row.cache_creation_tokens.unwrap_or_default(),
                    "cost":row.cost.unwrap_or_default(),
                    "errorPreview":(row.event_type=="turn.failed").then(|| preview_text(
                        payload["error"].as_str().unwrap_or("Model turn failed")
                    )),
                }));
                timeline.push(json!({
                    "occurredAt":row.timestamp,
                    "nodeId":model_node_id(&session.id,turn),
                    "stage":if row.event_type=="turn.failed" {"retry_repair"} else {"planning"},
                    "status":if row.event_type=="turn.failed" {"failed"} else {"completed"},
                    "summary":if row.event_type=="turn.failed" {
                        format!("Model turn {} failed",turn)
                    } else {
                        format!("Model turn {} completed",turn)
                    },
                    "technical":false,
                }));
            }
            "tool.invocation.started" | "tool.invocation.completed" => {
                let invocation_id = row
                    .invocation_id
                    .as_deref()
                    .or_else(|| payload["invocationId"].as_str());
                if invocation_id.is_some_and(|id| child_model_tool_ids.contains(id)) {
                    continue;
                }
                let tool_name = row
                    .tool_name
                    .as_deref()
                    .or_else(|| payload["toolName"].as_str())
                    .unwrap_or("tool");
                let started = row.event_type == "tool.invocation.started";
                timeline.push(json!({
                    "occurredAt":row.timestamp,
                    "nodeId":agent_node_id(&session.id),
                    "stage":"planning",
                    "status":if started {"running"} else if payload["isError"].as_bool().unwrap_or(false) {"failed"} else {"completed"},
                    "summary":format!(
                        "{} {}",
                        if started {"Started"} else {"Finished"},
                        friendly_tool_name(tool_name)
                    ),
                    "technical":is_technical_tool(tool_name),
                }));
            }
            _ => {}
        }
    }
}

fn append_run_event_timeline(events: &[WorkerRunEvent], timeline: &mut Vec<Value>) {
    for event in events {
        timeline.push(json!({
            "occurredAt":event.occurred_at,
            "nodeId":invocation_node_id(&event.invocation_id),
            "stage":event.stage.as_str(),
            "status":stage_status(event.stage),
            "summary":event.summary,
            "technical":false,
        }));
    }
}

fn append_invocation_fact_timeline(
    invocations: &[InvocationRecord],
    events: &[WorkerRunEvent],
    info: &HashMap<String, WorkerProjectionInfo>,
    timeline: &mut Vec<Value>,
) {
    for record in invocations {
        if events
            .iter()
            .any(|event| event.invocation_id == record.invocation_id)
        {
            continue;
        }
        let node_id = invocation_node_id(&record.invocation_id);
        timeline.push(json!({
            "occurredAt":record.created_at,
            "nodeId":&node_id,
            "stage":"queued",
            "status":"queued",
            "summary":"Queued for durable worker execution",
            "technical":false,
        }));
        if let Some(detached_at) = record.detached_at.as_deref() {
            timeline.push(json!({
                "occurredAt":detached_at,
                "nodeId":&node_id,
                "stage":"detached",
                "status":"running",
                "summary":"Conversation released while durable work continues",
                "technical":false,
            }));
        }
        if let Some(started_at) = record.started_at.as_deref() {
            let retry = record.attempt_count > 1;
            let agent = info
                .get(&record.invocation_id)
                .is_some_and(|value| value.runner == "agent");
            timeline.push(json!({
                "occurredAt":started_at,
                "nodeId":&node_id,
                "stage":if retry {"retry_repair"} else if agent {"planning"} else {"specialist_execution"},
                "status":"running",
                "summary":if retry {
                    "Retrying interrupted durable delivery"
                } else if agent {
                    "Planning worker execution"
                } else {
                    "Executing the worker runner"
                },
                "technical":false,
            }));
        }
        if let Some(completed_at) = record.completed_at.as_deref()
            && let Some(stage) = terminal_stage(&record.status)
        {
            timeline.push(json!({
                "occurredAt":completed_at,
                "nodeId":&node_id,
                "stage":stage.as_str(),
                "status":record.status,
                "summary":stage_label(stage,None),
                "technical":false,
            }));
        }
    }
}

fn append_attempt_timeline(record: &InvocationRecord, attempt: &Value, timeline: &mut Vec<Value>) {
    let number = attempt["attemptNumber"].as_u64().unwrap_or_default();
    if let Some(started_at) = attempt["startedAt"].as_str() {
        timeline.push(json!({
            "occurredAt":started_at,
            "nodeId":format!("attempt:{}",attempt["attemptId"].as_str().unwrap_or_default()),
            "stage":if number>1 {"retry_repair"} else {"specialist_execution"},
            "status":"running",
            "summary":format!("Attempt {number} started"),
            "technical":false,
        }));
    }
    if let Some(completed_at) = attempt["completedAt"].as_str() {
        timeline.push(json!({
            "occurredAt":completed_at,
            "nodeId":format!("attempt:{}",attempt["attemptId"].as_str().unwrap_or_default()),
            "stage":match attempt["status"].as_str().unwrap_or_default() {
                "interrupted" => "interrupted",
                "failed" => "failed",
                "cancelled" => "cancelled",
                _ => "publication",
            },
            "status":attempt["status"],
            "summary":format!(
                "Attempt {number} {}",
                attempt["status"].as_str().unwrap_or("finished")
            ),
            "technical":false,
            "invocationId":record.invocation_id,
        }));
    }
}

fn append_derived_synthesis_timeline(
    invocations: &[InvocationRecord],
    info: &HashMap<String, WorkerProjectionInfo>,
    timeline: &mut Vec<Value>,
) {
    for parent in invocations {
        if info
            .get(&parent.invocation_id)
            .map(|value| value.runner.as_str())
            != Some("agent")
        {
            continue;
        }
        let children = invocations
            .iter()
            .filter(|child| {
                child.parent_worker_invocation_id.as_deref() == Some(&parent.invocation_id)
            })
            .collect::<Vec<_>>();
        if children.is_empty() || children.iter().any(|child| !is_terminal(&child.status)) {
            continue;
        }
        let Some(occurred_at) = children
            .iter()
            .filter_map(|child| child.completed_at.as_deref())
            .max()
        else {
            continue;
        };
        timeline.push(json!({
            "occurredAt":occurred_at,
            "nodeId":invocation_node_id(&parent.invocation_id),
            "stage":"synthesis",
            "status":"running",
            "summary":"Specialist work finished; synthesis can continue",
            "technical":false,
        }));
    }
}

fn graph_stage(
    invocations: &[InvocationRecord],
    events: &[WorkerRunEvent],
    info: &HashMap<String, WorkerProjectionInfo>,
) -> (WorkerRunStage, String) {
    let root = &invocations[0];
    if let Some(stage) = terminal_stage(&root.status) {
        return (stage, stage_label(stage, None));
    }
    let active_child = invocations
        .iter()
        .skip(1)
        .filter(|record| !is_terminal(&record.status))
        .max_by_key(|record| {
            (
                record.causal_depth,
                u8::from(record.status == "running"),
                record.created_at.as_str(),
            )
        });
    if let Some(child) = active_child {
        let child_name = info
            .get(&child.invocation_id)
            .map(|value| value.name.as_str());
        if child.attempt_count > 1 {
            return (
                WorkerRunStage::RetryRepair,
                format!(
                    "Repairing or retrying {}",
                    child_name.unwrap_or("specialist work")
                ),
            );
        }
        return (
            WorkerRunStage::SpecialistExecution,
            format!(
                "{} {}",
                if child.status == "queued" {
                    "Waiting for"
                } else {
                    "Running"
                },
                child_name.unwrap_or("specialist work")
            ),
        );
    }
    if root.status == "queued" {
        return (
            WorkerRunStage::Queued,
            "Queued for durable worker execution".to_owned(),
        );
    }
    if root.attempt_count > 1 {
        return (
            WorkerRunStage::RetryRepair,
            "Retrying interrupted durable delivery".to_owned(),
        );
    }
    let has_terminal_children = invocations
        .iter()
        .skip(1)
        .any(|record| is_terminal(&record.status));
    if info
        .get(&root.invocation_id)
        .map(|value| value.runner.as_str())
        == Some("agent")
        && has_terminal_children
    {
        return (
            WorkerRunStage::Synthesis,
            "Synthesizing completed specialist work".to_owned(),
        );
    }
    let latest = events
        .iter()
        .filter(|event| event.invocation_id == root.invocation_id)
        .max_by_key(|event| event.sequence)
        .map(|event| event.stage)
        .unwrap_or_else(|| invocation_stage(root, events));
    (latest, stage_label(latest, None))
}

fn invocation_stage(record: &InvocationRecord, events: &[WorkerRunEvent]) -> WorkerRunStage {
    if let Some(stage) = terminal_stage(&record.status) {
        return stage;
    }
    if record.status == "queued" {
        return WorkerRunStage::Queued;
    }
    events
        .iter()
        .filter(|event| event.invocation_id == record.invocation_id)
        .max_by_key(|event| event.sequence)
        .map(|event| event.stage)
        .unwrap_or(WorkerRunStage::SpecialistExecution)
}

fn terminal_stage(status: &str) -> Option<WorkerRunStage> {
    match status {
        "completed" => Some(WorkerRunStage::Completed),
        "failed" => Some(WorkerRunStage::Failed),
        "cancelled" => Some(WorkerRunStage::Cancelled),
        _ => None,
    }
}

fn stage_label(stage: WorkerRunStage, subject: Option<&str>) -> String {
    match stage {
        WorkerRunStage::Queued => "Queued for durable worker execution",
        WorkerRunStage::Planning => "Planning the delegated work",
        WorkerRunStage::SpecialistExecution => subject.unwrap_or("Running specialist work"),
        WorkerRunStage::RetryRepair => "Repairing or retrying worker output",
        WorkerRunStage::Synthesis => "Synthesizing completed worker evidence",
        WorkerRunStage::Validation => "Validating the typed worker result",
        WorkerRunStage::Publication => "Publishing the durable worker result",
        WorkerRunStage::Detached => "Continuing in the background",
        WorkerRunStage::Completed => "Worker execution completed",
        WorkerRunStage::Failed => "Worker execution failed",
        WorkerRunStage::Cancelled => "Worker execution cancelled",
        WorkerRunStage::Interrupted => "Worker delivery was interrupted",
    }
    .to_owned()
}

fn expected_next_transition(stage: WorkerRunStage) -> Option<&'static str> {
    match stage {
        WorkerRunStage::Queued => Some("Execution begins when capacity is available"),
        WorkerRunStage::Planning => Some("Planning yields to specialist work or synthesis"),
        WorkerRunStage::SpecialistExecution => {
            Some("Active specialist work reaches a terminal result")
        }
        WorkerRunStage::RetryRepair => Some("Repair validates or reaches its retry ceiling"),
        WorkerRunStage::Synthesis => Some("Synthesis produces a typed result for validation"),
        WorkerRunStage::Validation => Some("Validated output is published to the durable inbox"),
        WorkerRunStage::Publication => {
            Some("The result becomes available to the originating session")
        }
        WorkerRunStage::Detached => Some("Durable execution continues independently"),
        WorkerRunStage::Interrupted => Some("The same invocation is redelivered"),
        WorkerRunStage::Completed | WorkerRunStage::Failed | WorkerRunStage::Cancelled => None,
    }
}

fn status_counts(invocations: &[InvocationRecord]) -> Value {
    let mut counts = BTreeMap::from([
        ("queued", 0_u64),
        ("running", 0),
        ("completed", 0),
        ("failed", 0),
        ("cancelled", 0),
    ]);
    for record in invocations {
        if let Some(count) = counts.get_mut(record.status.as_str()) {
            *count += 1;
        }
    }
    serde_json::to_value(counts).unwrap_or_else(|_| json!({}))
}

fn critical_path(
    invocations: &[InvocationRecord],
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<String> {
    let by_parent = invocations.iter().fold(
        HashMap::<Option<&str>, Vec<&InvocationRecord>>::new(),
        |mut values, record| {
            values
                .entry(record.parent_worker_invocation_id.as_deref())
                .or_default()
                .push(record);
            values
        },
    );
    let mut path = Vec::new();
    let mut current = invocations.first();
    while let Some(record) = current {
        path.push(invocation_node_id(&record.invocation_id));
        current = by_parent
            .get(&Some(record.invocation_id.as_str()))
            .and_then(|children| {
                children
                    .iter()
                    .copied()
                    .max_by_key(|child| invocation_timing(child, now).wall_ms)
            });
    }
    path
}

fn invocation_timing(record: &InvocationRecord, now: chrono::DateTime<chrono::Utc>) -> Timing {
    let queue_ms = duration_between(Some(&record.created_at), record.started_at.as_deref(), now);
    let execution_ms = record
        .started_at
        .as_deref()
        .map(|started| duration_between(Some(started), record.completed_at.as_deref(), now))
        .unwrap_or_default();
    Timing {
        queue_ms,
        execution_ms,
        wall_ms: duration_between(
            Some(&record.created_at),
            record.completed_at.as_deref(),
            now,
        ),
    }
}

fn duration_between(
    start: Option<&str>,
    end: Option<&str>,
    now: chrono::DateTime<chrono::Utc>,
) -> u64 {
    let Some(start) = start.and_then(parse_time) else {
        return 0;
    };
    let end = end.and_then(parse_time).unwrap_or(now);
    end.signed_duration_since(start)
        .num_milliseconds()
        .max(0)
        .try_into()
        .unwrap_or_default()
}

fn parse_time(value: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&chrono::Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(
        invocation_id: &str,
        status: &str,
        parent: Option<&str>,
        causal_depth: u32,
    ) -> InvocationRecord {
        InvocationRecord {
            invocation_id: invocation_id.to_owned(),
            worker_id: invocation_id.to_owned(),
            worker_version: "version".to_owned(),
            status: status.to_owned(),
            input: json!({"query":"test"}),
            output: None,
            error: None,
            idempotency_key: format!("key-{invocation_id}"),
            trace_id: "trace".to_owned(),
            causal_depth,
            trigger_kind: "manual".to_owned(),
            origin_session_id: Some("session".to_owned()),
            agent_session_id: None,
            interaction_mode: WorkerInteractionMode::Background,
            detached_at: Some("2026-07-24T00:00:00Z".to_owned()),
            model_tool_invocation_id: None,
            parent_worker_invocation_id: parent.map(ToOwned::to_owned),
            retry_of_invocation_id: None,
            attempt_count: u32::from(status == "running"),
            created_at: "2026-07-24T00:00:00Z".to_owned(),
            started_at: (status != "queued").then(|| "2026-07-24T00:00:01Z".to_owned()),
            completed_at: is_terminal(status).then(|| "2026-07-24T00:00:02Z".to_owned()),
        }
    }

    #[test]
    fn request_and_result_previews_prefer_user_facing_fields() {
        assert_eq!(
            preview_request(&json!({"query":"What happened today?","debug":"raw"})),
            "What happened today?"
        );
        assert_eq!(
            preview_result(&json!({"summary":"Three developments","payload":{"raw":true}})),
            "Three developments"
        );
    }

    #[test]
    fn technical_tool_names_are_structured_not_concatenated() {
        assert_eq!(
            friendly_tool_name("worker_kernel::filesystem_list"),
            "filesystem list"
        );
        assert!(is_technical_tool("worker_kernel::filesystem_list"));
        assert!(!is_technical_tool("research_search"));
    }

    #[test]
    fn active_child_and_retry_evidence_outrank_stale_parent_stage() {
        let root = record("root", "running", None, 0);
        let mut child = record("child", "running", Some("root"), 1);
        let info = HashMap::from([
            (
                "root".to_owned(),
                WorkerProjectionInfo {
                    name: "Coordinator".to_owned(),
                    runner: "agent".to_owned(),
                    presentation: None,
                },
            ),
            (
                "child".to_owned(),
                WorkerProjectionInfo {
                    name: "Source Review".to_owned(),
                    runner: "agent".to_owned(),
                    presentation: None,
                },
            ),
        ]);
        let stale = vec![WorkerRunEvent {
            event_id: "event".to_owned(),
            invocation_id: "root".to_owned(),
            sequence: 9,
            stage: WorkerRunStage::Validation,
            summary: "stale validation".to_owned(),
            occurred_at: "2026-07-24T00:00:01Z".to_owned(),
        }];

        let (stage, label) = graph_stage(&[root.clone(), child.clone()], &stale, &info);
        assert_eq!(stage, WorkerRunStage::SpecialistExecution);
        assert_eq!(label, "Running Source Review");

        child.attempt_count = 2;
        let (stage, label) = graph_stage(&[root, child], &stale, &info);
        assert_eq!(stage, WorkerRunStage::RetryRepair);
        assert_eq!(label, "Repairing or retrying Source Review");
    }

    #[test]
    fn terminal_and_synthesis_stages_are_derived_from_durable_status() {
        let info = HashMap::from([(
            "root".to_owned(),
            WorkerProjectionInfo {
                name: "Coordinator".to_owned(),
                runner: "agent".to_owned(),
                presentation: None,
            },
        )]);
        for (status, expected) in [
            ("completed", WorkerRunStage::Completed),
            ("failed", WorkerRunStage::Failed),
            ("cancelled", WorkerRunStage::Cancelled),
        ] {
            let (stage, _) = graph_stage(&[record("root", status, None, 0)], &[], &info);
            assert_eq!(stage, expected);
        }

        let root = record("root", "running", None, 0);
        let child = record("child", "completed", Some("root"), 1);
        let (stage, _) = graph_stage(&[root, child], &[], &info);
        assert_eq!(stage, WorkerRunStage::Synthesis);
    }

    #[tokio::test]
    async fn graph_projects_linked_agent_and_model_session_truth() {
        use crate::domains::session::event_store::{AppendOptions, EventType};

        let home = crate::shared::server::test_support::unique_tron_home();
        let (context, runtime) =
            crate::shared::server::test_support::make_test_context_and_worker_runtime_at(
                &home, None,
            );
        let bundle = serde_json::from_value::<WorkerBundle>(json!({
            "schemaVersion":"tron.worker_bundle.v1",
            "workerId":"graph-agent",
            "name":"Graph Agent",
            "description":"Exercises authoritative agent-session graph projection",
            "inputSchema":{
                "type":"object","additionalProperties":false,
                "required":["query"],"properties":{"query":{"type":"string"}}
            },
            "outputSchema":{
                "type":"object","additionalProperties":false,
                "required":["summary"],"properties":{"summary":{"type":"string"}}
            },
            "runner":{"kind":"agent","instructions":"Return a summary.","model":"mock/model"},
            "provenance":[{"source":"test:run-graph"}]
        }))
        .unwrap();
        let mut prepared = runtime.store.prepare(bundle, None).unwrap();
        runtime.store.finalize(&mut prepared).unwrap();
        let published = runtime.store.publish(prepared).unwrap();
        let (invocation, _) = runtime
            .store
            .begin_invocation(
                &published.worker.worker_id,
                &published.version,
                &json!({"query":"Inspect this run"}),
                "graph-agent-key",
                "graph-agent-trace",
                0,
                "manual",
                Some("origin-session"),
            )
            .unwrap();
        assert!(
            runtime
                .store
                .claim_running(&invocation.invocation_id)
                .unwrap()
        );
        let session_id = context
            .session_manager
            .create_worker_session("mock/model", "/tmp", Some("Worker: Graph Agent"))
            .unwrap();
        runtime
            .store
            .set_agent_session_id(&invocation.invocation_id, &session_id)
            .unwrap();
        context
            .event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::StreamTurnStart,
                payload: json!({"turn":1}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        context
            .event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::StreamTurnEnd,
                payload: json!({
                    "turn":1,
                    "model":"mock/model",
                    "latency":125,
                    "stopReason":"end_turn",
                    "tokenUsage":{
                        "inputTokens":100,
                        "outputTokens":20,
                        "cacheReadTokens":10,
                        "cacheCreationTokens":5
                    },
                    "cost":0.0125
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        let completed = runtime
            .store
            .complete_invocation(
                &invocation.invocation_id,
                &published.worker.worker_id,
                Ok(&json!({"summary":"Complete"})),
            )
            .unwrap();

        let graph = runtime.project_run_graph(&completed).unwrap();
        assert_eq!(graph["usage"]["inputTokens"], 100);
        assert_eq!(graph["usage"]["outputTokens"], 20);
        assert_eq!(graph["usage"]["cost"], 0.0125);
        assert_eq!(graph["timing"]["modelMs"], 125);
        let nodes = graph["nodes"].as_array().unwrap();
        assert!(
            nodes
                .iter()
                .any(|node| { node["kind"] == "agent" && node["sessionId"] == session_id })
        );
        assert!(nodes.iter().any(|node| {
            node["kind"] == "model" && node["model"] == "mock/model" && node["turn"] == 1
        }));
    }
}
