use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(super) const BUNDLE_SCHEMA: &str = "tron.worker_bundle.v1";
pub(super) const MAX_CAUSAL_DEPTH: u32 = 16;
pub(super) const MAX_ENGINE_CONCURRENCY: usize = 32;
pub(super) const MAX_WORKER_CONCURRENCY: usize = 8;
pub(super) const MAX_INVOCATION_SECONDS: u64 = 7_200;

fn default_bundle_schema() -> String {
    BUNDLE_SCHEMA.to_owned()
}

fn object_schema() -> Value {
    serde_json::json!({"type": "object"})
}

/// Complete, portable source contract accepted by the atomic worker upsert.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerBundle {
    #[serde(default = "default_bundle_schema")]
    pub schema_version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    pub name: String,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// Optional narrower schema projected to the model-facing direct tool.
    ///
    /// `input_schema` remains authoritative for every runtime source,
    /// including triggers and worker handoffs. This projection keeps
    /// engine-owned coordination fields out of ordinary model calls.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_input_schema: Option<Value>,
    #[serde(default = "object_schema")]
    pub input_schema: Value,
    #[serde(default = "object_schema")]
    pub output_schema: Value,
    pub runner: WorkerRunner,
    #[serde(default)]
    pub files: BTreeMap<String, String>,
    #[serde(default)]
    pub dependencies: Vec<WorkerDependency>,
    #[serde(default)]
    pub triggers: Vec<WorkerTrigger>,
    #[serde(default)]
    pub secret_bindings: Vec<WorkerSecretBinding>,
    #[serde(default)]
    pub smoke_tests: Vec<WorkerCommand>,
    /// Runner-specific checks that must pass before activation. Their results
    /// are sealed into the immutable version's verification evidence.
    #[serde(default)]
    pub health_checks: Vec<WorkerCommand>,
    #[serde(default)]
    pub provenance: Vec<SourceProvenance>,
    /// Optional semantic engine roles implemented by this immutable version.
    /// Upsert activates these roles with the worker; there is no separate
    /// binding or permission transition.
    #[serde(default)]
    pub engine_hooks: Vec<WorkerEngineHook>,
    /// Optional native-client actions implemented by this immutable version.
    /// The client owns only capture/presentation; the selected worker owns the
    /// typed transformation and all higher-level policy.
    #[serde(default)]
    pub client_actions: Vec<WorkerClientAction>,
    /// Optional native-client deliveries emitted by this immutable version.
    ///
    /// Deliveries flow from a completed worker invocation to authenticated
    /// clients. They are intentionally separate from client-initiated actions.
    #[serde(default)]
    pub client_deliveries: Vec<WorkerClientDelivery>,
    /// Fixed asynchronous routes that this immutable version may dispatch.
    ///
    /// Output chooses only a declared route and stable deduplication key. The
    /// route binds the target worker identity and response ownership.
    #[serde(default)]
    pub worker_dispatch_routes: Vec<WorkerDispatchRoute>,
    #[serde(default)]
    pub routing: WorkerRouting,
    /// Generic execution ceilings selected by this immutable worker version.
    ///
    /// The kernel enforces these values without interpreting why a worker
    /// chose them. Research policy, source budgets, retry strategy, and other
    /// task semantics remain inside the worker contract.
    #[serde(default, skip_serializing_if = "WorkerExecutionLimits::is_default")]
    pub execution_limits: WorkerExecutionLimits,
    /// Optional immutable binding to a supported native or declarative worker
    /// experience. Unsupported contracts always use the generic console.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub presentation: Option<WorkerPresentation>,
}

impl WorkerBundle {
    pub(crate) fn effective_tool_input_schema(&self) -> &Value {
        self.tool_input_schema
            .as_ref()
            .unwrap_or(&self.input_schema)
    }
}

/// Worker-selected ceilings enforced by the generic agent runner.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerExecutionLimits {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_agent_turns: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_child_invocations: Option<u32>,
}

impl WorkerExecutionLimits {
    fn is_default(&self) -> bool {
        self.max_agent_turns.is_none() && self.max_child_invocations.is_none()
    }
}

/// Generic execution stages recorded and projected by the durable kernel.
///
/// These values describe lifecycle evidence only. A worker may supply
/// presentation metadata for domain wording, but task-specific orchestration
/// policy never enters this enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerRunStage {
    Queued,
    Planning,
    SpecialistExecution,
    RetryRepair,
    Synthesis,
    Validation,
    Publication,
    Detached,
    Completed,
    Failed,
    Cancelled,
    Interrupted,
}

