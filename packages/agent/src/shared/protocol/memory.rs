//! Source-backed memory contract DTOs.
//!
//! This module describes the minimal engine-owned memory record, policy,
//! prompt-trace, retrieval-audit query, decision, eval, and migration shapes.
//! It deliberately does not define a retrieval algorithm, embedding/index
//! format, summarizer, procedural rule runtime, or automatic prompt-retention
//! behavior.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Schema version carried by memory contract payloads.
pub const MEMORY_SCHEMA_VERSION: &str = "tron.memory.v1";
/// Built-in deterministic engine id for the minimal resource-backed engine.
pub const RESOURCE_BACKED_MEMORY_ENGINE_ID: &str = "resource-backed-local";

/// Memory engine execution mode.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryMode {
    /// Memory writes and prompt inclusion are disabled.
    Disabled,
    /// The selected engine may retain records and can be considered for prompt inclusion.
    Active,
    /// The selected engine may observe/retain for audit without prompt inclusion.
    Shadow,
    /// Multiple engines can be compared without changing prompt inclusion.
    Compare,
}

impl MemoryMode {
    /// Wire string used in resource lifecycle/policy payloads.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Active => "active",
            Self::Shadow => "shadow",
            Self::Compare => "compare",
        }
    }
}

impl std::str::FromStr for MemoryMode {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "disabled" => Ok(Self::Disabled),
            "active" => Ok(Self::Active),
            "shadow" => Ok(Self::Shadow),
            "compare" => Ok(Self::Compare),
            other => Err(format!("unsupported memory mode {other}")),
        }
    }
}

impl Default for MemoryMode {
    fn default() -> Self {
        Self::Disabled
    }
}

/// Portable reference to a versioned engine resource.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryResourceRef {
    /// Resource kind.
    pub kind: String,
    /// Resource id.
    pub resource_id: String,
    /// Current or relevant resource version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_id: Option<String>,
    /// Ref role in the surrounding decision.
    pub role: String,
}

/// Memory engine descriptor stored as a `memory_engine` resource.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryEngineDescriptor {
    /// Memory schema version.
    pub schema_version: String,
    /// Stable engine id used in policies and traces.
    pub engine_id: String,
    /// Human-readable engine label for inspection surfaces.
    pub label: String,
    /// Engine descriptor version.
    pub version: String,
    /// Package or implementation provenance for the engine.
    pub package_provenance: Value,
    /// Memory modes supported by this engine.
    pub supported_modes: Vec<MemoryMode>,
    /// Storage substrates the engine can use.
    pub supported_stores: Vec<String>,
    /// Privacy guarantees exposed by the engine.
    pub privacy_features: Value,
    /// Import/export support metadata.
    pub migration_support: Value,
    /// Eval profile required before relying on the engine for richer behavior.
    pub eval_profile: Value,
    /// Engine lifecycle/status string.
    pub status: String,
}

/// Memory policy/engine-selection resource payload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryPolicyRecord {
    /// Memory schema version.
    pub schema_version: String,
    /// Current engine-selection mode.
    pub mode: MemoryMode,
    /// Active engine id, absent when memory is disabled.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_engine_id: Option<String>,
    /// Engine ids observed in compare mode.
    #[serde(default)]
    pub compare_engine_ids: Vec<String>,
    /// Prompt inclusion policy metadata.
    pub inclusion: Value,
    /// Retention policy metadata.
    pub retention: Value,
    /// Privacy policy metadata.
    pub privacy: Value,
    /// Migration policy metadata.
    pub migration: Value,
    /// Policy provenance metadata.
    pub provenance: Value,
    /// Monotonic policy revision.
    pub revision: u64,
}

