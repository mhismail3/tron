use serde_json::{Map, Value, json};

pub(super) fn insert_program_execution_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "programExecutionResourceId",
        "Durable program_execution_record resource id for program_execution_inspect.",
    );
    insert_string(
        properties,
        "programId",
        "Optional caller-visible program execution id for idempotent resource identity.",
    );
    insert_string(
        properties,
        "runtimeId",
        "Required bounded runtime identifier metadata for program_execution_record; never starts or installs a runtime.",
    );
    insert_string(
        properties,
        "languageId",
        "Required bounded language identifier metadata for program_execution_record.",
    );
    insert_string(
        properties,
        "programFingerprint",
        "Required bounded fingerprint for the program source or plan; never raw code or commands.",
    );
    for field in ["sourceRef", "inputRef", "outputRef"] {
        properties.insert(
            field.to_owned(),
            json!({"type": "object", "description": "Optional bounded resource reference for program_execution_record; contains only kind plus id/resourceId and optional role/versionId."}),
        );
    }
    for field in ["inputFingerprint", "outputFingerprint"] {
        insert_string(
            properties,
            field,
            "Optional bounded I/O fingerprint metadata; never raw stdin/stdout/stderr.",
        );
    }
    for field in ["maxWallClockMs", "maxMemoryMb", "maxOutputBytes"] {
        properties.insert(
            field.to_owned(),
            json!({"type": "integer", "description": "Optional declared resource limit metadata; not enforced by a runtime in Slice 15A."}),
        );
    }
    insert_string(
        properties,
        "programLabel",
        "Optional bounded short label for program_execution_record metadata.",
    );
    insert_string(
        properties,
        "programSummary",
        "Optional bounded summary for program_execution_record metadata; must not include executable command text.",
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
