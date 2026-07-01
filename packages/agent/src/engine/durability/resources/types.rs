//! Resource substrate type definitions.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{ActorId, InvocationId, TraceId, WorkerId};

/// Built-in generated UI resource kind.
pub const UI_SURFACE_KIND: &str = "ui_surface";
/// Built-in generated UI resource schema id.
pub const UI_SURFACE_SCHEMA_ID: &str = "tron.resource.ui_surface.v1";
/// Runtime UI surface schema version rendered by the client shell.
pub const UI_SURFACE_SCHEMA_VERSION: u64 = 1;
/// Built-in catalog discovery report resource kind.
pub const CATALOG_DISCOVERY_REPORT_KIND: &str = "catalog_discovery_report";
/// Built-in catalog discovery report resource schema id.
pub const CATALOG_DISCOVERY_REPORT_SCHEMA_ID: &str = "tron.resource.catalog_discovery_report.v1";
/// Built-in approval request resource kind.
pub const APPROVAL_REQUEST_KIND: &str = "approval_request";
/// Built-in approval request resource schema id.
pub const APPROVAL_REQUEST_SCHEMA_ID: &str = "tron.resource.approval_request.v1";
/// Built-in approval decision resource kind.
pub const APPROVAL_DECISION_KIND: &str = "approval_decision";
/// Built-in approval decision resource schema id.
pub const APPROVAL_DECISION_SCHEMA_ID: &str = "tron.resource.approval_decision.v1";
/// Built-in memory engine descriptor resource kind.
pub const MEMORY_ENGINE_KIND: &str = "memory_engine";
/// Built-in memory engine descriptor resource schema id.
pub const MEMORY_ENGINE_SCHEMA_ID: &str = "tron.resource.memory_engine.v1";
/// Built-in memory policy resource kind.
pub const MEMORY_POLICY_KIND: &str = "memory_policy";
/// Built-in memory policy resource schema id.
pub const MEMORY_POLICY_SCHEMA_ID: &str = "tron.resource.memory_policy.v1";
/// Built-in memory record resource kind.
pub const MEMORY_RECORD_KIND: &str = "memory_record";
/// Built-in memory record resource schema id.
pub const MEMORY_RECORD_SCHEMA_ID: &str = "tron.resource.memory_record.v1";
/// Built-in memory prompt inclusion trace resource kind.
pub const MEMORY_PROMPT_TRACE_KIND: &str = "memory_prompt_trace";
/// Built-in memory prompt inclusion trace resource schema id.
pub const MEMORY_PROMPT_TRACE_SCHEMA_ID: &str = "tron.resource.memory_prompt_trace.v1";
/// Built-in memory retrieval query evidence resource kind.
pub const MEMORY_QUERY_KIND: &str = "memory_query";
/// Built-in memory retrieval query evidence resource schema id.
pub const MEMORY_QUERY_SCHEMA_ID: &str = "tron.resource.memory_query.v1";
/// Built-in memory decision evidence resource kind.
pub const MEMORY_DECISION_KIND: &str = "memory_decision";
/// Built-in memory decision evidence resource schema id.
pub const MEMORY_DECISION_SCHEMA_ID: &str = "tron.resource.memory_decision.v1";
/// Built-in memory eval-run resource kind.
pub const MEMORY_EVAL_RUN_KIND: &str = "memory_eval_run";
/// Built-in memory eval-run resource schema id.
pub const MEMORY_EVAL_RUN_SCHEMA_ID: &str = "tron.resource.memory_eval_run.v1";
/// Built-in memory migration/export/import envelope resource kind.
pub const MEMORY_MIGRATION_ENVELOPE_KIND: &str = "memory_migration_envelope";
/// Built-in memory migration/export/import envelope resource schema id.
pub const MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID: &str = "tron.resource.memory_migration_envelope.v1";
/// Built-in durable process job resource kind.
pub const JOB_PROCESS_KIND: &str = "job_process";
/// Built-in durable process job resource schema id.
pub const JOB_PROCESS_SCHEMA_ID: &str = "tron.resource.job_process.v1";
/// Built-in user question resource kind.
pub const USER_QUESTION_KIND: &str = "user_question";
/// Built-in user question resource schema id.
pub const USER_QUESTION_SCHEMA_ID: &str = "tron.resource.user_question.v1";
/// Built-in goal answer resource kind.
pub const GOAL_ANSWER_KIND: &str = "goal_answer";
/// Built-in goal answer resource schema id.
pub const GOAL_ANSWER_SCHEMA_ID: &str = "tron.resource.goal_answer.v1";
/// Built-in Git index mutation evidence resource kind.
pub const GIT_INDEX_CHANGE_KIND: &str = "git_index_change";
/// Built-in Git index mutation evidence resource schema id.
pub const GIT_INDEX_CHANGE_SCHEMA_ID: &str = "tron.resource.git_index_change.v1";
/// Built-in Git commit evidence resource kind.
pub const GIT_COMMIT_KIND: &str = "git_commit";
/// Built-in Git commit evidence resource schema id.
pub const GIT_COMMIT_SCHEMA_ID: &str = "tron.resource.git_commit.v1";
/// Built-in Git branch-start evidence resource kind.
pub const GIT_BRANCH_START_KIND: &str = "git_branch_start";
/// Built-in Git branch-start evidence resource schema id.
pub const GIT_BRANCH_START_SCHEMA_ID: &str = "tron.resource.git_branch_start.v1";
/// Built-in web source/fetch provenance resource kind.
pub const WEB_SOURCE_KIND: &str = "web_source";
/// Built-in web source/fetch provenance resource schema id.
pub const WEB_SOURCE_SCHEMA_ID: &str = "tron.resource.web_source.v1";
/// Built-in web robots policy evidence resource kind.
pub const WEB_ROBOTS_POLICY_KIND: &str = "web_robots_policy";
/// Built-in web robots policy evidence resource schema id.
pub const WEB_ROBOTS_POLICY_SCHEMA_ID: &str = "tron.resource.web_robots_policy.v1";
/// Built-in external tool-source proposal resource kind.
pub const TOOL_SOURCE_PROPOSAL_KIND: &str = "tool_source_proposal";
/// Built-in external tool-source proposal resource schema id.
pub const TOOL_SOURCE_PROPOSAL_SCHEMA_ID: &str = "tron.resource.tool_source_proposal.v1";
/// Built-in external tool-source conformance/preflight report resource kind.
pub const TOOL_SOURCE_CONFORMANCE_REPORT_KIND: &str = "tool_source_conformance_report";
/// Built-in external tool-source conformance/preflight report resource schema id.
pub const TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID: &str =
    "tron.resource.tool_source_conformance_report.v1";
