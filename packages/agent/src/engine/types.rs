//! Engine definitions and metadata contracts.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::ids::{ActorId, AuthorityGrantId, FunctionId, TriggerId, TriggerTypeId, WorkerId};

macro_rules! revision_type {
    ($name:ident) => {
        #[doc = concat!("Monotonic revision counter for ", stringify!($name), " values.")]
        #[derive(
            Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize,
        )]
        #[serde(transparent)]
        pub struct $name(pub u64);

        impl $name {
            /// Return the next revision.
            #[must_use]
            pub fn next(self) -> Self {
                Self(self.0 + 1)
            }
        }
    };
}

revision_type!(CatalogRevision);
revision_type!(FunctionRevision);
revision_type!(TriggerRevision);
revision_type!(WorkerRevision);

/// Runtime kind of a registered worker.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkerKind {
    /// In-process Rust worker.
    InProcess,
    /// Future external worker.
    External,
    /// Future sandbox worker.
    Sandbox,
    /// Agent worker.
    Agent,
    /// Client participant.
    Client,
    /// System worker.
    System,
    /// Queue worker.
    Queue,
    /// Stream worker.
    Stream,
    /// Cron worker.
    Cron,
    /// State worker.
    State,
    /// MCP bridge worker.
    McpBridge,
    /// Migration adapter.
    Compatibility,
}

/// Worker lifecycle state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkerLifecycleState {
    /// Worker is starting.
    Starting,
    /// Worker is healthy and routable.
    Ready,
    /// Worker is available but degraded.
    Degraded,
    /// Worker is draining.
    Draining,
    /// Worker is stopped.
    Stopped,
}

/// Visibility scope for catalog entries.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum VisibilityScope {
    /// Engine-internal entry.
    Internal,
    /// Visible to a single session.
    Session,
    /// Visible to a workspace.
    Workspace,
    /// System-wide visibility.
    System,
    /// Client-visible entry.
    Client,
    /// Worker-visible entry.
    Worker,
    /// Agent-visible entry.
    Agent,
    /// Admin-only entry.
    Admin,
}

impl VisibilityScope {
    /// Whether this scope may be shown to an autonomous agent.
    #[must_use]
    pub fn is_agent_visible(&self) -> bool {
        matches!(
            self,
            Self::Session | Self::Workspace | Self::System | Self::Agent
        )
    }
}

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
    /// Side effect with compensation.
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

    /// Whether agent visibility requires an idempotency contract.
    #[must_use]
    pub fn requires_idempotency_for_agent_visibility(self) -> bool {
        self.requires_idempotency()
    }

    /// Whether autonomous agent visibility requires explicit approval metadata.
    #[must_use]
    pub fn requires_approval_for_agent_visibility(self) -> bool {
        matches!(self, Self::IrreversibleSideEffect)
    }
}

/// Risk level for discovery and policy.
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

/// Health state for routing and discovery.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FunctionHealth {
    /// Healthy and routable.
    Healthy,
    /// Routable, but callers should prefer healthy alternatives.
    Degraded,
    /// Not routable.
    Unhealthy,
    /// Unknown health.
    Unknown,
}

impl FunctionHealth {
    /// Whether normal invocation may route to the function.
    #[must_use]
    pub fn is_routable(&self) -> bool {
        matches!(self, Self::Healthy | Self::Degraded)
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
    /// Treat as no-op.
    NoOp,
    /// Reject duplicate.
    Reject,
    /// Run compensation.
    Compensate,
}

/// Ledger location for idempotency/effect tracking.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum LedgerKind {
    /// In-memory ledger for Phase 1 tests.
    InMemory,
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
}

/// Authority needed to discover or invoke a capability.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorityRequirement {
    /// Required authority scopes.
    pub scopes: Vec<String>,
    /// Whether explicit approval is required.
    pub approval_required: bool,
}

impl AuthorityRequirement {
    /// No additional authority.
    #[must_use]
    pub fn none() -> Self {
        Self::default()
    }

    /// Require one scope.
    #[must_use]
    pub fn scope(scope: impl Into<String>) -> Self {
        Self {
            scopes: vec![scope.into()],
            approval_required: false,
        }
    }

    /// Mark this requirement as requiring explicit approval.
    #[must_use]
    pub fn with_approval_required(mut self) -> Self {
        self.approval_required = true;
        self
    }
}

/// Provenance metadata for generated and registered artifacts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Provenance {
    /// Actor that created the artifact.
    pub created_by: ActorId,
    /// Source description.
    pub source: String,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
}

impl Provenance {
    /// Create provenance for an actor-authored artifact.
    #[must_use]
    pub fn new(created_by: ActorId, source: impl Into<String>) -> Self {
        Self {
            created_by,
            source: source.into(),
            session_id: None,
            workspace_id: None,
        }
    }

    /// System provenance for built-ins and tests.
    #[must_use]
    pub fn system() -> Self {
        Self::new(
            ActorId::new("system").expect("valid static actor id"),
            "system",
        )
    }

    /// Attach a session scope.
    #[must_use]
    pub fn with_session_id(mut self, session_id: impl Into<String>) -> Self {
        self.session_id = Some(session_id.into());
        self
    }

    /// Attach a workspace scope.
    #[must_use]
    pub fn with_workspace_id(mut self, workspace_id: impl Into<String>) -> Self {
        self.workspace_id = Some(workspace_id.into());
        self
    }
}

