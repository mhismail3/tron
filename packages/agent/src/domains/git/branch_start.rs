//! Local Git branch-start support.

use std::path::{Path, PathBuf};

use chrono::Utc;
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineHostHandle, EngineResource, EngineResourceScope, GIT_BRANCH_START_KIND,
    GIT_BRANCH_START_SCHEMA_ID, Invocation, PublishStreamEvent, VisibilityScope, WorkerId,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

use super::service;
use super::types::{
    BRANCH_START_SCHEMA_VERSION, DEFAULT_DIFF_BYTES, DEFAULT_STATUS_BYTES, GitBranchStartRecord,
    MAX_DIFF_BYTES, MAX_STATUS_BYTES, RepositoryFacts,
};
use super::{GIT_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(super) const BRANCH_START_OUTPUT_BYTES: usize = 8 * 1024;

pub(crate) async fn branch_start_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation_for_blocking = invocation.clone();
    let plan = run_blocking_task("git_branch_start", move || {
        branch_start_sync(&invocation_for_blocking, &request)
    })
    .await?;
    let resource = create_branch_start_resource(engine_host, invocation, &plan).await?;
    let resource_ref = resource_ref(&resource, GIT_BRANCH_START_KIND);
    let cursor = publish_lifecycle(engine_host, invocation, &plan, &resource).await?;

    Ok(json!({
        "schemaVersion": BRANCH_START_SCHEMA_VERSION,
        "status": "started",
        "operation": "branch_start",
        "repository": plan.repository.clone(),
        "branchName": plan.branch_name.clone(),
        "previousBranch": plan.previous_branch.clone(),
        "expectedHead": plan.expected_head.clone(),
        "headOid": plan.head_oid.clone(),
        "reason": plan.reason.clone(),
        "before": plan.before.clone(),
        "after": plan.after.clone(),
        "evidence": plan.evidence.clone(),
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref],
        "gitBranchStartResourceId": resource.resource_id
    }))
}

fn branch_start_sync(
    invocation: &Invocation,
    payload: &Value,
) -> Result<BranchStartPlan, CapabilityError> {
    let target = service::resolve_target(invocation, payload)?;
    let repository = service::repository_facts(&target)?;
    let trusted_root = service::resolve_target(invocation, &json!({"path": "."}))?;
    let trusted_repository = service::repository_facts(&trusted_root)?;
    if repository.worktree_root != trusted_repository.worktree_root {
        return Err(invalid(
            "git_branch_start path must belong to the trusted working-directory repository",
        ));
    }

    let branch_name = validate_branch_name(required_str(payload, "branchName")?)?;
    let branch_ref = format!("refs/heads/{branch_name}");
    let expected_head = required_str(payload, "expectedHead")?.to_owned();
    let reason = required_str(payload, "reason")?.to_owned();
    let _payload_idempotency_key = required_str(payload, "idempotencyKey")?;
    let previous_branch = repository
        .branch
        .clone()
        .ok_or_else(|| invalid("git_branch_start requires a current named branch"))?;
    if repository.detached_head {
        return Err(invalid("git_branch_start rejects detached HEAD"));
    }
    let Some(head_oid) = repository.head_oid.clone() else {
        return Err(invalid("git_branch_start requires a repository HEAD"));
    };
    if head_oid != expected_head {
        return Err(invalid(format!(
            "expectedHead mismatch: expected {expected_head}, actual {head_oid}"
        )));
    }
    reject_in_progress_state(&repository)?;
    if has_unmerged_index_entries(&repository)? {
        return Err(invalid(
            "git_branch_start refuses conflicted or unmerged index entries",
        ));
    }
    reject_existing_branch(&repository.worktree_root, &branch_ref)?;

    let max_status_bytes = optional_usize(payload, "maxStatusBytes")?
        .unwrap_or(DEFAULT_STATUS_BYTES)
        .min(MAX_STATUS_BYTES);
    let max_diff_bytes = optional_usize(payload, "maxDiffBytes")?
        .unwrap_or(DEFAULT_DIFF_BYTES)
        .min(MAX_DIFF_BYTES);
    let before = status_diff_snapshot(&repository, max_status_bytes, max_diff_bytes)?;
    let previous_branch_ref = format!("refs/heads/{previous_branch}");
    create_branch_and_move_head(
        &repository.worktree_root,
        &previous_branch_ref,
        &branch_ref,
        &expected_head,
    )?;

    let after_target = service::resolve_target(invocation, &json!({"path": "."}))?;
    let after_repository = service::repository_facts(&after_target)?;
    if after_repository.branch.as_deref() != Some(&branch_name) {
        return Err(internal(format!(
            "git_branch_start moved to unexpected branch: expected {branch_name}, actual {:?}",
            after_repository.branch
        )));
    }
    let after_head = after_repository
        .head_oid
        .clone()
        .ok_or_else(|| internal("git_branch_start lost repository HEAD after branch start"))?;
    if after_head != expected_head {
        return Err(internal(format!(
            "git_branch_start moved HEAD to unexpected oid: expected {expected_head}, actual {after_head}"
        )));
    }
    let branch_oid = git_ref_oid(&after_repository.worktree_root, &branch_ref)?;
    if branch_oid != expected_head {
        return Err(internal(format!(
            "git_branch_start created unexpected branch oid: expected {expected_head}, actual {branch_oid}"
        )));
    }
    if after_repository.index_tree_oid != repository.index_tree_oid {
        return Err(internal("git_branch_start changed the Git index tree"));
    }
    let after = status_diff_snapshot(&after_repository, max_status_bytes, max_diff_bytes)?;

    Ok(BranchStartPlan {
        repository: service::repository_value(&after_target, &after_repository),
        branch_name,
        previous_branch,
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
            "afterTruncated": after.truncated(),
            "mutationBoundary": "update-ref-plus-locked-symbolic-head",
            "refUpdatePolicy": "create-missing-ref-at-expected-head",
            "headPolicy": "locked-symbolic-head-with-expected-ref-and-oid",
            "checkoutPolicy": "not invoked",
            "hookPolicy": "not invoked",
            "indexPolicy": "preserved",
            "worktreePolicy": "preserved",
            "remotePolicy": "not invoked",
            "mergeRebaseResetPolicy": "not invoked",
            "networkPolicy": "none"
        }),
    })
}

