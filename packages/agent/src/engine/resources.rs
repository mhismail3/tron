//! Generic engine resource kernel.
//!
//! Resources are the collapsed durable object model for the modular engine.
//! Artifacts, goals, claims, evidence, decisions, UI surfaces, worker packages,
//! and materialized files all become typed resources with versioned payloads,
//! links, lifecycle state, policy, provenance, and auditable events. Streams,
//! indexes, and control-plane summaries are projections over this store.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, Row, params, types::Type};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::errors::{EngineError, Result};
use super::ids::{ActorId, FunctionId, InvocationId, TraceId, WorkerId};
use super::schema;

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

    fn parse(kind: &str, value: String) -> Result<Self> {
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
    fn as_str(&self) -> &'static str {
        match self {
            Self::AppendOnly => "append_only",
            Self::CurrentPointer => "current_pointer",
        }
    }

    fn parse(value: &str) -> Result<Self> {
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
    fn as_str(&self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Quarantined => "quarantined",
            Self::Damaged => "damaged",
            Self::Discarded => "discarded",
        }
    }

    fn parse(value: &str) -> Result<Self> {
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

    fn may_be_current(&self) -> bool {
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

/// Built-in resource kinds for the collapsed modular substrate.
#[must_use]
pub fn builtin_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        builtin_type(
            "artifact",
            "tron.resource.artifact.v1",
            json!({
                "type": "object",
                "required": ["title", "body"],
                "additionalProperties": true,
                "properties": {
                    "title": {"type": "string"},
                    "body": {},
                    "format": {"type": "string"},
                    "summary": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "promoted", "discarded", "archived"],
            vec![
                "input",
                "produced",
                "candidate_output",
                "promoted_output",
                "supported_by",
                "contradicted_by",
                "supports",
                "supersedes",
                "evidence_for",
                "derived_from",
                "part_of",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "promote": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "goal",
            "tron.resource.goal.v1",
            json!({
                "type": "object",
                "required": ["intent"],
                "additionalProperties": true,
                "properties": {
                    "intent": {"type": "string"},
                    "successCriteria": {"type": "array", "items": {"type": "string"}},
                    "inputResources": {"type": "array", "items": {"type": "string"}},
                    "expectedOutputKinds": {"type": "array", "items": {"type": "string"}},
                    "constraints": {"type": "object"},
                    "riskBudget": {"type": "object"},
                    "approvalPolicy": {"type": "object"},
                    "retentionPolicy": {"type": "object"},
                    "completionCondition": {"type": "string"}
                }
            }),
            vec!["open", "in_progress", "completed", "failed", "archived"],
            vec![
                "input",
                "subgoal",
                "produced",
                "produces",
                "candidate_output",
                "promoted_output",
                "decided_by",
                "supported_by",
                "contradicted_by",
                "supersedes",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "complete": ["resource.write"]}),
        ),
        builtin_type(
            "decision",
            "tron.resource.decision.v1",
            json!({
                "type": "object",
                "required": ["status", "summary"],
                "additionalProperties": true,
                "properties": {
                    "status": {"type": "string"},
                    "summary": {"type": "string"},
                    "promotedResources": {"type": "array", "items": {"type": "string"}},
                    "discardedResources": {"type": "array", "items": {"type": "string"}},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "final", "archived"],
            vec![
                "decides",
                "promotes",
                "discards",
                "supports",
                "supported_by",
                "contradicted_by",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "claim",
            "tron.resource.claim.v1",
            json!({
                "type": "object",
                "required": ["statement"],
                "additionalProperties": true,
                "properties": {
                    "statement": {"type": "string"},
                    "confidence": {"type": "number"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec![
                "claims_about",
                "supported_by",
                "contradicted_by",
                "contradicts",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "evidence",
            "tron.resource.evidence.v1",
            json!({
                "type": "object",
                "required": ["summary"],
                "additionalProperties": true,
                "properties": {
                    "summary": {"type": "string"},
                    "source": {"type": "string"},
                    "resourceRef": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec![
                "evidence_for",
                "supported_by",
                "contradicted_by",
                "derived_from",
                "supports",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "materialized_file",
            "tron.resource.materialized_file.v1",
            json!({
                "type": "object",
                "required": ["canonicalPath", "relativePath", "entryType", "contentHash", "sizeBytes"],
                "additionalProperties": true,
                "properties": {
                    "canonicalPath": {"type": "string"},
                    "relativePath": {"type": "string"},
                    "entryType": {"type": "string", "enum": ["file", "directory"]},
                    "content": {"type": "string"},
                    "contentHash": {"type": "string"},
                    "sizeBytes": {"type": "integer"},
                    "mimeType": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "draft",
                "materialized",
                "promoted",
                "discarded",
                "damaged",
                "quarantined",
                "archived",
            ],
            vec![
                "applies_patch",
                "derived_from",
                "materializes",
                "produced",
                "promoted_output",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "promote": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "patch_proposal",
            "tron.resource.patch_proposal.v1",
            json!({
                "type": "object",
                "required": ["targetPath", "diff", "status"],
                "additionalProperties": true,
                "properties": {
                    "targetPath": {"type": "string"},
                    "targetResourceId": {"type": "string"},
                    "baseVersionId": {"type": "string"},
                    "baseContentHash": {"type": "string"},
                    "diff": {"type": "string"},
                    "status": {"type": "string"},
                    "result": {"type": "object"}
                }
            }),
            vec![
                "proposed",
                "applied",
                "merged",
                "rejected",
                "discarded",
                "archived",
            ],
            vec![
                "applies_to",
                "produces",
                "produced",
                "derived_from",
                "promoted_output",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "apply": ["resource.write"]}),
        ),
        builtin_type(
            "execution_output",
            "tron.resource.execution_output.v1",
            json!({
                "type": "object",
                "required": ["exitCode", "durationMs", "timedOut", "outputTruncated"],
                "additionalProperties": true,
                "properties": {
                    "stdoutPreview": {"type": "string"},
                    "stderrPreview": {"type": "string"},
                    "logPreview": {"type": "string"},
                    "exitCode": {"type": "integer"},
                    "durationMs": {"type": "integer"},
                    "timedOut": {"type": "boolean"},
                    "outputTruncated": {"type": "boolean"},
                    "redactionPolicy": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["retained", "discarded", "archived"],
            vec!["produced_by", "produced", "derived_from"],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "agent_result",
            "tron.resource.agent_result.v1",
            json!({
                "type": "object",
                "required": ["message", "stopReason"],
                "additionalProperties": true,
                "properties": {
                    "message": {"type": "string"},
                    "promotedRefs": {"type": "array"},
                    "decisionRefs": {"type": "array"},
                    "subgoalRefs": {"type": "array"},
                    "stopReason": {"type": "string"},
                    "tokenUsage": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["final", "interrupted", "discarded", "archived"],
            vec![
                "answers",
                "decides",
                "promotes",
                "supports",
                "produced",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
    ]
}

/// In-memory resource store.
#[derive(Default)]
pub struct InMemoryEngineResourceStore {
    type_definitions: BTreeMap<String, EngineResourceTypeDefinition>,
    resources: BTreeMap<String, EngineResource>,
    versions: BTreeMap<String, EngineResourceVersion>,
    versions_by_resource: BTreeMap<String, Vec<String>>,
    links: BTreeMap<String, EngineResourceLink>,
    events_by_resource: BTreeMap<String, Vec<EngineResourceEvent>>,
}

impl InMemoryEngineResourceStore {
    /// Create an empty resource store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Register or update one resource type definition.
    pub fn register_type(
        &mut self,
        request: RegisterResourceType,
    ) -> Result<EngineResourceTypeDefinition> {
        validate_type_request(&request)?;
        let now = Utc::now();
        let revision = self
            .type_definitions
            .get(&request.kind)
            .map_or(1, |definition| definition.revision.saturating_add(1));
        let created_at = self
            .type_definitions
            .get(&request.kind)
            .map_or(now, |definition| definition.created_at);
        let definition = type_definition_from_request(request, revision, created_at, now);
        self.type_definitions
            .insert(definition.kind.clone(), definition.clone());
        Ok(definition)
    }

    /// Read one resource type definition.
    pub fn get_type(&self, kind: &str) -> Result<Option<EngineResourceTypeDefinition>> {
        validate_token("resource kind", kind)?;
        Ok(self.type_definitions.get(kind).cloned())
    }

    /// List registered resource type definitions.
    pub fn list_types(&self) -> Result<Vec<EngineResourceTypeDefinition>> {
        Ok(self.type_definitions.values().cloned().collect())
    }

    /// Create a resource.
    pub fn create(&mut self, request: CreateResource) -> Result<EngineResource> {
        validate_create_request(&request)?;
        let type_definition = self.require_type(&request.kind)?;
        let lifecycle = request
            .lifecycle
            .clone()
            .unwrap_or_else(|| type_definition.lifecycle_states[0].clone());
        ensure_lifecycle(&type_definition, &lifecycle)?;
        let schema_id = request
            .schema_id
            .clone()
            .unwrap_or_else(|| type_definition.schema_id.clone());
        if schema_id != type_definition.schema_id {
            return Err(EngineError::PolicyViolation(format!(
                "resource kind {} requires schema {}",
                request.kind, type_definition.schema_id
            )));
        }
        if let Some(payload) = &request.initial_payload {
            validate_resource_payload(&type_definition, payload)?;
        }
        let now = Utc::now();
        let resource_id = request
            .resource_id
            .clone()
            .unwrap_or_else(|| generated_id("res"));
        if self.resources.contains_key(&resource_id) {
            return Err(EngineError::PolicyViolation(format!(
                "resource {resource_id} already exists"
            )));
        }
        let mut resource = EngineResource {
            resource_id: resource_id.clone(),
            kind: request.kind.clone(),
            schema_id,
            scope: request.scope.clone(),
            owner_worker_id: request.owner_worker_id.clone(),
            owner_actor_id: request.owner_actor_id.clone(),
            lifecycle,
            policy: request.policy.clone(),
            current_version_id: None,
            trace_id: request.trace_id.clone(),
            created_by_invocation_id: request.invocation_id.clone(),
            created_at: now,
            updated_at: now,
        };
        self.resources.insert(resource_id.clone(), resource.clone());
        self.record_event(resource_event(
            &resource_id,
            "resource.created",
            json!({"kind": resource.kind, "lifecycle": resource.lifecycle}),
            request.invocation_id.clone(),
            request.trace_id.clone(),
        ));
        if let Some(payload) = request.initial_payload {
            let version = self.append_version_inner(
                &resource_id,
                None,
                None,
                payload,
                EngineResourceVersionState::Available,
                request.locations,
                request.trace_id,
                request.invocation_id,
            )?;
            resource.current_version_id = Some(version.version_id);
            resource.updated_at = Utc::now();
            self.resources.insert(resource_id, resource.clone());
        }
        Ok(resource)
    }

    /// Update one resource through compare-and-set.
    pub fn update(&mut self, request: UpdateResource) -> Result<EngineResourceVersion> {
        validate_update_request(&request)?;
        let resource = self.require_resource(&request.resource_id)?;
        let definition = self.require_type(&resource.kind)?;
        if let Some(lifecycle) = &request.lifecycle {
            ensure_lifecycle(&definition, lifecycle)?;
        }
        if resource.current_version_id != request.expected_current_version_id {
            return Err(EngineError::PolicyViolation(format!(
                "resource {} version conflict: expected {:?}, actual {:?}",
                request.resource_id,
                request.expected_current_version_id,
                resource.current_version_id
            )));
        }
        validate_resource_payload(&definition, &request.payload)?;
        self.append_version_inner(
            &request.resource_id,
            resource.current_version_id,
            request.lifecycle,
            request.payload,
            request.state.unwrap_or_default(),
            request.locations,
            request.trace_id,
            request.invocation_id,
        )
    }

    /// Link two resources.
    pub fn link(&mut self, request: LinkResources) -> Result<EngineResourceLink> {
        validate_link_request(&request)?;
        let source = self.require_resource(&request.source_resource_id)?;
        let _target = self.require_resource(&request.target_resource_id)?;
        let definition = self.require_type(&source.kind)?;
        ensure_relation(&definition, &request.relation)?;
        let link = EngineResourceLink {
            link_id: generated_id("link"),
            source_resource_id: request.source_resource_id,
            target_resource_id: request.target_resource_id,
            relation: request.relation,
            metadata: request.metadata,
            created_by_invocation_id: request.invocation_id.clone(),
            trace_id: request.trace_id.clone(),
            created_at: Utc::now(),
        };
        self.links.insert(link.link_id.clone(), link.clone());
        self.record_event(resource_event(
            &link.source_resource_id,
            "resource.linked",
            json!({
                "targetResourceId": link.target_resource_id,
                "relation": link.relation,
            }),
            request.invocation_id,
            request.trace_id,
        ));
        Ok(link)
    }

    /// Inspect one resource.
    pub fn inspect(&self, resource_id: &str) -> Result<Option<EngineResourceInspection>> {
        validate_token("resource id", resource_id)?;
        let Some(resource) = self.resources.get(resource_id).cloned() else {
            return Ok(None);
        };
        Ok(Some(EngineResourceInspection {
            versions: self
                .versions_by_resource
                .get(resource_id)
                .into_iter()
                .flatten()
                .filter_map(|version_id| self.versions.get(version_id))
                .cloned()
                .collect(),
            outgoing_links: self
                .links
                .values()
                .filter(|link| link.source_resource_id == resource_id)
                .cloned()
                .collect(),
            incoming_links: self
                .links
                .values()
                .filter(|link| link.target_resource_id == resource_id)
                .cloned()
                .collect(),
            events: self
                .events_by_resource
                .get(resource_id)
                .cloned()
                .unwrap_or_default(),
            resource,
        }))
    }

    /// List resources.
    pub fn list(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        validate_list_filter(&filter)?;
        let mut resources = self
            .resources
            .values()
            .filter(|resource| {
                filter
                    .kind
                    .as_ref()
                    .is_none_or(|kind| &resource.kind == kind)
                    && filter
                        .scope
                        .as_ref()
                        .is_none_or(|scope| &resource.scope == scope)
                    && filter
                        .lifecycle
                        .as_ref()
                        .is_none_or(|lifecycle| &resource.lifecycle == lifecycle)
            })
            .cloned()
            .collect::<Vec<_>>();
        resources.sort_by_key(|resource| resource.updated_at);
        resources.reverse();
        resources.truncate(filter.limit.min(500));
        Ok(resources)
    }

    fn append_version_inner(
        &mut self,
        resource_id: &str,
        parent_version_id: Option<String>,
        lifecycle: Option<String>,
        payload: Value,
        state: EngineResourceVersionState,
        locations: Vec<EngineResourceLocation>,
        trace_id: TraceId,
        invocation_id: Option<InvocationId>,
    ) -> Result<EngineResourceVersion> {
        let mut resource = self.require_resource(resource_id)?;
        let version = EngineResourceVersion {
            version_id: generated_id("ver"),
            resource_id: resource_id.to_owned(),
            parent_version_id,
            content_hash: payload_hash(&payload)?,
            state,
            payload,
            locations,
            created_by_invocation_id: invocation_id.clone(),
            trace_id: trace_id.clone(),
            created_at: Utc::now(),
        };
        self.versions
            .insert(version.version_id.clone(), version.clone());
        self.versions_by_resource
            .entry(resource_id.to_owned())
            .or_default()
            .push(version.version_id.clone());
        if version.state.may_be_current() {
            resource.current_version_id = Some(version.version_id.clone());
        }
        if let Some(lifecycle) = lifecycle {
            resource.lifecycle = lifecycle;
        }
        resource.updated_at = Utc::now();
        self.resources.insert(resource_id.to_owned(), resource);
        self.record_event(resource_event(
            resource_id,
            "resource.version.created",
            json!({
                "versionId": version.version_id,
                "contentHash": version.content_hash,
                "state": version.state.as_str(),
            }),
            invocation_id,
            trace_id,
        ));
        Ok(version)
    }

    fn require_type(&self, kind: &str) -> Result<EngineResourceTypeDefinition> {
        self.get_type(kind)?.ok_or_else(|| EngineError::NotFound {
            kind: "resource_type",
            id: kind.to_owned(),
        })
    }

    fn require_resource(&self, resource_id: &str) -> Result<EngineResource> {
        self.resources
            .get(resource_id)
            .cloned()
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: resource_id.to_owned(),
            })
    }

    fn record_event(&mut self, event: EngineResourceEvent) {
        self.events_by_resource
            .entry(event.resource_id.clone())
            .or_default()
            .push(event);
    }
}

/// SQLite-backed resource store.
pub struct SqliteEngineResourceStore {
    conn: Connection,
}

impl SqliteEngineResourceStore {
    /// Open a resource store in the engine ledger database.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("resource.open", err.to_string()))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_resource_type_definitions (
  kind TEXT PRIMARY KEY,
  schema_id TEXT NOT NULL,
  schema_json TEXT NOT NULL,
  lifecycle_states_json TEXT NOT NULL,
  versioning_mode TEXT NOT NULL,
  allowed_link_relations_json TEXT NOT NULL,
  default_retention_json TEXT NOT NULL,
  redaction_rules_json TEXT NOT NULL,
  materialization_rules_json TEXT NOT NULL,
  required_capabilities_json TEXT NOT NULL,
  owner_worker_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS engine_resources (
  resource_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  schema_id TEXT NOT NULL,
  scope_kind TEXT NOT NULL,
  scope_value TEXT NOT NULL,
  owner_worker_id TEXT NOT NULL,
  owner_actor_id TEXT NOT NULL,
  lifecycle TEXT NOT NULL,
  policy_json TEXT NOT NULL,
  current_version_id TEXT,
  trace_id TEXT NOT NULL,
  created_by_invocation_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(kind) REFERENCES engine_resource_type_definitions(kind)
);
CREATE INDEX IF NOT EXISTS idx_engine_resources_kind_scope
  ON engine_resources(kind, scope_kind, scope_value, lifecycle, updated_at);
CREATE TABLE IF NOT EXISTS engine_resource_versions (
  version_id TEXT PRIMARY KEY,
  resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  parent_version_id TEXT,
  content_hash TEXT NOT NULL,
  version_state TEXT NOT NULL DEFAULT 'available',
  payload_json TEXT NOT NULL,
  locations_json TEXT NOT NULL,
  created_by_invocation_id TEXT,
  trace_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_engine_resource_versions_resource
  ON engine_resource_versions(resource_id, created_at);
CREATE TABLE IF NOT EXISTS engine_resource_links (
  link_id TEXT PRIMARY KEY,
  source_resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  target_resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  relation TEXT NOT NULL,
  metadata_json TEXT NOT NULL,
  created_by_invocation_id TEXT,
  trace_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_engine_resource_links_source
  ON engine_resource_links(source_resource_id, relation);
CREATE INDEX IF NOT EXISTS idx_engine_resource_links_target
  ON engine_resource_links(target_resource_id, relation);
CREATE TABLE IF NOT EXISTS engine_resource_events (
  event_id TEXT PRIMARY KEY,
  resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  invocation_id TEXT,
  trace_id TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_engine_resource_events_resource
  ON engine_resource_events(resource_id, occurred_at);
"#,
            )
            .map_err(|err| sqlite_err("resource.init", err.to_string()))
    }

    /// Register or update one resource type definition.
    pub fn register_type(
        &mut self,
        request: RegisterResourceType,
    ) -> Result<EngineResourceTypeDefinition> {
        validate_type_request(&request)?;
        let now = Utc::now();
        let existing = self.get_type(&request.kind)?;
        let revision = existing
            .as_ref()
            .map_or(1, |definition| definition.revision.saturating_add(1));
        let created_at = existing
            .as_ref()
            .map_or(now, |definition| definition.created_at);
        let definition = type_definition_from_request(request, revision, created_at, now);
        self.conn
            .execute(
                "INSERT INTO engine_resource_type_definitions
                 (kind, schema_id, schema_json, lifecycle_states_json, versioning_mode,
                  allowed_link_relations_json, default_retention_json, redaction_rules_json,
                  materialization_rules_json, required_capabilities_json, owner_worker_id,
                  revision, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                 ON CONFLICT(kind) DO UPDATE SET
                   schema_id = excluded.schema_id,
                   schema_json = excluded.schema_json,
                   lifecycle_states_json = excluded.lifecycle_states_json,
                   versioning_mode = excluded.versioning_mode,
                   allowed_link_relations_json = excluded.allowed_link_relations_json,
                   default_retention_json = excluded.default_retention_json,
                   redaction_rules_json = excluded.redaction_rules_json,
                   materialization_rules_json = excluded.materialization_rules_json,
                   required_capabilities_json = excluded.required_capabilities_json,
                   owner_worker_id = excluded.owner_worker_id,
                   revision = excluded.revision,
                   updated_at = excluded.updated_at",
                params![
                    definition.kind,
                    definition.schema_id,
                    json_string(&definition.schema, "type.schema")?,
                    json_string(&definition.lifecycle_states, "type.lifecycle_states")?,
                    definition.versioning_mode.as_str(),
                    json_string(
                        &definition.allowed_link_relations,
                        "type.allowed_link_relations"
                    )?,
                    json_string(&definition.default_retention, "type.default_retention")?,
                    json_string(&definition.redaction_rules, "type.redaction_rules")?,
                    json_string(
                        &definition.materialization_rules,
                        "type.materialization_rules"
                    )?,
                    json_string(
                        &definition.required_capabilities,
                        "type.required_capabilities"
                    )?,
                    definition.owner_worker_id.as_str(),
                    definition.revision,
                    definition.created_at.to_rfc3339(),
                    definition.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.register_type", err.to_string()))?;
        Ok(definition)
    }

    /// Read one resource type definition.
    pub fn get_type(&self, kind: &str) -> Result<Option<EngineResourceTypeDefinition>> {
        validate_token("resource kind", kind)?;
        self.conn
            .query_row(
                "SELECT kind, schema_id, schema_json, lifecycle_states_json, versioning_mode,
                        allowed_link_relations_json, default_retention_json, redaction_rules_json,
                        materialization_rules_json, required_capabilities_json, owner_worker_id,
                        revision, created_at, updated_at
                 FROM engine_resource_type_definitions WHERE kind = ?1",
                params![kind],
                row_to_type_definition,
            )
            .optional()
            .map_err(|err| sqlite_err("resource.get_type", err.to_string()))
    }

    /// List registered resource type definitions.
    pub fn list_types(&self) -> Result<Vec<EngineResourceTypeDefinition>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT kind, schema_id, schema_json, lifecycle_states_json, versioning_mode,
                        allowed_link_relations_json, default_retention_json, redaction_rules_json,
                        materialization_rules_json, required_capabilities_json, owner_worker_id,
                        revision, created_at, updated_at
                 FROM engine_resource_type_definitions ORDER BY kind",
            )
            .map_err(|err| sqlite_err("resource.list_types.prepare", err.to_string()))?;
        let rows = stmt
            .query_map([], row_to_type_definition)
            .map_err(|err| sqlite_err("resource.list_types", err.to_string()))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|err| sqlite_err("resource.list_types.row", err.to_string()))
    }

    /// Create a resource.
    pub fn create(&mut self, request: CreateResource) -> Result<EngineResource> {
        validate_create_request(&request)?;
        let type_definition = self.require_type(&request.kind)?;
        let lifecycle = request
            .lifecycle
            .clone()
            .unwrap_or_else(|| type_definition.lifecycle_states[0].clone());
        ensure_lifecycle(&type_definition, &lifecycle)?;
        let schema_id = request
            .schema_id
            .clone()
            .unwrap_or_else(|| type_definition.schema_id.clone());
        if schema_id != type_definition.schema_id {
            return Err(EngineError::PolicyViolation(format!(
                "resource kind {} requires schema {}",
                request.kind, type_definition.schema_id
            )));
        }
        let resource_id = request
            .resource_id
            .clone()
            .unwrap_or_else(|| generated_id("res"));
        let exists = self
            .conn
            .query_row(
                "SELECT 1 FROM engine_resources WHERE resource_id = ?1",
                params![resource_id],
                |_row| Ok(()),
            )
            .optional()
            .map_err(|err| sqlite_err("resource.exists", err.to_string()))?
            .is_some();
        if exists {
            return Err(EngineError::PolicyViolation(format!(
                "resource {resource_id} already exists"
            )));
        }
        if let Some(payload) = &request.initial_payload {
            validate_resource_payload(&type_definition, payload)?;
        }
        let now = Utc::now();
        let mut resource = EngineResource {
            resource_id: resource_id.clone(),
            kind: request.kind.clone(),
            schema_id,
            scope: request.scope.clone(),
            owner_worker_id: request.owner_worker_id.clone(),
            owner_actor_id: request.owner_actor_id.clone(),
            lifecycle,
            policy: request.policy.clone(),
            current_version_id: None,
            trace_id: request.trace_id.clone(),
            created_by_invocation_id: request.invocation_id.clone(),
            created_at: now,
            updated_at: now,
        };
        self.insert_resource(&resource)?;
        self.record_event(resource_event(
            &resource_id,
            "resource.created",
            json!({"kind": resource.kind, "lifecycle": resource.lifecycle}),
            request.invocation_id.clone(),
            request.trace_id.clone(),
        ))?;
        if let Some(payload) = request.initial_payload {
            let version = self.append_version_inner(
                &resource_id,
                None,
                None,
                payload,
                EngineResourceVersionState::Available,
                request.locations,
                request.trace_id,
                request.invocation_id,
            )?;
            resource.current_version_id = Some(version.version_id);
            resource.updated_at = Utc::now();
            self.update_resource_pointer(&resource)?;
        }
        Ok(resource)
    }

    /// Update one resource through compare-and-set.
    pub fn update(&mut self, request: UpdateResource) -> Result<EngineResourceVersion> {
        validate_update_request(&request)?;
        let resource = self.require_resource(&request.resource_id)?;
        let definition = self.require_type(&resource.kind)?;
        if let Some(lifecycle) = &request.lifecycle {
            ensure_lifecycle(&definition, lifecycle)?;
        }
        if resource.current_version_id != request.expected_current_version_id {
            return Err(EngineError::PolicyViolation(format!(
                "resource {} version conflict: expected {:?}, actual {:?}",
                request.resource_id,
                request.expected_current_version_id,
                resource.current_version_id
            )));
        }
        validate_resource_payload(&definition, &request.payload)?;
        self.append_version_inner(
            &request.resource_id,
            resource.current_version_id,
            request.lifecycle,
            request.payload,
            request.state.unwrap_or_default(),
            request.locations,
            request.trace_id,
            request.invocation_id,
        )
    }

    /// Link two resources.
    pub fn link(&mut self, request: LinkResources) -> Result<EngineResourceLink> {
        validate_link_request(&request)?;
        let source = self.require_resource(&request.source_resource_id)?;
        let _target = self.require_resource(&request.target_resource_id)?;
        let definition = self.require_type(&source.kind)?;
        ensure_relation(&definition, &request.relation)?;
        let link = EngineResourceLink {
            link_id: generated_id("link"),
            source_resource_id: request.source_resource_id,
            target_resource_id: request.target_resource_id,
            relation: request.relation,
            metadata: request.metadata,
            created_by_invocation_id: request.invocation_id.clone(),
            trace_id: request.trace_id.clone(),
            created_at: Utc::now(),
        };
        self.conn
            .execute(
                "INSERT INTO engine_resource_links
                 (link_id, source_resource_id, target_resource_id, relation, metadata_json,
                  created_by_invocation_id, trace_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    link.link_id,
                    link.source_resource_id,
                    link.target_resource_id,
                    link.relation,
                    json_string(&link.metadata, "resource_link.metadata")?,
                    link.created_by_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    link.trace_id.as_str(),
                    link.created_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.link", err.to_string()))?;
        self.record_event(resource_event(
            &link.source_resource_id,
            "resource.linked",
            json!({
                "targetResourceId": link.target_resource_id,
                "relation": link.relation,
            }),
            request.invocation_id,
            request.trace_id,
        ))?;
        Ok(link)
    }

    /// Inspect one resource.
    pub fn inspect(&self, resource_id: &str) -> Result<Option<EngineResourceInspection>> {
        validate_token("resource id", resource_id)?;
        let Some(resource) = self.get_resource(resource_id)? else {
            return Ok(None);
        };
        Ok(Some(EngineResourceInspection {
            versions: self.versions_for_resource(resource_id)?,
            outgoing_links: self.links_for_source(resource_id)?,
            incoming_links: self.links_for_target(resource_id)?,
            events: self.events_for_resource(resource_id)?,
            resource,
        }))
    }

    /// List resources.
    pub fn list(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        validate_list_filter(&filter)?;
        let mut resources = Vec::new();
        let mut stmt = self
            .conn
            .prepare(
                "SELECT resource_id, kind, schema_id, scope_kind, scope_value, owner_worker_id,
                        owner_actor_id, lifecycle, policy_json, current_version_id, trace_id,
                        created_by_invocation_id, created_at, updated_at
                 FROM engine_resources
                 ORDER BY updated_at DESC",
            )
            .map_err(|err| sqlite_err("resource.list.prepare", err.to_string()))?;
        let rows = stmt
            .query_map([], row_to_resource)
            .map_err(|err| sqlite_err("resource.list.query", err.to_string()))?;
        for row in rows {
            let resource = row.map_err(|err| sqlite_err("resource.list.row", err.to_string()))?;
            if filter
                .kind
                .as_ref()
                .is_none_or(|kind| &resource.kind == kind)
                && filter
                    .scope
                    .as_ref()
                    .is_none_or(|scope| &resource.scope == scope)
                && filter
                    .lifecycle
                    .as_ref()
                    .is_none_or(|lifecycle| &resource.lifecycle == lifecycle)
            {
                resources.push(resource);
                if resources.len() >= filter.limit.min(500) {
                    break;
                }
            }
        }
        Ok(resources)
    }

    fn append_version_inner(
        &mut self,
        resource_id: &str,
        parent_version_id: Option<String>,
        lifecycle: Option<String>,
        payload: Value,
        state: EngineResourceVersionState,
        locations: Vec<EngineResourceLocation>,
        trace_id: TraceId,
        invocation_id: Option<InvocationId>,
    ) -> Result<EngineResourceVersion> {
        let mut resource = self.require_resource(resource_id)?;
        let version = EngineResourceVersion {
            version_id: generated_id("ver"),
            resource_id: resource_id.to_owned(),
            parent_version_id,
            content_hash: payload_hash(&payload)?,
            state,
            payload,
            locations,
            created_by_invocation_id: invocation_id.clone(),
            trace_id: trace_id.clone(),
            created_at: Utc::now(),
        };
        let owner_id = format!("resource_version:{}", version.version_id);
        let payload_json = crate::shared::storage::store_json_value(
            &self.conn,
            &version.payload,
            &crate::shared::storage::StorePayloadOptions::new(
                "engine_resource_version",
                owner_id,
                "payload",
                "correctness",
            )
            .with_scope(
                Some(trace_id.as_str().to_owned()),
                None,
                resource_scope_workspace(&resource.scope).map(str::to_owned),
            ),
        )
        .map_err(|err| sqlite_err("resource.version.payload", err.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO engine_resource_versions
                 (version_id, resource_id, parent_version_id, content_hash, version_state,
                  payload_json, locations_json, created_by_invocation_id, trace_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    version.version_id,
                    version.resource_id,
                    version.parent_version_id,
                    version.content_hash,
                    version.state.as_str(),
                    payload_json,
                    json_string(&version.locations, "resource_version.locations")?,
                    version
                        .created_by_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    version.trace_id.as_str(),
                    version.created_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.version.insert", err.to_string()))?;
        if version.state.may_be_current() {
            resource.current_version_id = Some(version.version_id.clone());
        }
        if let Some(lifecycle) = lifecycle {
            resource.lifecycle = lifecycle;
        }
        resource.updated_at = Utc::now();
        self.update_resource_pointer(&resource)?;
        self.record_event(resource_event(
            resource_id,
            "resource.version.created",
            json!({
                "versionId": version.version_id,
                "contentHash": version.content_hash,
                "state": version.state.as_str(),
            }),
            invocation_id,
            trace_id,
        ))?;
        Ok(version)
    }

    fn insert_resource(&self, resource: &EngineResource) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_resources
                 (resource_id, kind, schema_id, scope_kind, scope_value, owner_worker_id,
                  owner_actor_id, lifecycle, policy_json, current_version_id, trace_id,
                  created_by_invocation_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    resource.resource_id,
                    resource.kind,
                    resource.schema_id,
                    resource.scope.kind(),
                    resource.scope.value(),
                    resource.owner_worker_id.as_str(),
                    resource.owner_actor_id.as_str(),
                    resource.lifecycle,
                    json_string(&resource.policy, "resource.policy")?,
                    resource.current_version_id,
                    resource.trace_id.as_str(),
                    resource
                        .created_by_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    resource.created_at.to_rfc3339(),
                    resource.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.insert", err.to_string()))?;
        Ok(())
    }

    fn update_resource_pointer(&self, resource: &EngineResource) -> Result<()> {
        self.conn
            .execute(
                "UPDATE engine_resources
                 SET lifecycle = ?2, policy_json = ?3, current_version_id = ?4, updated_at = ?5
                 WHERE resource_id = ?1",
                params![
                    resource.resource_id,
                    resource.lifecycle,
                    json_string(&resource.policy, "resource.policy")?,
                    resource.current_version_id,
                    resource.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.pointer", err.to_string()))?;
        Ok(())
    }

    fn get_resource(&self, resource_id: &str) -> Result<Option<EngineResource>> {
        self.conn
            .query_row(
                "SELECT resource_id, kind, schema_id, scope_kind, scope_value, owner_worker_id,
                        owner_actor_id, lifecycle, policy_json, current_version_id, trace_id,
                        created_by_invocation_id, created_at, updated_at
                 FROM engine_resources WHERE resource_id = ?1",
                params![resource_id],
                row_to_resource,
            )
            .optional()
            .map_err(|err| sqlite_err("resource.get", err.to_string()))
    }

    fn require_type(&self, kind: &str) -> Result<EngineResourceTypeDefinition> {
        self.get_type(kind)?.ok_or_else(|| EngineError::NotFound {
            kind: "resource_type",
            id: kind.to_owned(),
        })
    }

    fn require_resource(&self, resource_id: &str) -> Result<EngineResource> {
        self.get_resource(resource_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: resource_id.to_owned(),
            })
    }

    fn versions_for_resource(&self, resource_id: &str) -> Result<Vec<EngineResourceVersion>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT version_id, resource_id, parent_version_id, content_hash, version_state,
                        payload_json, locations_json, created_by_invocation_id, trace_id, created_at
                 FROM engine_resource_versions WHERE resource_id = ?1 ORDER BY created_at ASC",
            )
            .map_err(|err| sqlite_err("resource.versions.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![resource_id], |row| {
                row_to_resource_version(&self.conn, row)
            })
            .map_err(|err| sqlite_err("resource.versions.query", err.to_string()))?;
        collect_rows(rows, "resource.versions.row")
    }

    fn links_for_source(&self, resource_id: &str) -> Result<Vec<EngineResourceLink>> {
        self.links_with_query(
            "SELECT link_id, source_resource_id, target_resource_id, relation, metadata_json,
                    created_by_invocation_id, trace_id, created_at
             FROM engine_resource_links WHERE source_resource_id = ?1 ORDER BY created_at ASC",
            resource_id,
            "resource.links.source",
        )
    }

    fn links_for_target(&self, resource_id: &str) -> Result<Vec<EngineResourceLink>> {
        self.links_with_query(
            "SELECT link_id, source_resource_id, target_resource_id, relation, metadata_json,
                    created_by_invocation_id, trace_id, created_at
             FROM engine_resource_links WHERE target_resource_id = ?1 ORDER BY created_at ASC",
            resource_id,
            "resource.links.target",
        )
    }

    fn links_with_query(
        &self,
        sql: &str,
        resource_id: &str,
        operation: &'static str,
    ) -> Result<Vec<EngineResourceLink>> {
        let mut stmt = self
            .conn
            .prepare(sql)
            .map_err(|err| sqlite_err(operation, err.to_string()))?;
        let rows = stmt
            .query_map(params![resource_id], row_to_resource_link)
            .map_err(|err| sqlite_err(operation, err.to_string()))?;
        collect_rows(rows, operation)
    }

    fn events_for_resource(&self, resource_id: &str) -> Result<Vec<EngineResourceEvent>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT event_id, resource_id, event_type, payload_json, invocation_id, trace_id,
                        occurred_at
                 FROM engine_resource_events WHERE resource_id = ?1 ORDER BY occurred_at ASC",
            )
            .map_err(|err| sqlite_err("resource.events.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![resource_id], row_to_resource_event)
            .map_err(|err| sqlite_err("resource.events.query", err.to_string()))?;
        collect_rows(rows, "resource.events.row")
    }

    fn record_event(&self, event: EngineResourceEvent) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_resource_events
                 (event_id, resource_id, event_type, payload_json, invocation_id, trace_id,
                  occurred_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    event.event_id,
                    event.resource_id,
                    event.event_type,
                    json_string(&event.payload, "resource_event.payload")?,
                    event.invocation_id.as_ref().map(InvocationId::as_str),
                    event.trace_id.as_str(),
                    event.occurred_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.event", err.to_string()))?;
        Ok(())
    }
}

fn type_definition_from_request(
    request: RegisterResourceType,
    revision: u64,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
) -> EngineResourceTypeDefinition {
    EngineResourceTypeDefinition {
        kind: request.kind,
        schema_id: request.schema_id,
        schema: request.schema,
        lifecycle_states: request.lifecycle_states,
        versioning_mode: request.versioning_mode,
        allowed_link_relations: request.allowed_link_relations,
        default_retention: request.default_retention,
        redaction_rules: request.redaction_rules,
        materialization_rules: request.materialization_rules,
        required_capabilities: request.required_capabilities,
        owner_worker_id: request.owner_worker_id,
        revision,
        created_at,
        updated_at,
    }
}

fn builtin_type(
    kind: &str,
    schema_id: &str,
    schema: Value,
    lifecycle_states: Vec<&str>,
    allowed_link_relations: Vec<&str>,
    required_capabilities: Value,
) -> RegisterResourceType {
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema,
        lifecycle_states: lifecycle_states.into_iter().map(str::to_owned).collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: allowed_link_relations
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({"preview": "metadata_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities,
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}

fn resource_event(
    resource_id: &str,
    event_type: &str,
    payload: Value,
    invocation_id: Option<InvocationId>,
    trace_id: TraceId,
) -> EngineResourceEvent {
    EngineResourceEvent {
        event_id: generated_id("revt"),
        resource_id: resource_id.to_owned(),
        event_type: event_type.to_owned(),
        payload,
        invocation_id,
        trace_id,
        occurred_at: Utc::now(),
    }
}

fn validate_type_request(request: &RegisterResourceType) -> Result<()> {
    validate_token("resource kind", &request.kind)?;
    validate_token("schema id", &request.schema_id)?;
    if request.lifecycle_states.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "resource kind {} must declare lifecycle states",
            request.kind
        )));
    }
    for state in &request.lifecycle_states {
        validate_token("lifecycle state", state)?;
    }
    for relation in &request.allowed_link_relations {
        validate_token("link relation", relation)?;
    }
    schema::validate_schema_definition(&resource_function_id(), "resource", &request.schema)?;
    Ok(())
}

fn validate_create_request(request: &CreateResource) -> Result<()> {
    validate_token("resource kind", &request.kind)?;
    if let Some(resource_id) = &request.resource_id {
        validate_token("resource id", resource_id)?;
    }
    if let Some(schema_id) = &request.schema_id {
        validate_token("schema id", schema_id)?;
    }
    if let Some(lifecycle) = &request.lifecycle {
        validate_token("lifecycle state", lifecycle)?;
    }
    validate_locations(&request.locations)
}

fn validate_update_request(request: &UpdateResource) -> Result<()> {
    validate_token("resource id", &request.resource_id)?;
    if let Some(version_id) = &request.expected_current_version_id {
        validate_token("version id", version_id)?;
    }
    if let Some(lifecycle) = &request.lifecycle {
        validate_token("lifecycle state", lifecycle)?;
    }
    validate_locations(&request.locations)
}

fn validate_link_request(request: &LinkResources) -> Result<()> {
    validate_token("source resource id", &request.source_resource_id)?;
    validate_token("target resource id", &request.target_resource_id)?;
    validate_token("link relation", &request.relation)
}

fn validate_list_filter(filter: &ListResources) -> Result<()> {
    if filter.limit == 0 {
        return Err(EngineError::PolicyViolation(
            "resource list limit must be greater than zero".to_owned(),
        ));
    }
    if let Some(kind) = &filter.kind {
        validate_token("resource kind", kind)?;
    }
    if let Some(lifecycle) = &filter.lifecycle {
        validate_token("lifecycle state", lifecycle)?;
    }
    Ok(())
}

fn validate_locations(locations: &[EngineResourceLocation]) -> Result<()> {
    for location in locations {
        validate_token("location kind", &location.kind)?;
        if location.uri.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "resource location uri must not be empty".to_owned(),
            ));
        }
    }
    Ok(())
}

fn validate_token(label: &str, value: &str) -> Result<()> {
    if value.trim().is_empty()
        || value.len() > 256
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | ':' | '.' | '/'))
    {
        return Err(EngineError::PolicyViolation(format!(
            "invalid {label} {value:?}"
        )));
    }
    Ok(())
}

fn ensure_lifecycle(definition: &EngineResourceTypeDefinition, lifecycle: &str) -> Result<()> {
    if definition
        .lifecycle_states
        .iter()
        .any(|state| state == lifecycle)
    {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource kind {} does not allow lifecycle {lifecycle}",
            definition.kind
        )))
    }
}

fn ensure_relation(definition: &EngineResourceTypeDefinition, relation: &str) -> Result<()> {
    if definition
        .allowed_link_relations
        .iter()
        .any(|allowed| allowed == "*" || allowed == relation)
    {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource kind {} does not allow relation {relation}",
            definition.kind
        )))
    }
}

fn validate_resource_payload(
    definition: &EngineResourceTypeDefinition,
    payload: &Value,
) -> Result<()> {
    schema::validate_payload(
        &resource_function_id(),
        "resource_payload",
        &definition.schema,
        payload,
    )
}

fn generated_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::now_v7())
}

fn resource_function_id() -> FunctionId {
    FunctionId::new("resource::payload").expect("valid static resource function id")
}

fn payload_hash(payload: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(payload).map_err(|error| EngineError::LedgerFailure {
        operation: "resource.payload_hash",
        message: error.to_string(),
    })?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

fn json_string<T: Serialize>(value: &T, operation: &'static str) -> Result<String> {
    serde_json::to_string(value).map_err(|error| EngineError::LedgerFailure {
        operation,
        message: error.to_string(),
    })
}

fn sqlite_err(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}

fn collect_rows<T>(
    rows: rusqlite::MappedRows<'_, impl FnMut(&Row<'_>) -> rusqlite::Result<T>>,
    operation: &'static str,
) -> Result<Vec<T>> {
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|err| sqlite_err(operation, err.to_string()))?);
    }
    Ok(values)
}

fn resource_scope_workspace(scope: &EngineResourceScope) -> Option<&str> {
    match scope {
        EngineResourceScope::Workspace(value) => Some(value.as_str()),
        EngineResourceScope::System | EngineResourceScope::Session(_) => None,
    }
}

fn row_to_type_definition(row: &Row<'_>) -> rusqlite::Result<EngineResourceTypeDefinition> {
    let versioning_mode_raw: String = row.get(4)?;
    Ok(EngineResourceTypeDefinition {
        kind: row.get(0)?,
        schema_id: row.get(1)?,
        schema: row_json(row, 2, "resource_type.schema")?,
        lifecycle_states: row_json(row, 3, "resource_type.lifecycle_states")?,
        versioning_mode: EngineResourceVersioningMode::parse(&versioning_mode_raw)
            .map_err(|err| row_engine_err(4, err))?,
        allowed_link_relations: row_json(row, 5, "resource_type.allowed_link_relations")?,
        default_retention: row_json(row, 6, "resource_type.default_retention")?,
        redaction_rules: row_json(row, 7, "resource_type.redaction_rules")?,
        materialization_rules: row_json(row, 8, "resource_type.materialization_rules")?,
        required_capabilities: row_json(row, 9, "resource_type.required_capabilities")?,
        owner_worker_id: WorkerId::new(row.get::<_, String>(10)?)
            .map_err(|err| row_engine_err(10, err))?,
        revision: row.get(11)?,
        created_at: row_time(row, 12, "resource_type.created_at")?,
        updated_at: row_time(row, 13, "resource_type.updated_at")?,
    })
}

fn row_to_resource(row: &Row<'_>) -> rusqlite::Result<EngineResource> {
    let scope_kind: String = row.get(3)?;
    let scope_value: String = row.get(4)?;
    Ok(EngineResource {
        resource_id: row.get(0)?,
        kind: row.get(1)?,
        schema_id: row.get(2)?,
        scope: EngineResourceScope::parse(&scope_kind, scope_value)
            .map_err(|err| row_engine_err(3, err))?,
        owner_worker_id: WorkerId::new(row.get::<_, String>(5)?)
            .map_err(|err| row_engine_err(5, err))?,
        owner_actor_id: ActorId::new(row.get::<_, String>(6)?)
            .map_err(|err| row_engine_err(6, err))?,
        lifecycle: row.get(7)?,
        policy: row_json(row, 8, "resource.policy")?,
        current_version_id: row.get(9)?,
        trace_id: TraceId::new(row.get::<_, String>(10)?).map_err(|err| row_engine_err(10, err))?,
        created_by_invocation_id: row_invocation_id(row, 11)?,
        created_at: row_time(row, 12, "resource.created_at")?,
        updated_at: row_time(row, 13, "resource.updated_at")?,
    })
}

fn row_to_resource_version(
    conn: &Connection,
    row: &Row<'_>,
) -> rusqlite::Result<EngineResourceVersion> {
    let payload_json: String = row.get(5)?;
    let payload = crate::shared::storage::resolve_stored_json_value(conn, &payload_json).map_err(
        |error| row_engine_err(5, sqlite_err("resource_version.payload", error.to_string())),
    )?;
    Ok(EngineResourceVersion {
        version_id: row.get(0)?,
        resource_id: row.get(1)?,
        parent_version_id: row.get(2)?,
        content_hash: row.get(3)?,
        state: EngineResourceVersionState::parse(&row.get::<_, String>(4)?)
            .map_err(|err| row_engine_err(4, err))?,
        payload,
        locations: row_json(row, 6, "resource_version.locations")?,
        created_by_invocation_id: row_invocation_id(row, 7)?,
        trace_id: TraceId::new(row.get::<_, String>(8)?).map_err(|err| row_engine_err(8, err))?,
        created_at: row_time(row, 9, "resource_version.created_at")?,
    })
}

fn row_to_resource_link(row: &Row<'_>) -> rusqlite::Result<EngineResourceLink> {
    Ok(EngineResourceLink {
        link_id: row.get(0)?,
        source_resource_id: row.get(1)?,
        target_resource_id: row.get(2)?,
        relation: row.get(3)?,
        metadata: row_json(row, 4, "resource_link.metadata")?,
        created_by_invocation_id: row_invocation_id(row, 5)?,
        trace_id: TraceId::new(row.get::<_, String>(6)?).map_err(|err| row_engine_err(6, err))?,
        created_at: row_time(row, 7, "resource_link.created_at")?,
    })
}

fn row_to_resource_event(row: &Row<'_>) -> rusqlite::Result<EngineResourceEvent> {
    Ok(EngineResourceEvent {
        event_id: row.get(0)?,
        resource_id: row.get(1)?,
        event_type: row.get(2)?,
        payload: row_json(row, 3, "resource_event.payload")?,
        invocation_id: row_invocation_id(row, 4)?,
        trace_id: TraceId::new(row.get::<_, String>(5)?).map_err(|err| row_engine_err(5, err))?,
        occurred_at: row_time(row, 6, "resource_event.occurred_at")?,
    })
}

fn row_json<T: for<'de> Deserialize<'de>>(
    row: &Row<'_>,
    idx: usize,
    operation: &'static str,
) -> rusqlite::Result<T> {
    let value: String = row.get(idx)?;
    serde_json::from_str(&value).map_err(|error| {
        row_engine_err(
            idx,
            EngineError::LedgerFailure {
                operation,
                message: error.to_string(),
            },
        )
    })
}

fn row_time(row: &Row<'_>, idx: usize, operation: &'static str) -> rusqlite::Result<DateTime<Utc>> {
    let value: String = row.get(idx)?;
    DateTime::parse_from_rfc3339(&value)
        .map(|time| time.with_timezone(&Utc))
        .map_err(|error| {
            row_engine_err(
                idx,
                EngineError::LedgerFailure {
                    operation,
                    message: error.to_string(),
                },
            )
        })
}

fn row_invocation_id(row: &Row<'_>, idx: usize) -> rusqlite::Result<Option<InvocationId>> {
    let value: Option<String> = row.get(idx)?;
    value
        .map(InvocationId::new)
        .transpose()
        .map_err(|err| row_engine_err(idx, err))
}

fn row_engine_err(idx: usize, error: EngineError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(idx, Type::Text, Box::new(error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn worker(value: &str) -> WorkerId {
        WorkerId::new(value).unwrap()
    }

    fn actor(value: &str) -> ActorId {
        ActorId::new(value).unwrap()
    }

    fn trace(value: &str) -> TraceId {
        TraceId::new(value).unwrap()
    }

    fn artifact_type() -> RegisterResourceType {
        RegisterResourceType {
            kind: "artifact".to_owned(),
            schema_id: "artifact.v1".to_owned(),
            schema: json!({"type": "object"}),
            lifecycle_states: vec![
                "draft".to_owned(),
                "promoted".to_owned(),
                "discarded".to_owned(),
            ],
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: vec!["supports".to_owned(), "supersedes".to_owned()],
            default_retention: json!({"class": "durable"}),
            redaction_rules: json!({"preview": "safe"}),
            materialization_rules: json!({"allowed": ["blob", "file"]}),
            required_capabilities: json!({
                "read": "resource::inspect",
                "write": "resource::update"
            }),
            owner_worker_id: worker("resource"),
        }
    }

    fn create_artifact(id: &str) -> CreateResource {
        CreateResource {
            resource_id: Some(id.to_owned()),
            kind: "artifact".to_owned(),
            schema_id: None,
            scope: EngineResourceScope::Workspace("workspace-1".to_owned()),
            owner_worker_id: worker("resource"),
            owner_actor_id: actor("actor"),
            lifecycle: Some("draft".to_owned()),
            policy: json!({"retention": "durable"}),
            initial_payload: Some(json!({"title": id, "body": "first"})),
            locations: vec![EngineResourceLocation {
                kind: "blob".to_owned(),
                uri: format!("blob://{id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: Some(16),
            }],
            trace_id: trace("trace"),
            invocation_id: None,
        }
    }

    #[test]
    fn in_memory_resources_are_versioned_and_inspectable() {
        let mut store = InMemoryEngineResourceStore::new();
        let definition = store.register_type(artifact_type()).unwrap();
        assert_eq!(definition.revision, 1);

        let resource = store.create(create_artifact("res_test")).unwrap();
        let current = resource.current_version_id.clone().unwrap();
        let version = store
            .update(UpdateResource {
                resource_id: "res_test".to_owned(),
                expected_current_version_id: Some(current.clone()),
                lifecycle: Some("promoted".to_owned()),
                payload: json!({"title": "res_test", "body": "second"}),
                state: None,
                locations: Vec::new(),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap();

        assert_eq!(version.parent_version_id.as_deref(), Some(current.as_str()));
        let inspection = store.inspect("res_test").unwrap().unwrap();
        assert_eq!(inspection.resource.lifecycle, "promoted");
        assert_eq!(inspection.versions.len(), 2);
        assert_eq!(inspection.events.len(), 3);
    }

    #[test]
    fn compare_and_set_rejects_stale_resource_updates() {
        let mut store = InMemoryEngineResourceStore::new();
        store.register_type(artifact_type()).unwrap();
        let resource = store.create(create_artifact("res_test")).unwrap();
        let current = resource.current_version_id.unwrap();
        store
            .update(UpdateResource {
                resource_id: "res_test".to_owned(),
                expected_current_version_id: Some(current),
                lifecycle: None,
                payload: json!({"body": "second"}),
                state: None,
                locations: Vec::new(),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap();

        let err = store
            .update(UpdateResource {
                resource_id: "res_test".to_owned(),
                expected_current_version_id: Some("stale".to_owned()),
                lifecycle: None,
                payload: json!({"body": "third"}),
                state: None,
                locations: Vec::new(),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap_err();
        assert!(matches!(err, EngineError::PolicyViolation(_)));
    }

    #[test]
    fn non_available_versions_do_not_advance_current_pointer() {
        let mut store = InMemoryEngineResourceStore::new();
        store.register_type(artifact_type()).unwrap();
        let resource = store.create(create_artifact("res_test")).unwrap();
        let current = resource.current_version_id.clone();
        let damaged = store
            .update(UpdateResource {
                resource_id: "res_test".to_owned(),
                expected_current_version_id: current.clone(),
                lifecycle: Some("draft".to_owned()),
                payload: json!({"title": "res_test", "body": "damaged"}),
                state: Some(EngineResourceVersionState::Damaged),
                locations: Vec::new(),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap();
        assert_eq!(damaged.state, EngineResourceVersionState::Damaged);
        let inspection = store.inspect("res_test").unwrap().unwrap();
        assert_eq!(inspection.resource.current_version_id, current);
        assert_eq!(inspection.versions.len(), 2);
    }

    #[test]
    fn resource_payloads_must_match_registered_schema_before_persisting() {
        let mut strict_type = artifact_type();
        strict_type.schema = json!({
            "type": "object",
            "required": ["title", "body"],
            "additionalProperties": false,
            "properties": {
                "title": {"type": "string"},
                "body": {"type": "string"}
            }
        });
        let mut store = InMemoryEngineResourceStore::new();
        store.register_type(strict_type).unwrap();

        let mut invalid_create = create_artifact("res_invalid");
        invalid_create.initial_payload = Some(json!({"title": "missing body"}));
        let err = store.create(invalid_create).unwrap_err();
        assert!(matches!(err, EngineError::SchemaViolation { .. }));
        assert!(store.inspect("res_invalid").unwrap().is_none());

        let resource = store.create(create_artifact("res_valid")).unwrap();
        let err = store
            .update(UpdateResource {
                resource_id: "res_valid".to_owned(),
                expected_current_version_id: resource.current_version_id,
                lifecycle: None,
                payload: json!({"title": "missing body"}),
                state: None,
                locations: Vec::new(),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap_err();
        assert!(matches!(err, EngineError::SchemaViolation { .. }));
        let inspection = store.inspect("res_valid").unwrap().unwrap();
        assert_eq!(inspection.versions.len(), 1);
    }

    #[test]
    fn links_must_use_declared_relations() {
        let mut store = InMemoryEngineResourceStore::new();
        store.register_type(artifact_type()).unwrap();
        store.create(create_artifact("res_source")).unwrap();
        store.create(create_artifact("res_target")).unwrap();

        let link = store
            .link(LinkResources {
                source_resource_id: "res_source".to_owned(),
                target_resource_id: "res_target".to_owned(),
                relation: "supports".to_owned(),
                metadata: json!({}),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap();
        assert_eq!(link.relation, "supports");

        let err = store
            .link(LinkResources {
                source_resource_id: "res_source".to_owned(),
                target_resource_id: "res_target".to_owned(),
                relation: "unknown".to_owned(),
                metadata: json!({}),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap_err();
        assert!(matches!(err, EngineError::PolicyViolation(_)));
    }

    #[test]
    fn sqlite_resource_store_round_trips_full_substrate() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("resources.sqlite");
        let mut store = SqliteEngineResourceStore::open(&path).unwrap();
        store.register_type(artifact_type()).unwrap();
        let resource = store.create(create_artifact("res_test")).unwrap();
        let current = resource.current_version_id.clone().unwrap();
        store
            .update(UpdateResource {
                resource_id: "res_test".to_owned(),
                expected_current_version_id: Some(current),
                lifecycle: Some("promoted".to_owned()),
                payload: json!({"title": "res_test", "body": "second"}),
                state: None,
                locations: Vec::new(),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap();
        store
            .link(LinkResources {
                source_resource_id: "res_test".to_owned(),
                target_resource_id: "res_test".to_owned(),
                relation: "supersedes".to_owned(),
                metadata: json!({"self": true}),
                trace_id: trace("trace"),
                invocation_id: None,
            })
            .unwrap();
        drop(store);

        let store = SqliteEngineResourceStore::open(&path).unwrap();
        let inspection = store.inspect("res_test").unwrap().unwrap();
        assert_eq!(inspection.resource.lifecycle, "promoted");
        assert_eq!(inspection.versions.len(), 2);
        assert_eq!(inspection.outgoing_links.len(), 1);
        assert_eq!(inspection.events.len(), 4);
    }

    #[test]
    fn resource_list_is_filtered_by_kind_scope_and_lifecycle() {
        let mut store = InMemoryEngineResourceStore::new();
        store.register_type(artifact_type()).unwrap();
        store.create(create_artifact("res_a")).unwrap();
        store.create(create_artifact("res_b")).unwrap();

        let resources = store
            .list(ListResources {
                kind: Some("artifact".to_owned()),
                scope: Some(EngineResourceScope::Workspace("workspace-1".to_owned())),
                lifecycle: Some("draft".to_owned()),
                limit: 10,
            })
            .unwrap();
        assert_eq!(resources.len(), 2);
    }
}
