//! Canonical scope validation and claim scheduling helpers.
//!
//! Process identity checks and fair claim promotion remain internal to coordination persistence.

use super::*;

pub(super) fn validate_canonical_scope(
    kind: WorkspaceClaimKind,
    value: &str,
) -> Result<String, String> {
    if kind == WorkspaceClaimKind::WorkspaceProcess {
        return (value == ".").then(|| value.to_owned()).ok_or_else(|| {
            "workspace process claims must use the whole-workspace scope '.'".to_owned()
        });
    }
    if value.is_empty() || value == "." || value.contains('\0') {
        return Err("scoped write claims require a non-root canonical relative path".to_owned());
    }
    let path = Path::new(value);
    if path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err("workspace write scope must be a canonical relative path".to_owned());
    }
    let normalized = path
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/");
    if normalized != value {
        return Err("workspace write scope must already be canonical".to_owned());
    }
    Ok(normalized)
}

pub(super) fn validate_workspace_process_gate_id(claim_id: &str) -> Result<(), String> {
    validate_runtime_identifier(claim_id, "workspace claim id", 256)?;
    if !claim_id
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err("workspace claim id is not a safe gate-path component".to_owned());
    }
    Ok(())
}

pub(super) fn scopes_overlap(
    left_kind: WorkspaceClaimKind,
    left: &str,
    right_kind: WorkspaceClaimKind,
    right: &str,
) -> bool {
    if left_kind == WorkspaceClaimKind::WorkspaceProcess
        || right_kind == WorkspaceClaimKind::WorkspaceProcess
    {
        return true;
    }
    left == right
        || left
            .strip_prefix(right)
            .is_some_and(|suffix| suffix.starts_with('/'))
        || right
            .strip_prefix(left)
            .is_some_and(|suffix| suffix.starts_with('/'))
}

pub(super) fn case_normalized_component(value: &str) -> String {
    value.chars().flat_map(char::to_lowercase).collect()
}

pub(super) fn scopes_have_ambiguous_case(left: &str, right: &str) -> bool {
    left.split('/').zip(right.split('/')).any(|(left, right)| {
        left != right && case_normalized_component(left) == case_normalized_component(right)
    })
}

pub(super) fn reject_ambiguous_case_scope(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    candidate: &str,
) -> Result<(), String> {
    if candidate == "." {
        return Ok(());
    }
    let active = {
        let mut statement = transaction
            .prepare(
                "SELECT canonical_scope FROM agent_write_claims
                 WHERE workspace_id=?1 AND state IN ('queued','held')
                   AND kind='scoped_write'",
            )
            .map_err(|error| format!("prepare workspace case-scope check: {error}"))?;
        statement
            .query_map([workspace_id], |row| row.get::<_, String>(0))
            .map_err(|error| format!("query workspace case-scope check: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode workspace case-scope check: {error}"))?
    };
    if active
        .iter()
        .any(|scope| scopes_have_ambiguous_case(scope, candidate))
    {
        return Err(
            "workspace mutation target has ambiguous case relative to an active path reservation"
                .to_owned(),
        );
    }
    Ok(())
}

pub(super) fn cancel_captured_workspace_process(process_id: u32, expected_identity: &str) {
    #[cfg(unix)]
    {
        if !matches!(
            workspace_process_identity(process_id),
            Ok(Some(identity)) if identity == expected_identity
        ) {
            return;
        }
        if let Some(process_group) = i32::try_from(process_id)
            .ok()
            .and_then(rustix::process::Pid::from_raw)
        {
            let _ =
                rustix::process::kill_process_group(process_group, rustix::process::Signal::KILL);
        }
    }
    #[cfg(not(unix))]
    let _ = (process_id, expected_identity);
}

