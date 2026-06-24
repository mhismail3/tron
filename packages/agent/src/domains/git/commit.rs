//! Staged-index Git commit support.

use std::path::{Path, PathBuf};

use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, EngineHostHandle, EngineResource, EngineResourceScope, GIT_COMMIT_KIND,
    GIT_COMMIT_SCHEMA_ID, Invocation, PublishStreamEvent, VisibilityScope, WorkerId,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

use super::service;
use super::types::{
    COMMIT_SCHEMA_VERSION, DEFAULT_DIFF_BYTES, DEFAULT_STATUS_BYTES, GitCommitRecord,
    MAX_COMMIT_MESSAGE_BYTES, MAX_DIFF_BYTES, MAX_STATUS_BYTES, RepositoryFacts, ResolvedTarget,
};
use super::{GIT_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

const COMMIT_OUTPUT_BYTES: usize = 8 * 1024;

pub(crate) async fn commit_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation_for_blocking = invocation.clone();
    let plan = run_blocking_task("git_commit", move || {
        commit_sync(&invocation_for_blocking, &request)
    })
    .await?;
    let resource = create_commit_resource(engine_host, invocation, &plan).await?;
    let resource_ref = resource_ref(&resource, GIT_COMMIT_KIND);
    let cursor = publish_lifecycle(engine_host, invocation, &plan, &resource).await?;

    Ok(json!({
        "schemaVersion": COMMIT_SCHEMA_VERSION,
        "status": "committed",
        "operation": "commit",
        "repository": plan.repository.clone(),
        "branch": plan.branch.clone(),
        "parentOid": plan.parent_oid.clone(),
        "expectedHead": plan.expected_head.clone(),
        "expectedIndexTree": plan.expected_index_tree.clone(),
        "actualTree": plan.actual_tree.clone(),
        "commitOid": plan.commit_oid.clone(),
        "message": plan.message_metadata.clone(),
        "reason": plan.reason.clone(),
        "before": plan.before.clone(),
        "after": plan.after.clone(),
        "evidence": plan.evidence.clone(),
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref],
        "gitCommitResourceId": resource.resource_id
    }))
}

