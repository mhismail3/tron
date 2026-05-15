//! Typed capability records projected from the live engine catalog.
//!
//! These types are the public shape of Tron's capability substrate. The v1
//! registry is layered over `FunctionDefinition`, but callers should reason in
//! terms of contracts, implementations, bindings, inspections, and execution
//! results rather than domain-specific worker functions.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Agent-facing invocation recipe generated from one live capability.
///
/// This is the compact action-oriented projection used by search results,
/// inspect summaries, and the capability primer. Operator details such as
/// binding provenance, schema digests, and trust metadata remain in inspection
/// and audit records.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentCapabilityRecipe {
    pub(crate) contract_id: String,
    pub(crate) display_name: String,
    pub(crate) use_when: String,
    pub(crate) execute_template: Value,
    pub(crate) required_payload: Vec<String>,
    pub(crate) optional_payload: Vec<String>,
    pub(crate) examples: Vec<Value>,
    pub(crate) direct_execution: String,
    pub(crate) inspect_required: bool,
    pub(crate) approval_behavior: String,
    pub(crate) lifecycle_kind: String,
    pub(crate) result_summary: String,
    pub(crate) aliases: Vec<String>,
}

/// Stable abstract capability interface.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityContractRecord {
    pub(crate) contract_id: String,
    pub(crate) version: u64,
    pub(crate) display_name: String,
    pub(crate) description: String,
    pub(crate) input_schema: Option<Value>,
    pub(crate) output_schema: Option<Value>,
    pub(crate) effect_class: String,
    pub(crate) risk_level: String,
    pub(crate) idempotency_contract: Option<Value>,
    pub(crate) approval_contract: Value,
    pub(crate) lease_contract: Option<Value>,
    pub(crate) compensation_contract: Option<Value>,
    pub(crate) examples: Vec<Value>,
    pub(crate) semantic_tags: Vec<String>,
}

/// Concrete provider of one capability contract.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityImplementationRecord {
    pub(crate) implementation_id: String,
    pub(crate) contract_id: String,
    pub(crate) plugin_id: String,
    pub(crate) worker_id: String,
    pub(crate) function_id: String,
    pub(crate) version: u64,
    pub(crate) health: String,
    pub(crate) visibility: String,
    pub(crate) latency_class: String,
    pub(crate) cost_class: String,
    pub(crate) trust_tier: String,
    pub(crate) authority_requirements: Value,
    pub(crate) runtime_requirements: Value,
    pub(crate) schema_digest: String,
    pub(crate) catalog_revision: u64,
    pub(crate) provenance: Value,
    pub(crate) conformance_state: String,
    pub(crate) signature_status: String,
}

/// Plugin manifest that owns one or more capability implementations.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityPluginManifest {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) version: String,
    pub(crate) publisher: String,
    pub(crate) signature_status: String,
    pub(crate) runtime: String,
    pub(crate) namespace_claims: Vec<String>,
    pub(crate) provided_contracts: Vec<String>,
    pub(crate) provided_implementations: Vec<String>,
    pub(crate) requested_authorities: Vec<String>,
    pub(crate) trust_tier: String,
    pub(crate) visibility_ceiling: String,
    pub(crate) conformance_state: String,
    pub(crate) docs: Value,
    pub(crate) examples: Vec<Value>,
    pub(crate) search_metadata: Value,
}

/// Policy-controlled selection from a contract to an implementation.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityBindingRecord {
    pub(crate) contract_id: String,
    pub(crate) selected_implementation: String,
    pub(crate) selection_policy: String,
    pub(crate) secondary_implementations: Vec<String>,
    pub(crate) enabled: bool,
}

/// Full inspection result returned by `capability::inspect`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityInspectionRecord {
    pub(crate) contract: CapabilityContractRecord,
    pub(crate) implementation: CapabilityImplementationRecord,
    pub(crate) binding: CapabilityBindingRecord,
    pub(crate) binding_decision: CapabilityBindingDecision,
    pub(crate) inspection_handle: CapabilityInspectionHandle,
    pub(crate) recipe: AgentCapabilityRecipe,
    pub(crate) execution_requirements: Value,
    pub(crate) docs: Value,
}

/// Freshness handle returned by inspect and required by elevated-risk execute.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityInspectionHandle {
    pub(crate) handle: String,
    pub(crate) catalog_revision: u64,
    pub(crate) function_revision: u64,
    pub(crate) schema_digest: String,
}

/// One implementation rejected during binding resolution.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityRejectedCandidate {
    pub(crate) implementation_id: String,
    pub(crate) function_id: String,
    pub(crate) reason: String,
}

