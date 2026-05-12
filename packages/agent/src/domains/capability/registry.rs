//! Registry, binding, and local search projection for live capabilities.
//!
//! The registry is deliberately layered over the engine catalog. The catalog is
//! still the source of truth for live functions, health, visibility, authority,
//! and invocation; this module gives the capability primitives a stable
//! contract/implementation vocabulary plus a search index boundary.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

use super::types::{
    CapabilityBindingDecision, CapabilityBindingRecord, CapabilityContractRecord,
    CapabilityImplementationRecord, CapabilityIndexHit, CapabilityIndexStatus,
    CapabilityInspectionHandle, CapabilityInspectionRecord,
};
use crate::engine::{
    ActorContext, EffectClass, FunctionDefinition, FunctionHealth, FunctionQuery, RiskLevel,
};

const TRUST_ORDER: &[&str] = &[
    "first_party_signed",
    "trusted_signed",
    "user_installed",
    "session_generated",
    "external_mcp",
    "external_openapi",
    "untrusted",
];

const CORE_CONTEXT_CAPABILITIES: &[&str] = &[
    "capability::search",
    "capability::inspect",
    "capability::execute",
    "filesystem::list_dir",
    "filesystem::read_file",
    "filesystem::write_file",
    "filesystem::edit_file",
    "filesystem::find",
    "filesystem::glob",
    "filesystem::search_text",
    "filesystem::diff",
    "filesystem::apply_patch",
    "process::run",
    "web::search",
    "web::fetch",
    "agent::status",
    "agent::submit_answers",
    "sandbox::spawn_worker",
    "sandbox::list_spawned_workers",
    "sandbox::stop_spawned_worker",
    "worker::protocol_guide",
];

/// Profile-controlled search policy.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct CapabilitySearchPolicy {
    pub(crate) lexical: bool,
    pub(crate) local_vector: bool,
    pub(crate) cloud_embeddings: bool,
    pub(crate) max_results: usize,
}

impl Default for CapabilitySearchPolicy {
    fn default() -> Self {
        Self {
            lexical: true,
            local_vector: true,
            cloud_embeddings: false,
            max_results: 50,
        }
    }
}

/// Profile-controlled context primer policy.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct CapabilityContextPrimerPolicy {
    pub(crate) enabled: bool,
    pub(crate) mode: String,
    pub(crate) max_tokens: usize,
    pub(crate) include_examples: bool,
    pub(crate) include_compact_schemas: bool,
}

impl Default for CapabilityContextPrimerPolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            mode: "coreFirstParty".to_owned(),
            max_tokens: 1800,
            include_examples: true,
            include_compact_schemas: true,
        }
    }
}

/// Filters accepted by `capability::search`.
#[derive(Clone, Debug, Default)]
pub(crate) struct CapabilitySearchFilters {
    pub(crate) kind: Option<String>,
    pub(crate) contract_id: Option<String>,
    pub(crate) namespace: Option<String>,
    pub(crate) plugin_id: Option<String>,
    pub(crate) effect: Option<EffectClass>,
    pub(crate) risk_max: Option<RiskLevel>,
    pub(crate) trust_tier_min: Option<String>,
    pub(crate) include_unavailable: bool,
    pub(crate) scope: Option<String>,
}

impl CapabilitySearchFilters {
    pub(crate) fn function_query(&self, actor: ActorContext) -> FunctionQuery {
        FunctionQuery {
            actor: Some(actor),
            namespace_prefix: self.namespace.clone(),
            effect_class: self.effect,
            max_risk: self.risk_max,
            health: if self.include_unavailable {
                None
            } else {
                Some(FunctionHealth::Healthy)
            },
            ..FunctionQuery::default()
        }
    }

    fn allows(&self, record: &CapabilityRegistryEntry) -> bool {
        if let Some(kind) = &self.kind
            && kind != "implementation"
            && kind != "function"
            && kind != "contract"
        {
            return false;
        }
        if let Some(contract_id) = &self.contract_id
            && record.contract_id != *contract_id
        {
            return false;
        }
        if let Some(plugin_id) = &self.plugin_id
            && record.plugin_id != *plugin_id
        {
            return false;
        }
        if let Some(scope) = &self.scope
            && record.visibility != *scope
        {
            return false;
        }
        if let Some(min) = &self.trust_tier_min
            && trust_rank(&record.trust_tier) > trust_rank(min)
        {
            return false;
        }
        true
    }
}

/// One catalog function projected into capability terms.
#[derive(Clone, Debug)]
pub(crate) struct CapabilityRegistryEntry {
    pub(crate) contract_id: String,
    pub(crate) implementation_id: String,
    pub(crate) plugin_id: String,
    pub(crate) worker_id: String,
    pub(crate) function_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) schema_digest: String,
    pub(crate) trust_tier: String,
    pub(crate) visibility: String,
    pub(crate) context_primer_level: String,
    pub(crate) search_text: String,
    pub(crate) function: FunctionDefinition,
}

