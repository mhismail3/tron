//! Registry, binding, and local search projection for live capabilities.
//!
//! The registry is deliberately layered over the engine catalog. The catalog is
//! still the source of truth for live functions, health, visibility, authority,
//! and invocation; this module gives the capability primitives a stable
//! contract/implementation vocabulary, search index boundary, and durable audit
//! records for binding, inspection, execution, and program runs.
//!
//! | Submodule | Ownership |
//! |---|---|
//! | `index` | Document identity, lexical ranking, local vector ranking, degraded-index status, and hybrid fusion |
//! | `primer` | Context-primer policy, visible-primer entry selection, and model-facing primer rendering |
//! | `recipes` | Capability recipe authoring for resolve/prepare guidance |
//! | `store` | In-memory and SQLite registry persistence, schema, redaction, and vector storage |
//!
//! The root module owns catalog projection records and selection semantics.
//! Concrete persistence stays in `store`; ranking and primer text stay outside
//! that boundary so durable storage cannot grow model-guidance policy by
//! accident.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

mod index;
mod primer;
mod recipes;
mod store;

pub(crate) use index::CapabilityIndexSearchResult;
#[cfg(test)]
pub(crate) use index::HybridLocalCapabilityIndex;
use index::{document_key, risk_rank, trust_rank};
use primer::is_core_context_capability;
pub(crate) use primer::{CapabilityContextPrimerPolicy, render_capability_primer};
use recipes::agent_recipe_for_entry;

use super::types::{
    AgentCapabilityRecipe, CapabilityBindingDecision, CapabilityBindingRecord,
    CapabilityContractRecord, CapabilityImplementationRecord, CapabilityInspectionHandle,
    CapabilityInspectionRecord, CapabilityPluginManifest,
};
use crate::engine::{
    ActorContext, EffectClass, FunctionDefinition, FunctionHealth, FunctionQuery, RiskLevel,
    TriggerDefinition,
};

/// Profile-controlled search policy.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct CapabilitySearchPolicy {
    pub(crate) lexical: bool,
    pub(crate) local_vector: bool,
    pub(crate) cloud_embeddings: bool,
    pub(crate) max_results: usize,
    pub(crate) require_local_vector: bool,
    pub(crate) allow_lexical_only_when_degraded: bool,
}

impl Default for CapabilitySearchPolicy {
    fn default() -> Self {
        Self {
            lexical: true,
            local_vector: true,
            cloud_embeddings: false,
            max_results: 50,
            require_local_vector: false,
            allow_lexical_only_when_degraded: true,
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
            // Discovery must keep enough candidates available for the index to
            // explain when model-supplied risk filters are too narrow. Execution
            // remains policy-enforced at invoke time.
            max_risk: None,
            health: if self.include_unavailable {
                None
            } else {
                Some(FunctionHealth::Healthy)
            },
            ..FunctionQuery::default()
        }
    }

    fn allows_document(&self, document: &CapabilityIndexDocument) -> bool {
        if let Some(kind) = &self.kind
            && !document_kind_matches(kind, &document.kind)
        {
            return false;
        }
        if let Some(contract_id) = &self.contract_id
            && document.contract_id != *contract_id
        {
            return false;
        }
        if let Some(namespace) = &self.namespace
            && !document.function_id.starts_with(&format!("{namespace}::"))
            && document.worker_id != *namespace
            && !document.plugin_id.contains(namespace)
        {
            return false;
        }
        if let Some(plugin_id) = &self.plugin_id
            && document.plugin_id != *plugin_id
        {
            return false;
        }
        if let Some(scope) = &self.scope
            && document.visibility != *scope
        {
            return false;
        }
        if let Some(effect) = self.effect
            && document.effect_class != effect_name(effect)
        {
            return false;
        }
        if let Some(risk_max) = self.risk_max
            && risk_rank(&document.risk_level) > risk_rank(risk_name(risk_max))
        {
            return false;
        }
        if let Some(min) = &self.trust_tier_min
            && trust_rank(&document.trust_tier) > trust_rank(min)
        {
            return false;
        }
        if !self.include_unavailable && document.health != "Healthy" && document.health != "ready" {
            return false;
        }
        true
    }

    fn without_risk_max(&self) -> Self {
        let mut relaxed = self.clone();
        relaxed.risk_max = None;
        relaxed
    }
}

