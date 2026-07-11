//! Provider-visible structural contracts for `capability::execute` operations.
//!
//! Every supported operation has one [`OperationSchemaContract`] here. Catalog
//! projection and runtime validation consume the same closed input schema,
//! provider output profile, semantic evidence requirements, summary policy,
//! and safety exclusions. Domain services retain lifecycle, stale-version, and
//! runtime resource validation after this structural gate. Typed resource-ref
//! fields encode their required kind prefix here so provider preflight rejects
//! malformed identities before an invocation reaches domain policy.

use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

#[cfg(test)]
use crate::engine::validate_engine_schema_definition;
use crate::engine::{FunctionId, validate_engine_schema_payload};
use crate::shared::server::errors::CapabilityError;

mod authority;
mod capability_binding;
mod direct;
mod governance;
mod metadata;
mod output;
mod policy;
mod records;

pub(crate) use output::provider_result_text;

macro_rules! define_operation_ids {
    ($($variant:ident => $name:literal,)+) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
        pub(crate) enum OperationId {
            $($variant,)+
        }

        impl OperationId {
            pub(crate) const ALL_NAMES: &'static [&'static str] = &[$($name,)+];

            pub(crate) fn parse(value: &str) -> Option<Self> {
                match value {
                    $($name => Some(Self::$variant),)+
                    _ => None,
                }
            }

            pub(crate) const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $name,)+
                }
            }
        }
    };
}