fn commit_sync(invocation: &Invocation, payload: &Value) -> Result<CommitPlan, CapabilityError> {
    let target = service::resolve_target(invocation, payload)?;
    let repository = service::repository_facts(&target)?;
    let trusted_root = service::resolve_target(invocation, &json!({"path": "."}))?;
    let trusted_repository = service::repository_facts(&trusted_root)?;
    if repository.worktree_root != trusted_repository.worktree_root {
        return Err(invalid(
            "git commit path must belong to the trusted working-directory repository",
        ));
    }

    let expected_head = required_str(payload, "expectedHead")?.to_owned();
    let expected_index_tree = required_str(payload, "expectedIndexTree")?.to_owned();
    let message = required_str(payload, "message")?.to_owned();
    validate_message(&message)?;
    let message_metadata = message_metadata(&message);
    let reason = required_str(payload, "reason")?.to_owned();
    let branch = repository
        .branch
        .clone()
        .ok_or_else(|| invalid("git_commit requires a named branch"))?;
    let branch_ref = named_branch_ref(&repository)?;
    if repository.detached_head {
        return Err(invalid("git_commit rejects detached HEAD"));
    }
    let Some(parent_oid) = repository.head_oid.clone() else {
        return Err(invalid("git_commit requires a repository HEAD"));
    };
    if parent_oid != expected_head {
        return Err(invalid(format!(
            "expectedHead mismatch: expected {expected_head}, actual {parent_oid}"
        )));
    }
    reject_in_progress_commit_state(&repository)?;
    if has_unmerged_index_entries(&repository)? {
        return Err(invalid(
            "git_commit refuses conflicted or unmerged index entries",
        ));
    }
    let actual_index_tree = repository
        .index_tree_oid
        .clone()
        .ok_or_else(|| invalid("git_commit requires a readable staged index tree"))?;
    if actual_index_tree != expected_index_tree {
        return Err(invalid(format!(
            "expectedIndexTree mismatch: expected {expected_index_tree}, actual {actual_index_tree}"
        )));
    }
    let head_tree = repository
        .head_tree_oid
        .clone()
        .ok_or_else(|| invalid("git_commit requires a repository HEAD tree"))?;
    if actual_index_tree == head_tree {
        return Err(invalid("git_commit requires non-empty staged changes"));
    }

    let max_status_bytes = optional_usize(payload, "maxStatusBytes")?
        .unwrap_or(DEFAULT_STATUS_BYTES)
        .min(MAX_STATUS_BYTES);
    let max_diff_bytes = optional_usize(payload, "maxDiffBytes")?
        .unwrap_or(DEFAULT_DIFF_BYTES)
        .min(MAX_DIFF_BYTES);
    let before = status_diff_snapshot(&repository, max_status_bytes, max_diff_bytes)?;
    let created_commit = create_single_parent_commit(
        &target,
        &branch_ref,
        &expected_head,
        &expected_index_tree,
        &message,
    )?;

    let after_target = service::resolve_target(invocation, &json!({"path": "."}))?;
    let after_repository = service::repository_facts(&after_target)?;
    let commit_oid = after_repository
        .head_oid
        .clone()
        .ok_or_else(|| internal("git_commit lost repository HEAD after commit"))?;
    if commit_oid != created_commit.commit_oid {
        return Err(internal(format!(
            "git_commit advanced unexpected HEAD: expected {}, actual {commit_oid}",
            created_commit.commit_oid
        )));
    }
    let actual_tree = after_repository
        .head_tree_oid
        .clone()
        .ok_or_else(|| internal("git_commit lost repository HEAD tree after commit"))?;
    if actual_tree != expected_index_tree {
        return Err(internal(format!(
            "git_commit created unexpected tree: expected {expected_index_tree}, actual {actual_tree}"
        )));
    }
    let after = status_diff_snapshot(&after_repository, max_status_bytes, max_diff_bytes)?;

    Ok(CommitPlan {
        repository: service::repository_value(&after_target, &after_repository),
        branch,
        parent_oid,
        expected_head,
        expected_index_tree,
        actual_tree,
        commit_oid,
        message_metadata,
        reason,
        before: before.value(),
        after: after.value(),
        evidence: json!({
            "bounded": true,
            "statusLimitBytes": max_status_bytes,
            "diffLimitBytes": max_diff_bytes,
            "beforeTruncated": before.truncated(),
            "afterTruncated": after.truncated(),
            "mutationBoundary": "commit-tree-plus-update-ref",
            "refUpdatePolicy": "compare-and-swap",
            "hookPolicy": "not invoked by commit-tree",
            "editorPolicy": "not invoked by commit-tree",
            "pagerPolicy": "disabled",
            "gpgSigningPolicy": "disabled",
            "credentialPromptPolicy": "disabled",
            "terminalPromptPolicy": "disabled",
            "networkPolicy": "none"
        }),
    })
}

fn create_single_parent_commit(
    target: &ResolvedTarget,
    branch_ref: &str,
    expected_head: &str,
    expected_index_tree: &str,
    message: &str,
) -> Result<CreatedCommit, CapabilityError> {
    let repository = service::repository_facts(target)?;
    if repository.detached_head {
        return Err(invalid("git_commit rejects detached HEAD"));
    }
    if named_branch_ref(&repository)? != branch_ref {
        return Err(invalid("git_commit rejects branch changes before commit"));
    }
    let Some(actual_head) = repository.head_oid.clone() else {
        return Err(invalid("git_commit requires a repository HEAD"));
    };
    if actual_head != expected_head {
        return Err(invalid(format!(
            "expectedHead mismatch: expected {expected_head}, actual {actual_head}"
        )));
    }
    reject_in_progress_commit_state(&repository)?;
    if has_unmerged_index_entries(&repository)? {
        return Err(invalid(
            "git_commit refuses conflicted or unmerged index entries",
        ));
    }
    let actual_index_tree = repository
        .index_tree_oid
        .clone()
        .ok_or_else(|| invalid("git_commit requires a readable staged index tree"))?;
    if actual_index_tree != expected_index_tree {
        return Err(invalid(format!(
            "expectedIndexTree mismatch: expected {expected_index_tree}, actual {actual_index_tree}"
        )));
    }
    let head_tree = repository
        .head_tree_oid
        .clone()
        .ok_or_else(|| invalid("git_commit requires a repository HEAD tree"))?;
    if actual_index_tree == head_tree {
        return Err(invalid("git_commit requires non-empty staged changes"));
    }

    let written_tree = write_index_tree(&repository)?;
    if written_tree != expected_index_tree {
        return Err(internal(format!(
            "git write-tree returned unexpected tree: expected {expected_index_tree}, actual {written_tree}"
        )));
    }
    let commit_oid = create_commit_object(&repository, &written_tree, expected_head, message)?;
    verify_commit_object(&repository, &commit_oid, expected_head, expected_index_tree)?;
    update_branch_ref_guarded(
        &repository.worktree_root,
        branch_ref,
        &commit_oid,
        expected_head,
    )?;
    Ok(CreatedCommit { commit_oid })
}

