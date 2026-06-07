//! Loopback external-worker protocol types.
//!
//! This module is protocol-only. The server runtime owns the authenticated
//! `/engine/workers` socket, while the engine owns the typed JSON envelope used
//! by local workers to register functions/triggers, receive invocations, publish
//! stream events through `stream::publish`, and cleanly disconnect.
//! Visible external/session workers also present a scoped worker token in
//! `hello`; the token is the protocol-level plugin lifecycle boundary for
//! namespace claims, grant identity, resource selectors, visibility, trust,
//! scope binding, and signature state.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::discovery::ActorKind;
use super::ids::{AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, WorkerId};
use super::types::{FunctionDefinition, TriggerDefinition, VisibilityScope, WorkerDefinition};

/// Protocol version used by the first local worker wire contract.
pub const WORKER_PROTOCOL_VERSION: u16 = 1;

/// External worker message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WorkerProtocolMessage {
    /// Worker hello/handshake.
    Hello(Box<WorkerHello>),
    /// Engine catalog snapshot.
    CatalogSnapshot(CatalogSnapshot),
    /// Worker registers one function.
    RegisterFunction(Box<RegisterFunction>),
    /// Worker registers one trigger.
    RegisterTrigger(RegisterTrigger),
    /// Worker publishes one engine stream event.
    PublishStream(WorkerStreamPublish),
    /// Engine asks a worker to invoke a function.
    Invoke(WorkerInvoke),
    /// Worker returns an invocation result.
    Result(WorkerInvocationResult),
    /// Engine broadcasts a catalog change.
    CatalogChange(WorkerCatalogChange),
    /// Liveness heartbeat.
    Heartbeat(WorkerHeartbeat),
    /// Worker or engine disconnect notice.
    Disconnect(WorkerDisconnect),
}

/// Worker identity supplied during hello.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerIdentity {
    /// Stable worker id.
    pub worker_id: WorkerId,
    /// Human-readable worker name.
    pub worker_name: String,
    /// Optional worker version.
    pub worker_version: Option<String>,
    /// Whether this identity was created by a local sandbox capability.
    pub sandboxed: bool,
}

impl WorkerIdentity {
    /// Build a default identity from a worker definition.
    #[must_use]
    pub fn from_worker(worker: &WorkerDefinition) -> Self {
        Self {
            worker_id: worker.id.clone(),
            worker_name: worker.id.to_string(),
            worker_version: None,
            sandboxed: false,
        }
    }
}

/// Local worker authorization policy.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerAuthPolicy {
    /// Authenticated loopback worker.
    LoopbackBearer,
    /// Engine-issued sandbox token.
    SandboxToken,
}

impl Default for WorkerAuthPolicy {
    fn default() -> Self {
        Self::LoopbackBearer
    }
}

/// Registration durability.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerRegistrationMode {
    /// Remove functions/triggers on disconnect or missed heartbeat.
    Volatile,
    /// Keep the registration after connection loss when policy allows it.
    Durable,
}

impl Default for WorkerRegistrationMode {
    fn default() -> Self {
        Self::Volatile
    }
}

/// Worker default visibility.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerVisibility {
    /// Session-scoped capability.
    Session,
    /// Workspace-scoped capability.
    Workspace,
    /// System-scoped capability.
    System,
}

impl Default for WorkerVisibility {
    fn default() -> Self {
        Self::Session
    }
}

impl WorkerVisibility {
    /// Convert to engine visibility.
    #[must_use]
    pub fn as_visibility_scope(&self) -> VisibilityScope {
        match self {
            Self::Session => VisibilityScope::Session,
            Self::Workspace => VisibilityScope::Workspace,
            Self::System => VisibilityScope::System,
        }
    }
}