fn validate_branch_name(raw: &str) -> Result<String, CapabilityError> {
    let value = raw.trim();
    if value.is_empty() {
        return Err(invalid("branchName must not be empty"));
    }
    if value.eq_ignore_ascii_case("head")
        || value.eq_ignore_ascii_case("fetch_head")
        || value.eq_ignore_ascii_case("orig_head")
        || value.eq_ignore_ascii_case("merge_head")
        || value.eq_ignore_ascii_case("cherry_pick_head")
        || value.eq_ignore_ascii_case("revert_head")
    {
        return Err(invalid("branchName uses a reserved Git ref name"));
    }
    if value.starts_with('-')
        || value.starts_with('/')
        || value.ends_with('/')
        || value.starts_with("refs/")
        || value.contains('\\')
        || value.contains("//")
        || value.contains("..")
        || value.contains("@{")
        || value.contains(':')
        || value.contains('?')
        || value.contains('*')
        || value.contains('[')
        || value.contains('^')
        || value.contains('~')
        || value
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace())
    {
        return Err(invalid("branchName is not a safe local branch name"));
    }
    for component in value.split('/') {
        if component.is_empty()
            || component == "."
            || component == ".."
            || component.ends_with(".lock")
        {
            return Err(invalid("branchName contains an invalid path component"));
        }
    }
    Ok(value.to_owned())
}

fn reject_existing_branch(worktree_root: &Path, branch_ref: &str) -> Result<(), CapabilityError> {
    let check = service::git_output_status_bounded(
        worktree_root,
        ["check-ref-format", "--normalize", branch_ref],
        BRANCH_START_OUTPUT_BYTES,
    )?;
    if !check.status.success() {
        return Err(invalid("branchName is not a valid local branch ref"));
    }
    let normalized = String::from_utf8_lossy(&check.stdout).trim().to_owned();
    if normalized != branch_ref {
        return Err(invalid("branchName normalizes to an unexpected ref"));
    }
    let exists = service::git_output_status_bounded(
        worktree_root,
        ["show-ref", "--verify", "--quiet", branch_ref],
        0,
    )?;
    if exists.status.success() {
        return Err(invalid(format!(
            "git_branch_start refuses existing branch {branch_ref}"
        )));
    }
    Ok(())
}

fn create_branch_and_move_head(
    worktree_root: &Path,
    expected_current_branch_ref: &str,
    branch_ref: &str,
    expected_head: &str,
) -> Result<(), CapabilityError> {
    create_branch_and_move_head_with_runner(
        &ServiceBranchStartGitRunner,
        worktree_root,
        expected_current_branch_ref,
        branch_ref,
        expected_head,
    )
}

pub(super) trait BranchStartGitRunner {
    fn git_output_status_bounded(
        &self,
        worktree_root: &Path,
        args: &[&str],
        stdout_limit: usize,
    ) -> Result<BranchStartGitStatus, CapabilityError>;