/// Built-in inert subagent task lifecycle resource kind.
pub const SUBAGENT_TASK_KIND: &str = "subagent_task";
/// Built-in inert subagent task lifecycle resource schema id.
pub const SUBAGENT_TASK_SCHEMA_ID: &str = "tron.resource.subagent_task.v1";
/// Built-in inert procedural state record resource kind.
pub const PROCEDURAL_RECORD_KIND: &str = "procedural_record";
/// Built-in inert procedural state record resource schema id.
pub const PROCEDURAL_RECORD_SCHEMA_ID: &str = "tron.resource.procedural_record.v1";
/// Built-in metadata-only procedural activation review request resource kind.
pub const PROCEDURAL_ACTIVATION_REQUEST_KIND: &str = "procedural_activation_request";
/// Built-in metadata-only procedural activation review request resource schema id.
pub const PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID: &str =
    "tron.resource.procedural_activation_request.v1";
/// Built-in metadata-only procedural activation decision resource kind.
pub const PROCEDURAL_ACTIVATION_DECISION_KIND: &str = "procedural_activation_decision";
/// Built-in metadata-only procedural activation decision resource schema id.
pub const PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID: &str =
    "tron.resource.procedural_activation_decision.v1";
/// Built-in durable schedule resource kind.
pub const SCHEDULE_KIND: &str = "schedule";
/// Built-in durable schedule resource schema id.
pub const SCHEDULE_SCHEMA_ID: &str = "tron.resource.schedule.v1";
/// Built-in durable schedule run resource kind.
pub const SCHEDULE_RUN_KIND: &str = "schedule_run";
/// Built-in durable schedule run resource schema id.
pub const SCHEDULE_RUN_SCHEMA_ID: &str = "tron.resource.schedule_run.v1";
/// Built-in APNs-capable device registration resource kind.
pub const DEVICE_REGISTRATION_KIND: &str = "device_registration";
/// Built-in APNs-capable device registration resource schema id.
pub const DEVICE_REGISTRATION_SCHEMA_ID: &str = "tron.resource.device_registration.v1";
/// Built-in server-owned notification inbox resource kind.
pub const NOTIFICATION_KIND: &str = "notification";
/// Built-in server-owned notification inbox resource schema id.
pub const NOTIFICATION_SCHEMA_ID: &str = "tron.resource.notification.v1";
/// Built-in notification delivery evidence resource kind.
pub const NOTIFICATION_DELIVERY_KIND: &str = "notification_delivery";
/// Built-in notification delivery evidence resource schema id.
pub const NOTIFICATION_DELIVERY_SCHEMA_ID: &str = "tron.resource.notification_delivery.v1";
/// Built-in durable media/voice-note artifact resource kind.
pub const MEDIA_ARTIFACT_KIND: &str = "media_artifact";
/// Built-in durable media/voice-note artifact resource schema id.
pub const MEDIA_ARTIFACT_SCHEMA_ID: &str = "tron.resource.media_artifact.v1";
/// Built-in import/session-resource graph lineage resource kind.
pub const IMPORT_HISTORY_RECORD_KIND: &str = "import_history_record";
/// Built-in import/session-resource graph lineage resource schema id.
pub const IMPORT_HISTORY_RECORD_SCHEMA_ID: &str = "tron.resource.import_history_record.v1";
/// Built-in content-free import preview resource kind.
pub const IMPORT_PREVIEW_KIND: &str = "import_preview";
/// Built-in content-free import preview resource schema id.
pub const IMPORT_PREVIEW_SCHEMA_ID: &str = "tron.resource.import_preview.v1";
/// Built-in content-free program execution record resource kind.
pub const PROGRAM_EXECUTION_KIND: &str = "program_execution_record";
/// Built-in content-free program execution record resource schema id.
pub const PROGRAM_EXECUTION_SCHEMA_ID: &str = "tron.resource.program_execution_record.v1";
/// Built-in prompt artifact metadata resource kind.
pub const PROMPT_ARTIFACT_KIND: &str = "prompt_artifact";
/// Built-in prompt artifact metadata resource schema id.
pub const PROMPT_ARTIFACT_SCHEMA_ID: &str = "tron.resource.prompt_artifact.v1";
/// Built-in content-free repository tree snapshot resource kind.
pub const REPOSITORY_TREE_SNAPSHOT_KIND: &str = "repository_tree_snapshot";
/// Built-in content-free repository tree snapshot resource schema id.
pub const REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID: &str = "tron.resource.repository_tree_snapshot.v1";
/// Built-in system update diagnostic metadata resource kind.
pub const UPDATE_DIAGNOSTIC_RECORD_KIND: &str = "update_diagnostic_record";
/// Built-in system update diagnostic metadata resource schema id.
pub const UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID: &str = "tron.resource.update_diagnostic_record.v1";
/// Built-in inspect-only module manifest resource kind.
pub const MODULE_MANIFEST_KIND: &str = "module_manifest";
/// Built-in inspect-only module manifest resource schema id.
pub const MODULE_MANIFEST_SCHEMA_ID: &str = "tron.resource.module_manifest.v1";
/// Built-in module authoring proposal resource kind.
pub const MODULE_PROPOSAL_KIND: &str = "module_proposal";
/// Built-in module authoring proposal resource schema id.
pub const MODULE_PROPOSAL_SCHEMA_ID: &str = "tron.resource.module_proposal.v1";
/// Built-in module validation report resource kind.
pub const MODULE_VALIDATION_REPORT_KIND: &str = "module_validation_report";
/// Built-in module validation report resource schema id.
pub const MODULE_VALIDATION_REPORT_SCHEMA_ID: &str = "tron.resource.module_validation_report.v1";
/// Built-in metadata-only module install review request resource kind.
pub const MODULE_INSTALL_REQUEST_KIND: &str = "module_install_request";
/// Built-in metadata-only module install review request resource schema id.
pub const MODULE_INSTALL_REQUEST_SCHEMA_ID: &str = "tron.resource.module_install_request.v1";
/// Built-in metadata-only module install decision resource kind.
pub const MODULE_INSTALL_DECISION_KIND: &str = "module_install_decision";
/// Built-in metadata-only module install decision resource schema id.
pub const MODULE_INSTALL_DECISION_SCHEMA_ID: &str = "tron.resource.module_install_decision.v1";
/// Built-in metadata-only module dependency request resource kind.
pub const MODULE_DEPENDENCY_REQUEST_KIND: &str = "module_dependency_request";
/// Built-in metadata-only module dependency request resource schema id.
pub const MODULE_DEPENDENCY_REQUEST_SCHEMA_ID: &str = "tron.resource.module_dependency_request.v1";
/// Built-in metadata-only module dependency decision resource kind.
pub const MODULE_DEPENDENCY_DECISION_KIND: &str = "module_dependency_decision";
/// Built-in metadata-only module dependency decision resource schema id.
pub const MODULE_DEPENDENCY_DECISION_SCHEMA_ID: &str =
    "tron.resource.module_dependency_decision.v1";
