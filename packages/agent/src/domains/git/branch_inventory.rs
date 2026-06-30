//! Read-only local Git branch inventory support.

use serde_json::{Value, json};

use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

use super::service;
use super::types::{
    BRANCH_INVENTORY_SCHEMA_VERSION, DEFAULT_BRANCH_BYTES, DEFAULT_BRANCH_COUNT, MAX_BRANCH_BYTES,
    MAX_BRANCH_COUNT, RepositoryFacts,
};

const BRANCH_SCAN_BYTES: usize = 1024 * 1024;
const BRANCH_METADATA_BYTES: usize = 16 * 1024;
const COMMIT_FIELD_BYTES: usize = 512;

pub(crate) async fn branch_inventory_value(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let invocation = invocation.clone();
    let request = payload.clone();
    run_blocking_task("git_branch_inventory", move || {
        branch_inventory_sync(&invocation, &request)
    })
    .await
}

fn branch_inventory_sync(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let target = service::resolve_target(invocation, payload)?;
    let repository = service::repository_facts_readonly(&target)?;
    let trusted_root = service::resolve_target(invocation, &json!({"path": "."}))?;
    let trusted_repository = service::repository_facts_readonly(&trusted_root)?;
    if repository.worktree_root != trusted_repository.worktree_root {
        return Err(invalid(
            "git_branch_inventory path must belong to the trusted working-directory repository",
        ));
    }

    let max_branches = optional_usize(payload, "maxBranches")?
        .unwrap_or(DEFAULT_BRANCH_COUNT)
        .min(MAX_BRANCH_COUNT);
    let max_branch_bytes = optional_usize(payload, "maxBranchBytes")?
        .unwrap_or(DEFAULT_BRANCH_BYTES)
        .min(MAX_BRANCH_BYTES);
    let current_ref = repository
        .branch
        .as_ref()
        .map(|branch| format!("refs/heads/{branch}"));
    let scan = branch_refs(&repository)?;
    let total_branches = scan.refs.len();
    let retained = retain_branch_rows(
        &repository,
        current_ref.as_deref(),
        scan.refs,
        max_branches,
        max_branch_bytes,
    )?;
    let current_branch = current_branch_value(&repository, current_ref.as_deref(), &retained.rows);

    Ok(json!({
        "schemaVersion": BRANCH_INVENTORY_SCHEMA_VERSION,
        "status": "ok",
        "operation": "branch_inventory",
        "path": service::path_value(&target),
        "repository": service::repository_value(&target, &repository),
        "currentBranch": current_branch,
        "detachedHead": detached_head_value(&repository),
        "branches": retained.rows,
        "evidence": {
            "totalBranches": total_branches,
            "returnedBranches": retained.returned_branches,
            "maxBranches": max_branches,
            "branchCountTruncated": retained.count_truncated,
            "maxBranchBytes": max_branch_bytes,
            "retainedBranchBytes": retained.retained_branch_bytes,
            "branchBytesTruncated": retained.bytes_truncated,
            "scanBytesLimit": BRANCH_SCAN_BYTES,
            "scanBytesTruncated": scan.scan_truncated,
            "sort": "refname",
            "remotePolicy": "not invoked",
            "pagerPolicy": "disabled",
            "networkPolicy": "local git refs only",
            "resourceRefs": []
        }
    }))
}

struct BranchScan {
    refs: Vec<String>,
    scan_truncated: bool,
}

struct RetainedRows {
    rows: Vec<Value>,
    returned_branches: usize,
    retained_branch_bytes: usize,
    count_truncated: bool,
    bytes_truncated: bool,
}