    fn move_symbolic_head_guarded(
        &self,
        worktree_root: &Path,
        expected_current_branch_ref: &str,
        expected_head: &str,
        branch_ref: &str,
    ) -> Result<(), CapabilityError>;
}

pub(super) struct BranchStartGitStatus {
    pub(super) success: bool,
    pub(super) stderr: Vec<u8>,
}

struct ServiceBranchStartGitRunner;

impl BranchStartGitRunner for ServiceBranchStartGitRunner {
    fn git_output_status_bounded(
        &self,
        worktree_root: &Path,
        args: &[&str],
        stdout_limit: usize,
    ) -> Result<BranchStartGitStatus, CapabilityError> {
        let output =
            service::git_output_status_bounded(worktree_root, args.iter().copied(), stdout_limit)?;
        Ok(BranchStartGitStatus {
            success: output.status.success(),
            stderr: output.stderr,
        })
    }

    fn move_symbolic_head_guarded(
        &self,
        worktree_root: &Path,
        expected_current_branch_ref: &str,
        expected_head: &str,
        branch_ref: &str,
    ) -> Result<(), CapabilityError> {
        service::git_move_symbolic_head_with_locked_current_head(
            worktree_root,
            expected_current_branch_ref,
            expected_head,
            branch_ref,
        )
    }
}

pub(super) fn create_branch_and_move_head_with_runner(
    runner: &impl BranchStartGitRunner,
    worktree_root: &Path,
    expected_current_branch_ref: &str,
    branch_ref: &str,
    expected_head: &str,
) -> Result<(), CapabilityError> {
    let create_args = ["update-ref", branch_ref, expected_head, ""];
    let create =
        runner.git_output_status_bounded(worktree_root, &create_args, BRANCH_START_OUTPUT_BYTES)?;
    if !create.success {
        let detail = stderr_detail(&create.stderr);
        return Err(invalid(format!(
            "git_branch_start could not create branch at expectedHead: {detail}"
        )));
    }

    if let Err(error) = runner.move_symbolic_head_guarded(
        worktree_root,
        expected_current_branch_ref,
        expected_head,
        branch_ref,
    ) {
        let detail = error.to_string();
        rollback_created_branch_ref(runner, worktree_root, branch_ref, expected_head, &detail)?;
        return Err(internal(format!(
            "git_branch_start created branch but could not move symbolic HEAD; rolled back {branch_ref} at {expected_head}: {detail}"
        )));
    }
    Ok(())
}

fn rollback_created_branch_ref(
    runner: &impl BranchStartGitRunner,
    worktree_root: &Path,
    branch_ref: &str,
    expected_head: &str,
    move_head_detail: &str,
) -> Result<(), CapabilityError> {
    let rollback_args = ["update-ref", "-d", branch_ref, expected_head];
    let rollback = runner
        .git_output_status_bounded(worktree_root, &rollback_args, BRANCH_START_OUTPUT_BYTES)
        .map_err(|error| {
            internal(format!(
                "git_branch_start could not move symbolic HEAD ({move_head_detail}); rollback command failed for {branch_ref} at {expected_head}: {error}"
            ))
        })?;
    if rollback.success {
        return Ok(());
    }

    let rollback_detail = stderr_detail(&rollback.stderr);
    Err(internal(format!(
        "git_branch_start could not move symbolic HEAD ({move_head_detail}); rollback failed for {branch_ref} at {expected_head}: {rollback_detail}"
    )))
}

fn git_ref_oid(worktree_root: &Path, branch_ref: &str) -> Result<String, CapabilityError> {
    let output = service::git_output_bounded(
        worktree_root,
        ["rev-parse", "--verify", branch_ref],
        BRANCH_START_OUTPUT_BYTES,
    )?;
    if output.stdout_truncated {
        return Err(internal("git rev-parse output was unexpectedly truncated"));
    }
    let oid = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if oid.is_empty() {
        return Err(internal("git rev-parse returned empty branch oid"));
    }
    Ok(oid)
}

fn status_diff_snapshot(
    repository: &RepositoryFacts,
    max_status_bytes: usize,
    max_diff_bytes: usize,
) -> Result<BranchStartSnapshot, CapabilityError> {
    let status = service::git_output_bounded(
        &repository.worktree_root,
        [
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--",
            ".",
        ],
        max_status_bytes,
    )?;
    let staged = service::git_diff_text(&repository.worktree_root, true, ".", max_diff_bytes)?;
    let unstaged = service::git_diff_text(&repository.worktree_root, false, ".", max_diff_bytes)?;
    Ok(BranchStartSnapshot {
        status_porcelain: String::from_utf8_lossy(&status.stdout).into_owned(),
        status_truncated: status.stdout_truncated,
        staged_diff: staged.0,
        staged_diff_truncated: staged.1,
        unstaged_diff: unstaged.0,
        unstaged_diff_truncated: unstaged.1,
        index_tree_oid: repository.index_tree_oid.clone(),
    })
}

