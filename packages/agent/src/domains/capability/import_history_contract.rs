use serde_json::{Map, Value, json};

pub(super) fn insert_import_history_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "importHistoryResourceId",
        "Durable import_history_record resource id for import_history_inspect.",
    );
    insert_string(
        properties,
        "recordId",
        "Optional caller-visible import/session graph record id for import_history_record idempotent resource identity.",
    );
    insert_string(
        properties,
        "graphKind",
        "Graph kind for import_history_record or import_history_list; currently only session_resource.",
    );
    insert_string(
        properties,
        "subjectKind",
        "Graph subject kind for import_history_record or import_history_list: session or resource.",
    );
    insert_string(
        properties,
        "subjectId",
        "Bounded subject id for import_history_record or import_history_list. Session subjects must match the trusted current session.",
    );
    properties.insert(
        "parentRefs".to_owned(),
        json!({"type": "array", "description": "Bounded parent lineage refs for import_history_record; each item must contain bounded kind and id/resourceId fields."}),
    );
    properties.insert(
        "childRefs".to_owned(),
        json!({"type": "array", "description": "Bounded child lineage refs for import_history_record; each item must contain bounded kind and id/resourceId fields."}),
    );
    insert_string(
        properties,
        "lineageLabel",
        "Optional bounded short label for import_history_record lineage metadata.",
    );
    insert_string(
        properties,
        "lineageSummary",
        "Optional bounded summary for import_history_record lineage metadata.",
    );
    insert_string(
        properties,
        "renderHint",
        "Render hint for import_history_record; currently only generic_graph.",
    );
    insert_string(
        properties,
        "importSourceKind",
        "Optional bounded import source classification token for metadata only.",
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
