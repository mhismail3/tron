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
    /// MCP capability worker.
    Mcp,
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
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Internal => "internal",
            Self::Session => "session",
            Self::Workspace => "workspace",
            Self::System => "system",
            Self::Client => "client",
            Self::Worker => "worker",
            Self::Agent => "agent",
            Self::Admin => "admin",
        }
    }

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
    /// Privileged meta-capability that delegates to another function whose
    /// effect/idempotency policy is checked at runtime.
    DelegatedInvocation,
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

impl ReplayBehavior {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ReturnPrevious => "return_previous",
            Self::NoOp => "no_op",
            Self::Reject => "reject",
            Self::Compensate => "compensate",
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

/// Fail-closed behavior when a declared resource lease cannot be acquired.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ResourceLeaseFailureBehavior {
    /// Reject the invocation before handler execution.
    FailClosed,
}

/// Engine-owned resource lease contract for a mutating function.
///
/// The first implementation resolves `resource_id_template` from invocation
/// payload fields plus canonical causal-context fields such as `sessionId` and
/// `workspaceId`. Keeping this metadata on the function definition makes
/// resource ownership visible through discovery and enforceable by the host
/// before any domain handler runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceLeaseRequirement {
    /// Resolver identifier. `payload_template` is the built-in v1 resolver.
    pub resolver_id: String,
    /// Domain resource kind, such as `session`, `worktree`, or `git`.
    pub resource_kind: String,
    /// Template used by the resolver to derive a canonical resource id.
    pub resource_id_template: String,
    /// Lease TTL in milliseconds.
    pub ttl_ms: i64,
    /// Whether this lease is exclusive. Only exclusive leases exist in v1.
    pub exclusive: bool,
    /// Stream topic for lease lifecycle records.
    pub stream_topic: String,
    /// Behavior when resolution/acquisition fails.
    pub failure_behavior: ResourceLeaseFailureBehavior,
}

impl ResourceLeaseRequirement {
    /// Build an exclusive payload-template lease requirement.
    #[must_use]
    pub fn exclusive_template(
        resource_kind: impl Into<String>,
        resource_id_template: impl Into<String>,
        ttl_ms: i64,
    ) -> Self {
        Self {
            resolver_id: "payload_template".to_owned(),
            resource_kind: resource_kind.into(),
            resource_id_template: resource_id_template.into(),
            ttl_ms,
            exclusive: true,
            stream_topic: "resource.leases".to_owned(),
            failure_behavior: ResourceLeaseFailureBehavior::FailClosed,
        }
    }
}

/// Compensation strategy for a mutating function.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompensationKind {
    /// No compensation is needed.
    None,
    /// The domain event log preserves enough information for manual recovery.
    EventSourced,
    /// A documented inverse command exists.
    InverseCommandAvailable,
    /// Manual recovery is required.
    ManualOnly,
    /// The side effect is external and cannot be safely undone automatically.
    ExternalIrreversible,
}

/// Durable compensation contract attached to high-risk functions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompensationContract {
    /// Compensation kind.
    pub kind: CompensationKind,
    /// Required operator-facing notes.
    pub notes: String,
}

impl CompensationContract {
    /// Create a compensation contract with notes.
    #[must_use]
    pub fn new(kind: CompensationKind, notes: impl Into<String>) -> Self {
        Self {
            kind,
            notes: notes.into(),
        }
    }

    /// Whether this contract has useful notes for audit/recovery.
    #[must_use]
    pub fn has_notes(&self) -> bool {
        !self.notes.trim().is_empty()
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
    /// Engine-enforced resource lease requirement.
    pub resource_lease: Option<ResourceLeaseRequirement>,
    /// Durable compensation/audit contract.
    pub compensation: Option<CompensationContract>,
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
            resource_lease: None,
            compensation: None,
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

    /// Attach an engine-enforced resource lease requirement.
    #[must_use]
    pub fn with_resource_lease(mut self, requirement: ResourceLeaseRequirement) -> Self {
        self.resource_lease = Some(requirement);
        self
    }

    /// Attach a durable compensation contract.
    #[must_use]
    pub fn with_compensation(mut self, contract: CompensationContract) -> Self {
        self.compensation = Some(contract);
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

/// Catalog subject type.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CatalogSubjectKind {
    /// Worker catalog entry.
    Worker,
    /// Function catalog entry.
    Function,
    /// Trigger type catalog entry.
    TriggerType,
    /// Trigger catalog entry.
    Trigger,
}

impl CatalogSubjectKind {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Worker => "worker",
            Self::Function => "function",
            Self::TriggerType => "trigger_type",
            Self::Trigger => "trigger",
        }
    }
}

/// Coarse class for catalog-change subscriptions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CatalogChangeClass {
    /// Worker or capability availability changed.
    Availability,
    /// Function contract changed.
    Contract,
    /// Trigger or trigger-type topology changed.
    Trigger,
    /// Visibility/promotion changed.
    Visibility,
    /// Health changed.
    Health,
}

impl CatalogChangeClass {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Availability => "availability",
            Self::Contract => "contract",
            Self::Trigger => "trigger",
            Self::Visibility => "visibility",
            Self::Health => "health",
        }
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
    /// Subject kind.
    pub subject_kind: CatalogSubjectKind,
    /// Coarse change class.
    pub class: CatalogChangeClass,
    /// Subject visibility at the time of the change.
    pub visibility: VisibilityScope,
    /// Subject session scope at the time of the change.
    pub session_id: Option<String>,
    /// Subject workspace scope at the time of the change.
    pub workspace_id: Option<String>,
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
