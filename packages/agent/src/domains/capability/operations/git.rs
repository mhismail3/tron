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
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
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

    format!(
        "git_status {status}: {path} on {branch} {dirty} (staged {staged}, unstaged {unstaged}, untracked {untracked}, conflicted {conflicted}; porcelain {porcelain}; refs {refs}; truncated {truncated})"
    )
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
                "repository": {"branch": "main", "detachedHead": false},
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
        assert!(text.contains("truncated false"));
    }
}
