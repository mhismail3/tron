use serde_json::{Map, Value, json};

pub(super) fn insert_scheduler_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "title",
        "Bounded schedule title for schedule_create.",
    );
    insert_string(
        properties,
        "scheduleKind",
        "Schedule kind for schedule_create: reminder, monitor, or automation.",
    );
    insert_string(
        properties,
        "triggerType",
        "Schedule trigger type for schedule_create: once or interval.",
    );
    insert_string(
        properties,
        "startAt",
        "RFC3339 instant for the first schedule fire.",
    );
    insert_string(
        properties,
        "createdAt",
        "Optional explicit RFC3339 audit timestamp for schedule_create; defaults to startAt for deterministic replay.",
    );
    insert_string(
        properties,
        "cancelledAt",
        "Optional explicit RFC3339 audit timestamp for schedule_cancel; defaults to the stored schedule update timestamp.",
    );
    insert_string(
        properties,
        "evaluationAt",
        "Required explicit RFC3339 instant for schedule_fire_due evaluation.",
    );
    insert_integer(
        properties,
        "intervalSeconds",
        60,
        Some(31_622_400),
        Some("Interval cadence for interval schedules."),
    );
    insert_string(
        properties,
        "timezone",
        "Bounded timezone label recorded in scheduler policy; instants are evaluated in UTC.",
    );
    insert_string(
        properties,
        "missedRunPolicy",
        "Missed-run policy for schedule_create: skip, fire_once, or catch_up.",
    );
    insert_integer(
        properties,
        "maxCatchUpRuns",
        1,
        Some(100),
        Some("Maximum catch-up run records emitted during one schedule_fire_due evaluation."),
    );
    properties.insert(
        "target".to_owned(),
        json!({"type": "object", "description": "Explicit non-wildcard schedule target descriptor with resourceKind, action, and bounded resourceIds. The scheduler records runs only; feature domains own execution."}),
    );
    insert_integer(
        properties,
        "maxRunRecords",
        1,
        Some(10_000),
        Some("Retention bound recorded on schedule resources."),
    );
    insert_integer(
        properties,
        "maxAgeDays",
        1,
        Some(366),
        Some("Retention age bound recorded on schedule resources."),
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}

fn insert_integer(
    properties: &mut Map<String, Value>,
    name: &str,
    minimum: u64,
    maximum: Option<u64>,
    description: Option<&str>,
) {
    let mut property = Map::new();
    property.insert("type".to_owned(), json!("integer"));
    property.insert("minimum".to_owned(), json!(minimum));
    if let Some(maximum) = maximum {
        property.insert("maximum".to_owned(), json!(maximum));
    }
    if let Some(description) = description {
        property.insert("description".to_owned(), json!(description));
    }
    properties.insert(name.to_owned(), Value::Object(property));
}
