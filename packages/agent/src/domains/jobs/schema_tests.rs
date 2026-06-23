use std::collections::BTreeSet;

use chrono::{TimeZone, Utc};
use serde_json::{Value, json};

use crate::engine::{
    DurableOutputContract, RegisterResourceType, builtin_resource_type_definitions,
};

use super::types::{
    JOB_SCHEMA_VERSION, JobAuthorityRecord, JobCancellationRecord, JobCommandRecord,
    JobLimitsRecord, JobProcessRecord, JobState, JobWorkingDirectory,
};

#[test]
fn resource_definition_matches_domain_constants_and_payload() {
    let definitions = builtin_resource_type_definitions();
    let definition = resource_definition(&definitions, super::JOB_PROCESS_KIND);
    assert_eq!(definition.schema_id, super::JOB_PROCESS_SCHEMA_ID);
    assert_resource_schema_matches_record(
        &definition.schema,
        job_record_value(),
        &[
            "schemaVersion",
            "state",
            "command",
            "authority",
            "limits",
            "retention",
            "createdAt",
            "startedAt",
            "traceRefs",
            "replayRefs",
            "revision",
        ],
    );

    let capabilities = super::contract::capabilities().expect("jobs capabilities");
    for function_id in [
        super::START_FUNCTION,
        super::CANCEL_FUNCTION,
        super::CLEANUP_FUNCTION,
    ] {
        assert_output_contract(
            &capabilities
                .iter()
                .find(|spec| spec.function_id.as_str() == function_id)
                .unwrap_or_else(|| panic!("missing capability {function_id}"))
                .output_contract,
            &[super::JOB_PROCESS_KIND],
        );
    }
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

fn assert_resource_schema_matches_record(schema: &Value, record: Value, required_fields: &[&str]) {
    let schema_fields = object_keys(&schema["properties"]);
    let record_fields = object_keys(&record);
    assert_eq!(
        schema_fields, record_fields,
        "job resource schema properties must match serialized domain record fields"
    );

    let required = string_array_values(&schema["required"]);
    let expected_required = required_fields
        .iter()
        .map(|field| (*field).to_owned())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        required, expected_required,
        "job resource required fields must match the persisted payload"
    );
}

fn assert_output_contract(contract: &DurableOutputContract, expected: &[&str]) {
    let DurableOutputContract::ResourceBacked {
        produced_resource_kinds,
        ..
    } = contract
    else {
        panic!("job write capability should be resource-backed");
    };
    assert_eq!(produced_resource_kinds, expected);
}

fn object_keys(value: &Value) -> BTreeSet<String> {
    value.as_object().expect("object").keys().cloned().collect()
}

fn string_array_values(value: &Value) -> BTreeSet<String> {
    value
        .as_array()
        .expect("array")
        .iter()
        .map(|value| value.as_str().expect("string").to_owned())
        .collect()
}

fn job_record_value() -> Value {
    serde_json::to_value(JobProcessRecord {
        schema_version: JOB_SCHEMA_VERSION.to_owned(),
        state: JobState::Running,
        command: JobCommandRecord {
            kind: "shell_command".to_owned(),
            command: "printf hello".to_owned(),
            working_directory: JobWorkingDirectory {
                root: "trusted_runtime_metadata".to_owned(),
                canonical_path: "/tmp/tron".to_owned(),
            },
            network_policy: "none".to_owned(),
        },
        authority: JobAuthorityRecord {
            actor_id: "agent:session-1".to_owned(),
            authority_grant_id: "grant-1".to_owned(),
            authority_scopes: vec!["capability.execute".to_owned()],
            session_id: Some("session-1".to_owned()),
            workspace_id: Some("workspace-1".to_owned()),
        },
        limits: JobLimitsRecord {
            timeout_ms: 1000,
            max_output_bytes: 1000,
        },
        retention: json!({"mode": "explicit"}),
        created_at: Utc.with_ymd_and_hms(2026, 6, 20, 12, 0, 0).unwrap(),
        started_at: Utc.with_ymd_and_hms(2026, 6, 20, 12, 0, 0).unwrap(),
        completed_at: None,
        cancellation: JobCancellationRecord {
            requested: false,
            requested_at: None,
            requested_by: None,
            reason: None,
        },
        terminal: None,
        output: None,
        trace_refs: vec![json!({"traceId": "trace-1"})],
        replay_refs: vec![json!({"kind": "engine_invocation"})],
        revision: 1,
    })
    .expect("job record value")
}