impl CapabilityRegistryEntry {
    pub(crate) fn from_function(function: FunctionDefinition, catalog_revision: u64) -> Self {
        let contract_id = string_metadata(&function, "contractId")
            .or_else(|| string_metadata(&function, "capabilityContractId"))
            .unwrap_or_else(|| function.id.as_str().to_owned());
        let implementation_id = string_metadata(&function, "implementationId")
            .or_else(|| string_metadata(&function, "capabilityImplementationId"))
            .unwrap_or_else(|| default_implementation_id(&function));
        let plugin_id = string_metadata(&function, "pluginId")
            .or_else(|| {
                string_metadata(&function, "domainModule").map(|module| {
                    if module.starts_with("first_party.") || module.starts_with("external.") {
                        module
                    } else {
                        format!("first_party.{module}")
                    }
                })
            })
            .unwrap_or_else(|| default_plugin_id(&function));
        let trust_tier =
            string_metadata(&function, "trustTier").unwrap_or_else(|| trust_tier(&function));
        let context_primer_level = string_metadata(&function, "contextPrimerLevel")
            .unwrap_or_else(|| default_context_primer_level(&function, &trust_tier));
        let schema_digest = schema_digest(&function);
        let search_text = searchable_text(&function);
        Self {
            contract_id,
            implementation_id,
            plugin_id,
            worker_id: function.owner_worker.as_str().to_owned(),
            function_id: function.id.as_str().to_owned(),
            catalog_revision,
            schema_digest,
            trust_tier,
            visibility: function.visibility.as_str().to_owned(),
            context_primer_level,
            search_text,
            function,
        }
    }

    pub(crate) fn is_capability_primitive(&self) -> bool {
        is_capability_primitive(&self.function)
    }

    pub(crate) fn capability_id(&self) -> String {
        self.implementation_id.clone()
    }

    pub(crate) fn search_document(&self) -> CapabilityIndexDocument {
        CapabilityIndexDocument {
            capability_id: self.capability_id(),
            contract_id: self.contract_id.clone(),
            implementation_id: self.implementation_id.clone(),
            plugin_id: self.plugin_id.clone(),
            worker_id: self.worker_id.clone(),
            function_id: self.function_id.clone(),
            catalog_revision: self.catalog_revision,
            schema_digest: self.schema_digest.clone(),
            trust_tier: self.trust_tier.clone(),
            health: format!("{:?}", self.function.health),
            visibility: self.visibility.clone(),
            effect_class: effect_name(self.function.effect_class).to_owned(),
            risk_level: risk_name(self.function.risk_level).to_owned(),
            text: self.search_text.clone(),
        }
    }

    pub(crate) fn contract_record(&self) -> CapabilityContractRecord {
        CapabilityContractRecord {
            contract_id: self.contract_id.clone(),
            version: self.function.revision.0,
            display_name: display_name(&self.function),
            description: self.function.description.clone(),
            input_schema: self.function.request_schema.clone(),
            output_schema: self.function.response_schema.clone(),
            effect_class: effect_name(self.function.effect_class).to_owned(),
            risk_level: risk_name(self.function.risk_level).to_owned(),
            idempotency_contract: serde_json::to_value(&self.function.idempotency).ok(),
            approval_contract: json!({
                "approvalRequired": self.function.required_authority.approval_required
            }),
            lease_contract: serde_json::to_value(&self.function.resource_lease).ok(),
            compensation_contract: serde_json::to_value(&self.function.compensation).ok(),
            examples: examples(&self.function),
            semantic_tags: self.function.tags.clone(),
        }
    }

    pub(crate) fn implementation_record(&self) -> CapabilityImplementationRecord {
        CapabilityImplementationRecord {
            implementation_id: self.implementation_id.clone(),
            contract_id: self.contract_id.clone(),
            plugin_id: self.plugin_id.clone(),
            worker_id: self.worker_id.clone(),
            function_id: self.function_id.clone(),
            version: self.function.revision.0,
            health: format!("{:?}", self.function.health),
            visibility: self.visibility.clone(),
            latency_class: string_metadata(&self.function, "latencyClass")
                .unwrap_or_else(|| "unknown".to_owned()),
            cost_class: string_metadata(&self.function, "costClass")
                .unwrap_or_else(|| "unknown".to_owned()),
            trust_tier: self.trust_tier.clone(),
            authority_requirements: serde_json::to_value(&self.function.required_authority)
                .unwrap_or(Value::Null),
            runtime_requirements: runtime_requirements(&self.function),
            schema_digest: self.schema_digest.clone(),
            catalog_revision: self.catalog_revision,
            provenance: serde_json::to_value(&self.function.provenance).unwrap_or(Value::Null),
        }
    }

