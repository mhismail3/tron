//! Aggregated canonical capability catalog.
//!
//! Domain workers own their full canonical function contracts in local
//! `contract.rs` modules. This file only collects those records, validates
//! uniqueness, and exposes discovery, diagnostics, and guardrail views.

use std::collections::BTreeSet;

use serde_json::json;

pub(crate) use super::contract::function_definition_for_capability;
use crate::engine::{
    ActorId, AuthorityGrantId, DeliveryMode, EffectClass, EngineError, FunctionId,
    IdempotencyContract, ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
    TriggerTypeDefinition, TriggerTypeId, VisibilityScope, WorkerId,
};
#[cfg(test)]
use crate::engine::{WorkerDefinition, WorkerKind};

/// System actor used for server-owned capability registration.
pub(crate) const SYSTEM_OWNER_ACTOR: &str = "system";
/// Authority grant carried by first-party engine transport and domain workers.
pub(crate) const SYSTEM_AUTHORITY_GRANT: &str = "engine-transport";

/// Idempotency source for a public engine transport method.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportIdempotencyMode {
    /// Read/delegated transport method; no transport-level key is required.
    NotRequired,
    /// Engine-native transport mode: payload contains an explicit key.
    ExplicitRequired,
}

impl TransportIdempotencyMode {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::NotRequired => "not_required",
            Self::ExplicitRequired => "explicit_required",
        }
    }
}

/// Canonical server capability contract.
#[derive(Clone, Debug, PartialEq)]
pub struct CapabilitySpec {
    /// Stable canonical operation key used by the domain dispatcher.
    pub operation_key: String,
    /// Stable engine function id.
    pub function_id: FunctionId,
    /// Owner worker id.
    pub owner_worker: WorkerId,
    /// Domain worker that owns the capability behavior.
    pub domain_worker: WorkerId,
    /// Effect class.
    pub effect_class: EffectClass,
    /// Risk level.
    pub risk_level: RiskLevel,
    /// Engine visibility.
    pub visibility: VisibilityScope,
    /// Optional authority scope required to invoke.
    pub authority_scope: Option<&'static str>,
    /// Public transport idempotency mode when this function is exposed through
    /// an engine protocol message.
    pub idempotency_mode: TransportIdempotencyMode,
    /// Domain module/group provenance.
    pub domain_module: &'static str,
    /// Strict request schema owned by the domain contract.
    pub request_schema: Option<serde_json::Value>,
    /// Strict response schema owned by the domain contract.
    pub response_schema: Option<serde_json::Value>,
    /// Idempotency contract owned by the domain contract for mutating functions.
    pub idempotency: Option<IdempotencyContract>,
    /// Engine-owned resource lease contract required before handler execution.
    pub resource_lease: Option<ResourceLeaseRequirement>,
    /// Durable compensation/audit contract.
    pub compensation: Option<crate::engine::CompensationContract>,
    /// Explicit approval metadata for agent-visible risk.
    pub approval_required: bool,
    /// High-risk contract metadata exposed through discovery.
    pub high_risk_contract: Option<serde_json::Value>,
    /// Stream topics emitted by this capability.
    pub stream_topics: Vec<&'static str>,
    /// Discovery description supplied by the owning domain.
    pub description: Option<&'static str>,
    /// Discovery/search tags supplied by the owning domain.
    pub tags: Vec<&'static str>,
    /// Compact examples supplied by the owning domain.
    pub examples: Vec<serde_json::Value>,
}

/// Agent-facing canonical function contract.
#[derive(Clone, Debug, PartialEq)]
pub struct CanonicalCapabilitySpec {
    /// Stable canonical function id shown to agents and engine-native clients.
    pub function_id: FunctionId,
    /// Worker that owns the function implementation.
    pub owner_worker: WorkerId,
    /// Engine visibility for the function.
    pub visibility: VisibilityScope,
    /// Effect class enforced by the engine.
    pub effect_class: EffectClass,
    /// Risk level used by approval and guardrail policy.
    pub risk_level: RiskLevel,
    /// Domain authority scope required for direct invocation.
    pub authority_scope: Option<&'static str>,
    /// Canonical operation key routed to the domain implementation.
    pub operation_key: String,
}

