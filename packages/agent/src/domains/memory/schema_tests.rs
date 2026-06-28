use std::collections::BTreeSet;

use chrono::{TimeZone, Utc};
use serde_json::{Value, json};

use crate::engine::{
    DurableOutputContract, MEMORY_EVAL_RUN_KIND, MEMORY_EVAL_RUN_SCHEMA_ID, RegisterResourceType,
    builtin_resource_type_definitions,
};
use crate::shared::protocol::memory::{
    MEMORY_SCHEMA_VERSION, MemoryDecisionEvidence, MemoryEngineDescriptor, MemoryEvalRun,
    MemoryMigrationEnvelope, MemoryMode, MemoryPolicyRecord, MemoryPromptDecision,
    MemoryPromptTrace, MemoryQueryEvidence, MemoryRecord, MemoryResourceRef,
    RESOURCE_BACKED_MEMORY_ENGINE_ID,
};

#[test]
fn resource_definitions_match_domain_constants_and_payloads() {
    let definitions = builtin_resource_type_definitions();

    assert_definition(
        &definitions,
        super::MEMORY_ENGINE_KIND,
        super::MEMORY_ENGINE_SCHEMA_ID,
        engine_value(),
        &[
            "schemaVersion",
            "engineId",
            "label",
            "version",
            "packageProvenance",
            "supportedModes",
            "supportedStores",
            "privacyFeatures",
            "migrationSupport",
            "evalProfile",
            "status",
        ],
    );
    assert_definition(
        &definitions,
        super::MEMORY_POLICY_KIND,
        super::MEMORY_POLICY_SCHEMA_ID,
        policy_value(),
        &[
            "schemaVersion",
            "mode",
            "inclusion",
            "retention",
            "privacy",
            "migration",
            "provenance",
            "revision",
        ],
    );
    assert_definition(
        &definitions,
        super::MEMORY_RECORD_KIND,
        super::MEMORY_RECORD_SCHEMA_ID,
        record_value(),
        &[
            "schemaVersion",
            "subject",
            "scope",
            "preview",
            "bodyRef",
            "provenance",
            "confidence",
            "sensitivity",
            "retention",
            "sourceRefs",
            "traceRefs",
            "replayRefs",
            "lifecycle",
            "migration",
            "revision",
        ],
    );
    assert_definition(
        &definitions,
        super::MEMORY_PROMPT_TRACE_KIND,
        super::MEMORY_PROMPT_TRACE_SCHEMA_ID,
        prompt_trace_value(),
        &[
            "schemaVersion",
            "mode",
            "considered",
            "included",
            "excluded",
            "promptBudget",
            "redaction",
            "traceRefs",
            "replayRefs",
            "createdAt",
        ],
    );
    assert_definition(
        &definitions,
        super::MEMORY_QUERY_KIND,
        super::MEMORY_QUERY_SCHEMA_ID,
        query_value(),
        &[
            "schemaVersion",
            "queryKind",
            "intent",
            "filters",
            "engineId",
            "mode",
            "selectedRefs",
            "excludedRefs",
            "retrieval",
            "results",
            "decisionRefs",
            "policy",
            "module",
            "redaction",
            "traceRefs",
            "replayRefs",
            "lifecycle",
            "idempotency",
            "occurredAt",
        ],
    );
    assert_definition(
        &definitions,
        super::MEMORY_DECISION_KIND,
        super::MEMORY_DECISION_SCHEMA_ID,
        decision_value(),
        &[
            "schemaVersion",
            "decisionKind",
            "reasonCodes",
            "sourceRefs",
            "promptInclusion",
            "retentionEvidence",
            "policyEvidence",
            "redaction",
            "traceRefs",
            "replayRefs",
            "lifecycle",
            "idempotency",
            "occurredAt",
        ],
    );
    assert_definition(
        &definitions,
        MEMORY_EVAL_RUN_KIND,
        MEMORY_EVAL_RUN_SCHEMA_ID,
        eval_run_value(),
        &[
            "schemaVersion",
            "engineId",
            "datasetProvenance",
            "scores",
            "outcome",
            "findings",
            "createdAt",
        ],
    );
    assert_definition(
        &definitions,
        super::MEMORY_MIGRATION_ENVELOPE_KIND,
        super::MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID,
        migration_envelope_value(),
        &[
            "schemaVersion",
            "operation",
            "sourceEngineId",
            "records",
            "indexMetadata",
            "lineage",
            "validation",
            "createdAt",
        ],
    );
}

