//! Index-only Git mutation support.

use chrono::Utc;
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineHostHandle, EngineResource, EngineResourceScope, GIT_INDEX_CHANGE_KIND,
    GIT_INDEX_CHANGE_SCHEMA_ID, Invocation, PublishStreamEvent, VisibilityScope, WorkerId,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

use super::service;
use super::types::{
    DEFAULT_DIFF_BYTES, DEFAULT_STATUS_BYTES, GitIndexChangeRecord, INDEX_CHANGE_SCHEMA_VERSION,
    MAX_DIFF_BYTES, MAX_STATUS_BYTES, RepositoryFacts,
};
use super::{GIT_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(crate) async fn stage_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    index_mutation_value(engine_host, invocation, payload, IndexOperation::Stage).await
}

pub(crate) async fn unstage_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    index_mutation_value(engine_host, invocation, payload, IndexOperation::Unstage).await
}

async fn index_mutation_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    operation: IndexOperation,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation_for_blocking = invocation.clone();
    let plan = run_blocking_task(operation.blocking_label(), move || {
        index_mutation_sync(&invocation_for_blocking, &request, operation)
    })
    .await?;
    let resource = create_index_change_resource(engine_host, invocation, &plan).await?;
    let resource_ref = resource_ref(&resource, GIT_INDEX_CHANGE_KIND);
    let cursor = publish_lifecycle(engine_host, invocation, &plan, &resource).await?;

    Ok(json!({
        "schemaVersion": INDEX_CHANGE_SCHEMA_VERSION,
        "status": "committed",
        "operation": plan.operation.as_str(),
        "path": plan.path.clone(),
        "repository": plan.repository.clone(),
        "expectedHead": plan.expected_head.clone(),
        "headOid": plan.head_oid.clone(),
        "reason": plan.reason.clone(),
        "before": plan.before.clone(),
        "after": plan.after.clone(),
        "evidence": plan.evidence.clone(),
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref],
        "gitIndexChangeResourceId": resource.resource_id
    }))
}

fn index_mutation_sync(
    invocation: &Invocation,
    payload: &Value,
    operation: IndexOperation,
) -> Result<IndexMutationPlan, CapabilityError> {
    required_str(payload, "path")?;
    let target = service::resolve_target(invocation, payload)?;
    let repository = service::repository_facts(&target)?;
    let trusted_root = service::resolve_target(invocation, &json!({"path": "."}))?;
    let trusted_repository = service::repository_facts(&trusted_root)?;
    if repository.worktree_root != trusted_repository.worktree_root {
        return Err(invalid(
            "git index mutation path must belong to the trusted working-directory repository",
        ));
    }
    let expected_head = required_str(payload, "expectedHead")?.to_owned();
    let reason = required_str(payload, "reason")?.to_owned();
    let Some(head_oid) = repository.head_oid.clone() else {
        return Err(invalid("git index mutation requires a repository HEAD"));
    };
    if head_oid != expected_head {
        return Err(invalid(format!(
            "expectedHead mismatch: expected {expected_head}, actual {head_oid}"
        )));
    }
    let max_status_bytes = optional_usize(payload, "maxStatusBytes")?
        .unwrap_or(DEFAULT_STATUS_BYTES)
        .min(MAX_STATUS_BYTES);
    let max_diff_bytes = optional_usize(payload, "maxDiffBytes")?
        .unwrap_or(DEFAULT_DIFF_BYTES)
        .min(MAX_DIFF_BYTES);
    let before = status_diff_snapshot(&repository, max_status_bytes, max_diff_bytes)?;
    if has_unmerged_index_entries(&repository)? {
        return Err(invalid("git index mutation refuses conflicted pathspecs"));
    }
    run_index_command(&repository, operation)?;
    let after = status_diff_snapshot(&repository, max_status_bytes, max_diff_bytes)?;

    Ok(IndexMutationPlan {
        operation,
        repository: service::repository_value(&target, &repository),
        path: service::path_value(&target),
        expected_head,
        head_oid,
        reason,
        before: before.value(),
        after: after.value(),
        evidence: json!({
            "bounded": true,
            "statusLimitBytes": max_status_bytes,
            "diffLimitBytes": max_diff_bytes,
            "beforeTruncated": before.truncated(),
            "afterTruncated": after.truncated()
        }),
    })
}

