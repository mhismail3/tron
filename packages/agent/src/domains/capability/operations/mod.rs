//! Primitive execute operations for the bare engine loop.
//!
//! `capability::execute` is the only model-facing tool on this branch. It does
//! not route, bind, approve, or execute catalog targets. It performs one direct
//! host primitive operation and returns a model-visible observation with engine
//! details for audit. Catalog search/inspect/conformance operations are
//! discovery-only: they inspect metadata and write only catalog-discovery
//! evidence. Memory operations are read-only audit views over the resource
//! memory contract and return redacted status/list/inspect facts only.
//! Filesystem package operations are bounded working-directory reads/searches
//! plus preview-first write/patch operations with resource evidence. Job
//! operations expose a durable non-interactive process lifecycle over the jobs
//! domain while leaving `process_run` as the short synchronous primitive.
//! `replay_manifest` is the only read-only operation that bypasses trace-record
//! creation; tracing that read would mutate the manifest it returns.
//!
//! The operation gate is intentionally stricter than the provider schema:
//! `execute` accepts only trusted agent/system runtime contexts, rejects
//! bootstrap authority grants, requires a derived least-privilege grant for
//! every effectful call, resolves file/process roots from trusted runtime
//! metadata, denies system-scoped state, and keeps trace/log/replay/job reads
//! bound to the current session. Process primitives additionally inspect the
//! active grant and run only when it carries `networkPolicy none`.

use std::time::Instant;

use chrono::Utc;
use serde_json::{Value, json};

use super::Deps;
use crate::engine::{ActorKind, Invocation, is_bootstrap_authority_grant_id};
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::errors::CapabilityError;
use tracing::{info, warn};

mod catalog;
mod filesystem;
mod git;
mod goals;
mod jobs;
mod logs;
mod memory;
mod process;
mod replay;
mod state;
mod subagents;
mod tool_sources;
mod trace;
mod web;
mod worker_packages;

