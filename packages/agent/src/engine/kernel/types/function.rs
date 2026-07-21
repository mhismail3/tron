//! Function catalog and policy contracts.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{FunctionHealth, FunctionRevision, FunctionVisibility};
use crate::engine::kernel::ids::{FunctionId, WorkerId};

/// Side-effect class of a function.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EffectClass {
    /// Reads without mutation.
    PureRead,
    /// Deterministic computation from payload only.
    DeterministicCompute,
    /// Mutates state with an idempotency key.
    IdempotentWrite,
    /// Appends immutable ledger/event data.
    AppendOnlyEvent,
    /// Side effect whose caller may safely retry after an explicit failure.
    ReversibleSideEffect,
    /// External system/device effect.
    ExternalSideEffect,
    /// Cannot be safely undone.
    IrreversibleSideEffect,
}

impl EffectClass {
    /// Whether this effect mutates durable state or the outside world.
    #[must_use]
    pub fn is_mutating(self) -> bool {
        !matches!(self, Self::PureRead | Self::DeterministicCompute)
    }

    /// Whether this effect requires an idempotency contract.
    #[must_use]
    pub fn requires_idempotency(self) -> bool {
        self.is_mutating()
    }
}

/// Risk level for discovery and policy, including its stable lowercase
/// persistence, policy-hash, and catalog spelling.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum RiskLevel {
    /// Low-risk capability.
    Low,
    /// Medium-risk capability.
    Medium,
    /// High-risk capability.
    High,
    /// Critical-risk capability.
    Critical,
}

impl RiskLevel {
    /// Stable serialized key used outside serde-owned protocol payloads.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Critical => "critical",
        }
    }
}

/// Replay behavior for a duplicate idempotency key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReplayBehavior {
    /// Return the previous result.
    ReturnPrevious,
    /// Accept the duplicate without changing state.
    NoOp,
    /// Reject duplicate.
    Reject,
}

impl ReplayBehavior {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ReturnPrevious => "return_previous",
            Self::NoOp => "no_op",
            Self::Reject => "reject",
        }
    }
}

/// Idempotency contract required for mutating agent-visible functions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdempotencyContract {
    /// Dedupe scope.
    pub dedupe_scope: DedupeScope,
    /// Duplicate replay behavior.
    pub replay_behavior: ReplayBehavior,
}

impl IdempotencyContract {
    /// Session-scoped duplicate replay.
    #[must_use]
    pub fn session() -> Self {
        Self {
            dedupe_scope: DedupeScope::Session,
            replay_behavior: ReplayBehavior::ReturnPrevious,
        }
    }

    /// System-scoped duplicate replay.
    #[must_use]
    pub fn system() -> Self {
        Self {
            dedupe_scope: DedupeScope::System,
            replay_behavior: ReplayBehavior::ReturnPrevious,
        }
    }
}

/// Extent within which an idempotency key is unique.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DedupeScope {
    /// Unique within the invocation's session.
    Session,
    /// Unique across the running Tron system.
    System,
}

/// Concrete dedupe scope attached to an invocation's idempotency key.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct IdempotencyScope {
    /// Scope kind: `session` or `system`.
    pub kind: String,
    /// Concrete scope value.
    pub value: String,
}

impl IdempotencyScope {
    /// Create a scope.
    #[must_use]
    pub fn new(kind: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            value: value.into(),
        }
    }
}

/// Typed model-tool projection attached only to functions intended for a
/// provider request.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelToolContract {
    /// Stable model-facing tool name.
    pub name: String,
    /// Whether autonomous mode currently exposes this tool.
    pub callable: bool,
    /// Stable ordering for fixed kernel tools. Dynamic workers have no fixed
    /// order because relevance owns their placement.
    pub order: Option<u16>,
    /// Fixed primitive family shown by engine introspection.
    pub group: Option<String>,
    /// Direct-worker routing and retrieval data, when this function projects a
    /// persistent worker.
    pub worker: Option<DirectWorkerToolContract>,
}

/// Typed routing evidence for a persistent worker's direct model tool.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirectWorkerToolContract {
    /// Stable worker id.
    pub worker_id: String,
    /// Human-readable worker name.
    pub worker_name: String,
    /// Immutable active content version.
    pub worker_version: String,
    /// Canonical worker update timestamp.
    pub updated_at: String,
    /// Declared routing intents.
    pub intents: Vec<String>,
    /// Declared routing examples.
    pub examples: Vec<String>,
    /// Compact source-and-revision provenance strings.
    pub provenance: Vec<String>,
}

/// Function catalog definition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FunctionDefinition {
    /// Function id.
    pub id: FunctionId,
    /// Function revision.
    pub revision: FunctionRevision,
    /// Owner worker.
    pub owner_worker: WorkerId,
    /// Human-readable description.
    pub description: String,
    /// Request JSON schema.
    pub request_schema: Option<Value>,
    /// Response JSON schema.
    pub response_schema: Option<Value>,
    /// Function admission boundary.
    pub visibility: FunctionVisibility,
    /// Side-effect class.
    pub effect_class: EffectClass,
    /// Risk level.
    pub risk_level: RiskLevel,
    /// Idempotency contract.
    pub idempotency: Option<IdempotencyContract>,
    /// Health.
    pub health: FunctionHealth,
    /// Optional typed provider-tool projection.
    pub model_tool: Option<ModelToolContract>,
}

impl FunctionDefinition {
    /// Create a function definition.
    #[must_use]
    pub fn new(
        id: FunctionId,
        owner_worker: WorkerId,
        description: impl Into<String>,
        visibility: FunctionVisibility,
        effect_class: EffectClass,
    ) -> Self {
        Self {
            id,
            revision: FunctionRevision(1),
            owner_worker,
            description: description.into(),
            request_schema: None,
            response_schema: None,
            visibility,
            effect_class,
            risk_level: RiskLevel::Low,
            idempotency: None,
            health: FunctionHealth::Healthy,
            model_tool: None,
        }
    }

    /// Attach an idempotency contract.
    #[must_use]
    pub fn with_idempotency(mut self, contract: IdempotencyContract) -> Self {
        self.idempotency = Some(contract);
        self
    }

    /// Set risk level.
    #[must_use]
    pub fn with_risk(mut self, risk: RiskLevel) -> Self {
        self.risk_level = risk;
        self
    }

    /// Set health.
    #[must_use]
    pub fn with_health(mut self, health: FunctionHealth) -> Self {
        self.health = health;
        self
    }

    /// Attach a request schema.
    #[must_use]
    pub fn with_request_schema(mut self, schema: Value) -> Self {
        self.request_schema = Some(schema);
        self
    }

    /// Attach a response schema.
    #[must_use]
    pub fn with_response_schema(mut self, schema: Value) -> Self {
        self.response_schema = Some(schema);
        self
    }
}