/// Built-in metadata-only module dependency policy resource kind.
pub const MODULE_DEPENDENCY_POLICY_KIND: &str = "module_dependency_policy";
/// Built-in metadata-only module dependency policy resource schema id.
pub const MODULE_DEPENDENCY_POLICY_SCHEMA_ID: &str = "tron.resource.module_dependency_policy.v1";
/// Built-in metadata-only module lifecycle state resource kind.
pub const MODULE_LIFECYCLE_STATE_KIND: &str = "module_lifecycle_state";
/// Built-in metadata-only module lifecycle state resource schema id.
pub const MODULE_LIFECYCLE_STATE_SCHEMA_ID: &str = "tron.resource.module_lifecycle_state.v1";
/// Built-in supervised module runtime state resource kind.
pub const MODULE_RUNTIME_STATE_KIND: &str = "module_runtime_state";
/// Built-in supervised module runtime state resource schema id.
pub const MODULE_RUNTIME_STATE_SCHEMA_ID: &str = "tron.resource.module_runtime_state.v1";
/// Built-in context-control snapshot resource kind.
pub const CONTEXT_CONTROL_SNAPSHOT_KIND: &str = "context_control_snapshot";
/// Built-in context-control snapshot resource schema id.
pub const CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID: &str = "tron.resource.context_control_snapshot.v1";
/// Built-in context-control action resource kind.
pub const CONTEXT_CONTROL_ACTION_KIND: &str = "context_control_action";
/// Built-in context-control action resource schema id.
pub const CONTEXT_CONTROL_ACTION_SCHEMA_ID: &str = "tron.resource.context_control_action.v1";
/// Built-in context-control epoch resource kind.
pub const CONTEXT_CONTROL_EPOCH_KIND: &str = "context_control_epoch";
/// Built-in context-control epoch resource schema id.
pub const CONTEXT_CONTROL_EPOCH_SCHEMA_ID: &str = "tron.resource.context_control_epoch.v1";
/// Built-in metadata-only web research request resource kind.
pub const WEB_RESEARCH_REQUEST_KIND: &str = "web_research_request";
/// Built-in metadata-only web research request resource schema id.
pub const WEB_RESEARCH_REQUEST_SCHEMA_ID: &str = "tron.resource.web_research_request.v1";
/// Built-in metadata-only web research review resource kind.
pub const WEB_RESEARCH_REVIEW_KIND: &str = "web_research_review";
/// Built-in metadata-only web research review resource schema id.
pub const WEB_RESEARCH_REVIEW_SCHEMA_ID: &str = "tron.resource.web_research_review.v1";
/// Built-in bounded web research source/citation artifact resource kind.
pub const WEB_RESEARCH_SOURCE_KIND: &str = "web_research_source";
/// Built-in bounded web research source/citation artifact resource schema id.
pub const WEB_RESEARCH_SOURCE_SCHEMA_ID: &str = "tron.resource.web_research_source.v1";
/// Scope for a durable engine resource.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineResourceScope {
    /// System-wide resource.
    System,
    /// Workspace-scoped resource.
    Workspace(String),
    /// Session-scoped resource.
    Session(String),
}