impl MemoryPolicyRecord {
    /// Default policy: explicit disabled memory, no prompt inclusion.
    #[must_use]
    pub fn disabled_default() -> Self {
        Self {
            schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
            mode: MemoryMode::Disabled,
            active_engine_id: None,
            compare_engine_ids: Vec::new(),
            inclusion: serde_json::json!({
                "promptInclusion": "disabled",
                "reason": "memory_policy_missing_default_disabled"
            }),
            retention: serde_json::json!({"defaultRetention": "none"}),
            privacy: serde_json::json!({"defaultSensitivity": "unspecified"}),
            migration: serde_json::json!({"exportImport": "supported_by_contract"}),
            provenance: serde_json::json!({"source": "implicit_default"}),
            revision: 0,
        }
    }
}

/// Canonical retained memory record payload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryRecord {
    /// Memory schema version.
    pub schema_version: String,
    /// Subject or key this memory describes.
    pub subject: String,
    /// Scope described by the record payload.
    pub scope: Value,
    /// Redacted preview safe for audit surfaces.
    pub preview: String,
    /// Pointer to private body material. The contract stores refs, not hidden prompt text.
    pub body_ref: Value,
    /// Origin and custody metadata for the record.
    pub provenance: Value,
    /// Confidence metadata for the record.
    pub confidence: Value,
    /// Sensitivity classification.
    pub sensitivity: String,
    /// Retention policy metadata.
    pub retention: Value,
    /// Optional expiration time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    /// Source resource/message refs.
    #[serde(default)]
    pub source_refs: Vec<Value>,
    /// Trace refs proving where the record came from.
    #[serde(default)]
    pub trace_refs: Vec<Value>,
    /// Replay refs for deterministic reconstruction.
    #[serde(default)]
    pub replay_refs: Vec<Value>,
    /// Lifecycle metadata for the current payload.
    pub lifecycle: Value,
    /// Migration metadata.
    pub migration: Value,
    /// Monotonic record revision.
    pub revision: u64,
}

/// Prompt inclusion decision for one memory ref.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryPromptDecision {
    /// Resource ref considered by the prompt inclusion pass.
    pub resource_ref: MemoryResourceRef,
    /// Reason the ref was included or excluded.
    pub reason: String,
    /// Additional decision metadata.
    #[serde(default)]
    pub metadata: Value,
}

/// Prompt inclusion trace stored as a `memory_prompt_trace` resource.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryPromptTrace {
    /// Memory schema version.
    pub schema_version: String,
    /// Mode observed for this prompt trace.
    pub mode: MemoryMode,
    /// Engine id observed for this prompt trace.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub engine_id: Option<String>,
    /// Memory refs considered for the prompt.
    #[serde(default)]
    pub considered: Vec<MemoryPromptDecision>,
    /// Memory refs included in the prompt.
    #[serde(default)]
    pub included: Vec<MemoryPromptDecision>,
    /// Memory refs excluded from the prompt.
    #[serde(default)]
    pub excluded: Vec<MemoryPromptDecision>,
    /// Prompt budget metadata.
    pub prompt_budget: Value,
    /// Redaction guarantees for this trace.
    pub redaction: Value,
    /// Trace refs for the prompt trace operation.
    pub trace_refs: Vec<Value>,
    /// Replay refs for deterministic reconstruction.
    pub replay_refs: Vec<Value>,
    /// Trace creation time.
    pub created_at: DateTime<Utc>,
}

/// Metadata-only query evidence for future memory retrieval engines.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryQueryEvidence {
    /// Memory schema version.
    pub schema_version: String,
    /// Query family, such as `semantic_candidate_query` or `episodic_trace_query`.
    pub query_kind: String,
    /// Bounded intent metadata; never raw prompt, provider payload, or private body text.
    pub intent: Value,
    /// Bounded filter metadata used to choose candidate refs.
    pub filters: Value,
    /// Engine id observed for this query evidence.
    pub engine_id: String,
    /// Memory mode observed for this query evidence.
    pub mode: MemoryMode,
    /// Candidate refs selected by this audit pass.
    #[serde(default)]
    pub selected_refs: Vec<MemoryResourceRef>,
    /// Candidate refs explicitly excluded by this audit pass.
    #[serde(default)]
    pub excluded_refs: Vec<MemoryResourceRef>,
    /// Decision refs linked to this query evidence.
    #[serde(default)]
    pub decision_refs: Vec<MemoryResourceRef>,
    /// Redaction guarantees for this query evidence.
    pub redaction: Value,
    /// Trace refs proving where the evidence came from.
    pub trace_refs: Vec<Value>,
    /// Replay refs for deterministic reconstruction.
    pub replay_refs: Vec<Value>,
    /// Lifecycle metadata for this evidence record.
    pub lifecycle: Value,
    /// Fingerprinted idempotency evidence; never raw idempotency keys.
    pub idempotency: Value,
    /// Evidence creation time.
    pub occurred_at: DateTime<Utc>,
}

