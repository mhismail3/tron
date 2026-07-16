//! Git primitive execute operations.

use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::domains::git::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn git_status(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps::from_host(&deps.engine_host);
    if let Some(route) = crate::domains::capability_binding::route::active_route_for_git_status(
        &binding_deps,
        invocation,
    )
    .await?
    {
        return crate::domains::capability_binding::route::execute_routed_git_status(
            &binding_deps,
            invocation,
            &route,
        )
        .await;
    }
    let result = service::status_value(invocation, &invocation.payload).await?;
    git_result("git_status", result)
}

pub(super) async fn git_diff(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let result = service::diff_value(invocation, &invocation.payload).await?;
    git_result("git_diff", result)
}

pub(super) async fn git_branch_inventory(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::branch_inventory::branch_inventory_value(
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_branch_inventory", result)
}

pub(super) async fn git_stage(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::mutation::stage_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_stage", result)
}

pub(super) async fn git_unstage(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::mutation::unstage_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_unstage", result)
}

pub(super) async fn git_commit(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::commit::commit_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_commit", result)
}

pub(super) async fn git_branch_start(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::branch_start::branch_start_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_branch_start", result)
}

fn git_result(operation: &'static str, result: Value) -> Result<CapabilityResult, CapabilityError> {
    let status = result["status"].as_str().unwrap_or("ok");
    let content = match operation {
        "git_status" => git_status_content(status, &result),
        _ => git_default_content(operation, status, &result),
    };
    Ok(ok_result(
        content,
        json!({
            "primitiveOperation": operation,
            "status": status,
            "git": result
        }),
    ))
}

fn git_default_content(operation: &str, status: &str, result: &Value) -> String {
    let path = result
        .pointer("/path/relativePath")
        .and_then(Value::as_str)
        .unwrap_or(".");
    format!("{operation} {status}: {path}")
}

fn git_status_content(status: &str, result: &Value) -> String {
    let path = result
        .pointer("/path/relativePath")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let branch = git_branch_label(result);
    let dirty = result
        .get("dirty")
        .and_then(Value::as_bool)
        .map(|dirty| if dirty { "dirty" } else { "clean" })
        .unwrap_or("state unknown");
    let staged = summary_count(result, "stagedCount");
    let unstaged = summary_count(result, "unstagedCount");
    let untracked = summary_count(result, "untrackedCount");
    let conflicted = summary_count(result, "conflictedCount");
    let porcelain = result
        .pointer("/evidence/statusPorcelainV1Z")
        .and_then(Value::as_str)
        .map(|porcelain| {
            if porcelain.is_empty() {
                "empty"
            } else {
                "non-empty"
            }
        })
        .unwrap_or("unknown");
    let refs = result
        .pointer("/evidence/resourceRefs")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let truncated = result
        .pointer("/evidence/statusTruncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let snapshot_refs = git_status_snapshot_refs_content(result);

    format!(
        "git_status {status}: {path} on {branch} {dirty} (staged {staged}, unstaged {unstaged}, untracked {untracked}, conflicted {conflicted}; porcelain {porcelain}; durable resource refs {refs}; truncated {truncated}){snapshot_refs}"
    )
}

fn git_status_snapshot_refs_content(result: &Value) -> String {
    let Some(snapshot_input) = result
        .pointer("/repository/repositoryTreeSnapshotInput")
        .and_then(Value::as_object)
    else {
        return String::new();
    };
    let repository_ref = snapshot_input.get("repositoryRef");
    let root_ref = snapshot_input.get("rootRef");
    let tree_object_ref = snapshot_input
        .get("treeObjectRef")
        .and_then(Value::as_str)
        .or_else(|| {
            result
                .pointer("/repository/treeObjectRef")
                .and_then(Value::as_str)
        });
    let head_ref = snapshot_input.get("headRef");
    let (Some(repository_ref), Some(root_ref), Some(tree_object_ref)) =
        (repository_ref, root_ref, tree_object_ref)
    else {
        return String::new();
    };
    let Some(repository_ref_json) = safe_compact_json(repository_ref) else {
        return String::new();
    };
    let Some(root_ref_json) = safe_compact_json(root_ref) else {
        return String::new();
    };
    let head_ref_json = head_ref
        .and_then(safe_compact_json)
        .unwrap_or_else(|| "none".to_owned());
    format!(
        "; content-free navigation input (not a durable resource; no resource was created): invoke repository_tree_snapshot by copying complete ref objects from details.git.repository.repositoryTreeSnapshotInput; repositoryRef={repository_ref_json}, rootRef={root_ref_json}, treeObjectRef={tree_object_ref}, headRef={head_ref_json}; do not pass only .id values"
    )
}

fn safe_compact_json(value: &Value) -> Option<String> {
    serde_json::to_string(value).ok()
}

fn git_branch_label(result: &Value) -> String {
    if result
        .pointer("/repository/detachedHead")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return "detached HEAD".to_owned();
    }
    result
        .pointer("/repository/branch")
        .and_then(Value::as_str)
        .filter(|branch| !branch.is_empty())
        .unwrap_or("branch unknown")
        .to_owned()
}

fn summary_count(result: &Value, key: &str) -> u64 {
    result
        .pointer(&format!("/summary/{key}"))
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::content::CapabilityResultContent;
    use crate::shared::protocol::model_capabilities::CapabilityResultBody;

    #[test]
    fn git_status_result_summarizes_provider_safe_facts() {
        let result = git_result(
            "git_status",
            json!({
                "status": "ok",
                "operation": "status",
                "path": {"relativePath": "."},
                "repository": {
                    "branch": "main",
                    "detachedHead": false,
                    "treeObjectRef": "git_tree:abc123",
                    "repositoryTreeSnapshotInput": {
                        "repositoryRef": {
                            "kind": "git_repository",
                            "id": "git_repository:repo",
                            "role": "repository"
                        },
                        "rootRef": {
                            "kind": "git_root",
                            "id": "git_root:root",
                            "role": "root"
                        },
                        "headRef": {
                            "kind": "git_commit",
                            "id": "git_commit:head",
                            "role": "head"
                        },
                        "treeObjectRef": "git_tree:abc123",
                        "pathEntrySource": "git_status_provider_safe_projection",
                        "contentFree": true,
                        "rawRepositoryContentsIncluded": false
                    }
                },
                "dirty": false,
                "summary": {
                    "stagedCount": 0,
                    "unstagedCount": 0,
                    "untrackedCount": 0,
                    "conflictedCount": 0
                },
                "evidence": {
                    "statusPorcelainV1Z": "",
                    "statusTruncated": false,
                    "resourceRefs": []
                }
            }),
        )
        .expect("git result");

        let CapabilityResultBody::Blocks(blocks) = result.content else {
            panic!("expected text block");
        };
        let CapabilityResultContent::Text { text } = &blocks[0] else {
            panic!("expected text content");
        };
        assert!(text.contains("git_status ok: . on main clean"));
        assert!(text.contains("staged 0, unstaged 0, untracked 0, conflicted 0"));
        assert!(text.contains("porcelain empty"));
        assert!(text.contains("durable resource refs 0"));
        assert!(text.contains("truncated false"));
        assert!(text.contains(
            "content-free navigation input (not a durable resource; no resource was created)"
        ));
        assert!(text.contains(
            r#"repositoryRef={"id":"git_repository:repo","kind":"git_repository","role":"repository"}"#
        ));
        assert!(text.contains(r#"rootRef={"id":"git_root:root","kind":"git_root","role":"root"}"#));
        assert!(text.contains("treeObjectRef=git_tree:abc123"));
        assert!(text.contains("do not pass only .id values"));
    }
}