impl EngineResourceScope {
    /// Scope kind stored on disk.
    #[must_use]
    pub fn kind(&self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Workspace(_) => "workspace",
            Self::Session(_) => "session",
        }
    }

    /// Concrete scope value stored on disk.
    #[must_use]
    pub fn value(&self) -> &str {
        match self {
            Self::System => "system",
            Self::Workspace(value) | Self::Session(value) => value,
        }
    }

    pub(crate) fn parse(kind: &str, value: String) -> Result<Self> {
        match kind {
            "system" if value == "system" => Ok(Self::System),
            "workspace" if !value.trim().is_empty() => Ok(Self::Workspace(value)),
            "session" if !value.trim().is_empty() => Ok(Self::Session(value)),
            _ => Err(EngineError::LedgerFailure {
                operation: "resource.scope",
                message: format!("invalid resource scope {kind}:{value}"),
            }),
        }
    }
}

/// Versioning behavior declared by a resource kind.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineResourceVersioningMode {
    /// Every content mutation creates a new immutable version.
    AppendOnly,
    /// Current version may be replaced through compare-and-set.
    CurrentPointer,
}

impl EngineResourceVersioningMode {
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Self::AppendOnly => "append_only",
            Self::CurrentPointer => "current_pointer",
        }
    }

    pub(crate) fn parse(value: &str) -> Result<Self> {
        match value {
            "append_only" => Ok(Self::AppendOnly),
            "current_pointer" => Ok(Self::CurrentPointer),
            _ => Err(EngineError::LedgerFailure {
                operation: "resource.versioning_mode",
                message: format!("unsupported resource versioning mode {value}"),
            }),
        }
    }
}