/// Domain worker ownership view used by guard tests.
#[cfg(test)]
#[derive(Clone, Debug, PartialEq)]
pub struct DomainWorkerModule {
    /// Worker definition registered with the engine.
    pub worker: WorkerDefinition,
    /// Claimed namespace owned by the worker.
    pub namespace: String,
    /// Canonical functions owned by the worker.
    pub functions: Vec<CanonicalCapabilitySpec>,
}

fn canonical_capability_contracts() -> EngineResult<Vec<CapabilitySpec>> {
    let mut specs = super::agent::contract::capabilities()?;
    specs.extend(super::auth::contract::capabilities()?);
    specs.extend(super::blob::contract::capabilities()?);
    specs.extend(super::browser::contract::capabilities()?);
    specs.extend(super::capability::contract::capabilities()?);
    specs.extend(super::codex_app::contract::capabilities()?);
    specs.extend(super::context::contract::capabilities()?);
    specs.extend(super::cron::contract::capabilities()?);
    specs.extend(super::device::contract::capabilities()?);
    specs.extend(super::display::contract::capabilities()?);
    specs.extend(super::events::contract::capabilities()?);
    specs.extend(super::filesystem::contract::capabilities()?);
    specs.extend(super::git::contract::capabilities()?);
    specs.extend(super::import::contract::capabilities()?);
    specs.extend(super::job::contract::capabilities()?);
    specs.extend(super::logs::contract::capabilities()?);
    specs.extend(super::mcp::contract::capabilities()?);
    specs.extend(super::memory::contract::capabilities()?);
    specs.extend(super::message::contract::capabilities()?);
    specs.extend(super::model::contract::capabilities()?);
    specs.extend(super::notifications::contract::capabilities()?);
    specs.extend(super::plan::contract::capabilities()?);
    specs.extend(super::process::contract::capabilities()?);
    specs.extend(super::program::contract::capabilities()?);
    specs.extend(super::prompt_library::contract::capabilities()?);
    specs.extend(super::repo::contract::capabilities()?);
    specs.extend(super::sandbox::contract::capabilities()?);
    specs.extend(super::session::contract::capabilities()?);
    specs.extend(super::settings::contract::capabilities()?);
    specs.extend(super::skills::contract::capabilities()?);
    specs.extend(super::system::contract::capabilities()?);
    specs.extend(super::transcription::contract::capabilities()?);
    specs.extend(super::tree::contract::capabilities()?);
    specs.extend(super::voice_notes::contract::capabilities()?);
    specs.extend(super::web::contract::capabilities()?);
    specs.extend(super::worktree::contract::capabilities()?);
    Ok(specs)
}

/// Build canonical capability specs from the complete domain capability catalog.
pub fn canonical_capability_specs() -> EngineResult<Vec<CanonicalCapabilitySpec>> {
    validate_seed_uniqueness()?;
    canonical_capability_contracts()?
        .into_iter()
        .map(|spec| {
            Ok(CanonicalCapabilitySpec {
                function_id: spec.function_id,
                owner_worker: spec.owner_worker,
                visibility: spec.visibility,
                effect_class: spec.effect_class,
                risk_level: spec.risk_level,
                authority_scope: spec.authority_scope,
                operation_key: spec.operation_key,
            })
        })
        .collect()
}

/// Group canonical functions by their owning domain worker.
#[cfg(test)]
pub(crate) fn domain_worker_modules() -> EngineResult<Vec<DomainWorkerModule>> {
    let specs = canonical_capability_specs()?;
    let mut worker_ids = BTreeSet::new();
    for spec in &specs {
        worker_ids.insert(spec.owner_worker.as_str().to_owned());
    }
    worker_ids
        .into_iter()
        .map(|worker| {
            let definition = WorkerDefinition::new(
                worker_id(&worker)?,
                WorkerKind::InProcess,
                actor_id(SYSTEM_OWNER_ACTOR)?,
                grant_id(SYSTEM_AUTHORITY_GRANT)?,
            )
            .with_namespace_claim(worker.clone());
            let functions = specs
                .iter()
                .filter(|spec| spec.owner_worker.as_str() == worker)
                .cloned()
                .collect();
            Ok(DomainWorkerModule {
                worker: definition,
                namespace: worker,
                functions,
            })
        })
        .collect()
}

