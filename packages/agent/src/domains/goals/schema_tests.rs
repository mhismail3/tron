use std::collections::BTreeSet;

use serde_json::Value;

use crate::engine::{RegisterResourceType, builtin_resource_type_definitions};

#[test]
fn resource_definitions_cover_goal_question_and_answer_lifecycle() {
    let definitions = builtin_resource_type_definitions();

    let goal = resource_definition(&definitions, "goal");
    assert_eq!(goal.schema_id, "tron.resource.goal.v1");
    assert_contains_all(
        &string_set(&goal.lifecycle_states),
        &["open", "cancelled", "completed", "failed", "archived"],
    );
    assert_contains_all(
        &property_keys(&goal.schema),
        &["queueRefs", "traceRefs", "replayRefs"],
    );
    assert_contains_all(
        &string_set(&goal.allowed_link_relations),
        &["blocks", "answered_by"],
    );

    let question = resource_definition(&definitions, super::USER_QUESTION_KIND);
    assert_eq!(question.schema_id, super::USER_QUESTION_SCHEMA_ID);
    assert_contains_all(
        &string_set(&question.lifecycle_states),
        &["pending", "answered", "expired", "cancelled", "archived"],
    );
    assert_contains_all(
        &required_keys(&question.schema),
        &[
            "schemaVersion",
            "state",
            "prompt",
            "requester",
            "scope",
            "traceRefs",
            "replayRefs",
            "revision",
        ],
    );
    assert_required_capability(question, "answer", "goals.write");

    let answer = resource_definition(&definitions, super::GOAL_ANSWER_KIND);
    assert_eq!(answer.schema_id, super::GOAL_ANSWER_SCHEMA_ID);
    assert_contains_all(
        &string_set(&answer.lifecycle_states),
        &["recorded", "archived"],
    );
    assert_contains_all(
        &required_keys(&answer.schema),
        &[
            "questionResourceId",
            "questionVersionId",
            "answerText",
            "reason",
            "authority",
            "freshness",
            "idempotency",
        ],
    );
    assert_required_capability(answer, "write", "goals.write");
}

fn resource_definition<'a>(
    definitions: &'a [RegisterResourceType],
    kind: &str,
) -> &'a RegisterResourceType {
    definitions
        .iter()
        .find(|definition| definition.kind == kind)
        .unwrap_or_else(|| panic!("missing built-in resource definition for {kind}"))
}

fn property_keys(schema: &Value) -> BTreeSet<String> {
    schema["properties"]
        .as_object()
        .expect("properties object")
        .keys()
        .cloned()
        .collect()
}

fn required_keys(schema: &Value) -> BTreeSet<String> {
    schema["required"]
        .as_array()
        .expect("required array")
        .iter()
        .map(|value| value.as_str().expect("string").to_owned())
        .collect()
}

fn string_set(values: &[String]) -> BTreeSet<String> {
    values.iter().cloned().collect()
}

fn assert_contains_all(actual: &BTreeSet<String>, expected: &[&str]) {
    for expected in expected {
        assert!(
            actual.contains(*expected),
            "missing expected value {expected} in {actual:?}"
        );
    }
}

fn assert_required_capability(definition: &RegisterResourceType, operation: &str, expected: &str) {
    let values = definition.required_capabilities[operation]
        .as_array()
        .unwrap_or_else(|| panic!("{operation} capabilities must be an array"));
    assert!(
        values.iter().any(|value| value.as_str() == Some(expected)),
        "missing capability {expected} for {operation}: {values:?}"
    );
}