define_operation_ids! {
    Observe => "observe",
    StateGet => "state_get",
    StateSet => "state_set",
    StateList => "state_list",
    FilesystemRead => "filesystem_read",
    FilesystemList => "filesystem_list",
    FilesystemFind => "filesystem_find",
    FilesystemGlob => "filesystem_glob",
    FilesystemSearchText => "filesystem_search_text",
    FilesystemDiff => "filesystem_diff",
    FilesystemWrite => "filesystem_write",
    FilesystemEdit => "filesystem_edit",
    FilesystemApplyPatch => "filesystem_apply_patch",
    GitStatus => "git_status",
    GitDiff => "git_diff",
    GitBranchInventory => "git_branch_inventory",
    GitStage => "git_stage",
    GitUnstage => "git_unstage",
    GitCommit => "git_commit",
    GitBranchStart => "git_branch_start",
    ProcessRun => "process_run",
    JobStart => "job_start",
    JobStatus => "job_status",
    JobList => "job_list",
    JobLog => "job_log",
    JobCancel => "job_cancel",
    GoalCreate => "goal_create",
    GoalList => "goal_list",
    GoalInspect => "goal_inspect",
    GoalCancel => "goal_cancel",
    QuestionCreate => "question_create",
    QuestionList => "question_list",
    QuestionInspect => "question_inspect",
    QuestionAnswer => "question_answer",
    TraceList => "trace_list",
    TraceGet => "trace_get",
    LogRecent => "log_recent",
    ReplayManifest => "replay_manifest",
    CatalogSearch => "catalog_search",
    CatalogInspect => "catalog_inspect",
    CatalogConformance => "catalog_conformance",
    MemoryStatus => "memory_status",
    MemoryList => "memory_list",
    MemoryInspect => "memory_inspect",
    MemoryQueryList => "memory_query_list",
    MemoryQueryInspect => "memory_query_inspect",
    MemoryDecisionList => "memory_decision_list",
    MemoryDecisionInspect => "memory_decision_inspect",
    ContextControlStatus => "context_control_status",
    ContextControlSnapshot => "context_control_snapshot",
    ContextControlCompact => "context_control_compact",
    ContextControlClear => "context_control_clear",
    ContextControlActionList => "context_control_action_list",
    ContextControlActionInspect => "context_control_action_inspect",
    ContextSurvivorRecord => "context_survivor_record",
    ContextSurvivorList => "context_survivor_list",
    ContextSurvivorDisable => "context_survivor_disable",
    ContextExclusionRecord => "context_exclusion_record",
    ContextExclusionList => "context_exclusion_list",
    ContextExclusionDisable => "context_exclusion_disable",
    ContextPolicySnapshot => "context_policy_snapshot",
    MediaCreate => "media_create",
    MediaList => "media_list",
    MediaInspect => "media_inspect",
    MediaArchive => "media_archive",
    ImportHistoryRecord => "import_history_record",
    ImportHistoryList => "import_history_list",
    ImportHistoryInspect => "import_history_inspect",
    RepositoryTreeSnapshot => "repository_tree_snapshot",
    RepositoryTreeList => "repository_tree_list",
    RepositoryTreeInspect => "repository_tree_inspect",
    ImportPreviewRecord => "import_preview_record",
    ImportPreviewList => "import_preview_list",
    ImportPreviewInspect => "import_preview_inspect",
    ProgramExecutionRecord => "program_execution_record",
    ProgramExecutionList => "program_execution_list",
    ProgramExecutionInspect => "program_execution_inspect",
    PromptArtifactRecord => "prompt_artifact_record",
    PromptArtifactList => "prompt_artifact_list",
    PromptArtifactInspect => "prompt_artifact_inspect",
    UpdateDiagnosticRecord => "update_diagnostic_record",
    UpdateDiagnosticList => "update_diagnostic_list",
    UpdateDiagnosticInspect => "update_diagnostic_inspect",
    DeviceList => "device_list",
    DeviceInspect => "device_inspect",
    NotificationSend => "notification_send",
    NotificationList => "notification_list",
    NotificationInspect => "notification_inspect",
    NotificationMarkRead => "notification_mark_read",
    NotificationMarkAllRead => "notification_mark_all_read",
    ProceduralDefinitionRecord => "procedural_definition_record",
    ProceduralStateList => "procedural_state_list",
    ProceduralStateInspect => "procedural_state_inspect",
    ProceduralActivationRequestRecord => "procedural_activation_request_record",
    ProceduralActivationRequestList => "procedural_activation_request_list",
    ProceduralActivationRequestInspect => "procedural_activation_request_inspect",
    ProceduralActivationDecisionRecord => "procedural_activation_decision_record",
    ProceduralActivationDecisionList => "procedural_activation_decision_list",
    ProceduralActivationDecisionInspect => "procedural_activation_decision_inspect",
    ScheduleCreate => "schedule_create",
    ScheduleList => "schedule_list",
    ScheduleInspect => "schedule_inspect",
    ScheduleCancel => "schedule_cancel",
    ScheduleFireDue => "schedule_fire_due",
    ToolSourceList => "tool_source_list",
    ToolSourceInspect => "tool_source_inspect",
    SubagentLaunch => "subagent_launch",
    SubagentStatus => "subagent_status",
    SubagentResult => "subagent_result",
    SubagentCancel => "subagent_cancel",
    SubagentTaskList => "subagent_task_list",
    SubagentTaskInspect => "subagent_task_inspect",
    WorkerPackageList => "worker_package_list",
    WorkerPackageInspect => "worker_package_inspect",
    ModuleList => "module_list",
    ModuleInspect => "module_inspect",
    ModuleProposalRecord => "module_proposal_record",
    ModuleProposalList => "module_proposal_list",
    ModuleProposalInspect => "module_proposal_inspect",
    ModuleValidationRecord => "module_validation_record",
    ModuleValidationList => "module_validation_list",
    ModuleValidationInspect => "module_validation_inspect",
    ModuleInstallRequestRecord => "module_install_request_record",
    ModuleInstallRequestList => "module_install_request_list",
    ModuleInstallRequestInspect => "module_install_request_inspect",
    ModuleInstallDecisionRecord => "module_install_decision_record",
    ModuleInstallDecisionList => "module_install_decision_list",
    ModuleInstallDecisionInspect => "module_install_decision_inspect",
    ModuleDependencyRequestRecord => "module_dependency_request_record",
    ModuleDependencyRequestList => "module_dependency_request_list",
    ModuleDependencyRequestInspect => "module_dependency_request_inspect",
    ModuleDependencyDecisionRecord => "module_dependency_decision_record",
    ModuleDependencyDecisionList => "module_dependency_decision_list",
    ModuleDependencyDecisionInspect => "module_dependency_decision_inspect",
    ModuleDependencyPolicyActivate => "module_dependency_policy_activate",
    ModuleDependencyPolicyList => "module_dependency_policy_list",
    ModuleDependencyPolicyInspect => "module_dependency_policy_inspect",
    CapabilityBindingRequestRecord => "capability_binding_request_record",
    CapabilityBindingRequestList => "capability_binding_request_list",
    CapabilityBindingRequestInspect => "capability_binding_request_inspect",
    CapabilityBindingDecisionRecord => "capability_binding_decision_record",
    CapabilityBindingDecisionList => "capability_binding_decision_list",
    CapabilityBindingDecisionInspect => "capability_binding_decision_inspect",
    CapabilityBindingPolicyActivate => "capability_binding_policy_activate",
    CapabilityBindingPolicyList => "capability_binding_policy_list",
    CapabilityBindingPolicyInspect => "capability_binding_policy_inspect",
    CapabilityBindingCockpitOverview => "capability_binding_cockpit_overview",
    CapabilityShadowTrialRequestRecord => "capability_shadow_trial_request_record",
    CapabilityShadowTrialDecisionRecord => "capability_shadow_trial_decision_record",
    CapabilityShadowTrialRunRecord => "capability_shadow_trial_run_record",
    CapabilityShadowTrialEvidenceInspect => "capability_shadow_trial_evidence_inspect",
    CapabilityReplacementCandidateRecord => "capability_replacement_candidate_record",
    CapabilityReplacementCandidateList => "capability_replacement_candidate_list",
    CapabilityReplacementCandidateInspect => "capability_replacement_candidate_inspect",
    CapabilityRouteBindingRecord => "capability_route_binding_record",
    CapabilityRouteBindingList => "capability_route_binding_list",
    CapabilityRouteBindingInspect => "capability_route_binding_inspect",
    CapabilityRouteActivate => "capability_route_activate",
    CapabilityRouteDisable => "capability_route_disable",
    CapabilityRouteRollback => "capability_route_rollback",
    CapabilityRouteEventList => "capability_route_event_list",
    CapabilityRouteEventInspect => "capability_route_event_inspect",
    ModuleLifecycleRequest => "module_lifecycle_request",
    ModuleLifecycleDecision => "module_lifecycle_decision",
    ModuleLifecycleList => "module_lifecycle_list",
    ModuleLifecycleInspect => "module_lifecycle_inspect",
    ModuleProgramExecutionStart => "module_program_execution_start",
    ModuleProgramExecutionStatus => "module_program_execution_status",
    ModuleProgramExecutionCancel => "module_program_execution_cancel",
    ModuleProgramExecutionCleanup => "module_program_execution_cleanup",
    ModuleRuntimeRequest => "module_runtime_request",
    ModuleRuntimeList => "module_runtime_list",
    ModuleRuntimeInspect => "module_runtime_inspect",
    ModuleRuntimeCancel => "module_runtime_cancel",
    WebFetch => "web_fetch",
    WebRobotsCheck => "web_robots_check",
    WebSourceList => "web_source_list",
    WebSourceInspect => "web_source_inspect",
    WebSourceArchive => "web_source_archive",
    WebResearchRequestRecord => "web_research_request_record",
    WebResearchRequestList => "web_research_request_list",
    WebResearchRequestInspect => "web_research_request_inspect",
    WebResearchReviewRecord => "web_research_review_record",
    WebResearchReviewList => "web_research_review_list",
    WebResearchReviewInspect => "web_research_review_inspect",
    WebResearchSourceRecord => "web_research_source_record",
    WebResearchSourceList => "web_research_source_list",
    WebResearchSourceInspect => "web_research_source_inspect",
}