/// Lifecycle of one immutable resource version.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineResourceVersionState {
    /// Bytes and payload verified; this version may be current.
    #[default]
    Available,
    /// Version was created by an interrupted or suspicious producer.
    Quarantined,
    /// Declared bytes, hash, or location are missing or inconsistent.
    Damaged,
    /// Version is intentionally no longer active.
    Discarded,
}

impl EngineResourceVersionState {
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Quarantined => "quarantined",
            Self::Damaged => "damaged",
            Self::Discarded => "discarded",
        }
    }

    pub(crate) fn parse(value: &str) -> Result<Self> {
        match value {
            "available" => Ok(Self::Available),
            "quarantined" => Ok(Self::Quarantined),
            "damaged" => Ok(Self::Damaged),
            "discarded" => Ok(Self::Discarded),
            _ => Err(EngineError::LedgerFailure {
                operation: "resource.version_state",
                message: format!("unsupported resource version state {value}"),
            }),
        }
    }

    pub(crate) fn may_be_current(&self) -> bool {
        matches!(self, Self::Available)
    }
}

/// Resource type definition registered by a worker.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResourceTypeDefinition {
    /// Resource kind, for example `artifact` or `goal`.
    pub kind: String,
    /// Schema id attached to resources of this kind.
    pub schema_id: String,
    /// JSON schema for version payloads.
    pub schema: Value,
    /// Allowed lifecycle states.
    pub lifecycle_states: Vec<String>,
    /// Versioning behavior.
    pub versioning_mode: EngineResourceVersioningMode,
    /// Allowed link relation names from this resource kind.
    pub allowed_link_relations: Vec<String>,
    /// Default retention policy.
    pub default_retention: Value,
    /// Redaction rules for previews/control-plane reads.
    pub redaction_rules: Value,
    /// Materialization rules for files/blob refs.
    pub materialization_rules: Value,
    /// Required capabilities for read/write/promote/delete operations.
    pub required_capabilities: Value,
    /// Worker that registered the type.
    pub owner_worker_id: WorkerId,
    /// Monotonic type definition revision.
    pub revision: u64,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
    /// Last update timestamp.
    pub updated_at: DateTime<Utc>,
}