/// Metadata-only decision evidence for memory retain/retrieve/redact actions.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryDecisionEvidence {
    /// Memory schema version.
    pub schema_version: String,
    /// Decision family, such as `retrieve`, `retain`, `redact`, or `reject`.
    pub decision_kind: String,
    /// Bounded reason codes explaining the decision.
    #[serde(default)]
    pub reason_codes: Vec<String>,
    /// Optional subject ref affected by this decision.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject_ref: Option<MemoryResourceRef>,
    /// Optional query ref that this decision supports.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query_ref: Option<MemoryResourceRef>,
    /// Bounded source refs. These are refs only, never raw event or prompt payloads.
    #[serde(default)]
    pub source_refs: Vec<Value>,
    /// Redaction guarantees for this decision evidence.
    pub redaction: Value,
    /// Trace refs proving where the evidence came from.
    pub trace_refs: Vec<Value>,
    /// Replay refs for deterministic reconstruction.
    pub replay_refs: Vec<Value>,
    /// Lifecycle metadata for this evidence record.
    pub lifecycle: Value,
    /// Fingerprinted idempotency evidence; never raw idempotency keys.
    pub idempotency: Value,
    /// Evidence creation time.
    pub occurred_at: DateTime<Utc>,
}

/// Eval-run result contract for future memory engines.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryEvalRun {
    /// Memory schema version.
    pub schema_version: String,
    /// Engine evaluated by this run.
    pub engine_id: String,
    /// Dataset provenance metadata.
    pub dataset_provenance: Value,
    /// Eval scores.
    pub scores: Value,
    /// Eval outcome string.
    pub outcome: String,
    /// Findings produced by the run.
    pub findings: Vec<Value>,
    /// Eval run creation time.
    pub created_at: DateTime<Utc>,
}

/// Portable migration/export/import envelope.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryMigrationEnvelope {
    /// Memory schema version.
    pub schema_version: String,
    /// Migration operation, usually `export` or `import`.
    pub operation: String,
    /// Source engine id.
    pub source_engine_id: String,
    /// Optional target engine id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_engine_id: Option<String>,
    /// Portable redacted record payloads.
    pub records: Vec<Value>,
    /// Index metadata; `none` for this slice.
    pub index_metadata: Value,
    /// Migration lineage metadata.
    pub lineage: Value,
    /// Validation metadata for the envelope.
    pub validation: Value,
    /// Envelope creation time.
    pub created_at: DateTime<Utc>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_policy_is_explicit_and_has_no_engine() {
        let policy = MemoryPolicyRecord::disabled_default();
        assert_eq!(policy.mode, MemoryMode::Disabled);
        assert!(policy.active_engine_id.is_none());
        assert_eq!(
            policy.inclusion["reason"],
            "memory_policy_missing_default_disabled"
        );
    }

    #[test]
    fn memory_mode_wire_strings_round_trip() {
        for (mode, wire) in [
            (MemoryMode::Disabled, "disabled"),
            (MemoryMode::Active, "active"),
            (MemoryMode::Shadow, "shadow"),
            (MemoryMode::Compare, "compare"),
        ] {
            assert_eq!(mode.as_str(), wire);
            assert_eq!(wire.parse::<MemoryMode>().unwrap(), mode);
        }
    }
}