    pub(crate) fn inspection(
        &self,
        decision: CapabilityBindingDecision,
    ) -> CapabilityInspectionRecord {
        CapabilityInspectionRecord {
            contract: self.contract_record(),
            implementation: self.implementation_record(),
            binding: CapabilityBindingRecord {
                contract_id: self.contract_id.clone(),
                selected_implementation: self.implementation_id.clone(),
                selection_policy: decision.selection_policy.clone(),
                secondary_implementations: decision
                    .rejected_candidates
                    .iter()
                    .map(|candidate| candidate.implementation_id.clone())
                    .collect(),
                enabled: true,
            },
            binding_decision: decision,
            inspection_handle: self.inspection_handle(),
            execution_requirements: json!({
                "expectedRevision": self.function.revision.0,
                "freshInspectionRequired": requires_fresh_revision(&self.function),
                "idempotencyKeyRequired": self.function.effect_class.is_mutating(),
                "approvalRequired": self.function.required_authority.approval_required,
                "timeoutMs": self.function.metadata.pointer("/runtimeRequirements/timeoutMs").cloned().unwrap_or(Value::Null),
                "budget": self.function.metadata.pointer("/runtimeRequirements/budget").cloned().unwrap_or(Value::Null)
            }),
            docs: json!({
                "summary": self.function.description,
                "metadata": self.function.metadata,
                "contextPrimerLevel": self.context_primer_level
            }),
        }
    }

    pub(crate) fn inspection_handle(&self) -> CapabilityInspectionHandle {
        let material = json!({
            "contractId": self.contract_id,
            "implementationId": self.implementation_id,
            "functionId": self.function_id,
            "catalogRevision": self.catalog_revision,
            "functionRevision": self.function.revision.0,
            "schemaDigest": self.schema_digest,
        });
        let serialized = serde_json::to_vec(&material).unwrap_or_default();
        CapabilityInspectionHandle {
            handle: format!("capability-inspection:v1:{}", sha256_hex(&serialized)),
            catalog_revision: self.catalog_revision,
            function_revision: self.function.revision.0,
            schema_digest: self.schema_digest.clone(),
        }
    }
}

/// Stable registry snapshot for one catalog revision.
#[derive(Clone, Debug)]
pub(crate) struct CapabilityRegistrySnapshot {
    pub(crate) catalog_revision: u64,
    pub(crate) entries: Vec<CapabilityRegistryEntry>,
}

impl CapabilityRegistrySnapshot {
    pub(crate) fn new(functions: Vec<FunctionDefinition>, catalog_revision: u64) -> Self {
        let mut entries = functions
            .into_iter()
            .map(|function| CapabilityRegistryEntry::from_function(function, catalog_revision))
            .collect::<Vec<_>>();
        entries.sort_by(|a, b| a.function_id.cmp(&b.function_id));
        Self {
            catalog_revision,
            entries,
        }
    }

    pub(crate) fn filtered_documents(
        &self,
        filters: &CapabilitySearchFilters,
    ) -> Vec<CapabilityIndexDocument> {
        self.entries
            .iter()
            .filter(|entry| filters.allows(entry))
            .filter(|entry| !entry.is_capability_primitive())
            .map(CapabilityRegistryEntry::search_document)
            .collect()
    }

    pub(crate) fn find_candidates(
        &self,
        target: &CapabilityTarget,
    ) -> Vec<CapabilityRegistryEntry> {
        let mut candidates = self
            .entries
            .iter()
            .filter(|entry| target.matches(entry))
            .cloned()
            .collect::<Vec<_>>();
        candidates.sort_by(compare_candidates);
        candidates
    }

    pub(crate) fn visible_primer_entries(
        &self,
        policy: &CapabilityContextPrimerPolicy,
    ) -> Vec<CapabilityRegistryEntry> {
        if !policy.enabled {
            return Vec::new();
        }
        let all_visible = policy.mode == "allVisibleCompact";
        let mut entries = self
            .entries
            .iter()
            .filter(|entry| {
                all_visible
                    || entry.context_primer_level == "core"
                    || CORE_CONTEXT_CAPABILITIES.contains(&entry.function_id.as_str())
            })
            .cloned()
            .collect::<Vec<_>>();
        entries.sort_by(|a, b| {
            primer_rank(a)
                .cmp(&primer_rank(b))
                .then_with(|| a.function_id.cmp(&b.function_id))
        });
        entries
    }
}

/// Search index document.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityIndexDocument {
    pub(crate) capability_id: String,
    pub(crate) contract_id: String,
    pub(crate) implementation_id: String,
    pub(crate) plugin_id: String,
    pub(crate) worker_id: String,
    pub(crate) function_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) schema_digest: String,
    pub(crate) trust_tier: String,
    pub(crate) health: String,
    pub(crate) visibility: String,
    pub(crate) effect_class: String,
    pub(crate) risk_level: String,
    pub(crate) text: String,
}

/// Hybrid local index.
#[derive(Clone, Debug, Default)]
pub(crate) struct HybridLocalCapabilityIndex {
    policy: CapabilitySearchPolicy,
}

impl HybridLocalCapabilityIndex {
    pub(crate) fn new(policy: CapabilitySearchPolicy) -> Self {
        Self { policy }
    }