fn branch_refs(repository: &RepositoryFacts) -> Result<BranchScan, CapabilityError> {
    let output = service::git_output_bounded(
        &repository.worktree_root,
        [
            "--no-pager",
            "for-each-ref",
            "--sort=refname",
            "--format=%(refname)",
            "refs/heads",
        ],
        BRANCH_SCAN_BYTES,
    )?;
    let complete_stdout = complete_line_bytes(&output.stdout, output.stdout_truncated);
    let refs = String::from_utf8_lossy(complete_stdout)
        .lines()
        .filter(|line| !line.is_empty())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();

    Ok(BranchScan {
        refs,
        scan_truncated: output.stdout_truncated,
    })
}

fn retain_branch_rows(
    repository: &RepositoryFacts,
    current_ref: Option<&str>,
    refs: Vec<String>,
    max_branches: usize,
    max_branch_bytes: usize,
) -> Result<RetainedRows, CapabilityError> {
    let total = refs.len();
    let mut retained = Vec::new();
    let mut retained_branch_bytes = 0usize;
    let mut bytes_truncated = false;

    for full_ref in refs.iter().take(max_branches) {
        let row = branch_row(repository, current_ref, full_ref)?;
        let row_bytes = serde_json::to_vec(&row)
            .map_err(|error| internal(format!("serialize branch row: {error}")))?
            .len();
        if retained_branch_bytes + row_bytes > max_branch_bytes {
            bytes_truncated = true;
            break;
        }
        retained_branch_bytes += row_bytes;
        retained.push(row);
    }

    let returned_branches = retained.len();
    Ok(RetainedRows {
        rows: retained,
        returned_branches,
        retained_branch_bytes,
        count_truncated: total > max_branches,
        bytes_truncated: bytes_truncated || returned_branches < total.min(max_branches),
    })
}

fn branch_row(
    repository: &RepositoryFacts,
    current_ref: Option<&str>,
    full_ref: &str,
) -> Result<Value, CapabilityError> {
    let metadata = branch_metadata(repository, full_ref)?;
    let (ahead, behind) = ahead_behind(
        &repository.worktree_root,
        full_ref,
        metadata.upstream_ref.as_str(),
    )?;
    let is_current = current_ref == Some(full_ref);

    Ok(json!({
        "ref": full_ref,
        "name": metadata.short_name.clone(),
        "shortName": metadata.short_name,
        "oid": metadata.oid,
        "current": is_current,
        "upstream": upstream_value(
            &metadata.upstream_ref,
            &metadata.upstream_name,
            ahead,
            behind
        ),
        "aheadBehind": ahead_behind_value(metadata.upstream_ref.is_empty(), ahead, behind),
        "lastCommit": {
            "subject": truncate_field(&metadata.subject),
            "subjectTruncated": metadata.metadata_truncated
                || metadata.subject.len() > COMMIT_FIELD_BYTES,
            "time": null_if_empty(metadata.commit_time),
            "author": {
                "name": truncate_field(&metadata.author_name),
                "nameTruncated": metadata.metadata_truncated
                    || metadata.author_name.len() > COMMIT_FIELD_BYTES
            },
            "metadataTruncated": metadata.metadata_truncated
        }
    }))
}

struct BranchMetadata {
    short_name: String,
    oid: String,
    upstream_ref: String,
    upstream_name: String,
    commit_time: String,
    author_name: String,
    subject: String,
    metadata_truncated: bool,
}

fn branch_metadata(
    repository: &RepositoryFacts,
    full_ref: &str,
) -> Result<BranchMetadata, CapabilityError> {
    let output = service::git_output_bounded(
        &repository.worktree_root,
        [
            "--no-pager",
            "for-each-ref",
            "--format=%(refname:short)%00%(objectname)%00%(upstream)%00%(upstream:short)%00%(committerdate:iso-strict)%00%(authorname)%00%(contents:subject)",
            full_ref,
        ],
        BRANCH_METADATA_BYTES,
    )?;
    let complete_stdout = trim_line_end(&output.stdout);
    let mut fields = complete_stdout.split(|byte| *byte == 0).collect::<Vec<_>>();
    if fields.len() < 7 && output.stdout_truncated {
        fields.resize(7, &[]);
    }
    if fields.len() != 7 {
        return Err(internal(format!(
            "parse git branch metadata for {full_ref}"
        )));
    }

    Ok(BranchMetadata {
        short_name: text_field(fields[0]),
        oid: text_field(fields[1]),
        upstream_ref: text_field(fields[2]),
        upstream_name: text_field(fields[3]),
        commit_time: text_field(fields[4]),
        author_name: text_field(fields[5]),
        subject: text_field(fields[6]),
        metadata_truncated: output.stdout_truncated,
    })
}