use catalog::{catalog_conformance, catalog_inspect, catalog_search};
use filesystem::{
    filesystem_apply_patch, filesystem_diff, filesystem_edit, filesystem_find, filesystem_glob,
    filesystem_list, filesystem_read, filesystem_search_text, filesystem_write,
};
use git::{
    git_branch_inventory, git_branch_start, git_commit, git_diff, git_stage, git_status,
    git_unstage,
};
use goals::{
    goal_cancel, goal_create, goal_inspect, goal_list, question_answer, question_create,
    question_inspect, question_list,
};
use jobs::{job_cancel, job_list, job_log, job_start, job_status};
use logs::log_recent;
use memory::{memory_inspect, memory_list, memory_status};
use process::process_run;
use replay::replay_manifest;
use state::{state_get, state_list, state_set};
use subagents::{
    subagent_cancel, subagent_launch, subagent_result, subagent_status, subagent_task_inspect,
    subagent_task_list,
};
use tool_sources::{tool_source_inspect, tool_source_list};
use trace::{complete_trace_record, started_trace_record, trace_get, trace_list};
use web::{web_fetch, web_robots_check, web_source_archive, web_source_inspect, web_source_list};
use worker_packages::{worker_package_inspect, worker_package_list};

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let operation = required_str(&invocation.payload, "operation")?.to_owned();
    validate_execute_context(invocation, &operation)?;
    info!(
        component = "agent.execute",
        agent_event = "execute_operation_started",
        operation = %operation,
        trace_id = %invocation.causal_context.trace_id.as_str(),
        invocation_id = %invocation.id.as_str(),
        parent_invocation_id = invocation
            .causal_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str())
            .unwrap_or("none"),
        session_id = invocation.causal_context.session_id.as_deref().unwrap_or("none"),
        workspace_id = invocation.causal_context.workspace_id.as_deref().unwrap_or("none"),
        actor_kind = ?invocation.causal_context.actor_kind,
        actor_id = %invocation.causal_context.actor_id.as_str(),
        "primitive execute operation started"
    );
    if operation == "replay_manifest" {
        info!(
            component = "agent.execute",
            agent_event = "execute_operation_trace_bypassed",
            operation = %operation,
            trace_id = %invocation.causal_context.trace_id.as_str(),
            invocation_id = %invocation.id.as_str(),
            session_id = invocation.causal_context.session_id.as_deref().unwrap_or("none"),
            "primitive execute operation bypassed trace mutation"
        );
        return result_value(replay_manifest(invocation, deps).await?);
    }

    let started_at = Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut trace_record = started_trace_record(invocation, deps, &operation, &started_at)?;
    deps.event_store
        .append_trace_record(&trace_record)
        .map_err(|error| internal(format!("record trace start: {error}")))?;
    info!(
        component = "agent.execute",
        agent_event = "execute_trace_record_started",
        operation = %operation,
        trace_record_id = %trace_record.id,
        trace_id = %trace_record.trace_id,
        invocation_id = %trace_record.invocation_id,
        provider_invocation_id = trace_record.provider_invocation_id.as_deref().unwrap_or("none"),
        session_id = trace_record.session_id.as_deref().unwrap_or("none"),
        turn = trace_record.turn.unwrap_or_default(),
        "primitive execute trace record started"
    );

    let result = execute_operation(&operation, invocation, deps).await;
    match result {
        Ok(result) => {
            complete_trace_record(
                &mut trace_record,
                invocation,
                &result,
                None,
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|error| internal(format!("record trace completion: {error}")))?;
            info!(
                component = "agent.execute",
                agent_event = "execute_operation_completed",
                operation = %operation,
                trace_record_id = %trace_record.id,
                trace_id = %trace_record.trace_id,
                invocation_id = %trace_record.invocation_id,
                status = %trace_record.status,
                duration_ms = trace_record.duration_ms.unwrap_or_default(),
                session_id = trace_record.session_id.as_deref().unwrap_or("none"),
                turn = trace_record.turn.unwrap_or_default(),
                "primitive execute operation completed"
            );
            result_value(result)
        }
        Err(error) => {
            complete_trace_record(
                &mut trace_record,
                invocation,
                &error_capability_result(error.to_string(), json!({"status": "failed"})),
                Some(&error),
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|store_error| internal(format!("record trace failure: {store_error}")))?;
            warn!(
                component = "agent.execute",
                agent_event = "execute_operation_failed",
                operation = %operation,
                trace_record_id = %trace_record.id,
                trace_id = %trace_record.trace_id,
                invocation_id = %trace_record.invocation_id,
                status = %trace_record.status,
                duration_ms = trace_record.duration_ms.unwrap_or_default(),
                session_id = trace_record.session_id.as_deref().unwrap_or("none"),
                turn = trace_record.turn.unwrap_or_default(),
                error = %error,
                "primitive execute operation failed"
            );
            Err(error)
        }
    }
}

fn validate_execute_context(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    match invocation.causal_context.actor_kind {
        ActorKind::Agent => {
            let session_id = invocation
                .causal_context
                .session_id
                .as_deref()
                .ok_or_else(|| invalid("capability::execute agent context requires session id"))?;
            let expected_actor = format!("agent:{session_id}");
            if invocation.causal_context.actor_id.as_str() != expected_actor {
                return Err(invalid(
                    "capability::execute agent actor must match the current session",
                ));
            }
        }
        ActorKind::System => {}
        _ => {
            return Err(invalid(
                "capability::execute requires a trusted agent or system runtime context",
            ));
        }
    }
    if is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id) {
        return Err(invalid(
            "capability::execute requires a derived least-privilege authority grant",
        ));
    }
    if matches!(
        operation,
        "job_start"
            | "job_status"
            | "job_list"
            | "job_log"
            | "job_cancel"
            | "goal_create"
            | "goal_list"
            | "goal_inspect"
            | "goal_cancel"
            | "question_create"
            | "question_list"
            | "question_inspect"
            | "question_answer"
            | "web_fetch"
            | "web_robots_check"
            | "web_source_list"
            | "web_source_inspect"
            | "web_source_archive"
            | "tool_source_list"
            | "tool_source_inspect"
            | "subagent_launch"
            | "subagent_status"
            | "subagent_result"
            | "subagent_cancel"
            | "subagent_task_list"
            | "subagent_task_inspect"
            | "worker_package_list"
            | "worker_package_inspect"
    ) {
        require_current_session(invocation, operation)?;
    }
    match operation {
        "state_get" | "state_set" | "state_list" => validate_state_scope(invocation),
        "trace_list" | "trace_get" | "log_recent" | "replay_manifest" | "memory_status"
        | "memory_list" | "memory_inspect" => require_current_session(invocation, operation),
        "catalog_conformance"
        | "filesystem_write"
        | "filesystem_edit"
        | "filesystem_apply_patch"
        | "git_stage"
        | "git_unstage"
        | "git_commit"
        | "git_branch_start"
        | "job_start"
        | "job_cancel"
        | "goal_create"
        | "goal_cancel"
        | "question_create"
        | "question_answer"
        | "web_fetch"
        | "web_robots_check"
        | "web_source_archive"
        | "subagent_launch"
        | "subagent_cancel" => require_idempotency_key(invocation, operation),
        _ => Ok(()),
    }
}

