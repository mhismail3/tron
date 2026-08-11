//! Fixed-audience filtering, stable ordering, digests, and retrieval projection.

use std::collections::BTreeSet;

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::engine::{DirectWorkerToolContract, FunctionDefinition, ModelToolAudience};

use super::snapshots::{EngineSurfaceSnapshot, ResolvedToolFunction, SurfaceToolSnapshot};

/// Inspect the canonical fixed model-tool inventory independently of whether
/// the current provider request projects those tools.
pub(crate) fn fixed_tool_inventory(
    resolved_surface: &EngineSurfaceSnapshot,
) -> Vec<SurfaceToolSnapshot> {
    resolved_surface.fixed_tools.clone()
}

pub(super) fn fixed_tool_snapshots(
    functions: &[FunctionDefinition],
    projected_tools: &[SurfaceToolSnapshot],
) -> Result<Vec<SurfaceToolSnapshot>, String> {
    let projected = projected_tools
        .iter()
        .map(|tool| (tool.function_id.as_str(), tool.model_name.as_str()))
        .collect::<BTreeSet<_>>();
    let mut fixed = functions
        .iter()
        .filter(|function| {
            function.request_schema.is_some()
                && function
                    .model_tool
                    .as_ref()
                    .is_some_and(|tool| tool.worker.is_none())
        })
        .map(|function| {
            let model_tool = function.model_tool.as_ref().expect("filtered model tool");
            let input_schema = function
                .request_schema
                .clone()
                .unwrap_or_else(|| serde_json::json!({"type":"object"}));
            let output_schema = function.response_schema.clone();
            let exposed = projected.contains(&(function.id.as_str(), model_tool.name.as_str()));
            Ok(SurfaceToolSnapshot {
                model_name: model_tool.name.clone(),
                function_id: function.id.as_str().to_owned(),
                function_revision: function.revision.0,
                owner_worker: function.owner_worker.as_str().to_owned(),
                description: function.description.clone(),
                input_schema_sha256: schema_digest(&input_schema)?,
                output_schema_sha256: output_schema.as_ref().map(schema_digest).transpose()?,
                input_schema,
                output_schema,
                effect_class: function.effect_class.as_str().to_owned(),
                risk: function.risk_level.as_str().to_owned(),
                delegation_policy: function.delegation_policy.as_str().to_owned(),
                workspace_effect: function.workspace_effect.as_str().to_owned(),
                exposed,
                worker_id: None,
                worker_version: None,
                primitive_group: model_tool.group.clone(),
                audience: model_tool.audience.as_str().to_owned(),
                access_path: model_tool_access_path(function).to_owned(),
                selection_reason: if exposed {
                    match &model_tool.audience {
                        ModelToolAudience::Ordinary => "ordinary",
                        ModelToolAudience::Specialist => "specialist_allowlist",
                        ModelToolAudience::Conditional { .. } => "conditional_request",
                    }
                } else {
                    "not_projected"
                }
                .to_owned(),
                omission_reason: (!exposed)
                    .then(|| match &model_tool.audience {
                        ModelToolAudience::Ordinary => "not_in_specialist_allowlist",
                        ModelToolAudience::Specialist => "specialist_only",
                        ModelToolAudience::Conditional { .. } => "condition_not_satisfied",
                    })
                    .map(str::to_owned),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    fixed.sort_by_key(|tool| {
        functions
            .iter()
            .find(|function| function.id.as_str() == tool.function_id)
            .and_then(|function| function.model_tool.as_ref())
            .and_then(|model_tool| model_tool.order)
            .unwrap_or(u16::MAX)
    });
    Ok(fixed)
}

pub(super) fn functions_order(function_id: &str, resolved: &[ResolvedToolFunction]) -> usize {
    resolved
        .iter()
        .find(|resolved| resolved.definition.id.as_str() == function_id)
        .and_then(|resolved| resolved.definition.model_tool.as_ref())
        .and_then(|tool| tool.order)
        .map_or(usize::MAX, usize::from)
}

pub(super) fn surface_hash(tools: &[SurfaceToolSnapshot]) -> Result<String, String> {
    let bytes = serde_json::to_vec(tools).map_err(|error| error.to_string())?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

pub(super) fn schema_digest(schema: &Value) -> Result<String, String> {
    serde_json::to_vec(schema)
        .map(|bytes| hex::encode(Sha256::digest(bytes)))
        .map_err(|error| format!("serialize tool schema for inspection digest: {error}"))
}

pub(super) fn retrieval_document(
    function: &FunctionDefinition,
    worker: &DirectWorkerToolContract,
    evidence: Option<&Value>,
) -> super::super::retrieval::WorkerRetrievalDocument {
    super::super::retrieval::WorkerRetrievalDocument {
        key: function.id.as_str().to_owned(),
        worker_id: worker.worker_id.clone(),
        name: worker.worker_name.clone(),
        description: worker.worker_description.clone(),
        intents: worker.intents.clone(),
        examples: worker.examples.clone(),
        completed_runs: evidence
            .and_then(|evidence| evidence.pointer("/successEvidence/completedRuns"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        updated_at: evidence
            .and_then(|evidence| evidence.get("updatedAt"))
            .and_then(Value::as_str)
            .unwrap_or(&worker.updated_at)
            .to_owned(),
    }
}

pub(super) fn is_provider_primitive(function: &FunctionDefinition) -> bool {
    function.model_tool.is_some()
}

pub(super) fn model_tool_exposure_allows(
    function: &FunctionDefinition,
    latest_user_query: Option<&str>,
    trusted_worker_allowlist: bool,
) -> bool {
    let Some(model_tool) = function.model_tool.as_ref() else {
        return false;
    };
    if trusted_worker_allowlist {
        return true;
    }
    match &model_tool.audience {
        ModelToolAudience::Ordinary => true,
        ModelToolAudience::Specialist => false,
        ModelToolAudience::Conditional {
            latest_user_intent_phrases,
        } => {
            let query = normalized_intent_text(latest_user_query.unwrap_or_default());
            !query.is_empty()
                && latest_user_intent_phrases.iter().any(|phrase| {
                    let phrase = normalized_intent_text(phrase);
                    !phrase.is_empty() && query.contains(&phrase)
                })
        }
    }
}

pub(super) fn model_tool_access_path(function: &FunctionDefinition) -> &'static str {
    let Some(model_tool) = function.model_tool.as_ref() else {
        return "unavailable";
    };
    if model_tool.worker.is_some() {
        return "dynamic_worker";
    }
    match &model_tool.audience {
        ModelToolAudience::Ordinary => "ordinary",
        ModelToolAudience::Specialist => "specialist_worker_or_dashboard",
        ModelToolAudience::Conditional { .. } => "conditional_request",
    }
}

pub(super) fn normalized_intent_text(value: &str) -> String {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>()
        .join(" ")
}

pub(super) fn model_tool_name(function: &FunctionDefinition) -> Option<String> {
    function.model_tool.as_ref().map(|tool| tool.name.clone())
}

pub(super) fn direct_worker_contract(
    function: &FunctionDefinition,
) -> Option<&DirectWorkerToolContract> {
    function.model_tool.as_ref()?.worker.as_ref()
}
