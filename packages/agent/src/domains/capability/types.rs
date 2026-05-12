//! Typed capability records projected from the live engine catalog.
//!
//! These types are the public shape of Tron's capability substrate. The v1
//! registry is layered over `FunctionDefinition`, but callers should reason in
//! terms of contracts, implementations, bindings, inspections, and execution
//! results rather than domain-specific worker functions.

use serde::{Deserialize, Serialize};
use serde_json::Value;

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
    pub(crate) execution_requirements: Value,
    pub(crate) docs: Value,
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
}
