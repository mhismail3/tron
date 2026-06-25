use serde_json::{Map, Value, json};

pub(super) fn insert_update_diagnostics_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "updateDiagnosticResourceId",
        "Durable update_diagnostic_record resource id for update_diagnostic_inspect.",
    );
    insert_string(
        properties,
        "diagnosticId",
        "Optional caller-visible update diagnostic id for update_diagnostic_record idempotent resource identity.",
    );
    insert_string(
        properties,
        "checkKind",
        "Update diagnostic check kind; currently only metadata_snapshot.",
    );
    insert_string(
        properties,
        "releaseChannel",
        "Bounded release channel token for update diagnostics, such as stable or beta.",
    );
    insert_string(
        properties,
        "releaseVersion",
        "Bounded signed-release version token for update_diagnostic_record.",
    );
    insert_string(
        properties,
        "releaseBuild",
        "Optional bounded signed-release build token for update_diagnostic_record.",
    );
    insert_string(
        properties,
        "diagnosticStatus",
        "Diagnostic status for update diagnostics: current, update_available, or unknown.",
    );
    insert_string(
        properties,
        "signatureStatus",
        "Signature/provenance status metadata: verified, not_checked, or unavailable.",
    );
    insert_string(
        properties,
        "diagnosticLabel",
        "Optional bounded short label for update diagnostic metadata.",
    );
    insert_string(
        properties,
        "diagnosticSummary",
        "Optional bounded summary for update diagnostic metadata.",
    );
    insert_string(
        properties,
        "provenanceSummary",
        "Optional bounded signed-release provenance summary; raw endpoints and package bytes are not accepted.",
    );
    properties.insert(
        "provenanceRefs".to_owned(),
        json!({"type": "array", "description": "Bounded signed-release provenance refs for update_diagnostic_record."}),
    );
    properties.insert(
        "signatureRefs".to_owned(),
        json!({"type": "array", "description": "Bounded signature evidence refs for update_diagnostic_record."}),
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