/// Durable engine resource.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResource {
    /// Stable resource id.
    pub resource_id: String,
    /// Resource kind.
    pub kind: String,
    /// Schema id used by the current resource payload.
    pub schema_id: String,
    /// Resource scope.
    pub scope: EngineResourceScope,
    /// Worker that owns the resource.
    pub owner_worker_id: WorkerId,
    /// Actor that created the resource.
    pub owner_actor_id: ActorId,
    /// Current lifecycle state.
    pub lifecycle: String,
    /// Resource policy envelope.
    pub policy: Value,
    /// Current version id, when content exists.
    pub current_version_id: Option<String>,
    /// Creation trace id.
    pub trace_id: TraceId,
    /// Invocation that created the resource.
    pub created_by_invocation_id: Option<InvocationId>,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
    /// Last update timestamp.
    pub updated_at: DateTime<Utc>,
}

/// One immutable resource version.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResourceVersion {
    /// Stable version id.
    pub version_id: String,
    /// Owning resource id.
    pub resource_id: String,
    /// Parent version, if any.
    pub parent_version_id: Option<String>,
    /// Hash of the payload JSON bytes.
    pub content_hash: String,
    /// Version state.
    pub state: EngineResourceVersionState,
    /// Version payload.
    pub payload: Value,
    /// Materialized locations for this version.
    pub locations: Vec<EngineResourceLocation>,
    /// Invocation that created the version.
    pub created_by_invocation_id: Option<InvocationId>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
}

/// One location where a resource version is materialized.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResourceLocation {
    /// Location kind, for example `blob`, `file`, `url`, or `vault_ref`.
    pub kind: String,
    /// Location URI/path/ref.
    pub uri: String,
    /// Optional MIME type.
    pub mime_type: Option<String>,
    /// Optional byte size.
    pub size_bytes: Option<u64>,
}

/// Typed edge between two resources.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResourceLink {
    /// Stable link id.
    pub link_id: String,
    /// Source resource.
    pub source_resource_id: String,
    /// Target resource.
    pub target_resource_id: String,
    /// Relation name.
    pub relation: String,
    /// Link metadata.
    pub metadata: Value,
    /// Invocation that created the link.
    pub created_by_invocation_id: Option<InvocationId>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
}

/// Append-only resource event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResourceEvent {
    /// Stable event id.
    pub event_id: String,
    /// Resource id.
    pub resource_id: String,
    /// Event type.
    pub event_type: String,
    /// Event payload.
    pub payload: Value,
    /// Invocation that caused the event.
    pub invocation_id: Option<InvocationId>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Event timestamp.
    pub occurred_at: DateTime<Utc>,
}

