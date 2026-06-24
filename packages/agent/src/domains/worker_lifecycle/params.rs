use serde_json::Value;

use crate::shared::server::errors::CapabilityError;

use super::errors::invalid_params;
use super::manifest::validate_tokenish;

#[derive(Clone)]
pub(super) struct PackageRef {
    pub(super) package_id: String,
    pub(super) package_version: String,
}

pub(super) fn package_ref_from_payload(payload: &Value) -> Result<PackageRef, CapabilityError> {
    let package_id = required_string(payload, "packageId")?;
    let package_version = required_string(payload, "packageVersion")?;
    validate_tokenish("packageId", &package_id, false)?;
    validate_tokenish("packageVersion", &package_version, false)?;
    Ok(PackageRef {
        package_id,
        package_version,
    })
}

pub(super) fn reason_from_payload(payload: &Value) -> Option<String> {
    payload
        .get("reason")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| invalid_params(format!("missing required string field {field}")))
}