/// Engine-issued capability worker token.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScopedWorkerToken {
    /// Plugin manifest id that owns registrations made on this connection.
    pub plugin_id: String,
    /// Namespaces the worker may claim for functions, contracts, and implementations.
    pub namespace_claims: Vec<String>,
    /// Engine-owned authority grant assigned to this worker.
    pub authority_grant_id: AuthorityGrantId,
    /// Grant revision captured when the token was issued.
    pub authority_grant_revision: u64,
    /// Policy hash captured when the token was issued.
    pub authority_grant_hash: String,
    /// Resource selectors the worker may reference.
    pub resource_selectors: Vec<String>,
    /// Maximum visibility the worker may request.
    pub visibility_ceiling: WorkerVisibility,
    /// Trust tier assigned by the issuing policy.
    pub trust_tier: String,
    /// Optional session binding.
    pub session_id: Option<String>,
    /// Optional workspace binding.
    pub workspace_id: Option<String>,
    /// Optional RFC3339 expiry timestamp.
    pub expires_at: Option<String>,
    /// Signature status for durable plugin policy.
    pub signature_status: String,
}

impl ScopedWorkerToken {
    /// Build a scoped loopback token from a worker definition.
    #[must_use]
    pub fn loopback(worker: &WorkerDefinition) -> Self {
        let namespace_claims = if worker.namespace_claims.is_empty() {
            vec![worker.id.as_str().to_owned()]
        } else {
            worker.namespace_claims.clone()
        };
        Self {
            plugin_id: format!("session_generated.{}", worker.id.as_str()),
            namespace_claims,
            authority_grant_id: worker.authority_grant.clone(),
            authority_grant_revision: 1,
            authority_grant_hash: "loopback-bootstrap".to_owned(),
            resource_selectors: vec!["*".to_owned()],
            visibility_ceiling: WorkerVisibility::Session,
            trust_tier: "session_generated".to_owned(),
            session_id: None,
            workspace_id: None,
            expires_at: None,
            signature_status: "session_scoped".to_owned(),
        }
    }
}

/// Worker health tracked by the local runtime.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerHealth {
    /// Worker is routable.
    Healthy,
    /// Worker failed health policy and should not route.
    Unhealthy,
    /// Worker is disconnected.
    Disconnected,
}

impl Default for WorkerHealth {
    fn default() -> Self {
        Self::Healthy
    }
}

/// Worker lifecycle payload stored on `worker.lifecycle`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerLifecycleEvent {
    /// Lifecycle event type, for example `worker.connected`.
    pub event_type: String,
    /// Worker id.
    pub worker_id: WorkerId,
    /// Registration durability mode.
    pub registration_mode: WorkerRegistrationMode,
    /// Worker visibility scope.
    pub visibility: WorkerVisibility,
    /// Session scope, when present.
    pub session_id: Option<String>,
    /// Workspace scope, when present.
    pub workspace_id: Option<String>,
    /// Worker health after the event.
    pub health: WorkerHealth,
    /// Optional lifecycle reason.
    pub reason: Option<String>,
    /// Function ids owned by the worker at event time.
    pub functions: Vec<String>,
    /// Trigger ids owned by the worker at event time.
    pub triggers: Vec<String>,
    /// Catalog revision observed after the lifecycle change.
    pub catalog_revision: u64,
    /// Trace id assigned to this lifecycle event.
    pub trace_id: TraceId,
    /// Event timestamp.
    pub timestamp: String,
}

/// Worker hello/handshake.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerHello {
    /// Protocol version.
    pub protocol_version: u16,
    /// Worker definition.
    pub worker: WorkerDefinition,
    /// Whether the connection is loopback/local-only.
    pub loopback_only: bool,
    /// Explicit worker identity.
    #[serde(default = "default_worker_identity")]
    pub identity: WorkerIdentity,
    /// Local authorization policy.
    #[serde(default)]
    pub auth_policy: WorkerAuthPolicy,
    /// Registration durability mode.
    #[serde(default)]
    pub registration_mode: WorkerRegistrationMode,
    /// Default visibility for functions/triggers registered by this worker.
    #[serde(default)]
    pub default_visibility: WorkerVisibility,
    /// Optional session scope for session-visible registrations.
    #[serde(default)]
    pub session_id: Option<String>,
    /// Optional workspace scope for workspace-visible registrations.
    #[serde(default)]
    pub workspace_id: Option<String>,
    /// Requested heartbeat interval.
    #[serde(default = "default_heartbeat_interval_ms")]
    pub heartbeat_interval_ms: u64,
    /// Human-readable supported capability labels.
    #[serde(default)]
    pub supported_capabilities: Vec<String>,
    /// Scoped token that bounds plugin/worker registration.
    pub worker_token: ScopedWorkerToken,
}