pub(crate) const fn supported_operation_names() -> &'static [&'static str] {
    OperationId::ALL_NAMES
}

pub(crate) fn is_supported_operation(operation: &str) -> bool {
    OperationId::parse(operation).is_some()
}

pub(crate) use authority::{
    AuthorityPolicy, ConditionalAuthority, ResourceKindPolicy, SelectorAddition,
    WorkerPackageKindSource,
};
pub(super) use policy::InvocationScope;
pub(crate) use policy::OperationEffect;

/// Exact request schema for one execute operation.
#[derive(Clone, Debug)]
pub(super) struct OperationSchemaContract {
    /// Closed top-level payload schema consumed by catalog and runtime.
    pub(super) input_schema: Value,
    /// Canonical provider output profile and semantic evidence requirements.
    pub(super) output_contract: output::OutputContract,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OperationBindingMetadata {
    pub operation: &'static str,
    pub family: &'static str,
    pub current_owner: &'static str,
    pub ownership_class: &'static str,
    pub replacement_target: &'static str,
}

pub(crate) fn binding_metadata(operation: &str) -> Option<OperationBindingMetadata> {
    let operation_id = OperationId::parse(operation)?;
    let metadata = metadata::metadata(operation_id);
    Some(OperationBindingMetadata {
        operation: operation_id.as_str(),
        family: metadata.family,
        current_owner: metadata.current_owner,
        ownership_class: metadata.ownership_class,
        replacement_target: metadata.replacement_target,
    })
}

pub(super) fn invocation_scope(operation: &str) -> InvocationScope {
    OperationId::parse(operation)
        .map(policy::invocation_scope)
        .unwrap_or(InvocationScope::None)
}

pub(crate) fn effect(operation: &str) -> Option<OperationEffect> {
    OperationId::parse(operation).map(policy::effect)
}

pub(crate) fn risk(operation: &str) -> Option<&'static str> {
    OperationId::parse(operation).map(|operation| policy::risk(operation).as_str())
}

