//! Shared domain capability registration contracts.
//!
//! Domain workers own their full canonical function contracts in domain-local
//! modules. This file owns only the common contract shape and stable
//! registration identities; production startup owns complete enumeration and
//! validation in `registration::domain_worker_modules`.

pub(crate) use super::contract::function_definition_for_capability;
use crate::engine::{
    ActorId, EffectClass, FunctionId, IdempotencyContract, Result as EngineResult, RiskLevel,
    VisibilityScope, WorkerId,
};

/// System actor used for server-owned capability registration.
pub(crate) const SYSTEM_OWNER_ACTOR: &str = "system";

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
    /// Stream topics emitted by this capability.
    pub stream_topics: Vec<&'static str>,
    /// Discovery description supplied by the owning domain.
    pub description: Option<&'static str>,
    /// Discovery/search tags supplied by the owning domain.
    pub tags: Vec<&'static str>,
    /// Generic trace/result presentation hints supplied by the owning domain.
    pub presentation_hints: Option<serde_json::Value>,
}

pub(crate) fn worker_id(value: &str) -> EngineResult<WorkerId> {
    WorkerId::new(value)
}

pub(crate) fn actor_id(value: &str) -> EngineResult<ActorId> {
    ActorId::new(value)
}