fn run_index_command(
    repository: &RepositoryFacts,
    operation: IndexOperation,
) -> Result<(), CapabilityError> {
    let output = match operation {
        IndexOperation::Stage => service::git_output_bounded(
            &repository.worktree_root,
            ["add", "--", repository.pathspec.as_str()],
            0,
        )?,
        IndexOperation::Unstage => service::git_output_bounded(
            &repository.worktree_root,
            ["restore", "--staged", "--", repository.pathspec.as_str()],
            0,
        )?,
    };
    if output.status.success() {
        return Ok(());
    }
    Err(CapabilityError::Custom {
        code: "GIT_COMMAND_FAILED".to_owned(),
        message: truncate_chars(String::from_utf8_lossy(&output.stderr).trim(), 1_000),
        details: None,
    })
}

fn status_diff_snapshot(
    repository: &RepositoryFacts,
    max_status_bytes: usize,
    max_diff_bytes: usize,
) -> Result<IndexSnapshot, CapabilityError> {
    let status = service::git_output_bounded(
        &repository.worktree_root,
        [
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--",
            repository.pathspec.as_str(),
        ],
        max_status_bytes,
    )?;
    let staged = service::git_diff_text(
        &repository.worktree_root,
        true,
        &repository.pathspec,
        max_diff_bytes,
    )?;
    let unstaged = service::git_diff_text(
        &repository.worktree_root,
        false,
        &repository.pathspec,
        max_diff_bytes,
    )?;
    Ok(IndexSnapshot {
        status_porcelain: String::from_utf8_lossy(&status.stdout).into_owned(),
        status_truncated: status.stdout_truncated,
        staged_diff: staged.0,
        staged_diff_truncated: staged.1,
        unstaged_diff: unstaged.0,
        unstaged_diff_truncated: unstaged.1,
    })
}

fn has_unmerged_index_entries(repository: &RepositoryFacts) -> Result<bool, CapabilityError> {
    let output = service::git_output_bounded(
        &repository.worktree_root,
        ["ls-files", "-u", "-z", "--", repository.pathspec.as_str()],
        1,
    )?;
    Ok(!output.stdout.is_empty() || output.stdout_truncated)
}

async fn create_index_change_resource(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    plan: &IndexMutationPlan,
) -> Result<EngineResource, CapabilityError> {
    engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!(
                "{}:{}",
                GIT_INDEX_CHANGE_KIND,
                invocation.id.as_str()
            )),
            kind: GIT_INDEX_CHANGE_KIND.to_owned(),
            schema_id: Some(GIT_INDEX_CHANGE_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error_to_capability_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("committed".to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": WRITE_SCOPE,
                "networkPolicy": "none",
                "mutationBoundary": "git_index_only"
            }),
            initial_payload: Some(record_value(invocation, plan)?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error_to_capability_error)
}

async fn publish_lifecycle(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    plan: &IndexMutationPlan,
    resource: &EngineResource,
) -> Result<crate::engine::StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: GIT_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": "git.index_changed",
                "operation": plan.operation.as_str(),
                "path": plan.path.clone(),
                "headOid": plan.head_oid.clone(),
                "expectedHead": plan.expected_head.clone(),
                "reason": plan.reason.clone(),
                "gitIndexChangeResourceId": resource.resource_id,
                "resourceRefs": [resource_ref(resource, GIT_INDEX_CHANGE_KIND)],
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
                "actorId": invocation.causal_context.actor_id.as_str()
            }),
            visibility: VisibilityScope::Session,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error_to_capability_error)
}