pub(crate) fn authority_policy(operation: &str) -> Option<AuthorityPolicy> {
    let operation = OperationId::parse(operation)?;
    authority::policy(operation.as_str())
}

fn input_schema(operation: OperationId) -> Option<Value> {
    let operation = operation.as_str();
    capability_binding::input_schema(operation)
        .or_else(|| governance::input_schema(operation))
        .or_else(|| records::input_schema(operation))
        .or_else(|| direct::input_schema(operation))
}

/// Return the exact request contract for one supported operation.
///
/// Binding, scope, effect, risk, and authority remain typed sibling policies in
/// this owner module and have lightweight accessors so runtime validation does
/// not rebuild unrelated JSON schemas.
pub(super) fn contract(operation: &str) -> Option<OperationSchemaContract> {
    let operation_id = OperationId::parse(operation)?;
    let input_schema = input_schema(operation_id)?;
    Some(OperationSchemaContract {
        input_schema,
        output_contract: output::contract(operation_id),
    })
}

/// Return the exact schema for catalog projection or runtime validation.
pub(super) fn exact_input_schema(operation: &str) -> Option<Value> {
    input_schema(OperationId::parse(operation)?)
}

pub(super) fn exact_output_schema(operation: &str) -> Option<Value> {
    let contract = contract(operation)?;
    Some(output::schema_for_contract(
        operation,
        contract.output_contract,
    ))
}

/// Build the engine-facing host union mechanically from the exact operation
/// contracts. The union is intentionally permissive only across operations;
/// [`validate_payload`] still applies the selected operation's closed schema
/// before authority derivation or dispatch.
pub(crate) fn host_request_schema() -> Value {
    let mut field_variants = BTreeMap::<String, Vec<Value>>::new();
    for operation in supported_operation_names() {
        let contract = contract(operation)
            .unwrap_or_else(|| panic!("{operation} must have one canonical contract"));
        let properties = contract.input_schema["properties"]
            .as_object()
            .expect("canonical operation schema properties");
        for (field, field_schema) in properties {
            if field == "operation" {
                continue;
            }
            let variants = field_variants.entry(field.clone()).or_default();
            if !variants.contains(field_schema) {
                variants.push(field_schema.clone());
            }
        }
    }

    let mut properties = Map::new();
    properties.insert(
        "operation".to_owned(),
        json!({
            "type": "string",
            "enum": supported_operation_names(),
            "description": format!(
                "One exact capability::execute operation. Never guess an operation name: use catalog_search, then catalog_inspect. Supported operations: {}.",
                operation_list_text()
            )
        }),
    );
    for (field, mut variants) in field_variants {
        let schema = if variants.len() == 1 {
            variants.pop().expect("one schema variant")
        } else {
            json!({
                "anyOf": variants,
                "description": "Operation-specific field; catalog_inspect returns the exact selected-operation contract."
            })
        };
        properties.insert(field, schema);
    }

    json!({
        "type": "object",
        "required": ["operation"],
        "properties": properties,
        "additionalProperties": false,
        "schemaCompleteness": "mechanical_union_of_exact_operation_contracts"
    })
}