impl WorkerRunStage {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Planning => "planning",
            Self::SpecialistExecution => "specialist_execution",
            Self::RetryRepair => "retry_repair",
            Self::Synthesis => "synthesis",
            Self::Validation => "validation",
            Self::Publication => "publication",
            Self::Detached => "detached",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Interrupted => "interrupted",
        }
    }
}

/// Append-only durable stage evidence for one worker invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerRunEvent {
    pub event_id: String,
    pub invocation_id: String,
    pub sequence: u32,
    pub stage: WorkerRunStage,
    pub summary: String,
    pub occurred_at: String,
}

/// Minimal immutable worker-experience identity used before the generalized
/// declarative presentation descriptor exists.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerPresentation {
    pub experience_id: String,
    pub contract_version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub component_role: Option<String>,
    #[serde(default)]
    pub primary: bool,
}

/// Semantic policy seams that may be implemented by normal workers.
///
/// Add a hook only when a production engine behavior has a concrete worker
/// replacement. Deterministic state custody and safety ceilings remain kernel
/// responsibilities.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerEngineHook {
    ContextSummary,
    InboxContext,
    SessionTitle,
    WorkerRelevance,
}

impl WorkerEngineHook {
    pub const fn all() -> &'static [Self] {
        &[
            Self::ContextSummary,
            Self::InboxContext,
            Self::SessionTitle,
            Self::WorkerRelevance,
        ]
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ContextSummary => "context_summary",
            Self::InboxContext => "inbox_context",
            Self::SessionTitle => "session_title",
            Self::WorkerRelevance => "worker_relevance",
        }
    }
}

/// Stable native-client seams that may be fulfilled by normal workers.
///
/// These are deliberately narrower than presentation metadata: each action
/// has one kernel-validated input/output contract and one active owner. A
/// client never needs to inspect worker files or invent worker-specific
/// payloads to use the action.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerClientAction {
    SpeechTranscription,
}

impl WorkerClientAction {
    pub const fn all() -> &'static [Self] {
        &[Self::SpeechTranscription]
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SpeechTranscription => "speech_transcription",
        }
    }
}

/// Stable worker-to-client delivery seams fulfilled by normal workers.
///
/// Each delivery kind has one kernel-validated output contract. Workers own
/// content and reminder semantics; the engine owns durable dispatch evidence,
/// and clients own native presentation and authenticated responses.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerClientDelivery {
    NotificationDelivery,
}

impl WorkerClientDelivery {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotificationDelivery => "notification_delivery",
        }
    }
}

/// One closed asynchronous worker-to-worker route.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerDispatchRoute {
    pub route: String,
    pub target_worker_id: String,
    #[serde(default)]
    pub client_response_owner: WorkerDispatchResponseOwner,
}

/// Notification response binding selected by the immutable source route.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerDispatchResponseOwner {
    Source,
    #[default]
    Target,
}

impl WorkerDispatchResponseOwner {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Target => "target",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", deny_unknown_fields)]
pub enum WorkerRunner {
    Agent {
        instructions: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },
    Command {
        command: Vec<String>,
    },
    Service {
        command: Vec<String>,
        #[serde(rename = "invokeUrl", alias = "invoke_url")]
        invoke_url: String,
        #[serde(
            default,
            rename = "healthUrl",
            alias = "health_url",
            skip_serializing_if = "Option::is_none"
        )]
        health_url: Option<String>,
    },
}