fn record_value(
    invocation: &Invocation,
    plan: &IndexMutationPlan,
) -> Result<Value, CapabilityError> {
    serde_json::to_value(GitIndexChangeRecord {
        schema_version: INDEX_CHANGE_SCHEMA_VERSION.to_owned(),
        operation: plan.operation.as_str().to_owned(),
        state: "committed".to_owned(),
        repository: plan.repository.clone(),
        path: plan.path.clone(),
        expected_head: plan.expected_head.clone(),
        head_oid: plan.head_oid.clone(),
        reason: plan.reason.clone(),
        authority: json!({
            "actorId": invocation.causal_context.actor_id.as_str(),
            "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
            "authorityScopes": invocation.causal_context.authority_scopes.clone(),
            "sessionId": invocation.causal_context.session_id.clone(),
            "workspaceId": invocation.causal_context.workspace_id.clone()
        }),
        before: plan.before.clone(),
        after: plan.after.clone(),
        evidence: plan.evidence.clone(),
        trace_refs: vec![json!({
            "traceId": invocation.causal_context.trace_id.as_str(),
            "invocationId": invocation.id.as_str(),
            "functionId": invocation.function_id.as_str()
        })],
        replay_refs: vec![json!({
            "kind": "engine_invocation",
            "invocationId": invocation.id.as_str(),
            "traceId": invocation.causal_context.trace_id.as_str()
        })],
        idempotency: json!({
            "key": invocation.causal_context.idempotency_key.clone(),
            "payloadKey": invocation.payload.get("idempotencyKey").and_then(Value::as_str),
            "invocationId": invocation.id.as_str(),
            "functionId": invocation.function_id.as_str()
        }),
        revision: 1,
        created_at: Utc::now(),
    })
    .map_err(|error| internal(format!("serialize git index change: {error}")))
}

fn resource_scope(invocation: &Invocation) -> EngineResourceScope {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .or_else(|| {
            invocation
                .causal_context
                .workspace_id
                .as_ref()
                .map(|workspace| EngineResourceScope::Workspace(workspace.clone()))
        })
        .unwrap_or(EngineResourceScope::System)
}

fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role
    })
}

fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str, CapabilityError> {
    match payload.get(field) {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(value.trim()),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
        None => Err(invalid(format!("missing {field}"))),
    }
}

fn optional_usize(payload: &Value, field: &str) -> Result<Option<usize>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .filter(|value| *value > 0)
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

fn truncate_chars(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    let mut end = max;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

#[derive(Clone, Copy)]
enum IndexOperation {
    Stage,
    Unstage,
}

impl IndexOperation {
    fn as_str(self) -> &'static str {
        match self {
            Self::Stage => "stage",
            Self::Unstage => "unstage",
        }
    }

    fn blocking_label(self) -> &'static str {
        match self {
            Self::Stage => "git::stage",
            Self::Unstage => "git::unstage",
        }
    }
}

struct IndexMutationPlan {
    operation: IndexOperation,
    repository: Value,
    path: Value,
    expected_head: String,
    head_oid: String,
    reason: String,
    before: Value,
    after: Value,
    evidence: Value,
}

struct IndexSnapshot {
    status_porcelain: String,
    status_truncated: bool,
    staged_diff: String,
    staged_diff_truncated: bool,
    unstaged_diff: String,
    unstaged_diff_truncated: bool,
}

impl IndexSnapshot {
    fn truncated(&self) -> bool {
        self.status_truncated || self.staged_diff_truncated || self.unstaged_diff_truncated
    }

    fn value(&self) -> Value {
        json!({
            "statusPorcelainV1Z": self.status_porcelain,
            "statusTruncated": self.status_truncated,
            "stagedDiff": {
                "text": self.staged_diff,
                "truncated": self.staged_diff_truncated
            },
            "unstagedDiff": {
                "text": self.unstaged_diff,
                "truncated": self.unstaged_diff_truncated
            },
            "truncated": self.truncated()
        })
    }
}
