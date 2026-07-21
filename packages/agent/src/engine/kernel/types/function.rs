//! Function catalog and policy contracts.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{FunctionHealth, FunctionRevision, Provenance, VisibilityScope};
use crate::engine::kernel::ids::{FunctionId, WorkerId};

/// Side-effect class of a function.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EffectClass {
    /// Reads without mutation.
    PureRead,
    /// Deterministic computation from payload only.
    DeterministicCompute,
    /// Privileged meta-capability that delegates to another function whose
    /// effect/idempotency policy is checked at runtime.
    DelegatedInvocation,
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
        !matches!(
            self,
            Self::PureRead | Self::DeterministicCompute | Self::DelegatedInvocation
        )
    }

    /// Whether this effect requires an idempotency contract.
    #[must_use]
    pub fn requires_idempotency(self) -> bool {
        self.is_mutating()
    }

    /// Whether agent visibility requires an idempotency contract.
    #[must_use]
    pub fn requires_idempotency_for_agent_visibility(self) -> bool {
        self.requires_idempotency()
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

/// Invocation delivery mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeliveryMode {
    /// Wait for a result.
    Sync,
    /// Fire-and-forget.
    Void,
    /// Durable queue handoff.
    Enqueue,
}

impl DeliveryMode {
    /// Static display string.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Sync => "sync",
            Self::Void => "void",
            Self::Enqueue => "enqueue",
        }
    }
}

/// Source of the idempotency key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum IdempotencyKeySource {
    /// Caller supplies the key.
    Caller,
    /// Engine derives the key.
    EngineDerived,
    /// Trigger derives the key.
    TriggerDerived,
    /// External provider supplies/accepts the key.
    ExternalProvider,
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

/// Ledger location for idempotency/effect tracking.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum LedgerKind {
    /// In-memory ledger for Phase 1 tests.
    InMemory,
    /// Tron-native durable engine ledger.
    EngineLedger,
    /// Future durable event ledger.
    EventStore,
    /// External service ledger.
    External,
}

/// Idempotency contract required for mutating agent-visible functions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdempotencyContract {
    /// Key source.
    pub key_source: IdempotencyKeySource,
    /// Dedupe scope.
    pub dedupe_scope: VisibilityScope,
    /// Duplicate replay behavior.
    pub replay_behavior: ReplayBehavior,
    /// Ledger kind.
    pub ledger_kind: LedgerKind,
}

impl IdempotencyContract {
    /// Caller-supplied session-scoped idempotency.
    #[must_use]
    pub fn caller_session() -> Self {
        Self {
            key_source: IdempotencyKeySource::Caller,
            dedupe_scope: VisibilityScope::Session,
            replay_behavior: ReplayBehavior::ReturnPrevious,
            ledger_kind: LedgerKind::InMemory,
        }
    }

    /// Caller-supplied session-scoped idempotency using the durable engine ledger.
    #[must_use]
    pub fn caller_session_engine_ledger() -> Self {
        Self {
            key_source: IdempotencyKeySource::Caller,
            dedupe_scope: VisibilityScope::Session,
            replay_behavior: ReplayBehavior::ReturnPrevious,
            ledger_kind: LedgerKind::EngineLedger,
        }
    }

    /// Caller-supplied system-scoped idempotency using the durable engine ledger.
    #[must_use]
    pub fn caller_system_engine_ledger() -> Self {
        Self {
            key_source: IdempotencyKeySource::Caller,
            dedupe_scope: VisibilityScope::System,
            replay_behavior: ReplayBehavior::ReturnPrevious,
            ledger_kind: LedgerKind::EngineLedger,
        }
    }
}

/// Concrete dedupe scope attached to an invocation's idempotency key.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct IdempotencyScope {
    /// Scope kind, such as `session`, `workspace`, or `system`.
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
    /// Whether response is intentionally opaque.
    pub opaque_response: bool,
    /// Search tags.
    pub tags: Vec<String>,
    /// Visibility scope.
    pub visibility: VisibilityScope,
    /// Side-effect class.
    pub effect_class: EffectClass,
    /// Risk level.
    pub risk_level: RiskLevel,
    /// Idempotency contract.
    pub idempotency: Option<IdempotencyContract>,
    /// Allowed delivery modes.
    pub allowed_delivery_modes: Vec<DeliveryMode>,
    /// Health.
    pub health: FunctionHealth,
    /// Provenance.
    pub provenance: Provenance,
    /// Escape-hatch metadata.
    pub metadata: Value,
}

impl FunctionDefinition {
    /// Create a function definition.
    #[must_use]
    pub fn new(
        id: FunctionId,
        owner_worker: WorkerId,
        description: impl Into<String>,
        visibility: VisibilityScope,
        effect_class: EffectClass,
    ) -> Self {
        Self {
            id,
            revision: FunctionRevision(1),
            owner_worker,
            description: description.into(),
            request_schema: None,
            response_schema: None,
            opaque_response: false,
            tags: Vec::new(),
            visibility,
            effect_class,
            risk_level: RiskLevel::Low,
            idempotency: None,
            allowed_delivery_modes: vec![DeliveryMode::Sync],
            health: FunctionHealth::Healthy,
            provenance: Provenance::system(),
            metadata: Value::Null,
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

    /// Set allowed delivery modes.
    #[must_use]
    pub fn with_allowed_delivery_modes(mut self, modes: Vec<DeliveryMode>) -> Self {
        self.allowed_delivery_modes = modes;
        self
    }

    /// Add tags.
    #[must_use]
    pub fn with_tags(mut self, tags: Vec<String>) -> Self {
        self.tags = tags;
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

    /// Set provenance.
    #[must_use]
    pub fn with_provenance(mut self, provenance: Provenance) -> Self {
        self.provenance = provenance;
        self
    }
}
