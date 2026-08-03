use super::*;

#[test]
fn engine_event_filters_are_recursive_json_subsets() {
    assert!(json_subset_matches(
        &json!({"kind":"message","nested":{"status":"ready"}}),
        &json!({"kind":"message","nested":{"status":"ready","extra":1}}),
    ));
    assert!(!json_subset_matches(
        &json!({"kind":"different"}),
        &json!({"kind":"message"}),
    ));
}

#[test]
fn engine_event_projection_overlays_only_typed_payload_fields_without_an_envelope() {
    let materialized = materialize_engine_event_input(
        &json!({"topic":"configured","asOf":"2026-07-20"}),
        &json!({"topic":"from-event","ready":true,"requestId":"ignored"}),
        &json!({
            "type":"object",
            "additionalProperties":false,
            "properties":{"topic":{"type":"string"},"asOf":{"type":"string"}}
        }),
    );
    assert_eq!(
        materialized,
        json!({"topic":"from-event","asOf":"2026-07-20"})
    );
    assert!(materialized.get("event").is_none());
    assert!(materialized.get("requestId").is_none());
}