fn has_unmerged_index_entries(repository: &RepositoryFacts) -> Result<bool, CapabilityError> {
    let output = service::git_output_bounded(
        &repository.worktree_root,
        ["ls-files", "-u", "-z", "--", "."],
        1,
    )?;
    Ok(!output.stdout.is_empty() || output.stdout_truncated)
}

fn reject_in_progress_state(repository: &RepositoryFacts) -> Result<(), CapabilityError> {
    for (git_path, state) in [
        ("MERGE_HEAD", "merge"),
        ("CHERRY_PICK_HEAD", "cherry-pick"),
        ("REVERT_HEAD", "revert"),
        ("REBASE_HEAD", "rebase"),
        ("rebase-merge", "rebase"),
        ("rebase-apply", "rebase"),
        ("sequencer", "sequencer"),
    ] {
        if git_path_exists(repository, git_path)? {
            return Err(invalid(format!(
                "git_branch_start refuses in-progress {state} state ({git_path})"
            )));
        }
    }
    Ok(())
}

fn git_path_exists(repository: &RepositoryFacts, git_path: &str) -> Result<bool, CapabilityError> {
    let output = service::git_output_bounded(
        &repository.worktree_root,
        ["rev-parse", "--git-path", git_path],
        BRANCH_START_OUTPUT_BYTES,
    )?;
    let resolved = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if resolved.is_empty() {
        return Ok(false);
    }
    let path = PathBuf::from(resolved);
    let path = if path.is_absolute() {
        path
    } else {
        repository.worktree_root.join(path)
    };
    Ok(path.exists())
}

async fn create_branch_start_resource(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    plan: &BranchStartPlan,
) -> Result<EngineResource, CapabilityError> {
    engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!(
                "{}:{}",
                GIT_BRANCH_START_KIND,
                invocation.id.as_str()
            )),
            kind: GIT_BRANCH_START_KIND.to_owned(),
            schema_id: Some(GIT_BRANCH_START_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error_to_capability_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("started".to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": WRITE_SCOPE,
                "networkPolicy": "none",
                "mutationBoundary": "git_branch_start"
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
    plan: &BranchStartPlan,
    resource: &EngineResource,
) -> Result<crate::engine::StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: GIT_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": "git.branch_started",
                "branchName": plan.branch_name.clone(),
                "previousBranch": plan.previous_branch.clone(),
                "headOid": plan.head_oid.clone(),
                "expectedHead": plan.expected_head.clone(),
                "reason": plan.reason.clone(),
                "gitBranchStartResourceId": resource.resource_id,
                "resourceRefs": [resource_ref(resource, GIT_BRANCH_START_KIND)],
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

fn record_value(invocation: &Invocation, plan: &BranchStartPlan) -> Result<Value, CapabilityError> {
    serde_json::to_value(GitBranchStartRecord {
        schema_version: BRANCH_START_SCHEMA_VERSION.to_owned(),
        operation: "branch_start".to_owned(),
        state: "started".to_owned(),
        repository: plan.repository.clone(),
        branch_name: plan.branch_name.clone(),
        previous_branch: plan.previous_branch.clone(),
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
    .map_err(|error| internal(format!("serialize git branch start: {error}")))
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

fn stderr_detail(stderr: &[u8]) -> String {
    let detail = truncate_chars(String::from_utf8_lossy(stderr).trim(), 1_000);
    if detail.is_empty() {
        "<no stderr>".to_owned()
    } else {
        detail
    }
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

struct BranchStartPlan {
    repository: Value,
    branch_name: String,
    previous_branch: String,
    expected_head: String,
    head_oid: String,
    reason: String,
    before: Value,
    after: Value,
    evidence: Value,
}

struct BranchStartSnapshot {
    status_porcelain: String,
    status_truncated: bool,
    staged_diff: String,
    staged_diff_truncated: bool,
    unstaged_diff: String,
    unstaged_diff_truncated: bool,
    index_tree_oid: Option<String>,
}

impl BranchStartSnapshot {
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
            "indexTreeOid": self.index_tree_oid,
            "truncated": self.truncated()
        })
    }
}
