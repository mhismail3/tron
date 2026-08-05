//! Provider-neutral surface snapshots and resolved function contracts.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::FunctionDefinition;

/// Provider-neutral evidence for one tool on a resolved model surface.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SurfaceToolSnapshot {
    pub(crate) model_name: String,
    pub(crate) function_id: String,
    pub(crate) function_revision: u64,
    pub(crate) owner_worker: String,
    pub(crate) description: String,
    pub(crate) input_schema: Value,
    pub(crate) input_schema_sha256: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) output_schema: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) output_schema_sha256: Option<String>,
    pub(crate) effect_class: String,
    pub(crate) risk: String,
    pub(crate) exposed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) worker_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) worker_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) primitive_group: Option<String>,
    pub(crate) audience: String,
    pub(crate) access_path: String,
    pub(crate) selection_reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) omission_reason: Option<String>,
}

/// Publication and selection evidence for every enabled direct worker tool,
/// including workers not projected into this particular provider request.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AvailableWorkerToolSnapshot {
    pub(crate) worker_id: String,
    pub(crate) model_name: String,
    pub(crate) function_id: String,
    pub(crate) function_revision: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) worker_version: Option<String>,
    pub(crate) promoted: bool,
    pub(crate) projected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) selection_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) omission_reason: Option<String>,
    pub(crate) ranking_mechanism: String,
    pub(crate) relevance_score: usize,
    pub(crate) completed_runs: u64,
}

/// Exact provider-neutral surface resolved for one agent request boundary.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EngineSurfaceSnapshot {
    pub(crate) catalog_revision: u64,
    pub(crate) surface_hash: String,
    pub(crate) fixed_tool_count: usize,
    pub(crate) ordinary_fixed_tool_count: usize,
    pub(crate) specialist_fixed_tool_count: usize,
    pub(crate) conditional_fixed_tool_count: usize,
    pub(crate) projected_worker_count: usize,
    pub(crate) available_worker_count: usize,
    pub(crate) ranking_mechanism: String,
    pub(crate) tools: Vec<SurfaceToolSnapshot>,
    pub(crate) fixed_tools: Vec<SurfaceToolSnapshot>,
    pub(crate) available_workers: Vec<AvailableWorkerToolSnapshot>,
}

/// One live function selected for provider adaptation.
#[derive(Clone, Debug)]
pub(crate) struct ResolvedToolFunction {
    pub(crate) model_name: String,
    pub(crate) definition: FunctionDefinition,
}

/// Function contracts plus the exact catalog evidence used to select them.
#[derive(Clone, Debug)]
pub(crate) struct ResolvedToolSurface {
    pub(crate) functions: Vec<ResolvedToolFunction>,
    pub(crate) snapshot: EngineSurfaceSnapshot,
}