/// Auditable binding resolution decision.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityBindingDecision {
    pub(crate) decision_id: String,
    pub(crate) contract_id: String,
    pub(crate) selected_implementation: String,
    pub(crate) selected_function_id: String,
    pub(crate) selection_policy: String,
    pub(crate) rejected_candidates: Vec<CapabilityRejectedCandidate>,
    pub(crate) catalog_revision: u64,
    pub(crate) schema_digest: String,
}

/// Local capability index health/status.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityIndexStatus {
    pub(crate) lexical: bool,
    pub(crate) local_vector: bool,
    pub(crate) cloud_embeddings: bool,
    pub(crate) vector_store: String,
    pub(crate) embedding_model: String,
    pub(crate) state: String,
    pub(crate) degraded_reason: Option<String>,
}

/// Search hit returned by `capability::search`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityIndexHit {
    pub(crate) kind: String,
    pub(crate) capability_id: String,
    pub(crate) contract_id: String,
    pub(crate) implementation_id: String,
    pub(crate) plugin_id: String,
    pub(crate) worker_id: String,
    pub(crate) function_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) schema_digest: String,
    pub(crate) trust_tier: String,
    pub(crate) health: String,
    pub(crate) visibility: String,
    pub(crate) effect_class: String,
    pub(crate) risk_level: String,
    pub(crate) lexical_score: f32,
    pub(crate) vector_score: Option<f32>,
    pub(crate) fused_score: f32,
    pub(crate) matched_by: String,
    pub(crate) snippet: String,
    pub(crate) requires_inspect: bool,
    pub(crate) recipe: Option<AgentCapabilityRecipe>,
}

/// Direct execution result metadata recorded by `capability::execute`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityExecutionRecord {
    pub(crate) status: String,
    pub(crate) trace_id: String,
    pub(crate) root_invocation_id: String,
    pub(crate) child_invocations: Vec<String>,
    pub(crate) selected_implementation: String,
    pub(crate) function_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) function_revision: u64,
    pub(crate) output: Value,
    pub(crate) approval_state: Option<Value>,
    pub(crate) plugin_versions: Vec<String>,
    pub(crate) binding_decision: CapabilityBindingDecision,
    pub(crate) schema_digest: String,
    pub(crate) presentation_hints: Option<Value>,
}

/// Durable record for one sandboxed program execution.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityProgramRunRecord {
    pub(crate) program_run_id: String,
    pub(crate) parent_invocation_id: Option<String>,
    pub(crate) root_invocation_id: String,
    pub(crate) binding_decision_id: Option<String>,
    pub(crate) status: String,
    pub(crate) trace_id: String,
    pub(crate) code_hash: String,
    pub(crate) args_hash: String,
    pub(crate) limits: Value,
    pub(crate) allowed_contracts: Vec<String>,
    pub(crate) allowed_implementations: Vec<String>,
    pub(crate) child_invocations: Vec<String>,
    pub(crate) selected_implementations: Vec<String>,
    pub(crate) approval_state: Option<Value>,
    pub(crate) artifacts: Vec<Value>,
    pub(crate) logs: Vec<String>,
    pub(crate) error: Option<Value>,
    pub(crate) compensation_attempts: Vec<Value>,
}

/// Durable record for a capability invocation that paused awaiting an external
/// decision or input.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityPauseRecord {
    pub(crate) pause_id: String,
    pub(crate) invocation_id: String,
    pub(crate) contract_id: String,
    pub(crate) implementation_id: String,
    pub(crate) function_id: String,
    pub(crate) plugin_id: Option<String>,
    pub(crate) worker_id: Option<String>,
    pub(crate) kind: String,
    pub(crate) status: String,
    pub(crate) prompt_payload: Value,
    pub(crate) resume_schema: Option<Value>,
    pub(crate) answer_authority: String,
    pub(crate) expires_at: Option<String>,
    pub(crate) trace_id: Option<String>,
    pub(crate) root_invocation_id: Option<String>,
    pub(crate) binding_decision_id: Option<String>,
}

/// Durable record for a capability invocation that continues after returning a
/// handle, such as a background process or spawned subagent.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityRunRecord {
    pub(crate) run_id: String,
    pub(crate) invocation_id: String,
    pub(crate) contract_id: String,
    pub(crate) implementation_id: String,
    pub(crate) function_id: String,
    pub(crate) plugin_id: Option<String>,
    pub(crate) worker_id: Option<String>,
    pub(crate) status: String,
    pub(crate) stream_topic: Option<String>,
    pub(crate) child_invocations: Vec<String>,
    pub(crate) trace_id: Option<String>,
    pub(crate) root_invocation_id: Option<String>,
    pub(crate) binding_decision_id: Option<String>,
    pub(crate) details: Value,
}