/// Return a stable OS birth identity only when `process_id` is also the
/// process-group leader Tron created. Numeric PIDs alone are never durable
/// evidence because the OS may recycle them after a crash.
pub(super) fn workspace_process_identity(process_id: u32) -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        let signed_id = i32::try_from(process_id)
            .map_err(|_| "workspace process id exceeds signed range".to_owned())?;
        let info = match libproc::proc_pid::pidinfo::<libproc::bsd_info::BSDInfo>(signed_id, 0) {
            Ok(info) => info,
            Err(_) => return Ok(None),
        };
        if info.pbi_pid != process_id || info.pbi_pgid != process_id {
            return Ok(None);
        }
        return Ok(Some(format!(
            "macos:{}:{}:{}",
            info.pbi_start_tvsec, info.pbi_start_tvusec, info.pbi_pgid
        )));
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        let stat = match std::fs::read_to_string(format!("/proc/{process_id}/stat")) {
            Ok(stat) => stat,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(format!(
                    "read workspace process identity for {process_id}: {error}"
                ));
            }
        };
        let (_, fields) = stat
            .rsplit_once(") ")
            .ok_or_else(|| "decode workspace process identity: malformed /proc stat".to_owned())?;
        let fields = fields.split_ascii_whitespace().collect::<Vec<_>>();
        // After the parenthesized command, index 0 is field 3 (`state`), index
        // 2 is field 5 (`pgrp`), and index 19 is field 22 (`starttime`).
        let process_group = fields
            .get(2)
            .and_then(|value| value.parse::<u32>().ok())
            .ok_or_else(|| "decode workspace process group from /proc stat".to_owned())?;
        let start_time = fields
            .get(19)
            .ok_or_else(|| "decode workspace process start time from /proc stat".to_owned())?;
        if process_group != process_id {
            return Ok(None);
        }
        return Ok(Some(format!("linux:{start_time}:{process_group}")));
    }

    #[cfg(all(
        unix,
        not(any(target_os = "macos", target_os = "linux", target_os = "android"))
    ))]
    {
        let output = std::process::Command::new("/bin/ps")
            .args([
                "-p",
                &process_id.to_string(),
                "-o",
                "pgid=",
                "-o",
                "lstart=",
            ])
            .output()
            .map_err(|error| format!("inspect workspace process identity: {error}"))?;
        if !output.status.success() {
            return Ok(None);
        }
        let value = String::from_utf8_lossy(&output.stdout);
        let Some((process_group, started_at)) = value.trim().split_once(char::is_whitespace) else {
            return Ok(None);
        };
        if process_group.parse::<u32>().ok() != Some(process_id) {
            return Ok(None);
        }
        return Ok(Some(format!("unix:{process_group}:{}", started_at.trim())));
    }

    #[cfg(not(unix))]
    {
        let _ = process_id;
        Ok(None)
    }
}

pub(super) fn promote_workspace_claims_in_tx(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    now: &str,
) -> Result<Vec<WorkspaceClaimRecord>, String> {
    let queued = {
        let mut statement = transaction
            .prepare(&format!(
                "SELECT {CLAIM_COLUMNS} FROM agent_write_claims
                 WHERE workspace_id=?1 AND state='queued'
                 ORDER BY requested_at,claim_id"
            ))
            .map_err(|error| format!("prepare queued workspace claims: {error}"))?;
        statement
            .query_map([workspace_id], map_claim)
            .map_err(|error| format!("query queued workspace claims: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode queued workspace claims: {error}"))?
    };
    let mut promoted = Vec::new();
    for (index, candidate) in queued.iter().enumerate() {
        if queued[..index].iter().any(|earlier| {
            scopes_overlap(
                candidate.kind,
                &candidate.canonical_scope,
                earlier.kind,
                &earlier.canonical_scope,
            )
        }) {
            // A conflicting earlier waiter owns queue priority even when it is
            // itself blocked. In particular, a queued whole-workspace process
            // prevents an unbounded stream of later disjoint writers from
            // starving it.
            continue;
        }
        let held = {
            let mut statement = transaction
                .prepare(&format!(
                    "SELECT {CLAIM_COLUMNS} FROM agent_write_claims
                     WHERE workspace_id=?1 AND state='held'
                     ORDER BY acquired_at,claim_id"
                ))
                .map_err(|error| format!("prepare held workspace claims: {error}"))?;
            statement
                .query_map([workspace_id], map_claim)
                .map_err(|error| format!("query held workspace claims: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode held workspace claims: {error}"))?
        };
        if held.iter().any(|held| {
            scopes_overlap(
                candidate.kind,
                &candidate.canonical_scope,
                held.kind,
                &held.canonical_scope,
            )
        }) {
            // FIFO writer preference: a blocked earlier request prevents a
            // later conflicting request, but disjoint scopes may still run.
            continue;
        }
        let changed = transaction
            .execute(
                "UPDATE agent_write_claims
                 SET state='held',acquired_at=?2
                 WHERE claim_id=?1 AND state='queued'",
                params![candidate.claim_id, now],
            )
            .map_err(|error| format!("acquire workspace claim: {error}"))?;
        if changed == 1
            && let Some(record) = query_claim(transaction, &candidate.claim_id)?
        {
            promoted.push(record);
        }
    }
    Ok(promoted)
}
