//! Shared domain capability registration contracts.
//!
//! Domain workers own their full canonical function contracts in domain-local
//! modules. This file owns only the common contract shape and stable
//! registration identities; production startup owns complete enumeration and
//! validation in `registration::domain_worker_modules`.

pub(crate) use super::contract::function_definition_for_capability;
use crate::engine::{
    ActorId, AuthorityGrantId, DurableOutputContract, EffectClass, FunctionId, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel, VisibilityScope, WorkerId,
};

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
    /// Durable output contract enforced after handler execution.
    pub output_contract: DurableOutputContract,
    /// Stream topics emitted by this capability.
    pub stream_topics: Vec<&'static str>,
    /// Discovery description supplied by the owning domain.
    pub description: Option<&'static str>,
    /// Discovery/search tags supplied by the owning domain.
    pub tags: Vec<&'static str>,
    /// Compact examples supplied by the owning domain.
    pub examples: Vec<serde_json::Value>,
    /// Capability lifecycle metadata supplied by the owning domain.
    pub lifecycle: Option<serde_json::Value>,
    /// Generated UI presentation hints supplied by the owning domain.
    pub presentation_hints: Option<serde_json::Value>,
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