    pub(crate) fn search(
        &self,
        query: &str,
        documents: Vec<CapabilityIndexDocument>,
        limit: usize,
    ) -> CapabilityIndexSearchResult {
        let mut lexical_hits = lexical_rank(query, &documents);
        let mut status = CapabilityIndexStatus {
            lexical: self.policy.lexical,
            local_vector: self.policy.local_vector,
            cloud_embeddings: false,
            vector_store: "sqlite-vec:vec0".to_owned(),
            embedding_model: "fastembed:AllMiniLML6V2".to_owned(),
            state: "ready".to_owned(),
            degraded_reason: None,
        };

        if self.policy.local_vector && !query.trim().is_empty() && !documents.is_empty() {
            match vector_rank(query, &documents) {
                Ok(vector_hits) => {
                    lexical_hits = fuse_hits(lexical_hits, vector_hits, &documents);
                }
                Err(error) => {
                    status.state = "degraded".to_owned();
                    status.degraded_reason = Some(error);
                }
            }
        }

        lexical_hits.truncate(limit.min(self.policy.max_results.max(1)));
        CapabilityIndexSearchResult {
            hits: lexical_hits,
            status,
        }
    }
}

/// Search result from the local index.
#[derive(Clone, Debug)]
pub(crate) struct CapabilityIndexSearchResult {
    pub(crate) hits: Vec<CapabilityIndexHit>,
    pub(crate) status: CapabilityIndexStatus,
}

/// Target supplied to inspect/execute.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum CapabilityTarget {
    Function(String),
    Implementation(String),
    Contract(String),
    Capability(String),
}

impl CapabilityTarget {
    pub(crate) fn matches(&self, entry: &CapabilityRegistryEntry) -> bool {
        match self {
            Self::Function(id) => entry.function_id == *id,
            Self::Implementation(id) => {
                entry.implementation_id == *id
                    || id.strip_prefix("function:") == Some(entry.function_id.as_str())
                    || (id.contains("::") && entry.function_id == *id)
            }
            Self::Contract(id) => entry.contract_id == *id || entry.function_id == *id,
            Self::Capability(id) => {
                entry.contract_id == *id
                    || entry.implementation_id == *id
                    || entry.function_id == *id
                    || id.strip_prefix("function:") == Some(entry.function_id.as_str())
            }
        }
    }
}

pub(crate) fn binding_decision(
    target: &CapabilityTarget,
    candidates: &[CapabilityRegistryEntry],
) -> Option<(CapabilityRegistryEntry, CapabilityBindingDecision)> {
    let selected = candidates.first()?.clone();
    let rejected_candidates = candidates
        .iter()
        .skip(1)
        .map(|entry| super::types::CapabilityRejectedCandidate {
            implementation_id: entry.implementation_id.clone(),
            function_id: entry.function_id.clone(),
            reason: "lower_precedence_candidate".to_owned(),
        })
        .collect::<Vec<_>>();
    let selection_policy = match target {
        CapabilityTarget::Function(_) | CapabilityTarget::Implementation(_) => "explicit",
        CapabilityTarget::Contract(_) => "first_party_preferred",
        CapabilityTarget::Capability(_) => "capability_target_resolution",
    };
    Some((
        selected.clone(),
        CapabilityBindingDecision {
            contract_id: selected.contract_id.clone(),
            selected_implementation: selected.implementation_id.clone(),
            selected_function_id: selected.function_id.clone(),
            selection_policy: selection_policy.to_owned(),
            rejected_candidates,
            catalog_revision: selected.catalog_revision,
            schema_digest: selected.schema_digest.clone(),
        },
    ))
}

pub(crate) fn parse_target(params: &Value) -> Option<CapabilityTarget> {
    for key in ["functionId", "function_id"] {
        if let Some(value) = string_field(params, key) {
            return Some(CapabilityTarget::Function(value));
        }
    }
    for key in ["implementationId", "implementation_id"] {
        if let Some(value) = string_field(params, key) {
            return Some(CapabilityTarget::Implementation(value));
        }
    }
    for key in ["contractId", "contract_id"] {
        if let Some(value) = string_field(params, key) {
            return Some(CapabilityTarget::Contract(value));
        }
    }
    for key in ["capabilityId", "capability_id"] {
        if let Some(value) = string_field(params, key) {
            return Some(CapabilityTarget::Capability(value));
        }
    }
    None
}

pub(crate) fn render_capability_primer(
    snapshot: &CapabilityRegistrySnapshot,
    policy: &CapabilityContextPrimerPolicy,
) -> Option<String> {
    let mut entries = snapshot.visible_primer_entries(policy);
    if entries.is_empty() {
        return None;
    }
    let mut out = String::from("# Capability Primer\n\n");
    out.push_str(&format!(
        "Catalog revision: {}.\n\n",
        snapshot.catalog_revision
    ));
    out.push_str("The model-facing tools are `search`, `inspect`, and `execute`. Use capability ids below with `execute`; inspect mutating or medium/high-risk capabilities first.\n\n");
    for entry in entries.drain(..) {
        let mut line = format!(
            "- `{}` via `{}`: {} effect={} risk={} trust={}",
            entry.contract_id,
            entry.implementation_id,
            compact_description(&entry.function.description),
            effect_name(entry.function.effect_class),
            risk_name(entry.function.risk_level),
            entry.trust_tier
        );
        if requires_fresh_revision(&entry.function) {
            line.push_str(&format!(" inspectRevision={}", entry.function.revision.0));
        }
        if policy.include_compact_schemas
            && let Some(schema) = compact_schema(entry.function.request_schema.as_ref())
        {
            line.push_str(&format!(" payload={schema}"));
        }
        line.push('\n');
        if estimated_tokens(out.len() + line.len()) > policy.max_tokens {
            out.push_str(
                "- Additional capabilities are available through `search` and `inspect`.\n",
            );
            break;
        }
        out.push_str(&line);
    }
    Some(out)
}

