//! Profile policy validation and persistence for capability admin operations.

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

use super::Deps;
use super::validate_nonempty_id;
use crate::shared::paths::files;
use crate::shared::profile::CapabilityExecutionPolicySpec;
use crate::shared::server::errors::CapabilityError;

pub(super) fn validate_capability_execution_policy_payload(raw_policy: Value) -> Value {
    match serde_json::from_value::<CapabilityExecutionPolicySpec>(raw_policy) {
        Ok(policy) => json!({
            "valid": true,
            "policy": policy,
            "errors": []
        }),
        Err(error) => json!({
            "valid": false,
            "errors": [error.to_string()]
        }),
    }
}

pub(super) fn validate_profile_id(policy_id: &str) -> Result<(), CapabilityError> {
    validate_nonempty_id("policyId", policy_id)?;
    let valid = policy_id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.' | ':'));
    if valid {
        return Ok(());
    }
    Err(CapabilityError::InvalidParams {
        message: "policyId contains unsupported characters".to_owned(),
    })
}

pub(super) fn current_profile_toml_path(deps: &Deps) -> PathBuf {
    deps.profile_runtime
        .current()
        .profile
        .active_dir
        .join(files::PROFILE_TOML)
}

pub(super) fn write_capability_execution_policy_to_profile_and_reload(
    path: &Path,
    policy_id: &str,
    policy: &CapabilityExecutionPolicySpec,
    runtime: &crate::domains::agent::runner::profile_runtime::ProfileRuntime,
) -> Result<(), CapabilityError> {
    let previous = fs::read_to_string(path).map_err(|error| CapabilityError::Internal {
        message: format!("read profile TOML {}: {error}", path.display()),
    })?;
    write_capability_execution_policy_to_profile_inner(path, policy_id, policy, &previous)?;
    if let Err(error) = runtime.reload_now("capability::policy_update") {
        atomic_write(path, previous.as_bytes())?;
        let _ = runtime.reload_now("capability::policy_update.rollback");
        return Err(CapabilityError::Internal {
            message: format!(
                "profile runtime rejected updated capability policy; profile TOML was rolled back: {error}"
            ),
        });
    }
    Ok(())
}

fn write_capability_execution_policy_to_profile_inner(
    path: &Path,
    policy_id: &str,
    policy: &CapabilityExecutionPolicySpec,
    previous: &str,
) -> Result<(), CapabilityError> {
    let mut value: toml::Value =
        toml::from_str(previous).map_err(|error| CapabilityError::InvalidParams {
            message: format!("profile TOML is invalid and cannot be updated: {error}"),
        })?;
    let Some(table) = value.as_table_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "profile TOML root must be a table".to_owned(),
        });
    };
    let policies = table
        .entry("capabilityExecutionPolicies".to_owned())
        .or_insert_with(|| toml::Value::Table(Default::default()));
    let Some(policies_table) = policies.as_table_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "profile capabilityExecutionPolicies must be a table".to_owned(),
        });
    };
    let policy_value =
        toml::Value::try_from(policy).map_err(|error| CapabilityError::Internal {
            message: format!("serialize capability execution policy to TOML: {error}"),
        })?;
    policies_table.insert(policy_id.to_owned(), policy_value);
    let next = toml::to_string_pretty(&value).map_err(|error| CapabilityError::Internal {
        message: format!("serialize profile TOML: {error}"),
    })?;
    atomic_write(path, next.as_bytes())
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), CapabilityError> {
    let parent = path.parent().ok_or_else(|| CapabilityError::Internal {
        message: format!("path {} has no parent", path.display()),
    })?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("profile.toml");
    let tmp = parent.join(format!(
        ".{file_name}.tmp-{}",
        uuid::Uuid::now_v7().as_simple()
    ));
    fs::write(&tmp, bytes).map_err(|error| CapabilityError::Internal {
        message: format!("write temporary profile TOML {}: {error}", tmp.display()),
    })?;
    fs::rename(&tmp, path).map_err(|error| CapabilityError::Internal {
        message: format!("replace profile TOML {}: {error}", path.display()),
    })
}
