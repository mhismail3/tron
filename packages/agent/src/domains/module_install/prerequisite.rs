use serde_json::{Value, json};

use crate::engine::{EngineResourceInspection, EngineResourceScope};
use crate::shared::server::errors::CapabilityError;

use super::validation::invalid;

pub(super) fn ensure_validation_report_prerequisite(
    inspection: &EngineResourceInspection,
    expected_scope: &EngineResourceScope,
) -> Result<Value, CapabilityError> {
    if inspection.resource.kind != "module_validation_report" {
        return Err(invalid(
            "module install requires a module_validation_report prerequisite",
        ));
    }
    if inspection.resource.schema_id != "tron.resource.module_validation_report.v1" {
        return Err(invalid(
            "module install requires the current module_validation_report schema",
        ));
    }
    if &inspection.resource.scope != expected_scope {
        return Err(invalid(
            "module install validation report must be in the current scope",
        ));
    }
    if !matches!(inspection.resource.lifecycle.as_str(), "passed") {
        return Err(invalid("module install requires passed validation report"));
    }
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid("module validation report has no current version"))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid("module validation report current version is missing"))?;
    if !version.state.may_be_current() {
        return Err(invalid(
            "module validation report current version is unavailable",
        ));
    }
    let payload = &version.payload;
    if payload.get("schemaVersion").and_then(Value::as_str)
        != Some("tron.module_validation_report.v1")
    {
        return Err(invalid(
            "module install requires current module validation payload version",
        ));
    }
    if payload
        .pointer("/validation/status")
        .and_then(Value::as_str)
        != Some("passed")
    {
        return Err(invalid("module install requires validation status passed"));
    }
    if ref_count(payload.pointer("/subjectRefs/modules")) == 0 {
        return Err(invalid("module install requires bounded module refs"));
    }
    if ref_count(payload.pointer("/evidence/docs")) == 0 {
        return Err(invalid("module install requires docs evidence"));
    }
    if ref_count(payload.pointer("/evidence/tests")) == 0 {
        return Err(invalid("module install requires tests evidence"));
    }
    let proof = payload
        .get("noInstallNoExecutionProof")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("module install requires no-install/no-execution proof"))?;
    for (field, expected) in [
        ("noInstall", true),
        ("noExecution", true),
        ("networkAccessPerformed", false),
        ("dependencyRestorePerformed", false),
        ("packageManagerUsed", false),
        ("repoManagedSkillsTouched", false),
        ("rawCommandsStored", false),
        ("rawLogsStored", false),
        ("fileContentsStored", false),
        ("absolutePathsStored", false),
    ] {
        if proof.get(field).and_then(Value::as_bool) != Some(expected) {
            return Err(invalid(format!(
                "module install requires validation proof {field}={expected}"
            )));
        }
    }
    if proof.get("networkPolicy").and_then(Value::as_str) != Some("none") {
        return Err(invalid(
            "module install requires validation proof networkPolicy none",
        ));
    }
    Ok(json!({
        "kind": inspection.resource.kind,
        "resourceId": inspection.resource.resource_id,
        "versionId": version.version_id,
        "schemaId": inspection.resource.schema_id,
        "status": "passed",
        "currentVersionRevalidated": true,
        "moduleRefCount": ref_count(payload.pointer("/subjectRefs/modules")),
        "proposalRefCount": ref_count(payload.pointer("/subjectRefs/proposals")),
        "docEvidenceCount": ref_count(payload.pointer("/evidence/docs")),
        "testEvidenceCount": ref_count(payload.pointer("/evidence/tests")),
        "noInstallNoExecutionProof": {
            "noInstall": true,
            "noExecution": true,
            "networkPolicy": "none",
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "networkAccessPerformed": false
        }
    }))
}

fn ref_count(value: Option<&Value>) -> usize {
    value.and_then(Value::as_array).map_or(0, Vec::len)
}