pub(crate) fn operation_list_text() -> String {
    match supported_operation_names() {
        [] => String::new(),
        [only] => (*only).to_owned(),
        names => {
            let (last, rest) = names.split_last().expect("non-empty operation names");
            format!("{}, or {}", rest.join(", "), last)
        }
    }
}

pub(crate) fn required_payload_fields(operation: &str) -> Option<Vec<String>> {
    contract(operation).map(|contract| {
        contract.input_schema["required"]
            .as_array()
            .expect("canonical operation schema required fields")
            .iter()
            .map(|field| {
                field
                    .as_str()
                    .expect("canonical required field is a string")
                    .to_owned()
            })
            .collect()
    })
}

/// Validate membership and the operation's closed payload shape.
pub(crate) fn validate_payload(payload: &Value) -> Result<(), CapabilityError> {
    let operation = payload
        .get("operation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|operation| !operation.is_empty())
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "Missing required parameter: operation".to_owned(),
        })?;
    if !is_supported_operation(operation) {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Unsupported capability::execute operation '{operation}'. Use catalog_search to discover an exact supported operation name."
            ),
        });
    }
    let contract = contract(operation)
        .expect("supported capability operation must have one canonical structural contract");
    let function_id =
        FunctionId::new("capability::execute").expect("canonical capability function id is valid");
    validate_engine_schema_payload(
        &function_id,
        "operation request",
        &contract.input_schema,
        payload,
    )
    .map_err(|error| CapabilityError::InvalidParams {
        message: format!("Invalid {operation} payload: {error}"),
    })
}

fn closed_schema(operation: &str, required: &[&str], fields: Vec<(&str, Value)>) -> Value {
    let mut properties = Map::new();
    properties.insert(
        "operation".to_owned(),
        json!({
            "type": "string",
            "const": operation,
            "description": "Exact capability::execute operation selector."
        }),
    );
    for (field, schema) in fields {
        properties.insert(field.to_owned(), schema);
    }
    json!({
        "type": "object",
        "required": required,
        "properties": properties,
        "additionalProperties": false,
        "payloadPlacement": "top_level_capability_execute_payload",
        "schemaCompleteness": "exact_structural_contract"
    })
}

fn string_schema(description: &str) -> Value {
    json!({"type": "string", "description": description})
}

fn bounded_integer_schema(minimum: u64, maximum: u64, description: &str) -> Value {
    json!({
        "type": "integer",
        "minimum": minimum,
        "maximum": maximum,
        "description": description
    })
}

fn network_policy_none_schema() -> Value {
    json!({
        "type": "string",
        "const": "none",
        "description": "Optional explicit no-network policy proof; only none is accepted."
    })
}

