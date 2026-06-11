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