#[test]
fn mutating_capabilities_declare_memory_resource_outputs() {
    let capabilities = super::contract::capabilities().expect("memory capabilities");

    assert_output_contract(
        &capabilities
            .iter()
            .find(|spec| spec.function_id.as_str() == super::CONFIGURE_FUNCTION)
            .expect("configure capability")
            .output_contract,
        &[super::MEMORY_ENGINE_KIND, super::MEMORY_POLICY_KIND],
    );
    assert_output_contract(
        &capabilities
            .iter()
            .find(|spec| spec.function_id.as_str() == super::RETAIN_FUNCTION)
            .expect("retain capability")
            .output_contract,
        &[super::MEMORY_RECORD_KIND],
    );
    assert_output_contract(
        &capabilities
            .iter()
            .find(|spec| spec.function_id.as_str() == super::PROMPT_TRACE_FUNCTION)
            .expect("prompt trace capability")
            .output_contract,
        &[
            super::MEMORY_PROMPT_TRACE_KIND,
            super::MEMORY_QUERY_KIND,
            super::MEMORY_DECISION_KIND,
        ],
    );
    assert_output_contract(
        &capabilities
            .iter()
            .find(|spec| spec.function_id.as_str() == super::EXPORT_FUNCTION)
            .expect("export capability")
            .output_contract,
        &[super::MEMORY_MIGRATION_ENVELOPE_KIND],
    );
    assert_output_contract(
        &capabilities
            .iter()
            .find(|spec| spec.function_id.as_str() == super::IMPORT_FUNCTION)
            .expect("import capability")
            .output_contract,
        &[
            super::MEMORY_MIGRATION_ENVELOPE_KIND,
            super::MEMORY_RECORD_KIND,
        ],
    );
}

fn assert_definition(
    definitions: &[RegisterResourceType],
    kind: &str,
    schema_id: &str,
    record: Value,
    required_fields: &[&str],
) {
    let definition = resource_definition(definitions, kind);
    assert_eq!(definition.schema_id, schema_id);
    assert_resource_schema_matches_record(kind, &definition.schema, record, required_fields);
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

fn assert_resource_schema_matches_record(
    kind: &str,
    schema: &Value,
    record: Value,
    required_fields: &[&str],
) {
    let schema_fields = object_keys(&schema["properties"]);
    let record_fields = object_keys(&record);
    assert_eq!(
        schema_fields, record_fields,
        "{kind} resource schema properties must match serialized domain record fields"
    );

    let required = string_array_values(&schema["required"]);
    let expected_required = required_fields
        .iter()
        .map(|field| (*field).to_owned())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        required, expected_required,
        "{kind} resource required fields must match the domain-owned persisted payload"
    );
    assert!(
        required.is_subset(&record_fields),
        "{kind} required fields must be serialized by the domain record"
    );
}

fn assert_output_contract(contract: &DurableOutputContract, expected: &[&str]) {
    let DurableOutputContract::ResourceBacked {
        produced_resource_kinds,
        required_resource_refs,
    } = contract
    else {
        panic!("memory capability must declare resource-backed output");
    };
    assert!(
        *required_resource_refs,
        "memory capabilities must return resource refs"
    );
    assert_eq!(
        produced_resource_kinds
            .iter()
            .cloned()
            .collect::<BTreeSet<_>>(),
        expected
            .iter()
            .map(|kind| (*kind).to_owned())
            .collect::<BTreeSet<_>>()
    );
}

fn engine_value() -> Value {
    serde_json::to_value(MemoryEngineDescriptor {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        engine_id: RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned(),
        label: "Resource-backed".to_owned(),
        version: "1".to_owned(),
        package_provenance: json!({"kind": "built_in"}),
        supported_modes: vec![MemoryMode::Disabled, MemoryMode::Active],
        supported_stores: vec!["engine_resources".to_owned()],
        privacy_features: json!({"redactedAudit": true}),
        migration_support: json!({"export": true, "import": true}),
        eval_profile: json!({"required": true}),
        status: "available".to_owned(),
    })
    .expect("memory engine descriptor should serialize")
}

fn policy_value() -> Value {
    serde_json::to_value(MemoryPolicyRecord {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        mode: MemoryMode::Active,
        active_engine_id: Some(RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned()),
        compare_engine_ids: vec!["compare-engine".to_owned()],
        inclusion: json!({"promptInclusion": "eligible_by_contract"}),
        retention: json!({"defaultRetention": "explicit"}),
        privacy: json!({"defaultSensitivity": "private"}),
        migration: json!({"exportImport": "enabled"}),
        provenance: json!({"source": "test"}),
        revision: 1,
    })
    .expect("memory policy should serialize")
}

fn record_value() -> Value {
    serde_json::to_value(MemoryRecord {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        subject: "preference".to_owned(),
        scope: json!({"kind": "session", "id": "memory-session"}),
        preview: "Preference preview".to_owned(),
        body_ref: json!({"kind": "vault_blob", "resourceId": "blob:memory", "contentHash": "hash"}),
        provenance: json!({"source": "test"}),
        confidence: json!({"score": 0.9}),
        sensitivity: "private".to_owned(),
        retention: json!({"policy": "explicit"}),
        expires_at: Some(timestamp()),
        source_refs: vec![json!({"kind": "message", "id": "msg"})],
        trace_refs: vec![json!({"traceId": "memory-trace"})],
        replay_refs: vec![json!({"source": "engine_invocation_ledger"})],
        lifecycle: json!({"state": "retained"}),
        migration: json!({"portable": true}),
        revision: 1,
    })
    .expect("memory record should serialize")
}