/// Create or update a type definition.
#[derive(Clone, Debug, PartialEq)]
pub struct RegisterResourceType {
    /// Resource kind.
    pub kind: String,
    /// Schema id.
    pub schema_id: String,
    /// JSON schema for version payloads.
    pub schema: Value,
    /// Allowed lifecycle states.
    pub lifecycle_states: Vec<String>,
    /// Versioning mode.
    pub versioning_mode: EngineResourceVersioningMode,
    /// Allowed outgoing link relations.
    pub allowed_link_relations: Vec<String>,
    /// Default retention policy.
    pub default_retention: Value,
    /// Redaction policy.
    pub redaction_rules: Value,
    /// Materialization policy.
    pub materialization_rules: Value,
    /// Capability requirements by operation.
    pub required_capabilities: Value,
    /// Worker that owns the type definition.
    pub owner_worker_id: WorkerId,
}

/// Create a resource and optional initial version.
#[derive(Clone, Debug, PartialEq)]
pub struct CreateResource {
    /// Optional caller-chosen resource id.
    pub resource_id: Option<String>,
    /// Resource kind.
    pub kind: String,
    /// Optional schema id. Defaults to the registered type schema id.
    pub schema_id: Option<String>,
    /// Resource scope.
    pub scope: EngineResourceScope,
    /// Worker that owns the resource.
    pub owner_worker_id: WorkerId,
    /// Actor that creates the resource.
    pub owner_actor_id: ActorId,
    /// Optional initial lifecycle. Defaults to the first registered state.
    pub lifecycle: Option<String>,
    /// Resource policy envelope.
    pub policy: Value,
    /// Optional initial version payload.
    pub initial_payload: Option<Value>,
    /// Optional locations for the initial version.
    pub locations: Vec<EngineResourceLocation>,
    /// Creation trace id.
    pub trace_id: TraceId,
    /// Invocation that creates the resource.
    pub invocation_id: Option<InvocationId>,
}

/// Add a resource version with compare-and-set protection.
#[derive(Clone, Debug, PartialEq)]
pub struct UpdateResource {
    /// Resource id.
    pub resource_id: String,
    /// Expected current version id. `None` means the resource must not have content yet.
    pub expected_current_version_id: Option<String>,
    /// Optional lifecycle update.
    pub lifecycle: Option<String>,
    /// New version payload.
    pub payload: Value,
    /// Optional version state. Defaults to `available`.
    pub state: Option<EngineResourceVersionState>,
    /// Locations for the new version.
    pub locations: Vec<EngineResourceLocation>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Invocation that creates the version.
    pub invocation_id: Option<InvocationId>,
}

/// Link two resources.
#[derive(Clone, Debug, PartialEq)]
pub struct LinkResources {
    /// Source resource id.
    pub source_resource_id: String,
    /// Target resource id.
    pub target_resource_id: String,
    /// Relation name.
    pub relation: String,
    /// Link metadata.
    pub metadata: Value,
    /// Trace id.
    pub trace_id: TraceId,
    /// Invocation that creates the link.
    pub invocation_id: Option<InvocationId>,
}

/// Resource list filters.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ListResources {
    /// Optional resource kind filter.
    pub kind: Option<String>,
    /// Optional scope filter.
    pub scope: Option<EngineResourceScope>,
    /// Optional lifecycle filter.
    pub lifecycle: Option<String>,
    /// Maximum result count.
    pub limit: usize,
}

/// Full inspect payload for one resource.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResourceInspection {
    /// Resource metadata.
    pub resource: EngineResource,
    /// Version history in creation order.
    pub versions: Vec<EngineResourceVersion>,
    /// Links from this resource.
    pub outgoing_links: Vec<EngineResourceLink>,
    /// Links to this resource.
    pub incoming_links: Vec<EngineResourceLink>,
    /// Resource events in creation order.
    pub events: Vec<EngineResourceEvent>,
}