fn validate_seed_uniqueness() -> EngineResult<()> {
    let mut seen = BTreeSet::new();
    for spec in canonical_capability_contracts()? {
        if !seen.insert(spec.function_id.as_str().to_owned()) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate canonical capability spec for {}",
                spec.function_id.as_str()
            )));
        }
    }
    Ok(())
}

pub(crate) fn cron_schedule_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("cron_schedule")?,
        worker_id("cron")?,
        "Cron schedule projection into an engine trigger",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    definition.config_schema = Some(json!({
        "type": "object",
        "required": ["jobId", "jobName", "enabled", "payloadKind"],
        "additionalProperties": true,
        "properties": {
            "jobId": {"type": "string"},
            "jobName": {"type": "string"},
            "enabled": {"type": "boolean"},
            "payloadKind": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    }));
    Ok(definition)
}

pub(crate) fn worker_id(value: &str) -> EngineResult<WorkerId> {
    WorkerId::new(value)
}

pub(crate) fn actor_id(value: &str) -> EngineResult<ActorId> {
    ActorId::new(value)
}

pub(crate) fn grant_id(value: &str) -> EngineResult<AuthorityGrantId> {
    AuthorityGrantId::new(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_worker_modules_own_all_canonical_functions_once() {
        let specs = canonical_capability_specs().expect("canonical specs");
        let modules = domain_worker_modules().expect("domain modules");
        let module_worker_ids: std::collections::BTreeSet<_> = modules
            .iter()
            .map(|module| module.worker.id.clone())
            .collect();
        let domain_owned_specs = specs
            .iter()
            .filter(|spec| module_worker_ids.contains(&spec.owner_worker))
            .count();
        let owned: usize = modules.iter().map(|module| module.functions.len()).sum();
        assert_eq!(
            owned, domain_owned_specs,
            "domain worker modules must account for every server-owned canonical function"
        );
        for module in modules {
            assert!(
                module.worker.namespace_claims.contains(&module.namespace),
                "worker {} must claim namespace {}",
                module.worker.id.as_str(),
                module.namespace
            );
            for function in module.functions {
                assert_eq!(
                    function.owner_worker,
                    module.worker.id,
                    "function {} must be owned by its domain worker",
                    function.function_id.as_str()
                );
            }
        }
    }

    #[test]
    fn domain_contract_stream_topics_are_domain_owned() {
        let specs = canonical_capability_contracts().expect("canonical specs");
        let engine_owned_topics = [
            "catalog.changes",
            "queue.lifecycle",
            "resource.leases",
            "approval.pending",
            "approval.resolved",
            "compensation.records",
        ];

        for spec in specs {
            for topic in &spec.stream_topics {
                assert!(
                    !engine_owned_topics.contains(topic),
                    "{} must not claim engine-owned stream topic {topic}",
                    spec.function_id.as_str()
                );
                assert!(
                    topic.contains('.'),
                    "{} stream topic {topic} must use domain-scoped dotted form",
                    spec.function_id.as_str()
                );
            }

            if let Some(contract) = &spec.high_risk_contract {
                let metadata_topics = contract
                    .get("streamTopics")
                    .and_then(serde_json::Value::as_array)
                    .expect("high-risk contract streamTopics must be an array");
                let metadata_topics = metadata_topics
                    .iter()
                    .map(|topic| {
                        topic
                            .as_str()
                            .expect("high-risk contract streamTopics must contain strings")
                    })
                    .collect::<Vec<_>>();
                assert_eq!(
                    metadata_topics,
                    spec.stream_topics,
                    "{} high-risk metadata must mirror its domain-owned stream topics",
                    spec.function_id.as_str()
                );
            }
        }
    }
}