impl WorkerRunner {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Agent { .. } => "agent",
            Self::Command { .. } => "command",
            Self::Service { .. } => "service",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerDependency {
    pub name: String,
    pub source: String,
    pub version: String,
    /// Optional expected `sha256:<hex>` digest. `worker_upsert` always replaces
    /// an omitted value with the fetched file/tree digest before publication.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checksum: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub install: Option<WorkerCommand>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerCommand {
    pub command: Vec<String>,
    #[serde(default = "default_command_timeout")]
    pub timeout_seconds: u64,
}

fn default_command_timeout() -> u64 {
    300
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", deny_unknown_fields)]
pub enum WorkerTrigger {
    Manual {
        id: String,
    },
    Schedule {
        id: String,
        #[serde(rename = "everySeconds", alias = "every_seconds")]
        every_seconds: u64,
        #[serde(default = "empty_object")]
        input: Value,
    },
    EngineEvent {
        id: String,
        topic: String,
        /// Recursive JSON subset that the stream event payload must match.
        #[serde(default = "empty_object")]
        filter: Value,
        #[serde(default = "empty_object")]
        input: Value,
    },
    Webhook {
        id: String,
        #[serde(default = "empty_object")]
        input: Value,
    },
}

impl WorkerTrigger {
    pub fn id(&self) -> &str {
        match self {
            Self::Manual { id }
            | Self::Schedule { id, .. }
            | Self::EngineEvent { id, .. }
            | Self::Webhook { id, .. } => id,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::Manual { .. } => "manual",
            Self::Schedule { .. } => "schedule",
            Self::EngineEvent { .. } => "engine_event",
            Self::Webhook { .. } => "webhook",
        }
    }
}

fn empty_object() -> Value {
    serde_json::json!({})
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceProvenance {
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checksum: Option<String>,
}

/// Logical runtime credential binding. Vault names resolve directly;
/// `provider-<id>` resolves the active named API key from provider auth. Bare
/// strings remain the concise optional form; object form can declare a binding
/// mandatory for execution.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum WorkerSecretBinding {
    Optional(String),
    Configured {
        name: String,
        #[serde(default)]
        required: bool,
    },
}

impl WorkerSecretBinding {
    pub fn name(&self) -> &str {
        match self {
            Self::Optional(name) | Self::Configured { name, .. } => name,
        }
    }

    pub fn required(&self) -> bool {
        matches!(self, Self::Configured { required: true, .. })
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerRouting {
    #[serde(default)]
    pub intents: Vec<String>,
    #[serde(default)]
    pub examples: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerState {
    pub worker_id: String,
    pub active_version: String,
    pub enabled: bool,
    pub retired: bool,
    #[serde(default = "default_worker_health")]
    pub health: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
    pub updated_at: String,
}

fn default_worker_health() -> String {
    "healthy".to_owned()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerSummary {
    pub worker_id: String,
    pub name: String,
    pub description: String,
    pub tool_name: String,
    pub runner_kind: String,
    pub active_version: String,
    pub enabled: bool,
    pub retired: bool,
    pub health: String,
    pub trigger_count: u64,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub presentation: Option<WorkerPresentation>,
}

#[derive(Clone, Debug)]
pub struct ActiveWorker {
    pub summary: WorkerSummary,
    pub bundle: WorkerBundle,
    pub version_dir: std::path::PathBuf,
}

#[derive(Clone, Debug)]
pub struct PreparedWorker {
    pub worker_id: String,
    pub version: String,
    pub tool_name: String,
    pub bundle: WorkerBundle,
    pub staging_dir: std::path::PathBuf,
    pub prior_state: Option<WorkerState>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InvocationRecord {
    pub invocation_id: String,
    pub worker_id: String,
    pub worker_version: String,
    pub status: String,
    pub input: Value,
    pub output: Option<Value>,
    pub error: Option<String>,
    pub idempotency_key: String,
    pub trace_id: String,
    pub causal_depth: u32,
    pub trigger_kind: String,
    /// Root chat session that originated this causal worker trace, when the
    /// trace began inside a session. Descendant worker calls inherit this
    /// value even when they execute through child agent sessions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_session_id: Option<String>,
    /// Child session created for an agent-runner invocation, when applicable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_id: Option<String>,
    /// Current interaction ownership. Background is durable execution state,
    /// not a separate job or execution path.
    #[serde(default)]
    pub interaction_mode: WorkerInteractionMode,
    /// Time at which a foreground caller released this same durable
    /// invocation, or admission time for predicted-background work.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detached_at: Option<String>,
    /// Provider/model tool call that admitted this invocation, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_tool_invocation_id: Option<String>,
    /// Direct durable parent worker invocation for causal-tree reconstruction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_worker_invocation_id: Option<String>,
    /// Terminal invocation retried by this run, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_of_invocation_id: Option<String>,
    /// Durable delivery attempts made for this invocation. Values greater than
    /// one are explicit at-least-once redelivery evidence.
    pub attempt_count: u32,
    pub created_at: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerInteractionMode {
    #[default]
    Foreground,
    Background,
}

impl WorkerInteractionMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Foreground => "foreground",
            Self::Background => "background",
        }
    }
}

#[derive(Clone, Debug)]
pub struct InvokeRequest {
    pub worker_id: String,
    pub input: Value,
    pub idempotency_key: String,
    pub trace_id: String,
    pub causal_depth: u32,
    pub trigger_kind: String,
    pub origin_session_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebhookCredential {
    pub trigger_id: String,
    pub path: String,
    pub token: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpsertOutcome {
    pub worker: WorkerSummary,
    pub version: String,
    pub created: bool,
    pub replaced_worker_id: Option<String>,
    pub webhooks: Vec<WebhookCredential>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PurgeOutcome {
    pub worker_id: String,
    pub purged: bool,
    pub archive_path: String,
    pub archive_sha256: String,
}