fn current_branch_value(
    repository: &RepositoryFacts,
    current_ref: Option<&str>,
    rows: &[Value],
) -> Value {
    let Some(current_ref) = current_ref else {
        return Value::Null;
    };
    let Some(branch) = repository.branch.as_ref() else {
        return Value::Null;
    };
    let oid = rows
        .iter()
        .find(|row| row["ref"] == json!(current_ref))
        .and_then(|row| row["oid"].as_str())
        .map(ToOwned::to_owned)
        .or_else(|| repository.head_oid.clone());
    json!({
        "ref": current_ref,
        "name": branch,
        "shortName": branch,
        "oid": oid
    })
}

fn detached_head_value(repository: &RepositoryFacts) -> Value {
    if !repository.detached_head {
        return Value::Null;
    }
    json!({
        "detached": true,
        "headOid": repository.head_oid
    })
}

fn upstream_value(
    upstream_ref: &str,
    upstream_name: &str,
    ahead: Option<u64>,
    behind: Option<u64>,
) -> Value {
    if upstream_ref.is_empty() {
        return Value::Null;
    }
    json!({
        "ref": upstream_ref,
        "name": if upstream_name.is_empty() { upstream_ref } else { upstream_name },
        "ahead": ahead,
        "behind": behind
    })
}

fn ahead_behind_value(no_upstream: bool, ahead: Option<u64>, behind: Option<u64>) -> Value {
    if no_upstream {
        return json!({
            "available": false,
            "reason": "no_upstream"
        });
    }
    match (ahead, behind) {
        (Some(ahead), Some(behind)) => json!({
            "available": true,
            "ahead": ahead,
            "behind": behind
        }),
        _ => json!({
            "available": false,
            "reason": "unavailable"
        }),
    }
}

fn ahead_behind(
    worktree_root: &std::path::Path,
    branch_ref: &str,
    upstream_ref: &str,
) -> Result<(Option<u64>, Option<u64>), CapabilityError> {
    if upstream_ref.is_empty() {
        return Ok((None, None));
    }
    let range = format!("{branch_ref}...{upstream_ref}");
    let output = service::git_output_status_bounded(
        worktree_root,
        [
            "--no-pager",
            "rev-list",
            "--left-right",
            "--count",
            range.as_str(),
        ],
        128,
    )?;
    if !output.status.success() {
        return Ok((None, None));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut parts = text.split_whitespace();
    let ahead = parts.next().and_then(|value| value.parse::<u64>().ok());
    let behind = parts.next().and_then(|value| value.parse::<u64>().ok());
    Ok((ahead, behind))
}

fn text_field(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn complete_line_bytes(bytes: &[u8], truncated: bool) -> &[u8] {
    if !truncated || bytes.last() == Some(&b'\n') {
        return bytes;
    }
    bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map(|index| &bytes[..=index])
        .unwrap_or(&[])
}

fn trim_line_end(bytes: &[u8]) -> &[u8] {
    let mut end = bytes.len();
    while end > 0 && matches!(bytes[end - 1], b'\n' | b'\r') {
        end -= 1;
    }
    &bytes[..end]
}

fn null_if_empty(value: String) -> Value {
    if value.is_empty() {
        Value::Null
    } else {
        json!(value)
    }
}

fn truncate_field(value: &str) -> String {
    if value.len() <= COMMIT_FIELD_BYTES {
        return value.to_owned();
    }
    let mut end = COMMIT_FIELD_BYTES;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
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