fn validate_state_scope(invocation: &Invocation) -> Result<(), CapabilityError> {
    match optional_str(&invocation.payload, "scope")?.unwrap_or("session") {
        "session" => require_current_session(invocation, "state operation"),
        "workspace" => {
            if invocation.causal_context.workspace_id.is_none() {
                return Err(invalid(
                    "workspace state requires trusted workspace context",
                ));
            }
            Ok(())
        }
        "system" => Err(invalid(
            "capability::execute cannot read or write system-scoped state",
        )),
        other => Err(invalid(format!("unsupported execute state scope {other}"))),
    }
}

fn require_current_session(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.session_id.is_none() {
        return Err(invalid(format!(
            "{operation} requires trusted current session context"
        )));
    }
    Ok(())
}

fn require_idempotency_key(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.idempotency_key.is_none()
        && optional_str(&invocation.payload, "idempotencyKey")?.is_none()
    {
        return Err(invalid(format!(
            "{operation} writes durable evidence and requires an idempotencyKey"
        )));
    }
    Ok(())
}

async fn execute_operation(
    operation: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    Ok(match operation {
        "observe" => observe(invocation)?,
        "state_get" => state_get(invocation, deps).await?,
        "state_set" => state_set(invocation, deps).await?,
        "state_list" => state_list(invocation, deps).await?,
        "filesystem_read" => filesystem_read(invocation).await?,
        "filesystem_list" => filesystem_list(invocation).await?,
        "filesystem_find" => filesystem_find(invocation).await?,
        "filesystem_glob" => filesystem_glob(invocation).await?,
        "filesystem_search_text" => filesystem_search_text(invocation).await?,
        "filesystem_diff" => filesystem_diff(invocation).await?,
        "filesystem_write" => filesystem_write(invocation, deps).await?,
        "filesystem_edit" => filesystem_edit(invocation, deps).await?,
        "filesystem_apply_patch" => filesystem_apply_patch(invocation, deps).await?,
        "git_status" => git_status(invocation).await?,
        "git_diff" => git_diff(invocation).await?,
        "git_branch_inventory" => git_branch_inventory(invocation).await?,
        "git_stage" => git_stage(invocation, deps).await?,
        "git_unstage" => git_unstage(invocation, deps).await?,
        "git_commit" => git_commit(invocation, deps).await?,
        "git_branch_start" => git_branch_start(invocation, deps).await?,
        "process_run" => process_run(invocation, deps).await?,
        "job_start" => job_start(invocation, deps).await?,
        "job_status" => job_status(invocation, deps).await?,
        "job_list" => job_list(invocation, deps).await?,
        "job_log" => job_log(invocation, deps).await?,
        "job_cancel" => job_cancel(invocation, deps).await?,
        "goal_create" => goal_create(invocation, deps).await?,
        "goal_list" => goal_list(invocation, deps).await?,
        "goal_inspect" => goal_inspect(invocation, deps).await?,
        "goal_cancel" => goal_cancel(invocation, deps).await?,
        "question_create" => question_create(invocation, deps).await?,
        "question_list" => question_list(invocation, deps).await?,
        "question_inspect" => question_inspect(invocation, deps).await?,
        "question_answer" => question_answer(invocation, deps).await?,
        "trace_list" => trace_list(invocation, deps)?,
        "trace_get" => trace_get(invocation, deps)?,
        "log_recent" => log_recent(invocation, deps).await?,
        "replay_manifest" => replay_manifest(invocation, deps).await?,
        "catalog_search" => catalog_search(invocation, deps).await?,
        "catalog_inspect" => catalog_inspect(invocation, deps).await?,
        "catalog_conformance" => catalog_conformance(invocation, deps).await?,
        "memory_status" => memory_status(invocation, deps).await?,
        "memory_list" => memory_list(invocation, deps).await?,
        "memory_inspect" => memory_inspect(invocation, deps).await?,
        "tool_source_list" => tool_source_list(invocation, deps).await?,
        "tool_source_inspect" => tool_source_inspect(invocation, deps).await?,
        "subagent_launch" => subagent_launch(invocation, deps).await?,
        "subagent_status" => subagent_status(invocation, deps).await?,
        "subagent_result" => subagent_result(invocation, deps).await?,
        "subagent_cancel" => subagent_cancel(invocation, deps).await?,
        "subagent_task_list" => subagent_task_list(invocation, deps).await?,
        "subagent_task_inspect" => subagent_task_inspect(invocation, deps).await?,
        "worker_package_list" => worker_package_list(invocation, deps).await?,
        "worker_package_inspect" => worker_package_inspect(invocation, deps).await?,
        "web_fetch" => web_fetch(invocation, deps).await?,
        "web_robots_check" => web_robots_check(invocation, deps).await?,
        "web_source_list" => web_source_list(invocation, deps).await?,
        "web_source_inspect" => web_source_inspect(invocation, deps).await?,
        "web_source_archive" => web_source_archive(invocation, deps).await?,
        other => {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Unsupported primitive execute operation '{other}'. Use observe, state_get, state_set, state_list, filesystem_read, filesystem_list, filesystem_find, filesystem_glob, filesystem_search_text, filesystem_diff, filesystem_write, filesystem_edit, filesystem_apply_patch, git_status, git_diff, git_branch_inventory, git_stage, git_unstage, git_commit, git_branch_start, process_run, job_start, job_status, job_list, job_log, job_cancel, goal_create, goal_list, goal_inspect, goal_cancel, question_create, question_list, question_inspect, question_answer, web_fetch, web_robots_check, web_source_list, web_source_inspect, web_source_archive, tool_source_list, tool_source_inspect, subagent_launch, subagent_status, subagent_result, subagent_cancel, subagent_task_list, subagent_task_inspect, worker_package_list, worker_package_inspect, trace_list, trace_get, log_recent, replay_manifest, catalog_search, catalog_inspect, catalog_conformance, memory_status, memory_list, or memory_inspect."
                ),
            });
        }
    })
}

fn observe(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let input = optional_str(&invocation.payload, "input")?.unwrap_or("");
    Ok(ok_result(
        if input.is_empty() {
            "Observation recorded.".to_owned()
        } else {
            input.to_owned()
        },
        json!({
            "primitiveOperation": "observe",
            "status": "ok"
        }),
    ))
}

fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str, CapabilityError> {
    optional_str(payload, field)?.ok_or_else(|| CapabilityError::InvalidParams {
        message: format!("missing required field {field}"),
    })
}

fn optional_str<'a>(payload: &'a Value, field: &str) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a string"),
        }),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => {
            value
                .as_u64()
                .map(Some)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: format!("{field} must be a positive integer"),
                })
        }
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a positive integer"),
        }),
    }
}

pub(super) fn ok_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(false),
        stop_turn: None,
    }
}

fn error_capability_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(true),
        stop_turn: None,
    }
}

fn result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
    serde_json::to_value(result).map_err(|error| internal(format!("serialize result: {error}")))
}

fn compact_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "<unserializable>".to_owned())
}

pub(super) fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
