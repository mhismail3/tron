use serde_json::{Value, json};

use crate::engine::{EngineResourceInspection, EngineResourceScope};
use crate::shared::server::errors::CapabilityError;

use super::validation::invalid;

pub(super) fn ensure_install_candidate_prerequisite(
    inspection: &EngineResourceInspection,
    expected_scope: &EngineResourceScope,
) -> Result<Value, CapabilityError> {
    if inspection.resource.kind != "module_install_decision" {
        return Err(invalid(
            "module lifecycle requires a module_install_decision prerequisite",
        ));
    }
    if inspection.resource.schema_id != "tron.resource.module_install_decision.v1" {
        return Err(invalid(
            "module lifecycle requires the current module_install_decision schema",
        ));
    }
    if &inspection.resource.scope != expected_scope {
        return Err(invalid(
            "module lifecycle install decision must be in the current scope",
        ));
    }
    if inspection.resource.lifecycle != "install_candidate" {
        return Err(invalid(
            "module lifecycle requires install_candidate install decision",
        ));
    }
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid("module install decision has no current version"))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid("module install decision current version is missing"))?;
    if !version.state.may_be_current() {
        return Err(invalid(
            "module install decision current version is unavailable",
        ));
    }
    let payload = &version.payload;
    if payload.get("schemaVersion").and_then(Value::as_str)
        != Some("tron.module_install_decision.v1")
    {
        return Err(invalid(
            "module lifecycle requires current module install decision payload version",
        ));
    }
    if payload.pointer("/decision/state").and_then(Value::as_str) != Some("install_candidate") {
        return Err(invalid(
            "module lifecycle requires install decision state install_candidate",
        ));
    }
    if payload
        .pointer("/decision/metadataOnly")
        .and_then(Value::as_bool)
        != Some(true)
        || payload
            .pointer("/decision/installPerformed")
            .and_then(Value::as_bool)
            != Some(false)
    {
        return Err(invalid(
            "module lifecycle requires metadata-only install candidate proof",
        ));
    }
    let side_effect = payload
        .get("sideEffectProof")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("module lifecycle requires install side-effect proof"))?;
    for (field, expected) in [
        ("metadataOnly", true),
        ("installPerformed", false),
        ("activationPerformed", false),
        ("executionPerformed", false),
        ("dependencyRestorePerformed", false),
        ("packageManagerUsed", false),
        ("networkAccessPerformed", false),
        ("repoManagedSkillsTouched", false),
        ("physicalWorkspaceDirectoryCreated", false),
        ("rawCommandsStored", false),
        ("rawLogsStored", false),
        ("fileContentsStored", false),
        ("absolutePathsStored", false),
    ] {
        if side_effect.get(field).and_then(Value::as_bool) != Some(expected) {
            return Err(invalid(format!(
                "module lifecycle requires install proof {field}={expected}"
            )));
        }
    }
    if side_effect.get("networkPolicy").and_then(Value::as_str) != Some("none") {
        return Err(invalid(
            "module lifecycle requires install proof networkPolicy none",
        ));
    }
    Ok(json!({
        "kind": inspection.resource.kind,
        "resourceId": inspection.resource.resource_id,
        "versionId": version.version_id,
        "schemaId": inspection.resource.schema_id,
        "status": "install_candidate",
        "currentVersionRevalidated": true,
        "validationReport": payload.get("validationReport").cloned().unwrap_or(Value::Null),
        "request": payload.get("request").cloned().unwrap_or(Value::Null),
        "rollback": payload.get("rollback").cloned().unwrap_or(Value::Null),
        "sideEffectProof": {
            "metadataOnly": true,
            "installPerformed": false,
            "activationPerformed": false,
            "executionPerformed": false,
            "networkPolicy": "none",
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "networkAccessPerformed": false
        }
    }))
}