fn document_kind_matches(filter: &str, document_kind: &str) -> bool {
    match filter.trim().to_ascii_lowercase().as_str() {
        "function" | "functions" => document_kind == "implementation",
        "capability" | "capabilities" => matches!(document_kind, "contract" | "implementation"),
        "contract" | "contracts" => document_kind == "contract",
        "implementation" | "implementations" => document_kind == "implementation",
        "plugin" | "plugins" => document_kind == "plugin",
        "worker" | "workers" => document_kind == "worker",
        other => document_kind == other,
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
            kind: "implementation".to_owned(),
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
            recipe: Some(self.agent_recipe()),
        }
    }

    pub(crate) fn agent_recipe(&self) -> AgentCapabilityRecipe {
        agent_recipe_for_entry(self)
    }

    pub(crate) fn contract_record(&self) -> CapabilityContractRecord {
        let conditional_approval = conditional_approval_contract(&self.function);
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
                "approvalMode": approval_mode(&self.function),
                "approvalRequired": self.function.required_authority.approval_required,
                "conditionalApproval": conditional_approval
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
            conformance_state: conformance_state(&self.function, &self.trust_tier),
            signature_status: signature_status(&self.function, &self.trust_tier),
        }
    }

    pub(crate) fn inspection(
        &self,
        decision: CapabilityBindingDecision,
    ) -> CapabilityInspectionRecord {
        let conditional_approval = conditional_approval_contract(&self.function);
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
            recipe: self.agent_recipe(),
            execution_requirements: json!({
                "inspectionHandle": self.inspection_handle().handle,
                "expectedRevision": self.function.revision.0,
                "expectedSchemaDigest": self.schema_digest,
                "freshInspectionRequired": requires_fresh_revision(&self.function),
                "idempotencyKeyRequired": self.function.effect_class.is_mutating(),
                "approvalMode": approval_mode(&self.function),
                "approvalRequired": self.function.required_authority.approval_required,
                "conditionalApproval": conditional_approval,
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
    #[cfg(test)]
    pub(crate) fn new(functions: Vec<FunctionDefinition>, catalog_revision: u64) -> Self {
        Self::with_triggers(functions, Vec::new(), catalog_revision)
    }

    pub(crate) fn with_triggers(
        functions: Vec<FunctionDefinition>,
        triggers: Vec<TriggerDefinition>,
        catalog_revision: u64,
    ) -> Self {
        let triggers_by_target = triggers_by_target_function(triggers);
        let mut entries = functions
            .into_iter()
            .map(|function| attach_related_trigger_metadata(function, &triggers_by_target))
            .map(|function| CapabilityRegistryEntry::from_function(function, catalog_revision))
            .collect::<Vec<_>>();
        entries.sort_by(|a, b| a.function_id.cmp(&b.function_id));
        Self {
            catalog_revision,
            entries,
        }
    }

    pub(crate) fn index_documents(&self) -> Vec<CapabilityIndexDocument> {
        let mut documents = self
            .entries
            .iter()
            .filter(|entry| !entry.is_capability_primitive())
            .map(CapabilityRegistryEntry::search_document)
            .collect::<Vec<_>>();
        documents.extend(aggregate_documents(self, "contract"));
        documents.extend(aggregate_documents(self, "plugin"));
        documents.extend(aggregate_documents(self, "worker"));
        documents.sort_by(|a, b| document_key(a).cmp(&document_key(b)));
        documents.dedup_by(|a, b| document_key(a) == document_key(b));
        documents
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
}

fn triggers_by_target_function(
    triggers: Vec<TriggerDefinition>,
) -> BTreeMap<String, Vec<TriggerDefinition>> {
    let mut by_target = BTreeMap::<String, Vec<TriggerDefinition>>::new();
    for trigger in triggers {
        by_target
            .entry(trigger.target_function.as_str().to_owned())
            .or_default()
            .push(trigger);
    }
    for triggers in by_target.values_mut() {
        triggers.sort_by(|a, b| a.id.as_str().cmp(b.id.as_str()));
    }
    by_target
}

fn attach_related_trigger_metadata(
    mut function: FunctionDefinition,
    triggers_by_target: &BTreeMap<String, Vec<TriggerDefinition>>,
) -> FunctionDefinition {
    let Some(triggers) = triggers_by_target.get(function.id.as_str()) else {
        return function;
    };
    if triggers.is_empty() {
        return function;
    }
    let mut metadata = function.metadata.as_object().cloned().unwrap_or_default();
    metadata.insert(
        "relatedTriggers".to_owned(),
        Value::Array(triggers.iter().map(related_trigger_metadata).collect()),
    );
    function.metadata = Value::Object(metadata);
    function
}

fn related_trigger_metadata(trigger: &TriggerDefinition) -> Value {
    json!({
        "triggerId": trigger.id.as_str(),
        "triggerType": trigger.trigger_type.as_str(),
        "targetFunction": trigger.target_function.as_str(),
        "targetRevision": trigger.target_revision.as_ref().map(|revision| revision.0),
        "ownerWorker": trigger.owner_worker.as_str(),
        "revision": trigger.revision.0,
        "visibility": trigger.visibility.as_str(),
        "deliveryMode": &trigger.delivery_mode,
        "authorityGrantId": trigger.authority_grant.as_str(),
        "config": trigger.config.clone(),
    })
}

/// Search index document.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityIndexDocument {
    pub(crate) kind: String,
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
    pub(crate) recipe: Option<AgentCapabilityRecipe>,
}

#[cfg(test)]
pub(crate) use store::InMemoryCapabilityRegistryStore;
pub(crate) use store::{
    CapabilityRegistryStore, SharedCapabilityRegistryStore, SqliteCapabilityRegistryStore,
    open_capability_registry_store,
};

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
            Self::Function(id) => entry.function_id == *id || entry.implementation_id == *id,
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
            decision_id: format!("binding_decision_{}", uuid::Uuid::now_v7()),
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

pub(crate) fn requires_fresh_revision(function: &FunctionDefinition) -> bool {
    function.effect_class.is_mutating() || function.risk_level >= RiskLevel::Medium
}

fn direct_execution_allowed(function: &FunctionDefinition) -> bool {
    function
        .metadata
        .pointer("/highRiskContract/directExecutionAllowed")
        .and_then(Value::as_bool)
        .unwrap_or(false)
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
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

pub(crate) fn u64_field(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(Value::as_u64)
}

pub(crate) fn bool_field(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(Value::as_bool)
}

fn binding_scope_parts(
    session_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Vec<(&'static str, String)> {
    let mut scopes = Vec::new();
    if let Some(session_id) = session_id {
        scopes.push(("session", session_id.to_owned()));
    }
    if let Some(workspace_id) = workspace_id {
        scopes.push(("workspace", workspace_id.to_owned()));
    }
    scopes.push(("system", "default".to_owned()));
    scopes
}

fn binding_scope_keys(
    contract_id: &str,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Vec<(String, String, String)> {
    binding_scope_parts(session_id, workspace_id)
        .into_iter()
        .map(|(scope_kind, scope_value)| {
            (contract_id.to_owned(), scope_kind.to_owned(), scope_value)
        })
        .collect()
}

fn aggregate_documents(
    snapshot: &CapabilityRegistrySnapshot,
    kind: &str,
) -> Vec<CapabilityIndexDocument> {
    let mut groups: BTreeMap<String, Vec<&CapabilityRegistryEntry>> = BTreeMap::new();
    for entry in &snapshot.entries {
        if entry.is_capability_primitive() {
            continue;
        }
        let key = match kind {
            "contract" => &entry.contract_id,
            "plugin" => &entry.plugin_id,
            "worker" => &entry.worker_id,
            _ => continue,
        };
        groups.entry(key.clone()).or_default().push(entry);
    }
    groups
        .into_iter()
        .filter_map(|(id, entries)| {
            let first = entries.first()?;
            let risk_level = aggregate_risk_level(&entries);
            let effect_class = aggregate_effect_class(&entries);
            let text = entries
                .iter()
                .map(|entry| {
                    format!(
                        "{} {} {} {}",
                        entry.contract_id,
                        entry.implementation_id,
                        entry.function_id,
                        entry.search_text
                    )
                })
                .collect::<Vec<_>>()
                .join("\n");
            Some(CapabilityIndexDocument {
                kind: kind.to_owned(),
                capability_id: id.clone(),
                contract_id: if kind == "contract" {
                    id.clone()
                } else {
                    first.contract_id.clone()
                },
                implementation_id: format!("{kind}:{id}"),
                plugin_id: if kind == "plugin" {
                    id.clone()
                } else {
                    first.plugin_id.clone()
                },
                worker_id: if kind == "worker" {
                    id.clone()
                } else {
                    first.worker_id.clone()
                },
                function_id: first.function_id.clone(),
                catalog_revision: snapshot.catalog_revision,
                schema_digest: sha256_hex(text.as_bytes()),
                trust_tier: first.trust_tier.clone(),
                health: "ready".to_owned(),
                visibility: first.visibility.clone(),
                effect_class,
                risk_level,
                text,
                recipe: if kind == "contract" && entries.len() == 1 {
                    Some(first.agent_recipe())
                } else {
                    None
                },
            })
        })
        .collect()
}

fn aggregate_risk_level(entries: &[&CapabilityRegistryEntry]) -> String {
    entries
        .iter()
        .map(|entry| risk_name(entry.function.risk_level))
        .max_by_key(|risk| risk_rank(risk))
        .unwrap_or("low")
        .to_owned()
}

fn aggregate_effect_class(entries: &[&CapabilityRegistryEntry]) -> String {
    let mut effects = entries
        .iter()
        .map(|entry| effect_name(entry.function.effect_class))
        .collect::<BTreeSet<_>>();
    if effects.len() == 1 {
        effects.pop_first().unwrap_or("pure_read").to_owned()
    } else {
        "mixed".to_owned()
    }
}

fn plugin_manifest_for_entry(entry: &CapabilityRegistryEntry) -> CapabilityPluginManifest {
    CapabilityPluginManifest {
        id: entry.plugin_id.clone(),
        name: string_metadata(&entry.function, "pluginName")
            .unwrap_or_else(|| entry.plugin_id.clone()),
        version: string_metadata(&entry.function, "pluginVersion")
            .unwrap_or_else(|| "1.0.0".to_owned()),
        publisher: string_metadata(&entry.function, "pluginPublisher").unwrap_or_else(|| {
            if entry.trust_tier == "first_party_signed" {
                "tron"
            } else {
                "unknown"
            }
            .to_owned()
        }),
        signature_status: signature_status(&entry.function, &entry.trust_tier),
        runtime: entry
            .function
            .metadata
            .pointer("/runtimeRequirements/workerKind")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned(),
        namespace_claims: vec![entry.function.id.namespace().to_owned()],
        provided_contracts: vec![entry.contract_id.clone()],
        provided_implementations: vec![entry.implementation_id.clone()],
        requested_authorities: entry.function.required_authority.scopes.clone(),
        trust_tier: entry.trust_tier.clone(),
        visibility_ceiling: entry.visibility.clone(),
        conformance_state: conformance_state(&entry.function, &entry.trust_tier),
        docs: json!({"summary": entry.function.description}),
        examples: examples(&entry.function),
        search_metadata: json!({"tags": entry.function.tags}),
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
    if is_core_context_capability(function.id.as_str()) && trust_tier == "first_party_signed" {
        "core".to_owned()
    } else {
        "catalog".to_owned()
    }
}

fn conformance_state(function: &FunctionDefinition, trust_tier: &str) -> String {
    string_metadata(function, "conformanceState").unwrap_or_else(|| {
        if trust_tier == "first_party_signed" {
            "healthy".to_owned()
        } else {
            "candidate".to_owned()
        }
    })
}

fn preserve_existing_conformance_state(state: &str) -> bool {
    matches!(state, "degraded" | "quarantined" | "disabled")
}

fn signature_status(function: &FunctionDefinition, trust_tier: &str) -> String {
    string_metadata(function, "signatureStatus").unwrap_or_else(|| match trust_tier {
        "first_party_signed" | "trusted_signed" => "valid".to_owned(),
        "session_generated" => "session_scoped".to_owned(),
        _ => "unsigned".to_owned(),
    })
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
        effect_name(function.effect_class).to_owned(),
        risk_name(function.risk_level).to_owned(),
        function.description.clone(),
        function.tags.join(" "),
        searchable_metadata_text(&function.metadata),
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

fn searchable_metadata_text(metadata: &Value) -> String {
    let mut terms = Vec::new();
    append_searchable_metadata_terms(metadata, &mut terms);
    terms.join(" ")
}

fn append_searchable_metadata_terms(value: &Value, terms: &mut Vec<String>) {
    match value {
        Value::Null => {}
        Value::Bool(flag) => terms.push(flag.to_string()),
        Value::Number(number) => terms.push(number.to_string()),
        Value::String(text) => terms.push(text.clone()),
        Value::Array(values) => {
            for value in values {
                append_searchable_metadata_terms(value, terms);
            }
        }
        Value::Object(map) => {
            for (key, value) in map {
                if metadata_value_is_searchable(value) {
                    terms.push(key.clone());
                    append_searchable_metadata_terms(value, terms);
                }
            }
        }
    }
}

fn metadata_value_is_searchable(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Array(values) => values.iter().any(metadata_value_is_searchable),
        Value::Object(map) => map.values().any(metadata_value_is_searchable),
        _ => true,
    }
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

fn conditional_approval_contract(function: &FunctionDefinition) -> Value {
    function
        .metadata
        .pointer("/highRiskContract/conditionalApproval")
        .cloned()
        .unwrap_or(Value::Null)
}

fn approval_mode(function: &FunctionDefinition) -> &'static str {
    if function.required_authority.approval_required {
        "always"
    } else if !conditional_approval_contract(function).is_null() {
        "conditional"
    } else {
        "none"
    }
}

fn compact_description(description: &str) -> String {
    let mut text = description.replace('\n', " ");
    if text.len() > 120 {
        text.truncate(117);
        text.push_str("...");
    }
    text
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use chrono::Utc;
    use serde_json::json;

    use super::super::embeddings::{EmbeddingProvider, HashEmbeddingProvider};
    use super::*;
    use crate::domains::capability::types::{
        CapabilityPauseRecord, CapabilityProgramRunRecord, CapabilityRunRecord,
    };
    use crate::engine::{
        AuthorityGrantId, FunctionId, TriggerId, TriggerTypeId, VisibilityScope, WorkerId,
    };

    struct FailingEmbeddingProvider;

    impl EmbeddingProvider for FailingEmbeddingProvider {
        fn model_id(&self) -> &'static str {
            "test:failing"
        }

        fn dimensions(&self) -> usize {
            64
        }

        fn embed(&self, _texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
            Err("embedding assets unavailable".to_owned())
        }
    }

    struct CountingEmbeddingProvider {
        calls: AtomicUsize,
        max_batch: AtomicUsize,
    }

    impl CountingEmbeddingProvider {
        fn new() -> Self {
            Self {
                calls: AtomicUsize::new(0),
                max_batch: AtomicUsize::new(0),
            }
        }

        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }

        fn max_batch(&self) -> usize {
            self.max_batch.load(Ordering::SeqCst)
        }
    }

    impl EmbeddingProvider for CountingEmbeddingProvider {
        fn model_id(&self) -> &'static str {
            "test:counting"
        }

        fn dimensions(&self) -> usize {
            64
        }

        fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.max_batch.fetch_max(texts.len(), Ordering::SeqCst);
            Ok(texts
                .iter()
                .map(|text| {
                    let mut vector = vec![0.0; 64];
                    vector[text.len() % 64] = 1.0;
                    vector
                })
                .collect())
        }
    }

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

    fn session_generated_function(id: &str, worker: &str) -> FunctionDefinition {
        let namespace = id
            .split_once("::")
            .map(|(namespace, _)| namespace)
            .unwrap_or(id);
        let local_name = id.split_once("::").map(|(_, local)| local).unwrap_or(id);
        let mut function = FunctionDefinition::new(
            FunctionId::new(id).expect("function id"),
            WorkerId::new(worker).expect("worker id"),
            "Live external worker function",
            VisibilityScope::System,
            EffectClass::PureRead,
        )
        .with_request_schema(json!({
            "type": "object",
            "additionalProperties": true
        }))
        .with_response_schema(json!({
            "type": "object",
            "additionalProperties": true
        }));
        function.metadata = json!({
            "contractId": id,
            "implementationId": format!("session_generated.{namespace}.{local_name}"),
            "pluginId": format!("session_generated.{worker}"),
            "trustTier": "session_generated",
            "contextPrimerLevel": "catalog",
            "runtimeRequirements": {
                "workerKind": "external",
                "deliveryModes": ["Sync"]
            },
            "signatureStatus": "session_scoped",
            "conformanceState": "healthy"
        });
        function
    }

    fn manual_trigger(id: &str, worker: &str, target: &str) -> TriggerDefinition {
        let mut trigger = TriggerDefinition::new(
            TriggerId::new(id).expect("trigger id"),
            WorkerId::new(worker).expect("worker id"),
            TriggerTypeId::new("manual").expect("trigger type"),
            FunctionId::new(target).expect("target function"),
            AuthorityGrantId::new("external-grant").expect("authority grant"),
        );
        trigger.visibility = VisibilityScope::System;
        trigger
    }

    fn sync_without_vectors(
        store: &mut dyn CapabilityRegistryStore,
        snapshot: &CapabilityRegistrySnapshot,
    ) {
        let policy = CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        };
        let provider = HashEmbeddingProvider::new(64);
        store
            .sync_snapshot(snapshot, &provider, &policy)
            .expect("sync snapshot");
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
    fn registry_snapshot_projects_related_triggers_into_function_metadata() {
        let snapshot = CapabilityRegistrySnapshot::with_triggers(
            vec![session_generated_function("rwo_n7::echo", "rwo-n7-worker")],
            vec![manual_trigger(
                "manual:rwo_n7.echo",
                "rwo-n7-worker",
                "rwo_n7::echo",
            )],
            7,
        );
        let entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.function_id == "rwo_n7::echo")
            .expect("entry");
        assert_eq!(
            entry.function.metadata["relatedTriggers"][0]["triggerId"],
            json!("manual:rwo_n7.echo")
        );
        assert!(entry.search_text.contains("manual:rwo_n7.echo"));
    }

    #[test]
    fn agent_recipe_projects_required_payload_and_execute_template() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let function = crate::domains::contract::function_definition_for_capability(&process_spec);
        let entry = CapabilityRegistryEntry::from_function(function, 7);
        let recipe = entry.agent_recipe();

        assert_eq!(recipe.contract_id, "process::run");
        assert!(
            recipe
                .required_payload
                .iter()
                .any(|field| field.starts_with("command:"))
        );
        assert!(
            recipe
                .optional_payload
                .iter()
                .any(|field| field.starts_with("expectedOutputs:"))
        );
        assert_eq!(recipe.execute_template["target"], json!("process::run"));
        assert_eq!(
            recipe.execute_template["arguments"]["command"],
            json!("date")
        );
        assert_eq!(recipe.direct_execution, "conditional_safe_direct");
        assert!(!recipe.inspect_required);
        assert!(recipe.approval_behavior.contains("conditional"));
    }

    #[test]
    fn first_party_recipes_include_every_required_payload_field() {
        let spec_sets = vec![
            crate::domains::agent::contract::capabilities().expect("agent specs"),
            crate::domains::auth::contract::capabilities().expect("auth specs"),
            crate::domains::blob::contract::capabilities().expect("blob specs"),
            crate::domains::browser::contract::capabilities().expect("browser specs"),
            crate::domains::context::contract::capabilities().expect("context specs"),
            crate::domains::cron::contract::capabilities().expect("cron specs"),
            crate::domains::device::contract::capabilities().expect("device specs"),
            crate::domains::display::contract::capabilities().expect("display specs"),
            crate::domains::events::contract::capabilities().expect("events specs"),
            crate::domains::filesystem::contract::capabilities().expect("filesystem specs"),
            crate::domains::git::contract::capabilities().expect("git specs"),
            crate::domains::import::contract::capabilities().expect("import specs"),
            crate::domains::job::contract::capabilities().expect("job specs"),
            crate::domains::logs::contract::capabilities().expect("logs specs"),
            crate::domains::mcp::contract::capabilities().expect("mcp specs"),
            crate::domains::memory::contract::capabilities().expect("memory specs"),
            crate::domains::message::contract::capabilities().expect("message specs"),
            crate::domains::model::contract::capabilities().expect("model specs"),
            crate::domains::notifications::contract::capabilities().expect("notification specs"),
            crate::domains::plan::contract::capabilities().expect("plan specs"),
            crate::domains::process::contract::capabilities().expect("process specs"),
            crate::domains::program::contract::capabilities().expect("program specs"),
            crate::domains::prompt_library::contract::capabilities().expect("prompt library specs"),
            crate::domains::repo::contract::capabilities().expect("repo specs"),
            crate::domains::sandbox::contract::capabilities().expect("sandbox specs"),
            crate::domains::session::contract::capabilities().expect("session specs"),
            crate::domains::settings::contract::capabilities().expect("settings specs"),
            crate::domains::skills::contract::capabilities().expect("skills specs"),
            crate::domains::system::contract::capabilities().expect("system specs"),
            crate::domains::transcription::contract::capabilities().expect("transcription specs"),
            crate::domains::tree::contract::capabilities().expect("tree specs"),
            crate::domains::voice_notes::contract::capabilities().expect("voice notes specs"),
            crate::domains::web::contract::capabilities().expect("web specs"),
            crate::domains::worktree::contract::capabilities().expect("worktree specs"),
        ];
        let mut checked = 0;

        for spec in spec_sets.into_iter().flatten() {
            let function = crate::domains::contract::function_definition_for_capability(&spec);
            if function.id.namespace() == "capability" {
                continue;
            }
            let Some(schema) = function.request_schema.as_ref() else {
                continue;
            };
            let Some(required) = schema.get("required").and_then(Value::as_array) else {
                continue;
            };
            let required = required
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>();
            if required.is_empty() {
                continue;
            }

            let entry = CapabilityRegistryEntry::from_function(function, 17);
            let recipe = entry.agent_recipe();
            for field in required {
                assert!(
                    recipe
                        .required_payload
                        .iter()
                        .any(|summary| summary.starts_with(&format!("{field}:"))),
                    "{} missing required payload summary for {field}",
                    recipe.contract_id
                );
                assert!(
                    recipe.execute_template["arguments"].get(&field).is_some(),
                    "{} execute template missing required payload field {field}",
                    recipe.contract_id
                );
            }
            checked += 1;
        }

        assert!(checked > 50, "expected broad first-party recipe coverage");
    }

    #[test]
    fn search_hits_persist_agent_recipe_in_index_documents() {
        let notification_spec = crate::domains::notifications::contract::capabilities()
            .expect("notification specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "notifications::send")
            .expect("notifications::send spec");
        let function =
            crate::domains::contract::function_definition_for_capability(&notification_spec);
        let entry = CapabilityRegistryEntry::from_function(function, 12);
        let document = entry.search_document();
        let recipe = document.recipe.as_ref().expect("recipe");

        assert_eq!(recipe.contract_id, "notifications::send");
        assert!(
            recipe
                .required_payload
                .iter()
                .any(|field| field.starts_with("title:"))
        );
        assert!(
            recipe
                .required_payload
                .iter()
                .any(|field| field.starts_with("body:"))
        );
        assert_eq!(
            recipe.execute_template["arguments"]["title"],
            json!("Tron test")
        );
    }

    #[test]
    fn registry_entry_surfaces_conditional_approval_metadata() {
        let mut function = test_function("process::run");
        function.effect_class = EffectClass::ExternalSideEffect;
        function.risk_level = RiskLevel::High;
        function.metadata = json!({
            "highRiskContract": {
                "conditionalApproval": {
                    "owner": "process",
                    "policy": "process::run command classifier",
                    "approvalRequiredFor": ["destructive commands"],
                    "approvalNotRequiredFor": ["date"]
                }
            }
        });
        let entry = CapabilityRegistryEntry::from_function(function, 17);
        let contract = entry.contract_record();
        let inspection = entry.inspection(CapabilityBindingDecision {
            decision_id: "binding_decision_test".to_owned(),
            contract_id: entry.contract_id.clone(),
            selected_implementation: entry.implementation_id.clone(),
            selected_function_id: entry.function_id.clone(),
            selection_policy: "test".to_owned(),
            rejected_candidates: Vec::new(),
            catalog_revision: entry.catalog_revision,
            schema_digest: entry.schema_digest.clone(),
        });

        assert_eq!(contract.approval_contract["approvalMode"], "conditional");
        assert_eq!(contract.approval_contract["approvalRequired"], false);
        assert_eq!(
            contract.approval_contract["conditionalApproval"]["policy"],
            "process::run command classifier"
        );
        assert_eq!(
            inspection.execution_requirements["approvalMode"],
            "conditional"
        );
        assert_eq!(
            inspection.execution_requirements["conditionalApproval"]["approvalNotRequiredFor"][0],
            "date"
        );
    }

    #[test]
    fn hybrid_index_reports_vector_hits_in_tests() {
        let docs = vec![
            CapabilityRegistryEntry::from_function(test_function("filesystem::read_file"), 1)
                .search_document(),
            CapabilityRegistryEntry::from_function(test_function("process::run"), 1)
                .search_document(),
        ];
        let result = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy::default())
            .search("read path", docs, 10)
            .expect("search");
        assert!(result.status.local_vector);
        assert_eq!(result.status.state, "ready");
        assert_eq!(result.hits[0].function_id, "filesystem::read_file");
        assert!(result.hits[0].vector_score.is_some());
    }

    #[test]
    fn search_kind_function_matches_runnable_implementations() {
        let snapshot = CapabilityRegistrySnapshot::new(vec![test_function("process::run")], 1);
        let mut store = InMemoryCapabilityRegistryStore::default();
        let provider = HashEmbeddingProvider::new(64);
        let policy = CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        };
        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("sync");
        let results = store
            .search(
                "process run",
                &CapabilitySearchFilters {
                    kind: Some("function".to_owned()),
                    include_unavailable: true,
                    ..CapabilitySearchFilters::default()
                },
                &policy,
                10,
                &provider,
            )
            .expect("search");
        assert!(
            results
                .hits
                .iter()
                .any(|hit| { hit.kind == "implementation" && hit.function_id == "process::run" }),
            "function searches should include runnable implementation documents"
        );
    }

    #[test]
    fn search_relaxes_risk_filter_after_zero_discovery_hits() {
        let mut process_function = test_function("process::run");
        process_function.effect_class = EffectClass::ExternalSideEffect;
        process_function.risk_level = RiskLevel::High;
        let snapshot = CapabilityRegistrySnapshot::new(vec![process_function], 1);
        let mut store = InMemoryCapabilityRegistryStore::default();
        let provider = HashEmbeddingProvider::new(64);
        let policy = CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        };
        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("sync");

        let result = store
            .search(
                "process run shell command date",
                &CapabilitySearchFilters {
                    kind: Some("contract".to_owned()),
                    risk_max: Some(RiskLevel::Low),
                    ..CapabilitySearchFilters::default()
                },
                &policy,
                10,
                &provider,
            )
            .expect("search");

        assert!(
            result
                .hits
                .iter()
                .any(|hit| hit.contract_id == "process::run"),
            "search should still explain the shell capability even when a discovery risk filter is too narrow"
        );
        assert!(
            result
                .status
                .degraded_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("riskMax relaxed"))
        );
    }

    #[test]
    fn sqlite_registry_store_round_trips_documents_bindings_and_conformance() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        let snapshot =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
        let policy = CapabilitySearchPolicy::default();
        let provider = HashEmbeddingProvider::new(64);
        let status = store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("sync");
        assert_eq!(status.state, "ready");

        let results = store
            .search(
                "read path",
                &CapabilitySearchFilters::default(),
                &policy,
                10,
                &provider,
            )
            .expect("search");
        assert!(
            results
                .hits
                .iter()
                .any(|hit| hit.function_id == "filesystem::read_file")
        );
        assert_eq!(
            store
                .implementation_conformance_state("first_party.filesystem.v1.read_file")
                .expect("conformance"),
            Some("healthy".to_owned())
        );
        let plugin_count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM capability_plugins", [], |row| {
                row.get(0)
            })
            .expect("plugin count");
        assert_eq!(plugin_count, 1);
        store
            .conn
            .execute(
                "INSERT INTO capability_bindings
                   (contract_id, scope_kind, scope_value, selected_implementation,
                    selection_policy, enabled, updated_at)
                 VALUES (?1, 'system', 'default', ?2, 'test_binding', 1, ?3)",
                rusqlite::params![
                    "filesystem::read_file",
                    "first_party.filesystem.v1.read_file",
                    Utc::now().to_rfc3339()
                ],
            )
            .expect("binding");
        let binding = store
            .active_binding("filesystem::read_file", None, None)
            .expect("active binding")
            .expect("binding present");
        assert_eq!(binding.selection_policy, "test_binding");

        let entry = snapshot.entries[0].clone();
        let handle = entry.inspection_handle();
        let decision = CapabilityBindingDecision {
            decision_id: "binding_decision_test".to_owned(),
            contract_id: entry.contract_id.clone(),
            selected_implementation: entry.implementation_id.clone(),
            selected_function_id: entry.function_id.clone(),
            selection_policy: "test".to_owned(),
            rejected_candidates: Vec::new(),
            catalog_revision: entry.catalog_revision,
            schema_digest: entry.schema_digest.clone(),
        };
        store
            .record_inspection(&handle, &entry, &decision)
            .expect("record inspection");
        assert!(
            store
                .validate_inspection(&handle.handle, &entry)
                .expect("validate inspection")
        );
        let mut stale_entry = entry.clone();
        stale_entry.schema_digest = "different".to_owned();
        assert!(
            !store
                .validate_inspection(&handle.handle, &stale_entry)
                .expect("stale inspection rejected")
        );
    }

    #[test]
    fn sqlite_registry_records_degraded_vector_metadata() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        let snapshot =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
        let policy = CapabilitySearchPolicy {
            require_local_vector: false,
            allow_lexical_only_when_degraded: true,
            ..CapabilitySearchPolicy::default()
        };

        let status = store
            .sync_snapshot(&snapshot, &FailingEmbeddingProvider, &policy)
            .expect("degraded sync");

        assert_eq!(status.state, "unavailable");
        let admin = store.admin_status().expect("status");
        assert_eq!(admin["indexStatus"]["state"], "unavailable");
        assert_eq!(
            admin["indexStatus"]["degradedReason"],
            "embedding assets unavailable"
        );
        assert_eq!(admin["indexStatus"]["embeddingModel"], "test:failing");
    }

    #[test]
    fn sqlite_search_degrades_while_filtered_vectors_are_still_indexing() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        let snapshot =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
        let metadata_only_policy = CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        };
        let strict_search_policy = CapabilitySearchPolicy {
            local_vector: true,
            require_local_vector: true,
            allow_lexical_only_when_degraded: false,
            ..CapabilitySearchPolicy::default()
        };
        let provider = HashEmbeddingProvider::new(64);

        store
            .sync_snapshot(&snapshot, &provider, &metadata_only_policy)
            .expect("metadata sync");
        let result = store
            .search(
                "read file",
                &CapabilitySearchFilters {
                    kind: Some("contract".to_owned()),
                    contract_id: Some("filesystem::read_file".to_owned()),
                    ..CapabilitySearchFilters::default()
                },
                &strict_search_policy,
                5,
                &provider,
            )
            .expect("indexing vectors should not make search unavailable");

        assert!(
            result
                .hits
                .iter()
                .any(|hit| hit.contract_id == "filesystem::read_file")
        );
        assert_eq!(result.status.state, "indexing");
        assert!(
            result
                .status
                .degraded_reason
                .as_deref()
                .is_some_and(|reason| reason.starts_with("CAPABILITY_INDEX_INDEXING:"))
        );
    }

    #[test]
    fn sqlite_registry_recreates_missing_vector_table_when_metadata_remains() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        let snapshot =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
        let policy = CapabilitySearchPolicy::default();
        let provider = HashEmbeddingProvider::new(64);
        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("initial vector sync");
        store
            .conn
            .execute_batch("DROP TABLE capability_index_vectors;")
            .expect("drop vector table");

        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("resync recreates vector table");
        let vector_count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM capability_index_vectors", [], |row| {
                row.get(0)
            })
            .expect("vector count");
        assert!(
            vector_count > 0,
            "resync should recreate and repopulate the vector table"
        );
    }

    #[test]
    fn sqlite_registry_batches_vector_indexing_for_registry_warmup() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        let functions = (0..20)
            .map(|index| test_function(&format!("test{index}::capability")))
            .collect::<Vec<_>>();
        let snapshot = CapabilityRegistrySnapshot::new(functions, 11);
        let policy = CapabilitySearchPolicy::default();
        let provider = CountingEmbeddingProvider::new();

        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("batched vector sync");

        let vector_count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM capability_index_vectors", [], |row| {
                row.get(0)
            })
            .expect("vector count");
        assert!(
            vector_count > 32,
            "test should exercise multiple vector jobs"
        );
        assert!(
            provider.calls() < vector_count as usize,
            "vector writes should use batched embedding calls"
        );
        assert!(
            provider.max_batch() > 1,
            "at least one embedding call should contain multiple documents"
        );
    }

    #[test]
    fn sqlite_registry_skips_unchanged_vector_documents_on_resync() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        let functions = (0..8)
            .map(|index| test_function(&format!("stable{index}::capability")))
            .collect::<Vec<_>>();
        let snapshot = CapabilityRegistrySnapshot::new(functions, 11);
        let policy = CapabilitySearchPolicy::default();
        let provider = CountingEmbeddingProvider::new();

        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("initial vector sync");
        let calls_after_initial = provider.calls();
        assert!(calls_after_initial > 0, "initial sync embeds documents");

        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("unchanged resync");
        assert_eq!(
            provider.calls(),
            calls_after_initial,
            "unchanged documents must not be re-embedded on the query or warmup path"
        );
    }

    #[test]
    fn sqlite_program_runs_keep_trace_parent_binding_and_redaction_metadata() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        store
            .record_program_run(&CapabilityProgramRunRecord {
                program_run_id: "program_run_test".to_owned(),
                parent_invocation_id: Some("invocation_parent".to_owned()),
                root_invocation_id: "invocation_root".to_owned(),
                binding_decision_id: Some("binding_decision_test".to_owned()),
                status: "ok".to_owned(),
                trace_id: "trace_test".to_owned(),
                code_hash: "code_hash".to_owned(),
                args_hash: "args_hash".to_owned(),
                limits: json!({"timeoutMs": 1000}),
                allowed_contracts: vec!["filesystem::read_file".to_owned()],
                allowed_implementations: vec!["first_party.filesystem.v1.read_file".to_owned()],
                child_invocations: vec!["child_invocation".to_owned()],
                selected_implementations: vec!["first_party.filesystem.v1.read_file".to_owned()],
                approval_state: None,
                artifacts: vec![json!({"path": "artifact.txt"})],
                logs: vec!["sensitive log".to_owned()],
                error: None,
                compensation_attempts: vec![json!({"status": "not_declared"})],
            })
            .expect("record program run");

        let redacted = store
            .program_run_query(Some("trace_test"), None, 10, false)
            .expect("program runs");
        let run = &redacted["programRuns"][0];
        assert_eq!(run["parentInvocationId"], "invocation_parent");
        assert_eq!(run["rootInvocationId"], "invocation_root");
        assert_eq!(run["bindingDecisionId"], "binding_decision_test");
        assert_eq!(run["logs"]["redacted"], true);
        assert_eq!(run["artifacts"]["count"], 1);
        assert_eq!(run["compensationAttempts"]["count"], 1);
        assert_eq!(
            run["payloadSummary"]["bindingDecisionId"],
            "binding_decision_test"
        );

        let revealed = store
            .program_run_query(Some("trace_test"), None, 10, true)
            .expect("revealed program runs");
        assert_eq!(revealed["programRuns"][0]["logs"][0], "sensitive log");
        assert_eq!(
            revealed["programRuns"][0]["compensationAttempts"][0]["status"],
            "not_declared"
        );
    }

    #[test]
    fn lifecycle_pause_and_run_records_round_trip_in_registry_store() {
        let mut store = InMemoryCapabilityRegistryStore::default();
        store
            .record_pause(&CapabilityPauseRecord {
                pause_id: "pause_test".to_owned(),
                invocation_id: "invocation_test".to_owned(),
                contract_id: "agent::ask_user".to_owned(),
                implementation_id: "first_party.agent.v1.ask_user".to_owned(),
                function_id: "agent::ask_user".to_owned(),
                plugin_id: Some("first_party.agent".to_owned()),
                worker_id: Some("agent".to_owned()),
                kind: "user_input".to_owned(),
                status: "pending".to_owned(),
                prompt_payload: json!({"question": "Proceed?"}),
                resume_schema: Some(json!({"type": "object"})),
                answer_authority: "user_client".to_owned(),
                expires_at: Some("2026-05-14T00:00:00Z".to_owned()),
                trace_id: Some("trace_test".to_owned()),
                root_invocation_id: Some("root_test".to_owned()),
                binding_decision_id: Some("binding_test".to_owned()),
            })
            .expect("record pause");
        let resolved = store
            .resolve_pause("pause_test", "resumed", json!({"answers": 1}))
            .expect("resolve pause")
            .expect("pause present");
        assert_eq!(resolved.status, "pending");
        let duplicate = store
            .resolve_pause("pause_test", "resumed", json!({"answers": 2}))
            .expect("duplicate resolve")
            .expect("pause present");
        assert_eq!(duplicate.status, "resumed");
        assert_eq!(duplicate.prompt_payload["resolution"]["answers"], json!(1));

        store
            .record_run(&CapabilityRunRecord {
                run_id: "run_test".to_owned(),
                invocation_id: "invocation_test".to_owned(),
                contract_id: "agent::spawn_subagent".to_owned(),
                implementation_id: "first_party.agent.v1.spawn_subagent".to_owned(),
                function_id: "agent::spawn_subagent".to_owned(),
                plugin_id: Some("first_party.agent".to_owned()),
                worker_id: Some("agent".to_owned()),
                status: "running".to_owned(),
                stream_topic: Some("agent.runtime".to_owned()),
                child_invocations: vec!["child_test".to_owned()],
                trace_id: Some("trace_test".to_owned()),
                root_invocation_id: Some("root_test".to_owned()),
                binding_decision_id: Some("binding_test".to_owned()),
                details: json!({"task": "check"}),
            })
            .expect("record run");
        let updated = store
            .update_run_status("run_test", "completed", json!({"result": "ok"}))
            .expect("update run")
            .expect("run present");
        assert_eq!(updated.status, "completed");
        assert_eq!(updated.details["statusDetails"]["result"], json!("ok"));
        assert_eq!(store.admin_status().expect("status")["runs"], json!(1));
    }

    #[test]
    fn registry_preserves_manual_conformance_state_across_resync() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        let snapshot =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 1);
        let policy = CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        };
        let provider = HashEmbeddingProvider::new(64);
        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("initial sync");
        store
            .set_implementation_state("first_party.filesystem.v1.read_file", "disabled")
            .expect("disable implementation");
        store
            .sync_snapshot(&snapshot, &provider, &policy)
            .expect("resync");
        assert_eq!(
            store
                .implementation_conformance_state("first_party.filesystem.v1.read_file")
                .expect("state"),
            Some("disabled".to_owned())
        );
    }

    #[test]
    fn registry_promotes_candidate_conformance_on_authoritative_resync() {
        let function = session_generated_function("rwo_n7::echo", "rwo-n7-worker");
        let snapshot = CapabilityRegistrySnapshot::new(vec![function], 1);
        let implementation_id = "session_generated.rwo_n7.echo";

        let mut memory_store = InMemoryCapabilityRegistryStore::default();
        sync_without_vectors(&mut memory_store, &snapshot);
        memory_store
            .set_implementation_state(implementation_id, "candidate")
            .expect("set candidate");
        sync_without_vectors(&mut memory_store, &snapshot);
        assert_eq!(
            memory_store
                .implementation_conformance_state(implementation_id)
                .expect("memory state"),
            Some("healthy".to_owned())
        );

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut sqlite_store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        sync_without_vectors(&mut sqlite_store, &snapshot);
        sqlite_store
            .set_implementation_state(implementation_id, "candidate")
            .expect("set candidate");
        sync_without_vectors(&mut sqlite_store, &snapshot);
        assert_eq!(
            sqlite_store
                .implementation_conformance_state(implementation_id)
                .expect("sqlite state"),
            Some("healthy".to_owned())
        );
    }

    #[test]
    fn registry_sync_removes_stale_session_generated_projection() {
        let snapshot = CapabilityRegistrySnapshot::new(
            vec![session_generated_function("rwo_n7::echo", "rwo-n7-worker")],
            1,
        );
        let empty_snapshot = CapabilityRegistrySnapshot::new(Vec::<FunctionDefinition>::new(), 2);
        let implementation_id = "session_generated.rwo_n7.echo";
        let plugin_id = "session_generated.rwo-n7-worker";

        let mut memory_store = InMemoryCapabilityRegistryStore::default();
        sync_without_vectors(&mut memory_store, &snapshot);
        assert_eq!(
            memory_store
                .implementation_conformance_state(implementation_id)
                .expect("memory state"),
            Some("healthy".to_owned())
        );
        assert!(
            memory_store
                .plugin_inspect(plugin_id)
                .expect("memory plugin inspect")
                .is_some()
        );
        sync_without_vectors(&mut memory_store, &empty_snapshot);
        assert_eq!(
            memory_store
                .implementation_conformance_state(implementation_id)
                .expect("memory state"),
            None
        );
        assert!(
            memory_store
                .plugin_inspect(plugin_id)
                .expect("memory plugin inspect")
                .is_none()
        );

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("tron.sqlite");
        let mut sqlite_store = SqliteCapabilityRegistryStore::open(&path).expect("store");
        sync_without_vectors(&mut sqlite_store, &snapshot);
        assert_eq!(
            sqlite_store
                .implementation_conformance_state(implementation_id)
                .expect("sqlite state"),
            Some("healthy".to_owned())
        );
        assert!(
            sqlite_store
                .plugin_inspect(plugin_id)
                .expect("sqlite plugin inspect")
                .is_some()
        );
        sync_without_vectors(&mut sqlite_store, &empty_snapshot);
        assert_eq!(
            sqlite_store
                .implementation_conformance_state(implementation_id)
                .expect("sqlite state"),
            None
        );
        assert!(
            sqlite_store
                .plugin_inspect(plugin_id)
                .expect("sqlite plugin inspect")
                .is_none()
        );
    }

    #[test]
    fn audit_query_redacts_payload_by_default() {
        let mut store = InMemoryCapabilityRegistryStore::default();
        store
            .record_audit_event(
                "capability.execute",
                Some("trace-1"),
                json!({
                    "contractId": "filesystem::read_file",
                    "secret": "should-not-render",
                }),
            )
            .expect("audit");
        let redacted = store
            .audit_query(Some("capability.execute"), Some("trace-1"), 10, false)
            .expect("query");
        let event = &redacted["events"][0];
        assert_eq!(event["redacted"], json!(true));
        assert_eq!(event["payload"]["redacted"], json!(true));
        assert_eq!(
            event["payloadSummary"]["contractId"],
            json!("filesystem::read_file")
        );
        assert_eq!(event["payload"].get("secret"), None);

        let revealed = store
            .audit_query(Some("capability.execute"), Some("trace-1"), 10, true)
            .expect("revealed query");
        assert_eq!(
            revealed["events"][0]["payload"]["secret"],
            json!("should-not-render")
        );
    }

    #[test]
    fn strict_registry_sync_returns_explicit_index_unavailable() {
        let snapshot =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 1);
        let mut store = InMemoryCapabilityRegistryStore::default();
        let strict_policy = CapabilitySearchPolicy {
            require_local_vector: true,
            allow_lexical_only_when_degraded: false,
            ..CapabilitySearchPolicy::default()
        };
        let error = store
            .sync_snapshot(&snapshot, &FailingEmbeddingProvider, &strict_policy)
            .expect_err("strict vector policy must fail");
        assert!(error.starts_with("CAPABILITY_INDEX_UNAVAILABLE:"));
    }

    #[test]
    fn degraded_policy_allows_lexical_only_with_status_reason() {
        let snapshot =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 1);
        let mut store = InMemoryCapabilityRegistryStore::default();
        let policy = CapabilitySearchPolicy {
            require_local_vector: false,
            allow_lexical_only_when_degraded: true,
            ..CapabilitySearchPolicy::default()
        };
        let status = store
            .sync_snapshot(&snapshot, &FailingEmbeddingProvider, &policy)
            .expect("degraded sync");
        assert_eq!(status.state, "unavailable");
        assert_eq!(
            status.degraded_reason.as_deref(),
            Some("embedding assets unavailable")
        );
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

    #[test]
    fn primer_marks_process_run_safe_direct_path() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let process = crate::domains::contract::function_definition_for_capability(&process_spec);
        let entry = CapabilityRegistryEntry::from_function(process.clone(), 1);
        let recipe = entry.agent_recipe();
        assert!(recipe.examples.iter().any(|example| {
            example["target"] == json!("process::run")
                && example["arguments"]["executionMode"] == json!("read_only")
        }));
        assert!(recipe.examples.iter().any(|example| {
            example["target"] == json!("process::run")
                && example["arguments"]["executionMode"] == json!("sandbox_materialized")
                && example["arguments"]["expectedOutputs"].is_array()
        }));

        let snapshot = CapabilityRegistrySnapshot::new(vec![process], 1);

        let text = render_capability_primer(
            &snapshot,
            &CapabilityContextPrimerPolicy {
                max_tokens: 600,
                include_compact_schemas: true,
                ..Default::default()
            },
        )
        .expect("primer");

        assert!(text.contains("process::run"));
        assert!(text.contains("conditional; payloads classified as risky"));
        assert!(text.contains("\"target\":\"process::run\""));
        assert!(!text.contains("\"capabilityId\""));
        assert!(!text.contains("inspectRevision=1"));
    }

    #[test]
    fn primer_guides_approval_gated_write_commands_to_process_run() {
        let specs = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .chain(crate::domains::process::contract::capabilities().expect("process specs"))
            .filter(|spec| {
                matches!(
                    spec.function_id.as_str(),
                    "filesystem::write_file" | "process::run"
                )
            })
            .map(|spec| crate::domains::contract::function_definition_for_capability(&spec))
            .collect::<Vec<_>>();
        let snapshot = CapabilityRegistrySnapshot::new(specs, 19);
        let text = render_capability_primer(
            &snapshot,
            &CapabilityContextPrimerPolicy {
                max_tokens: 1400,
                include_compact_schemas: true,
                include_examples: true,
                ..Default::default()
            },
        )
        .expect("primer");

        assert!(text.contains("do not target approval::request directly"));
        assert!(text.contains("Approval-gated write commands use process::run"));
        assert!(text.contains("not filesystem::write_file"));
        assert!(text.contains("\"executionMode\":\"sandbox_materialized\""));
        assert!(text.contains("\"expectedOutputs\""));
        assert!(text.contains("Each path must be relative"));
        assert!(
            text.contains("Use when: Create a new file or overwrite an existing file"),
            "write_file must keep its scratch-file recipe while the primer header disambiguates approval workflows"
        );
    }

    #[test]
    fn notification_send_is_core_searchable_and_primed() {
        let notification_spec = crate::domains::notifications::contract::capabilities()
            .expect("notification specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "notifications::send")
            .expect("notifications::send spec");
        let function =
            crate::domains::contract::function_definition_for_capability(&notification_spec);
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 12);
        assert_eq!(entry.context_primer_level, "core");
        assert!(entry.function.tags.iter().any(|tag| tag == "push"));

        let docs = vec![entry.search_document()];
        let result = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        })
        .search("send test notification push", docs, 10)
        .expect("search");
        assert_eq!(result.hits[0].contract_id, "notifications::send");

        let snapshot = CapabilityRegistrySnapshot::new(vec![function], 12);
        let text = render_capability_primer(
            &snapshot,
            &CapabilityContextPrimerPolicy {
                max_tokens: 700,
                include_compact_schemas: true,
                include_examples: true,
                ..Default::default()
            },
        )
        .expect("primer");
        assert!(text.contains("notifications::send"));
        assert!(text.contains("\"target\":\"notifications::send\""));
        assert!(!text.contains("\"capabilityId\""));
        assert!(!text.contains("inspectRevision=1"));
    }

    #[test]
    fn first_party_recipe_parity_covers_common_direct_capabilities() {
        let specs = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .chain(crate::domains::process::contract::capabilities().expect("process specs"))
            .chain(
                crate::domains::notifications::contract::capabilities()
                    .expect("notification specs"),
            )
            .collect::<Vec<_>>();

        let entries = specs
            .into_iter()
            .map(|spec| {
                CapabilityRegistryEntry::from_function(
                    crate::domains::contract::function_definition_for_capability(&spec),
                    17,
                )
            })
            .collect::<Vec<_>>();
        let by_contract = entries
            .iter()
            .map(|entry| (entry.contract_id.as_str(), entry.agent_recipe()))
            .collect::<BTreeMap<_, _>>();

        let process = by_contract.get("process::run").expect("process recipe");
        assert_eq!(process.execute_template["target"], json!("process::run"));
        assert!(
            process
                .required_payload
                .iter()
                .any(|field| field.starts_with("command:"))
        );
        assert!(
            process
                .optional_payload
                .iter()
                .any(|field| field.starts_with("expectedOutputs:"))
        );
        assert!(process.direct_execution.contains("conditional_safe_direct"));

        let notify = by_contract
            .get("notifications::send")
            .expect("notification recipe");
        assert_eq!(
            notify.execute_template["target"],
            json!("notifications::send")
        );
        assert!(
            notify
                .required_payload
                .iter()
                .any(|field| field.starts_with("title:"))
        );
        assert!(
            notify
                .required_payload
                .iter()
                .any(|field| field.starts_with("body:"))
        );

        let read = by_contract
            .get("filesystem::read_file")
            .expect("read file recipe");
        assert_eq!(
            read.execute_template["target"],
            json!("filesystem::read_file")
        );
        assert!(
            read.required_payload
                .iter()
                .any(|field| field.starts_with("path:"))
        );
        assert_eq!(read.approval_behavior, "none");
    }

    #[test]
    fn filesystem_recipes_separate_new_file_creation_from_existing_patch() {
        let specs = crate::domains::filesystem::contract::capabilities().expect("filesystem specs");
        let entries = specs
            .iter()
            .map(|spec| {
                CapabilityRegistryEntry::from_function(
                    crate::domains::contract::function_definition_for_capability(spec),
                    17,
                )
            })
            .collect::<Vec<_>>();
        let by_contract = entries
            .iter()
            .map(|entry| (entry.contract_id.as_str(), entry.agent_recipe()))
            .collect::<BTreeMap<_, _>>();

        let write = by_contract
            .get("filesystem::write_file")
            .expect("write file recipe");
        assert!(
            write.use_when.contains("new file"),
            "write_file recipe must advertise new-file creation"
        );
        assert!(
            write.use_when.contains("scratch"),
            "write_file recipe must cover scratch/docs-sandbox file creation"
        );

        let apply_patch = by_contract
            .get("filesystem::apply_patch")
            .expect("apply patch recipe");
        assert!(
            apply_patch.use_when.contains("existing"),
            "apply_patch recipe must say it targets an existing file"
        );
        assert!(
            apply_patch.use_when.contains("filesystem::write_file"),
            "apply_patch recipe must direct new-file creation to write_file"
        );
        assert!(
            apply_patch
                .required_payload
                .iter()
                .any(|field| field.contains("existing file")),
            "apply_patch required path summary must mention an existing file"
        );

        let documents = entries
            .into_iter()
            .map(|entry| entry.search_document())
            .collect::<Vec<_>>();
        let search = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        })
        .search("create scratch docs note file", documents, 8)
        .expect("filesystem search");
        assert_eq!(
            search.hits[0].contract_id, "filesystem::write_file",
            "new scratch-file searches should prefer write_file over patch"
        );
    }

    #[test]
    fn lexical_search_returns_recipes_for_common_first_party_queries() {
        let specs = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .chain(crate::domains::process::contract::capabilities().expect("process specs"))
            .chain(
                crate::domains::notifications::contract::capabilities()
                    .expect("notification specs"),
            )
            .collect::<Vec<_>>();
        let documents = specs
            .into_iter()
            .map(|spec| {
                CapabilityRegistryEntry::from_function(
                    crate::domains::contract::function_definition_for_capability(&spec),
                    18,
                )
                .search_document()
            })
            .collect::<Vec<_>>();
        let index = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        });

        let process = index
            .search("process run shell command date", documents.clone(), 8)
            .expect("process search");
        let process_recipe = process
            .hits
            .iter()
            .find(|hit| hit.contract_id == "process::run")
            .and_then(|hit| hit.recipe.as_ref())
            .expect("process recipe");
        assert!(
            process
                .hits
                .iter()
                .any(|hit| hit.contract_id == "process::run" && !hit.requires_inspect)
        );
        assert!(
            process_recipe
                .required_payload
                .iter()
                .any(|field| field.starts_with("command:"))
        );
        assert_eq!(
            process_recipe.execute_template["arguments"]["command"],
            json!("date")
        );

        let notifications = index
            .search("notification notify app", documents.clone(), 8)
            .expect("notification search");
        let notification_recipe = notifications
            .hits
            .iter()
            .find(|hit| hit.contract_id == "notifications::send")
            .and_then(|hit| hit.recipe.as_ref())
            .expect("notification recipe");
        assert!(
            notification_recipe
                .required_payload
                .iter()
                .any(|field| field.starts_with("title:"))
        );
        assert!(
            notification_recipe
                .required_payload
                .iter()
                .any(|field| field.starts_with("body:"))
        );

        let read_file = index
            .search("read file", documents, 8)
            .expect("read file search");
        let read_recipe = read_file
            .hits
            .iter()
            .find(|hit| hit.contract_id == "filesystem::read_file")
            .and_then(|hit| hit.recipe.as_ref())
            .expect("read file recipe");
        assert!(
            read_recipe
                .required_payload
                .iter()
                .any(|field| field.starts_with("path:"))
        );
    }

    #[test]
    fn approval_write_command_query_prefers_process_run_recipe() {
        let specs = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .chain(crate::domains::process::contract::capabilities().expect("process specs"))
            .collect::<Vec<_>>();
        let documents = specs
            .into_iter()
            .map(|spec| {
                CapabilityRegistryEntry::from_function(
                    crate::domains::contract::function_definition_for_capability(&spec),
                    19,
                )
                .search_document()
            })
            .collect::<Vec<_>>();
        let index = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
            local_vector: false,
            require_local_vector: false,
            ..CapabilitySearchPolicy::default()
        });

        let search = index
            .search(
                "high-risk write command approval pause resume",
                documents,
                8,
            )
            .expect("approval command search");
        let ranked = search
            .hits
            .iter()
            .map(|hit| format!("{}={:.2}", hit.contract_id, hit.lexical_score))
            .collect::<Vec<_>>()
            .join(", ");
        assert_eq!(
            search.hits[0].contract_id, "process::run",
            "approval-gated write command prompts should prefer process::run; ranked hits: {ranked}"
        );
        let process_recipe = search.hits[0].recipe.as_ref().expect("process recipe");
        assert!(
            process_recipe
                .examples
                .iter()
                .any(
                    |example| example["arguments"]["executionMode"] == "sandbox_materialized"
                        && example["arguments"]["expectedOutputs"].is_array()
                ),
            "process recipe should include a sandbox_materialized approval-shaped example"
        );
    }
}
