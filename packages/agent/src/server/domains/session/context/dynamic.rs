use super::*;

pub(crate) fn collect_dynamic_rule_paths(
    event_store: &EventStore,
    session_id: &str,
) -> Vec<String> {
    let events = event_store
        .get_events_by_type(
            session_id,
            &[
                "rules.activated",
                "compact.boundary",
                "compact.summary",
                "context.cleared",
            ],
            None,
        )
        .unwrap_or_default();

    let mut seen_paths = HashSet::new();
    let mut ordered_paths = Vec::new();

    for event in events {
        if event.event_type == "compact.boundary"
            || event.event_type == "compact.summary"
            || event.event_type == "context.cleared"
        {
            seen_paths.clear();
            ordered_paths.clear();
            continue;
        }

        let Ok(payload) = serde_json::from_str::<Value>(&event.payload) else {
            continue;
        };
        let Some(rules) = payload.get("rules").and_then(Value::as_array) else {
            continue;
        };

        for rule in rules {
            let Some(relative_path) = rule.get("relativePath").and_then(Value::as_str) else {
                continue;
            };
            if rule.get("scopeDir").and_then(Value::as_str).is_none() {
                continue;
            }

            if seen_paths.insert(relative_path.to_string()) {
                ordered_paths.push(relative_path.to_string());
            }
        }
    }

    ordered_paths
}