impl WorkerHello {
    /// Build a loopback volatile hello with session default visibility.
    #[must_use]
    pub fn loopback(worker: WorkerDefinition) -> Self {
        let worker_token = ScopedWorkerToken::loopback(&worker);
        Self {
            protocol_version: WORKER_PROTOCOL_VERSION,
            identity: WorkerIdentity::from_worker(&worker),
            worker,
            loopback_only: true,
            auth_policy: WorkerAuthPolicy::LoopbackBearer,
            registration_mode: WorkerRegistrationMode::Volatile,
            default_visibility: WorkerVisibility::Session,
            session_id: None,
            workspace_id: None,
            heartbeat_interval_ms: default_heartbeat_interval_ms(),
            supported_capabilities: Vec::new(),
            worker_token,
        }
    }
}

/// Catalog snapshot sent after connection.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogSnapshot {
    /// Visible functions.
    pub functions: Vec<FunctionDefinition>,
    /// Visible triggers.
    pub triggers: Vec<TriggerDefinition>,
}

/// Function registration message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterFunction {
    /// Function definition.
    pub definition: FunctionDefinition,
    /// Default visibility for external workers.
    pub default_visibility: VisibilityScope,
}

/// Trigger registration message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterTrigger {
    /// Trigger definition.
    pub definition: TriggerDefinition,
}

/// Invocation request sent to an external worker.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerInvoke {
    /// Invocation id.
    pub invocation_id: InvocationId,
    /// Target function id.
    pub function_id: FunctionId,
    /// Payload.
    pub payload: Value,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant id.
    pub authority_grant_id: AuthorityGrantId,
    /// Authority scopes.
    pub authority_scopes: Vec<String>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation.
    pub parent_invocation_id: Option<InvocationId>,
    /// Optional trigger id.
    pub trigger_id: Option<TriggerId>,
    /// Explicit idempotency key, when the target mutates.
    pub idempotency_key: Option<String>,
    /// Session scope.
    pub session_id: Option<String>,
    /// Workspace scope.
    pub workspace_id: Option<String>,
    /// Invocation timeout requested by the engine.
    pub timeout_ms: u64,
}

/// Invocation result from an external worker.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerInvocationResult {
    /// Invocation id.
    pub invocation_id: InvocationId,
    /// JSON result, if successful.
    pub result: Option<Value>,
    /// Structured error, if failed.
    pub error: Option<Value>,
}

/// Catalog change notice.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerCatalogChange {
    /// Changed subject id.
    pub subject_id: String,
    /// Owner worker.
    pub owner_worker: WorkerId,
    /// Change kind string.
    pub kind: String,
    /// Catalog revision after the change.
    pub catalog_revision: u64,
}

/// Worker request to publish one engine stream event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerStreamPublish {
    /// Worker id.
    pub worker_id: WorkerId,
    /// Topic.
    pub topic: String,
    /// Payload.
    pub payload: Value,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Session scope.
    pub session_id: Option<String>,
    /// Workspace scope.
    pub workspace_id: Option<String>,
    /// Trace id.
    pub trace_id: Option<TraceId>,
    /// Parent invocation.
    pub parent_invocation_id: Option<InvocationId>,
    /// Explicit idempotency key for stream publish.
    pub idempotency_key: String,
}

/// Heartbeat message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerHeartbeat {
    /// Worker id.
    pub worker_id: WorkerId,
    /// Monotonic sequence.
    pub sequence: u64,
}

/// Disconnect notice.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerDisconnect {
    /// Worker id.
    pub worker_id: WorkerId,
    /// Human-readable reason.
    pub reason: String,
}

fn default_heartbeat_interval_ms() -> u64 {
    15_000
}

fn default_worker_identity() -> WorkerIdentity {
    WorkerIdentity {
        worker_id: WorkerId::new("unidentified-worker").expect("valid static worker id"),
        worker_name: "unidentified-worker".to_owned(),
        worker_version: None,
        sandboxed: false,
    }
}