fn prompt_trace_value() -> Value {
    let decision = MemoryPromptDecision {
        resource_ref: resource_ref("memory_record:one"),
        reason: "test".to_owned(),
        metadata: json!({"privateContentLogged": false}),
    };
    serde_json::to_value(MemoryPromptTrace {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        mode: MemoryMode::Active,
        engine_id: Some(RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned()),
        considered: vec![decision.clone()],
        included: Vec::new(),
        excluded: vec![decision],
        prompt_budget: json!({"recordLimit": 50, "includedContentBytes": 0}),
        redaction: json!({"promptReceivesRecordBody": false}),
        trace_refs: vec![json!({"traceId": "memory-trace"})],
        replay_refs: vec![json!({"source": "engine_invocation_ledger"})],
        created_at: timestamp(),
    })
    .expect("memory prompt trace should serialize")
}

fn query_value() -> Value {
    serde_json::to_value(MemoryQueryEvidence {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        query_kind: "resource_backed_prompt_retrieval".to_owned(),
        intent: json!({"kind": "prompt_memory_context"}),
        filters: json!({"scope": "current_memory_scope"}),
        engine_id: RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned(),
        mode: MemoryMode::Active,
        selected_refs: vec![resource_ref("memory_record:one")],
        excluded_refs: Vec::new(),
        retrieval: json!({"executed": true, "algorithm": "deterministic"}),
        results: vec![json!({"rank": 1, "snippet": "Preference preview"})],
        decision_refs: Vec::new(),
        policy: json!({"mode": "active"}),
        module: json!({"modulePackId": "memory_engine_module"}),
        redaction: json!({"memoryBodyStored": false}),
        trace_refs: vec![json!({"traceId": "memory-trace"})],
        replay_refs: vec![json!({"source": "engine_invocation_ledger"})],
        lifecycle: json!({"state": "recorded"}),
        idempotency: json!({"rawKeyStored": false}),
        occurred_at: timestamp(),
    })
    .expect("memory query should serialize")
}

fn decision_value() -> Value {
    serde_json::to_value(MemoryDecisionEvidence {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        decision_kind: "prompt_inclusion".to_owned(),
        reason_codes: vec!["bounded_snippets_policy_enabled".to_owned()],
        subject_ref: Some(resource_ref("memory_record:one")),
        query_ref: Some(MemoryResourceRef {
            kind: super::MEMORY_QUERY_KIND.to_owned(),
            resource_id: "memory_query:one".to_owned(),
            version_id: Some("ver_query".to_owned()),
            role: "prompt_retrieval_query".to_owned(),
        }),
        source_refs: vec![json!({"kind": "memory_record", "resourceId": "memory_record:one"})],
        prompt_inclusion: json!({"appliedToPrompt": true, "privateBodyIncluded": false}),
        retention_evidence: json!({"automaticRetentionPerformed": false}),
        policy_evidence: json!({"mode": "active"}),
        redaction: json!({"memoryBodyStored": false}),
        trace_refs: vec![json!({"traceId": "memory-trace"})],
        replay_refs: vec![json!({"source": "engine_invocation_ledger"})],
        lifecycle: json!({"state": "recorded"}),
        idempotency: json!({"rawKeyStored": false}),
        occurred_at: timestamp(),
    })
    .expect("memory decision should serialize")
}

fn eval_run_value() -> Value {
    serde_json::to_value(MemoryEvalRun {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        engine_id: RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned(),
        dataset_provenance: json!({"dataset": "schema-only"}),
        scores: json!({"privacy": 1.0}),
        outcome: "passed".to_owned(),
        findings: vec![json!({"kind": "none"})],
        created_at: timestamp(),
    })
    .expect("memory eval run should serialize")
}

fn migration_envelope_value() -> Value {
    serde_json::to_value(MemoryMigrationEnvelope {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        operation: "export".to_owned(),
        source_engine_id: RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned(),
        target_engine_id: Some("future-memory-engine".to_owned()),
        records: vec![json!({"record": record_value()})],
        index_metadata: json!({"kind": "none"}),
        lineage: json!({"source": "test"}),
        validation: json!({"redacted": true}),
        created_at: timestamp(),
    })
    .expect("memory migration envelope should serialize")
}

fn resource_ref(resource_id: &str) -> MemoryResourceRef {
    MemoryResourceRef {
        kind: super::MEMORY_RECORD_KIND.to_owned(),
        resource_id: resource_id.to_owned(),
        version_id: Some("ver_memory".to_owned()),
        role: "considered_memory_record".to_owned(),
    }
}

fn object_keys(value: &Value) -> BTreeSet<String> {
    value
        .as_object()
        .expect("value should be an object")
        .keys()
        .cloned()
        .collect()
}

fn string_array_values(value: &Value) -> BTreeSet<String> {
    value
        .as_array()
        .expect("value should be an array")
        .iter()
        .map(|item| {
            item.as_str()
                .expect("array item should be a string")
                .to_owned()
        })
        .collect()
}

fn timestamp() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 6, 19, 12, 0, 0)
        .single()
        .expect("valid memory test timestamp")
}