fn create_commit_object(
    repository: &RepositoryFacts,
    tree_oid: &str,
    parent_oid: &str,
    message: &str,
) -> Result<String, CapabilityError> {
    let output = service::git_commit_tree_output_bounded(
        &repository.worktree_root,
        tree_oid,
        parent_oid,
        message,
        COMMIT_OUTPUT_BYTES,
    )?;
    if !output.status.success() {
        return Err(CapabilityError::Custom {
            code: "GIT_COMMAND_FAILED".to_owned(),
            message: truncate_chars(String::from_utf8_lossy(&output.stderr).trim(), 1_000),
            details: None,
        });
    }
    if output.stdout_truncated {
        return Err(internal(
            "git commit-tree output was unexpectedly truncated",
        ));
    }
    let commit_oid = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if commit_oid.is_empty() {
        return Err(internal("git commit-tree did not return a commit oid"));
    }
    Ok(commit_oid)
}

fn write_index_tree(repository: &RepositoryFacts) -> Result<String, CapabilityError> {
    let output = service::git_output_bounded(
        &repository.worktree_root,
        ["write-tree"],
        COMMIT_OUTPUT_BYTES,
    )?;
    if !output.status.success() {
        return Err(CapabilityError::Custom {
            code: "GIT_COMMAND_FAILED".to_owned(),
            message: truncate_chars(String::from_utf8_lossy(&output.stderr).trim(), 1_000),
            details: None,
        });
    }
    if output.stdout_truncated {
        return Err(internal("git write-tree output was unexpectedly truncated"));
    }
    let tree_oid = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if tree_oid.is_empty() {
        return Err(internal("git write-tree did not return a tree oid"));
    }
    Ok(tree_oid)
}

fn verify_commit_object(
    repository: &RepositoryFacts,
    commit_oid: &str,
    expected_head: &str,
    expected_index_tree: &str,
) -> Result<(), CapabilityError> {
    let parents = service::git_output_bounded(
        &repository.worktree_root,
        ["rev-list", "--parents", "-n", "1", commit_oid],
        COMMIT_OUTPUT_BYTES,
    )?;
    if !parents.status.success() {
        return Err(internal(
            "git_commit could not inspect created commit parents",
        ));
    }
    let parent_line = String::from_utf8_lossy(&parents.stdout).trim().to_owned();
    let parent_oids = parent_line.split_whitespace().skip(1).collect::<Vec<_>>();
    if parent_oids.as_slice() != [expected_head] {
        return Err(internal(format!(
            "git_commit created unexpected parents: expected {expected_head}, actual {}",
            parent_oids.join(" ")
        )));
    }
    let tree = service::git_output_bounded(
        &repository.worktree_root,
        vec![
            "rev-parse".to_owned(),
            "--verify".to_owned(),
            format!("{commit_oid}^{{tree}}"),
        ],
        COMMIT_OUTPUT_BYTES,
    )?;
    if !tree.status.success() {
        return Err(internal("git_commit could not inspect created commit tree"));
    }
    let actual_tree = String::from_utf8_lossy(&tree.stdout).trim().to_owned();
    if actual_tree != expected_index_tree {
        return Err(internal(format!(
            "git_commit created unexpected tree: expected {expected_index_tree}, actual {actual_tree}"
        )));
    }
    Ok(())
}

pub(super) fn update_branch_ref_guarded(
    worktree_root: &Path,
    branch_ref: &str,
    new_commit: &str,
    expected_head: &str,
) -> Result<(), CapabilityError> {
    let output = service::git_update_ref_output_bounded(
        worktree_root,
        branch_ref,
        new_commit,
        expected_head,
        COMMIT_OUTPUT_BYTES,
    )?;
    if output.status.success() {
        return Ok(());
    }
    let detail = truncate_chars(String::from_utf8_lossy(&output.stderr).trim(), 1_000);
    Err(invalid(format!(
        "expectedHead changed before ref update: expected {expected_head}; {detail}"
    )))
}

fn named_branch_ref(repository: &RepositoryFacts) -> Result<String, CapabilityError> {
    let head_ref = service::git_symbolic_head_ref(&repository.worktree_root)?
        .ok_or_else(|| invalid("git_commit requires a named branch"))?;
    if !head_ref.starts_with("refs/heads/") {
        return Err(invalid("git_commit requires a local branch ref"));
    }
    Ok(head_ref)
}