pub(crate) fn requires_fresh_revision(function: &FunctionDefinition) -> bool {
    function.effect_class.is_mutating() || function.risk_level >= RiskLevel::Medium
}

pub(crate) fn effect_name(effect: EffectClass) -> &'static str {
    match effect {
        EffectClass::PureRead => "pure_read",
        EffectClass::DeterministicCompute => "deterministic_compute",
        EffectClass::DelegatedInvocation => "delegated_invocation",
        EffectClass::IdempotentWrite => "idempotent_write",
        EffectClass::AppendOnlyEvent => "append_only_event",
        EffectClass::ReversibleSideEffect => "reversible_side_effect",
        EffectClass::ExternalSideEffect => "external_side_effect",
        EffectClass::IrreversibleSideEffect => "irreversible_side_effect",
    }
}

pub(crate) fn risk_name(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

pub(crate) fn string_field(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

pub(crate) fn u64_field(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(Value::as_u64)
}

pub(crate) fn bool_field(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(Value::as_bool)
}

fn lexical_rank(query: &str, documents: &[CapabilityIndexDocument]) -> Vec<CapabilityIndexHit> {
    let mut hits = documents
        .iter()
        .map(|document| {
            let lexical_score = lexical_score(document, query);
            CapabilityIndexHit {
                capability_id: document.capability_id.clone(),
                contract_id: document.contract_id.clone(),
                implementation_id: document.implementation_id.clone(),
                plugin_id: document.plugin_id.clone(),
                worker_id: document.worker_id.clone(),
                function_id: document.function_id.clone(),
                catalog_revision: document.catalog_revision,
                schema_digest: document.schema_digest.clone(),
                trust_tier: document.trust_tier.clone(),
                health: document.health.clone(),
                visibility: document.visibility.clone(),
                effect_class: document.effect_class.clone(),
                risk_level: document.risk_level.clone(),
                lexical_score,
                vector_score: None,
                fused_score: lexical_score + trust_boost(&document.trust_tier),
                matched_by: "local_lexical".to_owned(),
                snippet: snippet(&document.text, query),
                requires_inspect: true,
            }
        })
        .filter(|hit| query.trim().is_empty() || hit.lexical_score > 0.0)
        .collect::<Vec<_>>();
    hits.sort_by(|a, b| {
        b.fused_score
            .partial_cmp(&a.fused_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.function_id.cmp(&b.function_id))
    });
    hits
}

fn vector_rank(
    query: &str,
    documents: &[CapabilityIndexDocument],
) -> Result<Vec<CapabilityIndexHit>, String> {
    let texts = std::iter::once(query.to_owned())
        .chain(documents.iter().map(|document| document.text.clone()))
        .collect::<Vec<_>>();
    let embeddings = local_embeddings(&texts)?;
    let Some((query_embedding, doc_embeddings)) = embeddings.split_first() else {
        return Ok(Vec::new());
    };
    let ranked = sqlite_vec_rank(query_embedding, doc_embeddings)?;
    let mut hits = ranked
        .into_iter()
        .filter_map(|(document_index, distance)| {
            let document = documents.get(document_index)?;
            let score = 1.0 / (1.0 + distance.max(0.0));
            Some(CapabilityIndexHit {
                capability_id: document.capability_id.clone(),
                contract_id: document.contract_id.clone(),
                implementation_id: document.implementation_id.clone(),
                plugin_id: document.plugin_id.clone(),
                worker_id: document.worker_id.clone(),
                function_id: document.function_id.clone(),
                catalog_revision: document.catalog_revision,
                schema_digest: document.schema_digest.clone(),
                trust_tier: document.trust_tier.clone(),
                health: document.health.clone(),
                visibility: document.visibility.clone(),
                effect_class: document.effect_class.clone(),
                risk_level: document.risk_level.clone(),
                lexical_score: lexical_score(document, query),
                vector_score: Some(score),
                fused_score: score + trust_boost(&document.trust_tier),
                matched_by: "local_vector".to_owned(),
                snippet: snippet(&document.text, query),
                requires_inspect: true,
            })
        })
        .collect::<Vec<_>>();
    hits.sort_by(|a, b| {
        b.fused_score
            .partial_cmp(&a.fused_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.function_id.cmp(&b.function_id))
    });
    Ok(hits)
}

fn sqlite_vec_rank(
    query_embedding: &[f32],
    doc_embeddings: &[Vec<f32>],
) -> Result<Vec<(usize, f32)>, String> {
    if query_embedding.is_empty() || doc_embeddings.is_empty() {
        return Ok(Vec::new());
    }
    let dimensions = query_embedding.len();
    if doc_embeddings
        .iter()
        .any(|embedding| embedding.len() != dimensions)
    {
        return Err("fastembed returned inconsistent vector dimensions".to_owned());
    }
    register_sqlite_vec_extension()?;
    let db = rusqlite::Connection::open_in_memory()
        .map_err(|error| format!("sqlite-vec connection failed: {error}"))?;
    db.execute(
        &format!(
            "create virtual table capability_vectors using vec0(document_id integer primary key, embedding float[{dimensions}] distance_metric=cosine)"
        ),
        [],
    )
    .map_err(|error| format!("sqlite-vec virtual table init failed: {error}"))?;
    {
        let mut insert = db
            .prepare("insert into capability_vectors(document_id, embedding) values (?1, ?2)")
            .map_err(|error| format!("sqlite-vec insert prepare failed: {error}"))?;
        for (index, embedding) in doc_embeddings.iter().enumerate() {
            insert
                .execute(rusqlite::params![
                    index as i64,
                    bytemuck::cast_slice::<f32, u8>(embedding)
                ])
                .map_err(|error| format!("sqlite-vec insert failed: {error}"))?;
        }
    }
    let query_bytes = bytemuck::cast_slice::<f32, u8>(query_embedding);
    let mut stmt = db
        .prepare(
            "select document_id, distance from capability_vectors where embedding match ?1 and k = ?2",
        )
        .map_err(|error| format!("sqlite-vec query prepare failed: {error}"))?;
    let rows = stmt
        .query_map(
            rusqlite::params![query_bytes, doc_embeddings.len() as i64],
            |row| {
                let document_id: i64 = row.get(0)?;
                let distance: f32 = row.get(1)?;
                Ok((document_id as usize, distance))
            },
        )
        .map_err(|error| format!("sqlite-vec query failed: {error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("sqlite-vec row decode failed: {error}"))
}

#[allow(unsafe_code)]
fn register_sqlite_vec_extension() -> Result<(), String> {
    static SQLITE_VEC_REGISTERED: std::sync::OnceLock<Result<(), String>> =
        std::sync::OnceLock::new();
    SQLITE_VEC_REGISTERED
        .get_or_init(|| {
            // SAFETY: this follows sqlite-vec's official Rust integration:
            // register the statically linked extension with SQLite once before
            // opening the ephemeral in-memory vector index connection.
            let rc = unsafe {
                let init = std::mem::transmute::<
                    *const (),
                    rusqlite::auto_extension::RawAutoExtension,
                >(sqlite_vec::sqlite3_vec_init as *const ());
                rusqlite::ffi::sqlite3_auto_extension(Some(init))
            };
            if rc == rusqlite::ffi::SQLITE_OK {
                Ok(())
            } else {
                Err(format!("sqlite3_auto_extension returned {rc}"))
            }
        })
        .clone()
}

fn fuse_hits(
    lexical_hits: Vec<CapabilityIndexHit>,
    vector_hits: Vec<CapabilityIndexHit>,
    documents: &[CapabilityIndexDocument],
) -> Vec<CapabilityIndexHit> {
    let mut ranks: BTreeMap<String, (Option<usize>, Option<usize>, CapabilityIndexHit)> =
        BTreeMap::new();
    for (rank, hit) in lexical_hits.into_iter().enumerate() {
        ranks.insert(hit.function_id.clone(), (Some(rank + 1), None, hit));
    }
    for (rank, hit) in vector_hits.into_iter().enumerate() {
        ranks
            .entry(hit.function_id.clone())
            .and_modify(|(_, vector_rank, existing)| {
                *vector_rank = Some(rank + 1);
                existing.vector_score = hit.vector_score;
            })
            .or_insert((None, Some(rank + 1), hit));
    }
    let ids = documents
        .iter()
        .map(|doc| (doc.function_id.as_str(), doc))
        .collect::<BTreeMap<_, _>>();
    let mut hits = ranks
        .into_iter()
        .map(|(function_id, (lex_rank, vec_rank, mut hit))| {
            let lexical_rrf = lex_rank.map_or(0.0, |rank| 1.0 / (60.0 + rank as f32));
            let vector_rrf = vec_rank.map_or(0.0, |rank| 1.0 / (60.0 + rank as f32));
            let trust = ids
                .get(function_id.as_str())
                .map(|doc| trust_boost(&doc.trust_tier))
                .unwrap_or(0.0);
            hit.fused_score = lexical_rrf + vector_rrf + trust;
            hit.matched_by = if vec_rank.is_some() && lex_rank.is_some() {
                "hybrid_local".to_owned()
            } else if vec_rank.is_some() {
                "local_vector".to_owned()
            } else {
                "local_lexical".to_owned()
            };
            hit
        })
        .collect::<Vec<_>>();
    hits.sort_by(|a, b| {
        b.fused_score
            .partial_cmp(&a.fused_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.function_id.cmp(&b.function_id))
    });
    hits
}

#[cfg(not(test))]
fn local_embeddings(texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    static MODEL: std::sync::OnceLock<std::sync::Mutex<Option<fastembed::TextEmbedding>>> =
        std::sync::OnceLock::new();
    let model = MODEL.get_or_init(|| {
        let init = fastembed::TextInitOptions::new(fastembed::EmbeddingModel::AllMiniLML6V2)
            .with_show_download_progress(false);
        std::sync::Mutex::new(fastembed::TextEmbedding::try_new(init).ok())
    });
    let mut guard = model
        .lock()
        .map_err(|_| "fastembed model mutex poisoned".to_owned())?;
    let Some(model) = guard.as_mut() else {
        return Err("fastembed model unavailable; local vector search degraded".to_owned());
    };
    model
        .embed(texts, None)
        .map_err(|error| format!("fastembed failed: {error}"))
}

#[cfg(test)]
fn local_embeddings(texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    Ok(texts.iter().map(|text| hash_embedding(text, 64)).collect())
}

#[cfg(test)]
fn hash_embedding(text: &str, dims: usize) -> Vec<f32> {
    let mut out = vec![0.0; dims];
    for token in search_tokens(text) {
        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        let digest = hasher.finalize();
        let idx = usize::from(digest[0]) % dims;
        out[idx] += 1.0;
    }
    out
}

fn lexical_score(document: &CapabilityIndexDocument, query: &str) -> f32 {
    if query.trim().is_empty() {
        return trust_boost(&document.trust_tier);
    }
    let tokens = search_tokens(query);
    if tokens.is_empty() {
        return 0.0;
    }
    let mut score = 0.0;
    let haystack = document.text.to_ascii_lowercase();
    for token in &tokens {
        if document.function_id.to_ascii_lowercase() == *token {
            score += 100.0;
        } else if document.function_id.to_ascii_lowercase().contains(token) {
            score += 50.0;
        } else if document.contract_id.to_ascii_lowercase().contains(token) {
            score += 40.0;
        } else if haystack.contains(token) {
            score += 10.0;
        }
    }
    score / tokens.len() as f32
}

fn trust_boost(tier: &str) -> f32 {
    match tier {
        "first_party_signed" => 0.060,
        "trusted_signed" => 0.050,
        "user_installed" => 0.035,
        "session_generated" => 0.025,
        "external_mcp" | "external_openapi" => 0.015,
        _ => 0.0,
    }
}

fn compare_candidates(
    a: &CapabilityRegistryEntry,
    b: &CapabilityRegistryEntry,
) -> std::cmp::Ordering {
    candidate_rank(a)
        .cmp(&candidate_rank(b))
        .then_with(|| a.implementation_id.cmp(&b.implementation_id))
}

fn candidate_rank(entry: &CapabilityRegistryEntry) -> (u8, u8, u8) {
    let health = if entry.function.health == FunctionHealth::Healthy {
        0
    } else {
        1
    };
    (
        health,
        trust_rank(&entry.trust_tier),
        if entry.function.owner_worker.as_str() == "mcp" {
            1
        } else {
            0
        },
    )
}

fn primer_rank(entry: &CapabilityRegistryEntry) -> (u8, u8, u8) {
    let primitive = if entry.is_capability_primitive() {
        0
    } else {
        1
    };
    let core = if entry.context_primer_level == "core" {
        0
    } else {
        1
    };
    (primitive, core, trust_rank(&entry.trust_tier))
}

fn trust_rank(tier: &str) -> u8 {
    TRUST_ORDER
        .iter()
        .position(|candidate| *candidate == tier)
        .unwrap_or(TRUST_ORDER.len()) as u8
}

fn default_implementation_id(function: &FunctionDefinition) -> String {
    if function.provenance.source == "system" {
        format!(
            "first_party.{}.v{}.{}",
            function.owner_worker.as_str(),
            function.revision.0,
            function
                .id
                .as_str()
                .rsplit_once("::")
                .map(|(_, local)| local)
                .unwrap_or(function.id.as_str())
        )
    } else {
        format!("function:{}", function.id.as_str())
    }
}

fn default_plugin_id(function: &FunctionDefinition) -> String {
    match function.owner_worker.as_str() {
        "mcp" => "external.mcp".to_owned(),
        worker => format!("first_party.{worker}"),
    }
}

fn trust_tier(function: &FunctionDefinition) -> String {
    match function.owner_worker.as_str() {
        "mcp" => "external_mcp".to_owned(),
        worker if function.provenance.source == "system" || worker != "sandbox" => {
            "first_party_signed".to_owned()
        }
        "sandbox" => "session_generated".to_owned(),
        _ => "untrusted".to_owned(),
    }
}

fn default_context_primer_level(function: &FunctionDefinition, trust_tier: &str) -> String {
    if CORE_CONTEXT_CAPABILITIES.contains(&function.id.as_str())
        && trust_tier == "first_party_signed"
    {
        "core".to_owned()
    } else {
        "catalog".to_owned()
    }
}

fn schema_digest(function: &FunctionDefinition) -> String {
    let material = json!({
        "functionId": function.id.as_str(),
        "revision": function.revision.0,
        "request": function.request_schema,
        "response": function.response_schema,
        "effect": effect_name(function.effect_class),
        "risk": risk_name(function.risk_level),
    });
    let serialized = serde_json::to_vec(&material).unwrap_or_default();
    sha256_hex(&serialized)
}

fn searchable_text(function: &FunctionDefinition) -> String {
    let mut text = [
        function.id.as_str().to_owned(),
        function.description.clone(),
        function.tags.join(" "),
        function.metadata.to_string(),
        function
            .request_schema
            .as_ref()
            .map(Value::to_string)
            .unwrap_or_default(),
    ]
    .join(" ");
    text.make_ascii_lowercase();
    text
}

fn search_tokens(text: &str) -> Vec<String> {
    text.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_' && ch != ':')
        .filter(|token| !token.trim().is_empty())
        .map(|token| token.to_ascii_lowercase())
        .collect()
}

fn snippet(text: &str, query: &str) -> String {
    if query.trim().is_empty() {
        return text.chars().take(160).collect();
    }
    let lower = text.to_ascii_lowercase();
    for token in search_tokens(query) {
        if let Some(index) = lower.find(&token) {
            let start = index.saturating_sub(40);
            return text.chars().skip(start).take(180).collect();
        }
    }
    text.chars().take(160).collect()
}

fn string_metadata(function: &FunctionDefinition, key: &str) -> Option<String> {
    function
        .metadata
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn runtime_requirements(function: &FunctionDefinition) -> Value {
    function
        .metadata
        .get("runtimeRequirements")
        .cloned()
        .unwrap_or_else(|| {
            json!({
                "workerKind": function.metadata.get("workerKind").cloned().unwrap_or(Value::Null),
                "deliveryModes": function.allowed_delivery_modes.iter().map(|mode| format!("{:?}", mode)).collect::<Vec<_>>()
            })
        })
}

fn examples(function: &FunctionDefinition) -> Vec<Value> {
    function
        .metadata
        .get("examples")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn display_name(function: &FunctionDefinition) -> String {
    string_metadata(function, "displayName")
        .or_else(|| {
            function
                .id
                .as_str()
                .rsplit_once("::")
                .map(|(_, name)| name.to_owned())
        })
        .unwrap_or_else(|| function.id.as_str().to_owned())
}

fn is_capability_primitive(function: &FunctionDefinition) -> bool {
    function
        .metadata
        .get("capabilityPrimitive")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn compact_description(description: &str) -> String {
    let mut text = description.replace('\n', " ");
    if text.len() > 120 {
        text.truncate(117);
        text.push_str("...");
    }
    text
}

fn compact_schema(schema: Option<&Value>) -> Option<String> {
    let schema = schema?;
    let properties = schema.get("properties")?.as_object()?;
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let mut fields = Vec::new();
    for (name, field) in properties.iter().take(8) {
        let ty = field.get("type").and_then(Value::as_str).unwrap_or("value");
        let suffix = if required.contains(name.as_str()) {
            ""
        } else {
            "?"
        };
        fields.push(format!("{name}{suffix}:{ty}"));
    }
    Some(format!("{{{}}}", fields.join(",")))
}

fn estimated_tokens(chars: usize) -> usize {
    chars / 4
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::engine::{FunctionId, VisibilityScope, WorkerId};

    fn test_function(id: &str) -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new(id).expect("function id"),
            WorkerId::new(id.split("::").next().expect("namespace")).expect("worker id"),
            "Searchable test function",
            VisibilityScope::System,
            EffectClass::PureRead,
        )
        .with_request_schema(json!({
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"]
        }))
    }

    #[test]
    fn registry_entry_defaults_to_first_party_metadata() {
        let entry =
            CapabilityRegistryEntry::from_function(test_function("filesystem::read_file"), 7);
        assert_eq!(entry.contract_id, "filesystem::read_file");
        assert_eq!(
            entry.implementation_id,
            "first_party.filesystem.v1.read_file"
        );
        assert_eq!(entry.plugin_id, "first_party.filesystem");
        assert_eq!(entry.trust_tier, "first_party_signed");
        assert_eq!(entry.context_primer_level, "core");
        assert!(!entry.schema_digest.is_empty());
    }

    #[test]
    fn hybrid_index_reports_vector_hits_in_tests() {
        let docs = vec![
            CapabilityRegistryEntry::from_function(test_function("filesystem::read_file"), 1)
                .search_document(),
            CapabilityRegistryEntry::from_function(test_function("process::run"), 1)
                .search_document(),
        ];
        let result = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy::default()).search(
            "read path",
            docs,
            10,
        );
        assert!(result.status.local_vector);
        assert_eq!(result.status.state, "ready");
        assert_eq!(result.hits[0].function_id, "filesystem::read_file");
        assert!(result.hits[0].vector_score.is_some());
    }

    #[test]
    fn primer_respects_core_policy() {
        let snapshot = CapabilityRegistrySnapshot::new(
            vec![
                test_function("filesystem::read_file"),
                test_function("memory::retain"),
            ],
            1,
        );
        let text = render_capability_primer(
            &snapshot,
            &CapabilityContextPrimerPolicy {
                max_tokens: 200,
                ..Default::default()
            },
        )
        .expect("primer");
        assert!(text.contains("filesystem::read_file"));
        assert!(!text.contains("memory::retain"));
    }
}