fn idempotency_schema() -> Value {
    string_schema(
        "Stable bounded caller idempotency key for this durable write. This value is provider-visible in the tool-call payload because the caller supplies it, but provider-safe result, status, log, and trace projections redact it.",
    )
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn every_contract_is_a_single_source_closed_schema() {
        let contracts = supported_operation_names()
            .iter()
            .filter_map(|operation| contract(operation).map(|contract| (*operation, contract)))
            .collect::<Vec<_>>();
        assert_eq!(contracts.len(), supported_operation_names().len());
        for (operation, contract) in contracts {
            assert_eq!(contract.input_schema["additionalProperties"], false);
            assert_eq!(
                contract.input_schema["schemaCompleteness"],
                "exact_structural_contract"
            );
            assert_eq!(
                contract.input_schema["properties"]["operation"]["const"],
                operation
            );
            validate_engine_schema_definition(
                &FunctionId::new("capability::execute").expect("function id"),
                "operation request",
                &contract.input_schema,
            )
            .expect("canonical schema uses only enforced structural keywords");
        }
    }

    #[test]
    fn every_supported_operation_has_exactly_one_contract_family_owner() {
        for operation in supported_operation_names() {
            let owners = [
                capability_binding::input_schema(operation).is_some(),
                governance::input_schema(operation).is_some(),
                records::input_schema(operation).is_some(),
                direct::input_schema(operation).is_some(),
            ]
            .into_iter()
            .filter(|owned| *owned)
            .count();
            assert_eq!(owners, 1, "{operation} has {owners} contract family owners");
        }
    }

    #[test]
    fn catalog_and_runtime_schemas_are_identical() {
        for operation in supported_operation_names() {
            let Some(contract) = contract(operation) else {
                continue;
            };
            assert_eq!(
                super::super::catalog::execute_operation_input_schema(operation),
                contract.input_schema,
                "catalog and pre-authority runtime schema drifted for {operation}"
            );
        }
    }

    #[test]
    fn every_non_read_only_operation_requires_caller_idempotency() {
        let missing = supported_operation_names()
            .iter()
            .filter(|operation| {
                effect(operation).is_some_and(|effect| effect != OperationEffect::ReadOnly)
            })
            .filter(|operation| {
                let schema = exact_input_schema(operation).expect("canonical input schema");
                !schema["required"]
                    .as_array()
                    .is_some_and(|required| required.contains(&json!("idempotencyKey")))
            })
            .copied()
            .collect::<Vec<_>>();
        assert!(
            missing.is_empty(),
            "non-read-only operations missing caller idempotency: {missing:?}"
        );
    }

    #[test]
    fn host_union_is_derived_exactly_from_canonical_contract_fields() {
        let host = host_request_schema();
        let host_properties = host["properties"].as_object().expect("host properties");
        assert_eq!(
            host["schemaCompleteness"],
            "mechanical_union_of_exact_operation_contracts"
        );
        assert_eq!(host["additionalProperties"], false);
        assert_eq!(
            host_properties["operation"]["enum"]
                .as_array()
                .expect("operation enum")
                .len(),
            supported_operation_names().len()
        );

        let mut expected_fields = std::collections::BTreeSet::new();
        for operation in supported_operation_names() {
            let schema = exact_input_schema(operation).expect("canonical input schema");
            for field in schema["properties"]
                .as_object()
                .expect("operation properties")
                .keys()
            {
                expected_fields.insert(field.clone());
            }
        }
        assert_eq!(
            host_properties
                .keys()
                .cloned()
                .collect::<std::collections::BTreeSet<_>>(),
            expected_fields
        );
    }

    #[test]
    fn exact_catalog_inspect_contract_requires_kind_and_id() {
        let error = validate_payload(&json!({"operation": "catalog_inspect"}))
            .expect_err("catalog_inspect without kind/id must fail structurally");
        assert!(error.to_string().contains("$.kind"));
        assert!(error.to_string().contains("required field is missing"));
    }

    #[test]
    fn catalog_conformance_contract_requires_explicit_idempotency() {
        let schema = exact_input_schema("catalog_conformance").expect("exact contract");
        assert_eq!(schema["required"], json!(["operation", "idempotencyKey"]));
        let error = validate_payload(&json!({"operation": "catalog_conformance"}))
            .expect_err("durable conformance report requires caller idempotency");
        assert!(error.to_string().contains("$.idempotencyKey"));
    }

    #[test]
    fn exact_contract_rejects_cross_operation_fields() {
        let error = validate_payload(&json!({
            "operation": "catalog_search",
            "text": "git status",
            "command": "ignored by catalog search"
        }))
        .expect_err("exact operation contracts reject unrelated host-union fields");
        assert!(error.to_string().contains("$.command"));
        assert!(
            error
                .to_string()
                .contains("additional property is not allowed")
        );
    }

    #[test]
    fn exact_contract_enforces_const_and_bounds() {
        let inert_policy = validate_payload(&json!({
            "operation": "repository_tree_list",
            "networkPolicy": "none"
        }))
        .expect_err("authority-owned network policy is not a payload parameter");
        assert!(
            inert_policy
                .to_string()
                .contains("additional property is not allowed")
        );

        let excessive_limit = validate_payload(&json!({
            "operation": "capability_binding_cockpit_overview",
            "limit": 201
        }))
        .expect_err("cockpit bound must match its domain contract");
        assert!(excessive_limit.to_string().contains("exceeds maximum 200"));
    }

    #[test]
    fn direct_operation_uses_its_canonical_closed_contract() {
        validate_payload(&json!({
            "operation": "filesystem_read",
            "path": "README.md"
        }))
        .expect("direct operation validates through the canonical contract owner");
    }
}