fn status_diff_snapshot(
    repository: &RepositoryFacts,
    max_status_bytes: usize,
    max_diff_bytes: usize,
) -> Result<CommitSnapshot, CapabilityError> {
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
    Ok(CommitSnapshot {
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
        ["ls-files", "-u", "-z", "--", "."],
        1,
    )?;
    Ok(!output.stdout.is_empty() || output.stdout_truncated)
}

fn reject_in_progress_commit_state(repository: &RepositoryFacts) -> Result<(), CapabilityError> {
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
                "git_commit refuses in-progress {state} state ({git_path})"
            )));
        }
    }
    Ok(())
}

fn git_path_exists(repository: &RepositoryFacts, git_path: &str) -> Result<bool, CapabilityError> {
    let output = service::git_output_bounded(
        &repository.worktree_root,
        ["rev-parse", "--git-path", git_path],
        COMMIT_OUTPUT_BYTES,
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

async fn create_commit_resource(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    plan: &CommitPlan,
) -> Result<EngineResource, CapabilityError> {
    engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!("{}:{}", GIT_COMMIT_KIND, invocation.id.as_str())),
            kind: GIT_COMMIT_KIND.to_owned(),
            schema_id: Some(GIT_COMMIT_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error_to_capability_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("committed".to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": WRITE_SCOPE,
                "networkPolicy": "none",
                "mutationBoundary": "git_staged_index_commit"
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
    plan: &CommitPlan,
    resource: &EngineResource,
) -> Result<crate::engine::StreamCursor, CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: GIT_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": "git.commit_created",
                "branch": plan.branch.clone(),
                "commitOid": plan.commit_oid.clone(),
                "parentOid": plan.parent_oid.clone(),
                "expectedHead": plan.expected_head.clone(),
                "expectedIndexTree": plan.expected_index_tree.clone(),
                "actualTree": plan.actual_tree.clone(),
                "reason": plan.reason.clone(),
                "gitCommitResourceId": resource.resource_id,
                "resourceRefs": [resource_ref(resource, GIT_COMMIT_KIND)],
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

fn record_value(invocation: &Invocation, plan: &CommitPlan) -> Result<Value, CapabilityError> {
    serde_json::to_value(GitCommitRecord {
        schema_version: COMMIT_SCHEMA_VERSION.to_owned(),
        operation: "commit".to_owned(),
        state: "committed".to_owned(),
        repository: plan.repository.clone(),
        branch: plan.branch.clone(),
        parent_oid: plan.parent_oid.clone(),
        expected_head: plan.expected_head.clone(),
        expected_index_tree: plan.expected_index_tree.clone(),
        actual_tree: plan.actual_tree.clone(),
        commit_oid: plan.commit_oid.clone(),
        message: plan.message_metadata.clone(),
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
    .map_err(|error| internal(format!("serialize git commit: {error}")))
}

fn message_metadata(message: &str) -> Value {
    let byte_len = message.len();
    let line_count = message.lines().count().max(1);
    let subject = message.lines().next().unwrap_or("");
    let subject_preview = truncate_chars(subject, 120);
    let hash = Sha256::digest(message.as_bytes());
    json!({
        "byteLength": byte_len,
        "lineCount": line_count,
        "subjectPreview": subject_preview,
        "subjectPreviewTruncated": subject_preview.len() < subject.len(),
        "sha256": hex::encode(hash)
    })
}

fn validate_message(message: &str) -> Result<(), CapabilityError> {
    if message.len() > MAX_COMMIT_MESSAGE_BYTES {
        return Err(invalid(format!(
            "message exceeds {MAX_COMMIT_MESSAGE_BYTES} byte limit"
        )));
    }
    Ok(())
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

struct CommitPlan {
    repository: Value,
    branch: String,
    parent_oid: String,
    expected_head: String,
    expected_index_tree: String,
    actual_tree: String,
    commit_oid: String,
    message_metadata: Value,
    reason: String,
    before: Value,
    after: Value,
    evidence: Value,
}

struct CreatedCommit {
    commit_oid: String,
}

struct CommitSnapshot {
    status_porcelain: String,
    status_truncated: bool,
    staged_diff: String,
    staged_diff_truncated: bool,
    unstaged_diff: String,
    unstaged_diff_truncated: bool,
}

impl CommitSnapshot {
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