/// Worker catalog definition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WorkerDefinition {
    /// Worker id.
    pub id: WorkerId,
    /// Worker revision.
    pub revision: WorkerRevision,
    /// Worker kind.
    pub kind: WorkerKind,
    /// Lifecycle state.
    pub lifecycle: WorkerLifecycleState,
    /// Actor that owns the worker.
    pub owner_actor: ActorId,
    /// Authority grant used by the worker.
    pub authority_grant: AuthorityGrantId,
    /// Claimed namespaces.
    pub namespace_claims: Vec<String>,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Provenance.
    pub provenance: Provenance,
}

impl WorkerDefinition {
    /// Create a worker definition.
    #[must_use]
    pub fn new(
        id: WorkerId,
        kind: WorkerKind,
        owner_actor: ActorId,
        authority_grant: AuthorityGrantId,
    ) -> Self {
        let provenance = Provenance::new(owner_actor.clone(), "worker");
        Self {
            id,
            revision: WorkerRevision(1),
            kind,
            lifecycle: WorkerLifecycleState::Ready,
            owner_actor,
            authority_grant,
            namespace_claims: Vec::new(),
            visibility: VisibilityScope::Internal,
            provenance,
        }
    }

    /// Add a namespace claim.
    #[must_use]
    pub fn with_namespace_claim(mut self, namespace: impl Into<String>) -> Self {
        self.namespace_claims.push(namespace.into());
        self
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
    /// Required authority.
    pub required_authority: AuthorityRequirement,
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
            required_authority: AuthorityRequirement::none(),
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

    /// Attach a required authority.
    #[must_use]
    pub fn with_required_authority(mut self, requirement: AuthorityRequirement) -> Self {
        self.required_authority = requirement;
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

    /// Set provenance.
    #[must_use]
    pub fn with_provenance(mut self, provenance: Provenance) -> Self {
        self.provenance = provenance;
        self
    }
}

/// Trigger type catalog definition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TriggerTypeDefinition {
    /// Trigger type id.
    pub id: TriggerTypeId,
    /// Owner worker.
    pub owner_worker: WorkerId,
    /// Description.
    pub description: String,
    /// Config schema.
    pub config_schema: Option<Value>,
    /// Allowed delivery modes.
    pub allowed_delivery_modes: Vec<DeliveryMode>,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Provenance.
    pub provenance: Provenance,
}

impl TriggerTypeDefinition {
    /// Create a trigger type definition.
    #[must_use]
    pub fn new(id: TriggerTypeId, owner_worker: WorkerId, description: impl Into<String>) -> Self {
        Self {
            id,
            owner_worker,
            description: description.into(),
            config_schema: None,
            allowed_delivery_modes: vec![DeliveryMode::Sync],
            visibility: VisibilityScope::Internal,
            provenance: Provenance::system(),
        }
    }
}

/// Trigger catalog definition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TriggerDefinition {
    /// Trigger id.
    pub id: TriggerId,
    /// Trigger revision.
    pub revision: TriggerRevision,
    /// Owner worker.
    pub owner_worker: WorkerId,
    /// Trigger type.
    pub trigger_type: TriggerTypeId,
    /// Target function.
    pub target_function: FunctionId,
    /// Required target revision, if pinned.
    pub target_revision: Option<FunctionRevision>,
    /// Trigger config.
    pub config: Value,
    /// Delivery mode.
    pub delivery_mode: DeliveryMode,
    /// Authority grant used when fired.
    pub authority_grant: AuthorityGrantId,
    /// Idempotency key strategy.
    pub idempotency_key_strategy: Option<IdempotencyKeySource>,
    /// Max causal depth.
    pub max_depth: Option<u32>,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Provenance.
    pub provenance: Provenance,
}

impl TriggerDefinition {
    /// Create a trigger definition.
    #[must_use]
    pub fn new(
        id: TriggerId,
        owner_worker: WorkerId,
        trigger_type: TriggerTypeId,
        target_function: FunctionId,
        authority_grant: AuthorityGrantId,
    ) -> Self {
        Self {
            id,
            revision: TriggerRevision(1),
            owner_worker,
            trigger_type,
            target_function,
            target_revision: None,
            config: Value::Null,
            delivery_mode: DeliveryMode::Sync,
            authority_grant,
            idempotency_key_strategy: None,
            max_depth: None,
            visibility: VisibilityScope::Internal,
            provenance: Provenance::system(),
        }
    }

    /// Set delivery mode.
    #[must_use]
    pub fn with_delivery_mode(mut self, mode: DeliveryMode) -> Self {
        self.delivery_mode = mode;
        self
    }
}

/// Catalog change event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CatalogChange {
    /// Change id.
    pub id: String,
    /// Revision before the change.
    pub before: CatalogRevision,
    /// Revision after the change.
    pub after: CatalogRevision,
    /// Change kind.
    pub kind: CatalogChangeKind,
    /// Subject id.
    pub subject_id: String,
    /// Owner worker, when applicable.
    pub owner_worker: Option<WorkerId>,
    /// Timestamp.
    pub timestamp: DateTime<Utc>,
}

/// Kind of catalog change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CatalogChangeKind {
    /// Worker registered.
    WorkerRegistered,
    /// Worker updated.
    WorkerUpdated,
    /// Worker unregistered.
    WorkerUnregistered,
    /// Function registered.
    FunctionRegistered,
    /// Function updated.
    FunctionUpdated,
    /// Function unregistered.
    FunctionUnregistered,
    /// Trigger type registered.
    TriggerTypeRegistered,
    /// Trigger type updated.
    TriggerTypeUpdated,
    /// Trigger type unregistered.
    TriggerTypeUnregistered,
    /// Trigger registered.
    TriggerRegistered,
    /// Trigger updated.
    TriggerUpdated,
    /// Trigger unregistered.
    TriggerUnregistered,
    /// Visibility changed.
    VisibilityChanged,
    /// Health changed.
    HealthChanged,
}
