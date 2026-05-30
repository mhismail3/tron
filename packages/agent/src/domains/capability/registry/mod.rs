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
//! | `search_policy` | Profile-controlled search flags and document filters |
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
mod search_policy;
mod store;

pub(crate) use index::CapabilityIndexSearchResult;
#[cfg(test)]
pub(crate) use index::HybridLocalCapabilityIndex;
use index::{document_key, risk_rank, trust_rank};
use primer::is_core_context_capability;
pub(crate) use primer::{CapabilityContextPrimerPolicy, render_capability_primer};
pub(crate) use recipes::AgentCapabilityRecipeDisplay;
use recipes::agent_recipe_for_entry;
pub(crate) use search_policy::{CapabilitySearchFilters, CapabilitySearchPolicy};

use super::types::{
    AgentCapabilityRecipe, CapabilityBindingDecision, CapabilityBindingRecord,
    CapabilityContractRecord, CapabilityImplementationRecord, CapabilityInspectionHandle,
    CapabilityInspectionRecord, CapabilityPluginManifest,
};
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionHealth, RiskLevel, TriggerDefinition,
};

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
mod tests;
