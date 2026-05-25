//! Registry, binding, and local search projection for live capabilities.
//!
//! The registry is deliberately layered over the engine catalog. The catalog is
//! still the source of truth for live functions, health, visibility, authority,
//! and invocation; this module gives the capability primitives a stable
//! contract/implementation vocabulary, search index boundary, and durable audit
//! records for binding, inspection, execution, and program runs.

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use super::embeddings::EmbeddingProvider;
#[cfg(test)]
use super::embeddings::HashEmbeddingProvider;
use super::types::{
    AgentCapabilityRecipe, CapabilityBindingDecision, CapabilityBindingRecord,
    CapabilityContractRecord, CapabilityImplementationRecord, CapabilityIndexHit,
    CapabilityIndexStatus, CapabilityInspectionHandle, CapabilityInspectionRecord,
    CapabilityPauseRecord, CapabilityPluginManifest, CapabilityProgramRunRecord,
    CapabilityRunRecord,
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
    "notifications::send",
    "agent::ask_user",
    "agent::status",
    "agent::submit_answers",
    "agent::spawn_subagent",
    "agent::subagent_status",
    "agent::subagent_result",
    "agent::cancel_subagent",
    "job::wait",
    "job::stream_output",
    "worker::spawn",
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

impl CapabilitySearchPolicy {
    pub(crate) fn from_profile(
        policy: &crate::shared::profile::CapabilitySearchPolicySpec,
    ) -> Self {
        Self {
            lexical: policy.lexical,
            local_vector: policy.local_vector,
            cloud_embeddings: policy.cloud_embeddings,
            max_results: policy.max_results,
            require_local_vector: policy.require_local_vector,
            allow_lexical_only_when_degraded: policy.allow_lexical_only_when_degraded,
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
            max_tokens: 2600,
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

pub(crate) type SharedCapabilityRegistryStore = Arc<Mutex<Box<dyn CapabilityRegistryStore>>>;

pub(crate) fn open_capability_registry_store(
    engine_ledger_path: Option<PathBuf>,
) -> Result<SharedCapabilityRegistryStore, String> {
    let store: Box<dyn CapabilityRegistryStore> = match engine_ledger_path {
        Some(path) => Box::new(SqliteCapabilityRegistryStore::open(&path)?),
        None => Box::new(InMemoryCapabilityRegistryStore::default()),
    };
    Ok(Arc::new(Mutex::new(store)))
}

pub(crate) trait CapabilityRegistryStore: Send {
    fn sync_snapshot(
        &mut self,
        snapshot: &CapabilityRegistrySnapshot,
        embedding_provider: &dyn EmbeddingProvider,
        policy: &CapabilitySearchPolicy,
    ) -> Result<CapabilityIndexStatus, String>;

    fn search(
        &self,
        query: &str,
        filters: &CapabilitySearchFilters,
        policy: &CapabilitySearchPolicy,
        limit: usize,
        embedding_provider: &dyn EmbeddingProvider,
    ) -> Result<CapabilityIndexSearchResult, String>;

    fn active_binding(
        &self,
        contract_id: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
    ) -> Result<Option<CapabilityBindingRecord>, String>;

    fn implementation_conformance_state(
        &self,
        implementation_id: &str,
    ) -> Result<Option<String>, String>;

    fn record_inspection(
        &mut self,
        handle: &CapabilityInspectionHandle,
        entry: &CapabilityRegistryEntry,
        decision: &CapabilityBindingDecision,
    ) -> Result<(), String>;

    fn validate_inspection(
        &self,
        handle: &str,
        entry: &CapabilityRegistryEntry,
    ) -> Result<bool, String>;

    fn record_binding_decision(
        &mut self,
        decision: &CapabilityBindingDecision,
        selected_entry: &CapabilityRegistryEntry,
    ) -> Result<(), String>;

    fn record_audit_event(
        &mut self,
        event_type: &str,
        trace_id: Option<&str>,
        payload: Value,
    ) -> Result<(), String>;

    fn record_program_run(&mut self, record: &CapabilityProgramRunRecord) -> Result<(), String>;

    fn record_pause(&mut self, record: &CapabilityPauseRecord) -> Result<(), String>;

    fn resolve_pause(
        &mut self,
        pause_id: &str,
        status: &str,
        resolution: Value,
    ) -> Result<Option<CapabilityPauseRecord>, String>;

    fn record_run(&mut self, record: &CapabilityRunRecord) -> Result<(), String>;

    fn update_run_status(
        &mut self,
        run_id: &str,
        status: &str,
        details: Value,
    ) -> Result<Option<CapabilityRunRecord>, String>;

    fn program_run_query(
        &self,
        trace_id: Option<&str>,
        status: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String>;

    fn admin_status(&self) -> Result<Value, String>;

    fn registry_snapshot(&self) -> Result<Value, String>;

    fn audit_query(
        &self,
        event_type: Option<&str>,
        trace_id: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String>;

    fn list_bindings(&self) -> Result<Value, String>;

    fn upsert_binding(
        &mut self,
        contract_id: &str,
        scope_kind: &str,
        scope_value: &str,
        selected_implementation: &str,
        selection_policy: &str,
        secondary_implementations: &[String],
        priority: i64,
        enabled: bool,
    ) -> Result<(), String>;

    fn list_plugins(&self) -> Result<Value, String>;

    fn plugin_inspect(&self, plugin_id: &str) -> Result<Option<Value>, String>;

    fn upsert_plugin_manifest(
        &mut self,
        manifest: &CapabilityPluginManifest,
        conformance_state: &str,
        catalog_revision: u64,
    ) -> Result<(), String>;

    fn set_plugin_state(&mut self, plugin_id: &str, state: &str) -> Result<(), String>;

    fn set_implementation_state(
        &mut self,
        implementation_id: &str,
        state: &str,
    ) -> Result<(), String>;
}

#[derive(Default)]
pub(crate) struct InMemoryCapabilityRegistryStore {
    documents: BTreeMap<String, CapabilityIndexDocument>,
    bindings: BTreeMap<(String, String, String), CapabilityBindingRecord>,
    conformance: BTreeMap<String, String>,
    plugins: BTreeMap<String, Value>,
    implementations: BTreeMap<String, Value>,
    inspections: BTreeMap<String, (String, u64, String)>,
    audits: Vec<Value>,
    program_runs: BTreeMap<String, Value>,
    pauses: BTreeMap<String, CapabilityPauseRecord>,
    runs: BTreeMap<String, CapabilityRunRecord>,
}

impl CapabilityRegistryStore for InMemoryCapabilityRegistryStore {
    fn sync_snapshot(
        &mut self,
        snapshot: &CapabilityRegistrySnapshot,
        embedding_provider: &dyn EmbeddingProvider,
        policy: &CapabilitySearchPolicy,
    ) -> Result<CapabilityIndexStatus, String> {
        let prior_conformance = self.conformance.clone();
        let prior_plugins = self.plugins.clone();
        self.documents.clear();
        self.conformance.clear();
        self.plugins.clear();
        self.implementations.clear();
        for document in snapshot.index_documents() {
            let _ = self.documents.insert(document_key(&document), document);
        }
        for entry in &snapshot.entries {
            let state = prior_conformance
                .get(&entry.implementation_id)
                .cloned()
                .unwrap_or_else(|| conformance_state(&entry.function, &entry.trust_tier));
            let _ = self
                .conformance
                .insert(entry.implementation_id.clone(), state.clone());
            let mut manifest_value =
                serde_json::to_value(plugin_manifest_for_entry(entry)).unwrap_or(Value::Null);
            if let Some(existing_state) = prior_plugins
                .get(&entry.plugin_id)
                .and_then(|plugin| plugin.get("conformanceState"))
                .and_then(Value::as_str)
            {
                manifest_value["conformanceState"] = json!(existing_state);
            }
            let _ = self.plugins.insert(entry.plugin_id.clone(), manifest_value);
            let mut implementation =
                serde_json::to_value(entry.implementation_record()).unwrap_or(Value::Null);
            implementation["conformanceState"] = json!(state);
            let _ = self
                .implementations
                .insert(entry.implementation_id.clone(), implementation);
        }
        let mut status = ready_index_status(policy, embedding_provider);
        if policy.local_vector {
            let texts = self
                .documents
                .values()
                .map(|document| document.text.clone())
                .collect::<Vec<_>>();
            match embedding_provider.embed(&texts) {
                Ok(_) => {}
                Err(error) => {
                    status.state = "unavailable".to_owned();
                    status.degraded_reason = Some(error.clone());
                    if policy.require_local_vector && !policy.allow_lexical_only_when_degraded {
                        return Err(format!("CAPABILITY_INDEX_UNAVAILABLE: {error}"));
                    }
                }
            }
        }
        Ok(status)
    }

    fn search(
        &self,
        query: &str,
        filters: &CapabilitySearchFilters,
        policy: &CapabilitySearchPolicy,
        limit: usize,
        embedding_provider: &dyn EmbeddingProvider,
    ) -> Result<CapabilityIndexSearchResult, String> {
        let documents = self
            .documents
            .values()
            .filter(|document| filters.allows_document(document))
            .cloned()
            .collect::<Vec<_>>();
        let mut result = HybridLocalCapabilityIndex::new(policy.clone()).search_with_provider(
            query,
            documents,
            limit,
            embedding_provider,
        )?;
        if result.hits.is_empty() && filters.risk_max.is_some() {
            let relaxed_filters = filters.without_risk_max();
            let relaxed_documents = self
                .documents
                .values()
                .filter(|document| relaxed_filters.allows_document(document))
                .cloned()
                .collect::<Vec<_>>();
            let mut relaxed = HybridLocalCapabilityIndex::new(policy.clone())
                .search_with_provider(query, relaxed_documents, limit, embedding_provider)?;
            if !relaxed.hits.is_empty() {
                relaxed.status.degraded_reason = Some(
                    "riskMax relaxed after zero strict discovery results; execution still enforces capability policy"
                        .to_owned(),
                );
                result = relaxed;
            }
        }
        Ok(result)
    }

    fn active_binding(
        &self,
        contract_id: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
    ) -> Result<Option<CapabilityBindingRecord>, String> {
        for key in binding_scope_keys(contract_id, session_id, workspace_id) {
            if let Some(binding) = self.bindings.get(&key)
                && binding.enabled
            {
                return Ok(Some(binding.clone()));
            }
        }
        Ok(None)
    }

    fn implementation_conformance_state(
        &self,
        implementation_id: &str,
    ) -> Result<Option<String>, String> {
        Ok(self.conformance.get(implementation_id).cloned())
    }

    fn record_inspection(
        &mut self,
        handle: &CapabilityInspectionHandle,
        entry: &CapabilityRegistryEntry,
        _decision: &CapabilityBindingDecision,
    ) -> Result<(), String> {
        let _ = self.inspections.insert(
            handle.handle.clone(),
            (
                entry.implementation_id.clone(),
                handle.function_revision,
                handle.schema_digest.clone(),
            ),
        );
        Ok(())
    }

    fn validate_inspection(
        &self,
        handle: &str,
        entry: &CapabilityRegistryEntry,
    ) -> Result<bool, String> {
        Ok(self
            .inspections
            .get(handle)
            .is_some_and(|(implementation_id, revision, digest)| {
                implementation_id == &entry.implementation_id
                    && *revision == entry.function.revision.0
                    && digest == &entry.schema_digest
            }))
    }

    fn record_binding_decision(
        &mut self,
        _decision: &CapabilityBindingDecision,
        _selected_entry: &CapabilityRegistryEntry,
    ) -> Result<(), String> {
        Ok(())
    }

    fn record_audit_event(
        &mut self,
        event_type: &str,
        trace_id: Option<&str>,
        payload: Value,
    ) -> Result<(), String> {
        self.audits.push(json!({
            "eventType": event_type,
            "traceId": trace_id,
            "payload": payload,
            "createdAt": Utc::now().to_rfc3339()
        }));
        Ok(())
    }

    fn record_program_run(&mut self, record: &CapabilityProgramRunRecord) -> Result<(), String> {
        let mut value = serde_json::to_value(record)
            .map_err(|error| format!("serialize program run: {error}"))?;
        value["createdAt"] = json!(Utc::now().to_rfc3339());
        let _ = self
            .program_runs
            .insert(record.program_run_id.clone(), value);
        Ok(())
    }

    fn record_pause(&mut self, record: &CapabilityPauseRecord) -> Result<(), String> {
        let _ = self.pauses.insert(record.pause_id.clone(), record.clone());
        Ok(())
    }

    fn resolve_pause(
        &mut self,
        pause_id: &str,
        status: &str,
        resolution: Value,
    ) -> Result<Option<CapabilityPauseRecord>, String> {
        let Some(record) = self.pauses.get_mut(pause_id) else {
            return Ok(None);
        };
        let previous = record.clone();
        if record.status != "pending" {
            return Ok(Some(previous));
        }
        record.status = status.to_owned();
        record.prompt_payload = merge_record_payload(
            record.prompt_payload.clone(),
            json!({
                "resolution": resolution,
                "resolvedAt": Utc::now().to_rfc3339()
            }),
        );
        Ok(Some(previous))
    }

    fn record_run(&mut self, record: &CapabilityRunRecord) -> Result<(), String> {
        let _ = self.runs.insert(record.run_id.clone(), record.clone());
        Ok(())
    }

    fn update_run_status(
        &mut self,
        run_id: &str,
        status: &str,
        details: Value,
    ) -> Result<Option<CapabilityRunRecord>, String> {
        let Some(record) = self.runs.get_mut(run_id) else {
            return Ok(None);
        };
        record.status = status.to_owned();
        record.details = merge_record_payload(
            record.details.clone(),
            json!({
                "statusDetails": details,
                "updatedAt": Utc::now().to_rfc3339()
            }),
        );
        Ok(Some(record.clone()))
    }

    fn program_run_query(
        &self,
        trace_id: Option<&str>,
        status: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String> {
        let runs = self
            .program_runs
            .values()
            .rev()
            .filter(|run| {
                trace_id.is_none_or(|expected| {
                    run.get("traceId").and_then(Value::as_str) == Some(expected)
                }) && status.is_none_or(|expected| {
                    run.get("status").and_then(Value::as_str) == Some(expected)
                })
            })
            .take(limit)
            .cloned()
            .map(|run| redact_program_run(run, reveal_payloads))
            .collect::<Vec<_>>();
        Ok(json!({ "programRuns": runs, "redacted": !reveal_payloads }))
    }

    fn admin_status(&self) -> Result<Value, String> {
        Ok(json!({
            "plugins": self.plugins.len(),
            "implementations": self.implementations.len(),
            "bindings": self.bindings.len(),
            "documents": self.documents.len(),
            "auditEvents": self.audits.len(),
            "programRuns": self.program_runs.len(),
            "pauses": self.pauses.len(),
            "runs": self.runs.len(),
            "indexStatus": {
                "state": "memory",
                "lexical": true,
                "localVector": false,
                "cloudEmbeddings": false,
                "vectorStore": "memory",
                "embeddingModel": "none",
                "degradedReason": Value::Null
            }
        }))
    }

    fn registry_snapshot(&self) -> Result<Value, String> {
        Ok(json!({
            "plugins": self.plugins.values().cloned().collect::<Vec<_>>(),
            "implementations": self.implementations.values().cloned().collect::<Vec<_>>(),
            "bindings": self.bindings.values().cloned().collect::<Vec<_>>(),
            "documents": self.documents.values().cloned().collect::<Vec<_>>(),
            "programRuns": self.program_runs.values().cloned().collect::<Vec<_>>(),
            "pauses": self.pauses.values().cloned().collect::<Vec<_>>(),
            "runs": self.runs.values().cloned().collect::<Vec<_>>(),
        }))
    }

    fn audit_query(
        &self,
        event_type: Option<&str>,
        trace_id: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String> {
        let events = self
            .audits
            .iter()
            .rev()
            .filter(|event| {
                event_type.is_none_or(|expected| {
                    event.get("eventType").and_then(Value::as_str) == Some(expected)
                }) && trace_id.is_none_or(|expected| {
                    event.get("traceId").and_then(Value::as_str) == Some(expected)
                })
            })
            .take(limit)
            .map(|event| redact_audit_event(event.clone(), reveal_payloads))
            .collect::<Vec<_>>();
        Ok(json!({ "events": events, "redacted": !reveal_payloads }))
    }

    fn list_bindings(&self) -> Result<Value, String> {
        Ok(json!({ "bindings": self.bindings.values().cloned().collect::<Vec<_>>() }))
    }

    fn upsert_binding(
        &mut self,
        contract_id: &str,
        scope_kind: &str,
        scope_value: &str,
        selected_implementation: &str,
        selection_policy: &str,
        secondary_implementations: &[String],
        _priority: i64,
        enabled: bool,
    ) -> Result<(), String> {
        let binding = CapabilityBindingRecord {
            contract_id: contract_id.to_owned(),
            selected_implementation: selected_implementation.to_owned(),
            selection_policy: selection_policy.to_owned(),
            secondary_implementations: secondary_implementations.to_vec(),
            enabled,
        };
        let _ = self.bindings.insert(
            (
                contract_id.to_owned(),
                scope_kind.to_owned(),
                scope_value.to_owned(),
            ),
            binding,
        );
        Ok(())
    }

    fn list_plugins(&self) -> Result<Value, String> {
        Ok(json!({ "plugins": self.plugins.values().cloned().collect::<Vec<_>>() }))
    }

    fn plugin_inspect(&self, plugin_id: &str) -> Result<Option<Value>, String> {
        Ok(self.plugins.get(plugin_id).cloned().map(|manifest| {
            let implementations = self
                .implementations
                .values()
                .filter(|implementation| {
                    implementation.get("pluginId").and_then(Value::as_str) == Some(plugin_id)
                })
                .cloned()
                .collect::<Vec<_>>();
            json!({ "manifest": manifest, "implementations": implementations })
        }))
    }

    fn upsert_plugin_manifest(
        &mut self,
        manifest: &CapabilityPluginManifest,
        conformance_state: &str,
        _catalog_revision: u64,
    ) -> Result<(), String> {
        let mut value = serde_json::to_value(manifest)
            .map_err(|error| format!("serialize plugin manifest: {error}"))?;
        value["conformanceState"] = json!(conformance_state);
        let _ = self.plugins.insert(manifest.id.clone(), value);
        Ok(())
    }

    fn set_plugin_state(&mut self, plugin_id: &str, state: &str) -> Result<(), String> {
        let Some(plugin) = self.plugins.get_mut(plugin_id) else {
            return Err(format!("plugin '{plugin_id}' not found"));
        };
        plugin["conformanceState"] = json!(state);
        Ok(())
    }

    fn set_implementation_state(
        &mut self,
        implementation_id: &str,
        state: &str,
    ) -> Result<(), String> {
        let _ = self
            .conformance
            .insert(implementation_id.to_owned(), state.to_owned());
        if let Some(implementation) = self.implementations.get_mut(implementation_id) {
            implementation["conformanceState"] = json!(state);
        }
        Ok(())
    }
}

pub(crate) struct SqliteCapabilityRegistryStore {
    conn: Connection,
}

#[derive(Clone, Copy, Debug)]
struct DocumentUpsert {
    rowid: i64,
    vector_stale: bool,
}

fn search_sqlite_documents(
    store: &SqliteCapabilityRegistryStore,
    query: &str,
    documents: Vec<CapabilityIndexDocument>,
    policy: &CapabilitySearchPolicy,
    limit: usize,
    embedding_provider: &dyn EmbeddingProvider,
) -> Result<CapabilityIndexSearchResult, String> {
    let mut lexical_hits = if policy.lexical {
        lexical_rank(query, &documents)
    } else {
        Vec::new()
    };
    let mut status = ready_index_status(policy, embedding_provider);
    if policy.local_vector && !query.trim().is_empty() && !documents.is_empty() {
        let vector_hits = store.vector_search(query, &documents, limit, embedding_provider);
        match vector_hits {
            Ok(hits) => {
                lexical_hits = fuse_hits(lexical_hits, hits, &documents);
            }
            Err(error) => {
                status.state = if is_vector_indexing_error(&error) {
                    "indexing".to_owned()
                } else {
                    "unavailable".to_owned()
                };
                status.degraded_reason = Some(error.clone());
                if policy.require_local_vector
                    && !policy.allow_lexical_only_when_degraded
                    && !is_vector_indexing_error(&error)
                {
                    return Err(format!("CAPABILITY_INDEX_UNAVAILABLE: {error}"));
                }
            }
        }
    }
    lexical_hits.truncate(limit.min(policy.max_results.max(1)));
    Ok(CapabilityIndexSearchResult {
        hits: lexical_hits,
        status,
    })
}

fn is_vector_indexing_error(error: &str) -> bool {
    error.starts_with("CAPABILITY_INDEX_INDEXING:")
}

impl SqliteCapabilityRegistryStore {
    pub(crate) fn open(path: &Path) -> Result<Self, String> {
        register_sqlite_vec_extension()?;
        let conn =
            Connection::open(path).map_err(|error| format!("open registry store: {error}"))?;
        let store = Self { conn };
        store.initialize_schema()?;
        Ok(store)
    }

    fn initialize_schema(&self) -> Result<(), String> {
        self.conn
            .execute_batch(CAPABILITY_REGISTRY_SCHEMA)
            .map_err(|error| format!("initialize capability registry schema: {error}"))?;
        self.ensure_schema_columns()?;
        Ok(())
    }

    fn ensure_schema_columns(&self) -> Result<(), String> {
        let has_text_hash = self
            .conn
            .prepare("PRAGMA table_info(capability_index_documents)")
            .and_then(|mut stmt| {
                let columns = stmt.query_map([], |row| row.get::<_, String>(1))?;
                for column in columns {
                    if column? == "text_hash" {
                        return Ok(true);
                    }
                }
                Ok(false)
            })
            .map_err(|error| format!("inspect capability_index_documents schema: {error}"))?;
        if !has_text_hash {
            self.conn
                .execute(
                    "ALTER TABLE capability_index_documents
                     ADD COLUMN text_hash TEXT NOT NULL DEFAULT ''",
                    [],
                )
                .map_err(|error| format!("add capability document text_hash column: {error}"))?;
        }
        Ok(())
    }

    fn read_pause(&self, pause_id: &str) -> Result<Option<CapabilityPauseRecord>, String> {
        self.conn
            .query_row(
                "SELECT pause_id, invocation_id, contract_id, implementation_id, function_id,
                        plugin_id, worker_id, kind, status, prompt_payload_json,
                        resume_schema_json, answer_authority, expires_at, trace_id,
                        root_invocation_id, binding_decision_id
                 FROM capability_pauses WHERE pause_id = ?1",
                params![pause_id],
                |row| {
                    Ok(CapabilityPauseRecord {
                        pause_id: row.get(0)?,
                        invocation_id: row.get(1)?,
                        contract_id: row.get(2)?,
                        implementation_id: row.get(3)?,
                        function_id: row.get(4)?,
                        plugin_id: row.get(5)?,
                        worker_id: row.get(6)?,
                        kind: row.get(7)?,
                        status: row.get(8)?,
                        prompt_payload: json_from_row(row.get::<_, String>(9)?),
                        resume_schema: serde_json::from_str::<Option<Value>>(
                            &row.get::<_, String>(10)?,
                        )
                        .unwrap_or(None),
                        answer_authority: row.get(11)?,
                        expires_at: row.get(12)?,
                        trace_id: row.get(13)?,
                        root_invocation_id: row.get(14)?,
                        binding_decision_id: row.get(15)?,
                    })
                },
            )
            .optional()
            .map_err(|error| format!("read capability pause: {error}"))
    }

    fn read_run(&self, run_id: &str) -> Result<Option<CapabilityRunRecord>, String> {
        self.conn
            .query_row(
                "SELECT run_id, invocation_id, contract_id, implementation_id, function_id,
                        plugin_id, worker_id, status, stream_topic, child_invocations_json,
                        trace_id, root_invocation_id, binding_decision_id, details_json
                 FROM capability_runs WHERE run_id = ?1",
                params![run_id],
                |row| {
                    let child_invocations =
                        serde_json::from_str::<Vec<String>>(&row.get::<_, String>(9)?)
                            .unwrap_or_default();
                    Ok(CapabilityRunRecord {
                        run_id: row.get(0)?,
                        invocation_id: row.get(1)?,
                        contract_id: row.get(2)?,
                        implementation_id: row.get(3)?,
                        function_id: row.get(4)?,
                        plugin_id: row.get(5)?,
                        worker_id: row.get(6)?,
                        status: row.get(7)?,
                        stream_topic: row.get(8)?,
                        child_invocations,
                        trace_id: row.get(10)?,
                        root_invocation_id: row.get(11)?,
                        binding_decision_id: row.get(12)?,
                        details: json_from_row(row.get::<_, String>(13)?),
                    })
                },
            )
            .optional()
            .map_err(|error| format!("read capability run: {error}"))
    }

    fn ensure_vector_table(&self, dimensions: usize, model_id: &str) -> Result<(), String> {
        register_sqlite_vec_extension()?;
        let current: Option<(usize, String)> = self
            .conn
            .query_row(
                "SELECT dimension, model_id FROM capability_vector_metadata WHERE name = 'default'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|error| format!("read capability vector metadata: {error}"))?;
        let table_exists = self.vector_table_exists()?;
        let metadata_matches = current.as_ref().is_some_and(|(dimension, current_model)| {
            *dimension == dimensions && current_model == model_id
        });
        if !metadata_matches || !table_exists {
            self.conn
                .execute_batch(
                    "DROP TABLE IF EXISTS capability_index_vectors;
                     DELETE FROM capability_vector_metadata WHERE name = 'default';",
                )
                .map_err(|error| format!("reset capability vector table: {error}"))?;
            self.conn
                .execute(
                    &format!(
                        "CREATE VIRTUAL TABLE capability_index_vectors USING vec0(embedding float[{dimensions}] distance_metric=cosine)"
                    ),
                    [],
                )
                .map_err(|error| format!("create capability vector table: {error}"))?;
            self.conn
                .execute(
                    "INSERT INTO capability_vector_metadata(name, dimension, model_id, state, updated_at)
                     VALUES ('default', ?1, ?2, 'ready', ?3)",
                    params![
                        dimensions as i64,
                        model_id,
                        Utc::now().to_rfc3339()
                    ],
                )
                .map_err(|error| format!("write capability vector metadata: {error}"))?;
        }
        Ok(())
    }

    fn vector_table_exists(&self) -> Result<bool, String> {
        self.conn
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE name = 'capability_index_vectors'
                      AND type IN ('table', 'virtual table')
                 )",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map(|value| value != 0)
            .map_err(|error| format!("check capability vector table: {error}"))
    }

    fn record_vector_unavailable(
        &self,
        dimensions: usize,
        model_id: &str,
        error: &str,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO capability_vector_metadata(name, dimension, model_id, state, degraded_reason, updated_at)
                 VALUES ('default', ?1, ?2, 'unavailable', ?3, ?4)
                 ON CONFLICT(name) DO UPDATE SET
                    dimension = excluded.dimension,
                    model_id = excluded.model_id,
                    state = excluded.state,
                    degraded_reason = excluded.degraded_reason,
                    updated_at = excluded.updated_at",
                params![
                    dimensions as i64,
                    model_id,
                    error,
                    Utc::now().to_rfc3339()
                ],
            )
            .map(|_| ())
            .map_err(|error| format!("record capability vector unavailable: {error}"))
    }

    fn upsert_document(
        &self,
        document: &CapabilityIndexDocument,
    ) -> Result<DocumentUpsert, String> {
        let key = document_key(document);
        let text_hash = document_text_hash(document);
        let previous_hash = self
            .conn
            .query_row(
                "SELECT text_hash FROM capability_index_documents WHERE document_key = ?1",
                params![key.as_str()],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| format!("read capability index document hash: {error}"))?;
        self.conn
            .execute(
                "INSERT INTO capability_index_documents
                   (document_key, kind, capability_id, contract_id, implementation_id,
                    plugin_id, worker_id, function_id, catalog_revision, schema_digest,
                    trust_tier, health, visibility, effect_class, risk_level, text,
                    text_hash, document_json, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
                 ON CONFLICT(document_key) DO UPDATE SET
                    kind = excluded.kind,
                    capability_id = excluded.capability_id,
                    contract_id = excluded.contract_id,
                    implementation_id = excluded.implementation_id,
                    plugin_id = excluded.plugin_id,
                    worker_id = excluded.worker_id,
                    function_id = excluded.function_id,
                    catalog_revision = excluded.catalog_revision,
                    schema_digest = excluded.schema_digest,
                    trust_tier = excluded.trust_tier,
                    health = excluded.health,
                    visibility = excluded.visibility,
                    effect_class = excluded.effect_class,
                    risk_level = excluded.risk_level,
                    text = excluded.text,
                    text_hash = excluded.text_hash,
                    document_json = excluded.document_json,
                    updated_at = excluded.updated_at",
                params![
                    key.as_str(),
                    document.kind,
                    document.capability_id,
                    document.contract_id,
                    document.implementation_id,
                    document.plugin_id,
                    document.worker_id,
                    document.function_id,
                    document.catalog_revision as i64,
                    document.schema_digest,
                    document.trust_tier,
                    document.health,
                    document.visibility,
                    document.effect_class,
                    document.risk_level,
                    document.text,
                    text_hash.as_str(),
                    serde_json::to_string(document)
                        .map_err(|error| format!("serialize index document: {error}"))?,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("upsert capability index document: {error}"))?;
        let rowid = self
            .conn
            .query_row(
                "SELECT rowid FROM capability_index_documents WHERE document_key = ?1",
                params![key.as_str()],
                |row| row.get(0),
            )
            .map_err(|error| format!("read capability index document rowid: {error}"))?;
        let text_changed = previous_hash.as_deref() != Some(text_hash.as_str());
        Ok(DocumentUpsert {
            rowid,
            vector_stale: text_changed || !self.vector_exists(rowid)?,
        })
    }

    fn vector_exists(&self, rowid: i64) -> Result<bool, String> {
        if !self.vector_table_exists()? {
            return Ok(false);
        }
        self.conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM capability_index_vectors WHERE rowid = ?1)",
                params![rowid],
                |row| row.get::<_, i64>(0),
            )
            .map(|value| value != 0)
            .map_err(|error| format!("check capability vector freshness: {error}"))
    }

    fn load_documents(
        &self,
        filters: &CapabilitySearchFilters,
    ) -> Result<Vec<CapabilityIndexDocument>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT document_json FROM capability_index_documents")
            .map_err(|error| format!("prepare capability document load: {error}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| format!("query capability documents: {error}"))?;
        let mut documents = Vec::new();
        for row in rows {
            let json = row.map_err(|error| format!("read capability document row: {error}"))?;
            let document: CapabilityIndexDocument =
                serde_json::from_str(&json).map_err(|error| format!("decode document: {error}"))?;
            if filters.allows_document(&document) {
                documents.push(document);
            }
        }
        Ok(documents)
    }
}

impl CapabilityRegistryStore for SqliteCapabilityRegistryStore {
    fn sync_snapshot(
        &mut self,
        snapshot: &CapabilityRegistrySnapshot,
        embedding_provider: &dyn EmbeddingProvider,
        policy: &CapabilitySearchPolicy,
    ) -> Result<CapabilityIndexStatus, String> {
        let mut status = ready_index_status(policy, embedding_provider);
        let documents = snapshot.index_documents();
        let keys = documents.iter().map(document_key).collect::<BTreeSet<_>>();
        let tx = self
            .conn
            .transaction()
            .map_err(|error| format!("begin capability registry sync: {error}"))?;
        for entry in &snapshot.entries {
            let manifest = plugin_manifest_for_entry(entry);
            tx.execute(
                "INSERT INTO capability_plugins
                   (plugin_id, manifest_json, trust_tier, signature_status, conformance_state,
                    catalog_revision, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(plugin_id) DO UPDATE SET
                    manifest_json = excluded.manifest_json,
                    trust_tier = excluded.trust_tier,
                    signature_status = excluded.signature_status,
                    conformance_state = CASE
                      WHEN capability_plugins.conformance_state IN ('candidate', 'degraded', 'quarantined', 'disabled')
                      THEN capability_plugins.conformance_state
                      ELSE excluded.conformance_state
                    END,
                    catalog_revision = excluded.catalog_revision,
                    updated_at = excluded.updated_at",
                params![
                    manifest.id,
                    serde_json::to_string(&manifest)
                        .map_err(|error| format!("serialize plugin manifest: {error}"))?,
                    manifest.trust_tier,
                    manifest.signature_status,
                    manifest.conformance_state,
                    snapshot.catalog_revision as i64,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("upsert capability plugin: {error}"))?;
            tx.execute(
                "INSERT INTO capability_implementations
                   (implementation_id, contract_id, function_id, plugin_id, worker_id,
                    schema_digest, catalog_revision, trust_tier, health, visibility,
                    conformance_state, signature_status, function_json, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                 ON CONFLICT(implementation_id) DO UPDATE SET
                    contract_id = excluded.contract_id,
                    function_id = excluded.function_id,
                    plugin_id = excluded.plugin_id,
                    worker_id = excluded.worker_id,
                    schema_digest = excluded.schema_digest,
                    catalog_revision = excluded.catalog_revision,
                    trust_tier = excluded.trust_tier,
                    health = excluded.health,
                    visibility = excluded.visibility,
                    conformance_state = CASE
                      WHEN capability_implementations.conformance_state IN ('candidate', 'degraded', 'quarantined', 'disabled')
                      THEN capability_implementations.conformance_state
                      ELSE excluded.conformance_state
                    END,
                    signature_status = excluded.signature_status,
                    function_json = excluded.function_json,
                    updated_at = excluded.updated_at",
                params![
                    entry.implementation_id,
                    entry.contract_id,
                    entry.function_id,
                    entry.plugin_id,
                    entry.worker_id,
                    entry.schema_digest,
                    snapshot.catalog_revision as i64,
                    entry.trust_tier,
                    format!("{:?}", entry.function.health),
                    entry.visibility,
                    conformance_state(&entry.function, &entry.trust_tier),
                    signature_status(&entry.function, &entry.trust_tier),
                    serde_json::to_string(&entry.function)
                        .map_err(|error| format!("serialize function definition: {error}"))?,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("upsert capability implementation: {error}"))?;
        }
        tx.commit()
            .map_err(|error| format!("commit capability registry sync: {error}"))?;

        let vector_index_ready = if policy.local_vector {
            match self.ensure_vector_table(
                embedding_provider.dimensions(),
                embedding_provider.model_id(),
            ) {
                Ok(()) => true,
                Err(error) => {
                    status.state = "unavailable".to_owned();
                    status.degraded_reason = Some(error.clone());
                    let _ = self.record_vector_unavailable(
                        embedding_provider.dimensions(),
                        embedding_provider.model_id(),
                        &error,
                    );
                    if policy.require_local_vector && !policy.allow_lexical_only_when_degraded {
                        return Err(format!("CAPABILITY_INDEX_UNAVAILABLE: {error}"));
                    }
                    false
                }
            }
        } else {
            false
        };

        let mut vector_jobs = Vec::new();
        for document in &documents {
            let upsert = self.upsert_document(document)?;
            if policy.local_vector && vector_index_ready && upsert.vector_stale {
                vector_jobs.push((upsert.rowid, document.text.clone()));
            }
        }
        if policy.local_vector && !vector_jobs.is_empty() {
            match self.write_vectors(&vector_jobs, embedding_provider) {
                Ok(()) => {
                    self.conn
                        .execute(
                            "UPDATE capability_vector_metadata
                             SET state = 'ready', degraded_reason = NULL, model_id = ?1, updated_at = ?2
                             WHERE name = 'default'",
                            params![embedding_provider.model_id(), Utc::now().to_rfc3339()],
                        )
                        .map_err(|error| format!("update capability vector metadata: {error}"))?;
                }
                Err(error) => {
                    status.state = "unavailable".to_owned();
                    status.degraded_reason = Some(error.clone());
                    let _ = self.record_vector_unavailable(
                        embedding_provider.dimensions(),
                        embedding_provider.model_id(),
                        &error,
                    );
                    if policy.require_local_vector && !policy.allow_lexical_only_when_degraded {
                        return Err(format!("CAPABILITY_INDEX_UNAVAILABLE: {error}"));
                    }
                }
            }
        }
        let keep_json = serde_json::to_string(&keys.into_iter().collect::<Vec<_>>())
            .map_err(|error| format!("serialize live document keys: {error}"))?;
        self.conn
            .execute(
                "DELETE FROM capability_index_documents
                 WHERE document_key NOT IN (SELECT value FROM json_each(?1))",
                params![keep_json],
            )
            .map_err(|error| format!("delete stale capability documents: {error}"))?;
        let _ = self.conn.execute(
            "DELETE FROM capability_index_vectors
             WHERE rowid NOT IN (SELECT rowid FROM capability_index_documents)",
            [],
        );
        Ok(status)
    }

    fn search(
        &self,
        query: &str,
        filters: &CapabilitySearchFilters,
        policy: &CapabilitySearchPolicy,
        limit: usize,
        embedding_provider: &dyn EmbeddingProvider,
    ) -> Result<CapabilityIndexSearchResult, String> {
        let documents = self.load_documents(filters)?;
        let mut result =
            search_sqlite_documents(self, query, documents, policy, limit, embedding_provider)?;
        if result.hits.is_empty() && filters.risk_max.is_some() {
            let relaxed_filters = filters.without_risk_max();
            let relaxed_documents = self.load_documents(&relaxed_filters)?;
            let mut relaxed = search_sqlite_documents(
                self,
                query,
                relaxed_documents,
                policy,
                limit,
                embedding_provider,
            )?;
            if !relaxed.hits.is_empty() {
                relaxed.status.degraded_reason = Some(
                    "riskMax relaxed after zero strict discovery results; execution still enforces capability policy"
                        .to_owned(),
                );
                result = relaxed;
            }
        }
        Ok(result)
    }

    fn active_binding(
        &self,
        contract_id: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
    ) -> Result<Option<CapabilityBindingRecord>, String> {
        for (scope_kind, scope_value) in binding_scope_parts(session_id, workspace_id) {
            let value = self
                .conn
                .query_row(
                    "SELECT selected_implementation, selection_policy, secondary_implementations_json, enabled
                     FROM capability_bindings
                     WHERE contract_id = ?1 AND scope_kind = ?2 AND scope_value = ?3
                     ORDER BY priority DESC, updated_at DESC LIMIT 1",
                    params![contract_id, scope_kind, scope_value],
                    |row| {
                        Ok(CapabilityBindingRecord {
                            contract_id: contract_id.to_owned(),
                            selected_implementation: row.get(0)?,
                            selection_policy: row.get(1)?,
                            secondary_implementations: serde_json::from_str(
                                &row.get::<_, String>(2)?,
                            )
                            .unwrap_or_default(),
                            enabled: row.get::<_, i64>(3)? == 1,
                        })
                    },
                )
                .optional()
                .map_err(|error| format!("read capability binding: {error}"))?;
            if let Some(binding) = value
                && binding.enabled
            {
                return Ok(Some(binding));
            }
        }
        Ok(None)
    }

    fn implementation_conformance_state(
        &self,
        implementation_id: &str,
    ) -> Result<Option<String>, String> {
        self.conn
            .query_row(
                "SELECT conformance_state FROM capability_implementations WHERE implementation_id = ?1",
                params![implementation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| format!("read implementation conformance: {error}"))
    }

    fn record_inspection(
        &mut self,
        handle: &CapabilityInspectionHandle,
        entry: &CapabilityRegistryEntry,
        decision: &CapabilityBindingDecision,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO capability_inspection_handles
                   (handle, contract_id, implementation_id, function_id, catalog_revision,
                    function_revision, schema_digest, binding_decision_json, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(handle) DO UPDATE SET
                    binding_decision_json = excluded.binding_decision_json",
                params![
                    handle.handle,
                    entry.contract_id,
                    entry.implementation_id,
                    entry.function_id,
                    handle.catalog_revision as i64,
                    handle.function_revision as i64,
                    handle.schema_digest,
                    serde_json::to_string(decision)
                        .map_err(|error| format!("serialize binding decision: {error}"))?,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("record inspection handle: {error}"))?;
        Ok(())
    }

    fn validate_inspection(
        &self,
        handle: &str,
        entry: &CapabilityRegistryEntry,
    ) -> Result<bool, String> {
        let found = self
            .conn
            .query_row(
                "SELECT implementation_id, function_revision, schema_digest
                 FROM capability_inspection_handles WHERE handle = ?1",
                params![handle],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, u64>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| format!("validate inspection handle: {error}"))?;
        Ok(
            found.is_some_and(|(implementation_id, revision, schema_digest)| {
                implementation_id == entry.implementation_id
                    && revision == entry.function.revision.0
                    && schema_digest == entry.schema_digest
            }),
        )
    }

    fn record_binding_decision(
        &mut self,
        decision: &CapabilityBindingDecision,
        selected_entry: &CapabilityRegistryEntry,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO capability_binding_decisions
                   (id, contract_id, selected_implementation, selected_function_id,
                    selection_policy, rejected_candidates_json, catalog_revision,
                    schema_digest, plugin_id, worker_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    decision.decision_id,
                    decision.contract_id,
                    decision.selected_implementation,
                    decision.selected_function_id,
                    decision.selection_policy,
                    serde_json::to_string(&decision.rejected_candidates)
                        .map_err(|error| format!("serialize rejected candidates: {error}"))?,
                    decision.catalog_revision as i64,
                    decision.schema_digest,
                    selected_entry.plugin_id,
                    selected_entry.worker_id,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("record binding decision: {error}"))?;
        Ok(())
    }

    fn record_audit_event(
        &mut self,
        event_type: &str,
        trace_id: Option<&str>,
        payload: Value,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO capability_audit_events(id, event_type, trace_id, payload_json, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    format!("capability_audit:{}:{}", Utc::now().timestamp_nanos_opt().unwrap_or_default(), uuid::Uuid::now_v7()),
                    event_type,
                    trace_id,
                    serde_json::to_string(&payload)
                        .map_err(|error| format!("serialize audit payload: {error}"))?,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("record capability audit event: {error}"))?;
        Ok(())
    }

    fn record_program_run(&mut self, record: &CapabilityProgramRunRecord) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO capability_program_runs(
                    program_run_id, parent_invocation_id, root_invocation_id,
                    binding_decision_id, status, trace_id, code_hash, args_hash,
                    limits_json, allowed_contracts_json, allowed_implementations_json,
                    child_invocations_json, selected_implementations_json, approval_state_json,
                    artifacts_json, logs_json, error_json, compensation_attempts_json,
                    created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?19)
                 ON CONFLICT(program_run_id) DO UPDATE SET
                    parent_invocation_id = excluded.parent_invocation_id,
                    root_invocation_id = excluded.root_invocation_id,
                    binding_decision_id = excluded.binding_decision_id,
                    status = excluded.status,
                    trace_id = excluded.trace_id,
                    code_hash = excluded.code_hash,
                    args_hash = excluded.args_hash,
                    limits_json = excluded.limits_json,
                    allowed_contracts_json = excluded.allowed_contracts_json,
                    allowed_implementations_json = excluded.allowed_implementations_json,
                    child_invocations_json = excluded.child_invocations_json,
                    selected_implementations_json = excluded.selected_implementations_json,
                    approval_state_json = excluded.approval_state_json,
                    artifacts_json = excluded.artifacts_json,
                    logs_json = excluded.logs_json,
                    error_json = excluded.error_json,
                    compensation_attempts_json = excluded.compensation_attempts_json,
                    updated_at = excluded.updated_at",
                params![
                    record.program_run_id,
                    record.parent_invocation_id,
                    record.root_invocation_id,
                    record.binding_decision_id,
                    record.status,
                    record.trace_id,
                    record.code_hash,
                    record.args_hash,
                    serde_json::to_string(&record.limits)
                        .map_err(|error| format!("serialize program limits: {error}"))?,
                    serde_json::to_string(&record.allowed_contracts)
                        .map_err(|error| format!("serialize allowed contracts: {error}"))?,
                    serde_json::to_string(&record.allowed_implementations)
                        .map_err(|error| format!("serialize allowed implementations: {error}"))?,
                    serde_json::to_string(&record.child_invocations)
                        .map_err(|error| format!("serialize child invocations: {error}"))?,
                    serde_json::to_string(&record.selected_implementations)
                        .map_err(|error| format!("serialize selected implementations: {error}"))?,
                    serde_json::to_string(&record.approval_state)
                        .map_err(|error| format!("serialize approval state: {error}"))?,
                    serde_json::to_string(&record.artifacts)
                        .map_err(|error| format!("serialize artifacts: {error}"))?,
                    serde_json::to_string(&record.logs)
                        .map_err(|error| format!("serialize logs: {error}"))?,
                    serde_json::to_string(&record.error)
                        .map_err(|error| format!("serialize program error: {error}"))?,
                    serde_json::to_string(&record.compensation_attempts).map_err(|error| {
                        format!("serialize compensation attempts: {error}")
                    })?,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("record program run: {error}"))?;
        Ok(())
    }

    fn record_pause(&mut self, record: &CapabilityPauseRecord) -> Result<(), String> {
        let now = Utc::now().to_rfc3339();
        self.conn
            .execute(
                "INSERT INTO capability_pauses(
                    pause_id, invocation_id, contract_id, implementation_id, function_id,
                    plugin_id, worker_id, kind, status, prompt_payload_json, resume_schema_json,
                    answer_authority, expires_at, trace_id, root_invocation_id,
                    binding_decision_id, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?17)
                 ON CONFLICT(pause_id) DO UPDATE SET
                    status = excluded.status,
                    prompt_payload_json = excluded.prompt_payload_json,
                    updated_at = excluded.updated_at",
                params![
                    record.pause_id,
                    record.invocation_id,
                    record.contract_id,
                    record.implementation_id,
                    record.function_id,
                    record.plugin_id,
                    record.worker_id,
                    record.kind,
                    record.status,
                    serde_json::to_string(&record.prompt_payload)
                        .map_err(|error| format!("serialize pause payload: {error}"))?,
                    serde_json::to_string(&record.resume_schema)
                        .map_err(|error| format!("serialize pause resume schema: {error}"))?,
                    record.answer_authority,
                    record.expires_at,
                    record.trace_id,
                    record.root_invocation_id,
                    record.binding_decision_id,
                    now,
                ],
            )
            .map_err(|error| format!("record capability pause: {error}"))?;
        Ok(())
    }

    fn resolve_pause(
        &mut self,
        pause_id: &str,
        status: &str,
        resolution: Value,
    ) -> Result<Option<CapabilityPauseRecord>, String> {
        let Some(mut record) = self.read_pause(pause_id)? else {
            return Ok(None);
        };
        let previous = record.clone();
        if record.status != "pending" {
            return Ok(Some(previous));
        }
        record.status = status.to_owned();
        record.prompt_payload = merge_record_payload(
            record.prompt_payload,
            json!({
                "resolution": resolution,
                "resolvedAt": Utc::now().to_rfc3339()
            }),
        );
        self.record_pause(&record)?;
        Ok(Some(previous))
    }

    fn record_run(&mut self, record: &CapabilityRunRecord) -> Result<(), String> {
        let now = Utc::now().to_rfc3339();
        self.conn
            .execute(
                "INSERT INTO capability_runs(
                    run_id, invocation_id, contract_id, implementation_id, function_id,
                    plugin_id, worker_id, status, stream_topic, child_invocations_json,
                    trace_id, root_invocation_id, binding_decision_id, details_json,
                    created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?15)
                 ON CONFLICT(run_id) DO UPDATE SET
                    status = excluded.status,
                    child_invocations_json = excluded.child_invocations_json,
                    details_json = excluded.details_json,
                    updated_at = excluded.updated_at",
                params![
                    record.run_id,
                    record.invocation_id,
                    record.contract_id,
                    record.implementation_id,
                    record.function_id,
                    record.plugin_id,
                    record.worker_id,
                    record.status,
                    record.stream_topic,
                    serde_json::to_string(&record.child_invocations)
                        .map_err(|error| format!("serialize child invocations: {error}"))?,
                    record.trace_id,
                    record.root_invocation_id,
                    record.binding_decision_id,
                    serde_json::to_string(&record.details)
                        .map_err(|error| format!("serialize run details: {error}"))?,
                    now,
                ],
            )
            .map_err(|error| format!("record capability run: {error}"))?;
        Ok(())
    }

    fn update_run_status(
        &mut self,
        run_id: &str,
        status: &str,
        details: Value,
    ) -> Result<Option<CapabilityRunRecord>, String> {
        let Some(mut record) = self.read_run(run_id)? else {
            return Ok(None);
        };
        record.status = status.to_owned();
        record.details = merge_record_payload(
            record.details,
            json!({
                "statusDetails": details,
                "updatedAt": Utc::now().to_rfc3339()
            }),
        );
        self.record_run(&record)?;
        Ok(Some(record))
    }

    fn program_run_query(
        &self,
        trace_id: Option<&str>,
        status: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT program_run_id, status, trace_id, code_hash, args_hash,
                        parent_invocation_id, root_invocation_id, binding_decision_id,
                        limits_json, allowed_contracts_json, allowed_implementations_json,
                        child_invocations_json, selected_implementations_json, approval_state_json,
                        artifacts_json, logs_json, error_json, compensation_attempts_json,
                        created_at, updated_at
                 FROM capability_program_runs
                 WHERE (?1 IS NULL OR trace_id = ?1)
                   AND (?2 IS NULL OR status = ?2)
                 ORDER BY updated_at DESC
                 LIMIT ?3",
            )
            .map_err(|error| format!("prepare program run query: {error}"))?;
        let rows = stmt
            .query_map(params![trace_id, status, limit as i64], |row| {
                let limits = json_from_row(row.get::<_, String>(8)?);
                let approval_state = json_from_row(row.get::<_, String>(13)?);
                Ok(json!({
                    "programRunId": row.get::<_, String>(0)?,
                    "status": row.get::<_, String>(1)?,
                    "traceId": row.get::<_, String>(2)?,
                    "codeHash": row.get::<_, String>(3)?,
                    "argsHash": row.get::<_, String>(4)?,
                    "parentInvocationId": row.get::<_, Option<String>>(5)?,
                    "rootInvocationId": row.get::<_, String>(6)?,
                    "bindingDecisionId": row.get::<_, Option<String>>(7)?,
                    "limits": limits,
                    "allowedContracts": json_from_row(row.get::<_, String>(9)?),
                    "allowedImplementations": json_from_row(row.get::<_, String>(10)?),
                    "childInvocations": json_from_row(row.get::<_, String>(11)?),
                    "selectedImplementations": json_from_row(row.get::<_, String>(12)?),
                    "approvalState": approval_state,
                    "artifacts": json_from_row(row.get::<_, String>(14)?),
                    "logs": json_from_row(row.get::<_, String>(15)?),
                    "error": json_from_row(row.get::<_, String>(16)?),
                    "compensationAttempts": json_from_row(row.get::<_, String>(17)?),
                    "createdAt": row.get::<_, String>(18)?,
                    "updatedAt": row.get::<_, String>(19)?,
                }))
            })
            .map_err(|error| format!("query program runs: {error}"))?;
        let mut runs = Vec::new();
        for row in rows {
            runs.push(redact_program_run(
                row.map_err(|error| format!("read program run: {error}"))?,
                reveal_payloads,
            ));
        }
        Ok(json!({ "programRuns": runs, "redacted": !reveal_payloads }))
    }

    fn admin_status(&self) -> Result<Value, String> {
        let count = |table: &str| -> Result<i64, String> {
            self.conn
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                    row.get(0)
                })
                .map_err(|error| format!("count {table}: {error}"))
        };
        let vector = self
            .conn
            .query_row(
                "SELECT dimension, model_id, state, degraded_reason, updated_at
                 FROM capability_vector_metadata WHERE name = 'default'",
                [],
                |row| {
                    Ok(json!({
                        "dimension": row.get::<_, i64>(0)?,
                        "embeddingModel": row.get::<_, String>(1)?,
                        "state": row.get::<_, String>(2)?,
                        "degradedReason": row.get::<_, Option<String>>(3)?,
                        "updatedAt": row.get::<_, String>(4)?,
                        "vectorStore": "sqlite-vec",
                        "localVector": true,
                        "cloudEmbeddings": false,
                    }))
                },
            )
            .optional()
            .map_err(|error| format!("read vector metadata: {error}"))?
            .unwrap_or_else(|| {
                json!({
                    "state": "unavailable",
                    "degradedReason": "no vector metadata",
                    "vectorStore": "sqlite-vec",
                    "localVector": false,
                    "cloudEmbeddings": false,
                })
            });
        let catalog_revision = self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(catalog_revision), 0) FROM capability_implementations",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or_default();
        Ok(json!({
            "catalogRevision": catalog_revision,
            "plugins": count("capability_plugins")?,
            "implementations": count("capability_implementations")?,
            "bindings": count("capability_bindings")?,
            "documents": count("capability_index_documents")?,
            "inspectionHandles": count("capability_inspection_handles")?,
            "bindingDecisions": count("capability_binding_decisions")?,
            "auditEvents": count("capability_audit_events")?,
            "programRuns": count("capability_program_runs")?,
            "pauses": count("capability_pauses")?,
            "runs": count("capability_runs")?,
            "indexStatus": vector,
        }))
    }

    fn registry_snapshot(&self) -> Result<Value, String> {
        Ok(json!({
            "plugins": query_json_column(&self.conn, "SELECT manifest_json FROM capability_plugins ORDER BY plugin_id")?,
            "implementations": query_implementations(&self.conn)?,
            "bindings": query_bindings(&self.conn)?,
            "documents": query_json_column(&self.conn, "SELECT document_json FROM capability_index_documents ORDER BY kind, capability_id")?,
            "programRuns": self.program_run_query(None, None, 100, false)?["programRuns"].clone(),
            "pauses": query_json_column(&self.conn, "SELECT prompt_payload_json FROM capability_pauses ORDER BY updated_at DESC LIMIT 100")?,
            "runs": query_json_column(&self.conn, "SELECT details_json FROM capability_runs ORDER BY updated_at DESC LIMIT 100")?,
        }))
    }

    fn audit_query(
        &self,
        event_type: Option<&str>,
        trace_id: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, event_type, trace_id, payload_json, created_at
                 FROM capability_audit_events
                 WHERE (?1 IS NULL OR event_type = ?1)
                   AND (?2 IS NULL OR trace_id = ?2)
                 ORDER BY created_at DESC
                 LIMIT ?3",
            )
            .map_err(|error| format!("prepare audit query: {error}"))?;
        let rows = stmt
            .query_map(params![event_type, trace_id, limit as i64], |row| {
                let payload_json: String = row.get(3)?;
                let payload = serde_json::from_str::<Value>(&payload_json).unwrap_or(Value::Null);
                Ok(json!({
                    "id": row.get::<_, String>(0)?,
                    "eventType": row.get::<_, String>(1)?,
                    "traceId": row.get::<_, Option<String>>(2)?,
                    "payload": payload,
                    "createdAt": row.get::<_, String>(4)?,
                }))
            })
            .map_err(|error| format!("query audit events: {error}"))?;
        let mut events = Vec::new();
        for row in rows {
            events.push(redact_audit_event(
                row.map_err(|error| format!("read audit event: {error}"))?,
                reveal_payloads,
            ));
        }
        Ok(json!({ "events": events, "redacted": !reveal_payloads }))
    }

    fn list_bindings(&self) -> Result<Value, String> {
        Ok(json!({ "bindings": query_bindings(&self.conn)? }))
    }

    fn upsert_binding(
        &mut self,
        contract_id: &str,
        scope_kind: &str,
        scope_value: &str,
        selected_implementation: &str,
        selection_policy: &str,
        secondary_implementations: &[String],
        priority: i64,
        enabled: bool,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO capability_bindings
                   (contract_id, scope_kind, scope_value, selected_implementation,
                    selection_policy, secondary_implementations_json, enabled, priority, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(contract_id, scope_kind, scope_value, selected_implementation)
                 DO UPDATE SET
                    selection_policy = excluded.selection_policy,
                    secondary_implementations_json = excluded.secondary_implementations_json,
                    enabled = excluded.enabled,
                    priority = excluded.priority,
                    updated_at = excluded.updated_at",
                params![
                    contract_id,
                    scope_kind,
                    scope_value,
                    selected_implementation,
                    selection_policy,
                    serde_json::to_string(secondary_implementations)
                        .map_err(|error| format!("serialize secondary implementations: {error}"))?,
                    if enabled { 1 } else { 0 },
                    priority,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("upsert capability binding: {error}"))?;
        Ok(())
    }

    fn list_plugins(&self) -> Result<Value, String> {
        Ok(
            json!({ "plugins": query_json_column(&self.conn, "SELECT manifest_json FROM capability_plugins ORDER BY plugin_id")? }),
        )
    }

    fn plugin_inspect(&self, plugin_id: &str) -> Result<Option<Value>, String> {
        let manifest = self
            .conn
            .query_row(
                "SELECT manifest_json FROM capability_plugins WHERE plugin_id = ?1",
                params![plugin_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| format!("read capability plugin: {error}"))?;
        let Some(manifest_json) = manifest else {
            return Ok(None);
        };
        let manifest = serde_json::from_str::<Value>(&manifest_json)
            .map_err(|error| format!("decode plugin manifest: {error}"))?;
        let implementations = query_implementations_for_plugin(&self.conn, plugin_id)?;
        Ok(Some(json!({
            "manifest": manifest,
            "implementations": implementations
        })))
    }

    fn upsert_plugin_manifest(
        &mut self,
        manifest: &CapabilityPluginManifest,
        conformance_state: &str,
        catalog_revision: u64,
    ) -> Result<(), String> {
        let mut manifest_value = serde_json::to_value(manifest)
            .map_err(|error| format!("serialize plugin manifest: {error}"))?;
        manifest_value["conformanceState"] = json!(conformance_state);
        self.conn
            .execute(
                "INSERT INTO capability_plugins
                   (plugin_id, manifest_json, trust_tier, signature_status,
                    conformance_state, catalog_revision, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(plugin_id) DO UPDATE SET
                    manifest_json = excluded.manifest_json,
                    trust_tier = excluded.trust_tier,
                    signature_status = excluded.signature_status,
                    conformance_state = excluded.conformance_state,
                    catalog_revision = excluded.catalog_revision,
                    updated_at = excluded.updated_at",
                params![
                    manifest.id,
                    serde_json::to_string(&manifest_value)
                        .map_err(|error| format!("serialize plugin manifest json: {error}"))?,
                    manifest.trust_tier,
                    manifest.signature_status,
                    conformance_state,
                    catalog_revision as i64,
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|error| format!("upsert plugin manifest: {error}"))?;
        Ok(())
    }

    fn set_plugin_state(&mut self, plugin_id: &str, state: &str) -> Result<(), String> {
        let manifest_json = self
            .conn
            .query_row(
                "SELECT manifest_json FROM capability_plugins WHERE plugin_id = ?1",
                params![plugin_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| format!("read plugin manifest for state update: {error}"))?;
        let Some(manifest_json) = manifest_json else {
            return Err(format!("plugin '{plugin_id}' not found"));
        };
        let mut manifest = serde_json::from_str::<Value>(&manifest_json)
            .map_err(|error| format!("decode plugin manifest for state update: {error}"))?;
        manifest["conformanceState"] = json!(state);
        let changed = self
            .conn
            .execute(
                "UPDATE capability_plugins
                 SET conformance_state = ?1,
                     manifest_json = ?2,
                     updated_at = ?3
                 WHERE plugin_id = ?4",
                params![
                    state,
                    serde_json::to_string(&manifest)
                        .map_err(|error| format!("serialize plugin manifest: {error}"))?,
                    Utc::now().to_rfc3339(),
                    plugin_id
                ],
            )
            .map_err(|error| format!("set plugin state: {error}"))?;
        if changed == 0 {
            return Err(format!("plugin '{plugin_id}' not found"));
        }
        Ok(())
    }

    fn set_implementation_state(
        &mut self,
        implementation_id: &str,
        state: &str,
    ) -> Result<(), String> {
        let changed = self
            .conn
            .execute(
                "UPDATE capability_implementations
                 SET conformance_state = ?1, updated_at = ?2
                 WHERE implementation_id = ?3",
                params![state, Utc::now().to_rfc3339(), implementation_id],
            )
            .map_err(|error| format!("set implementation state: {error}"))?;
        if changed == 0 {
            return Err(format!("implementation '{implementation_id}' not found"));
        }
        Ok(())
    }
}

impl SqliteCapabilityRegistryStore {
    fn write_vectors(
        &self,
        jobs: &[(i64, String)],
        embedding_provider: &dyn EmbeddingProvider,
    ) -> Result<(), String> {
        self.ensure_vector_table(
            embedding_provider.dimensions(),
            embedding_provider.model_id(),
        )?;
        for chunk in jobs.chunks(32) {
            let texts = chunk
                .iter()
                .map(|(_, text)| text.clone())
                .collect::<Vec<_>>();
            let vectors = embedding_provider.embed(&texts)?;
            if vectors.len() != chunk.len() {
                return Err(format!(
                    "embedding provider returned {} vectors for {} texts",
                    vectors.len(),
                    chunk.len()
                ));
            }
            for ((rowid, _), vector) in chunk.iter().zip(vectors.iter()) {
                self.conn
                    .execute(
                        "DELETE FROM capability_index_vectors WHERE rowid = ?1",
                        params![rowid],
                    )
                    .map_err(|error| format!("delete stale capability vector: {error}"))?;
                self.conn
                    .execute(
                        "INSERT INTO capability_index_vectors(rowid, embedding) VALUES (?1, ?2)",
                        params![rowid, bytemuck::cast_slice::<f32, u8>(vector)],
                    )
                    .map_err(|error| format!("insert capability vector: {error}"))?;
            }
        }
        Ok(())
    }

    fn vector_search(
        &self,
        query: &str,
        documents: &[CapabilityIndexDocument],
        limit: usize,
        embedding_provider: &dyn EmbeddingProvider,
    ) -> Result<Vec<CapabilityIndexHit>, String> {
        self.ensure_vector_table(
            embedding_provider.dimensions(),
            embedding_provider.model_id(),
        )?;
        let indexed = self.vector_count_for_documents(documents)?;
        if indexed < documents.len() {
            return Err(format!(
                "CAPABILITY_INDEX_INDEXING: local vector index has {indexed}/{} current documents",
                documents.len()
            ));
        }
        let query_embedding = embedding_provider.embed(&[query.to_owned()])?;
        let Some(query_embedding) = query_embedding.first() else {
            return Err("embedding provider returned no query vector".to_owned());
        };
        let query_bytes = bytemuck::cast_slice::<f32, u8>(query_embedding);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT d.document_json, v.distance
                 FROM capability_index_vectors v
                 JOIN capability_index_documents d ON d.rowid = v.rowid
                 WHERE v.embedding MATCH ?1 AND k = ?2",
            )
            .map_err(|error| format!("prepare capability vector query: {error}"))?;
        let rows = stmt
            .query_map(params![query_bytes, limit as i64], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, f32>(1)?))
            })
            .map_err(|error| format!("query capability vectors: {error}"))?;
        let visible = documents
            .iter()
            .map(|doc| (document_key(doc), doc.clone()))
            .collect::<BTreeMap<_, _>>();
        let mut hits = Vec::new();
        for row in rows {
            let (json, distance) =
                row.map_err(|error| format!("read capability vector row: {error}"))?;
            let document: CapabilityIndexDocument = serde_json::from_str(&json)
                .map_err(|error| format!("decode vector doc: {error}"))?;
            if !visible.contains_key(&document_key(&document)) {
                continue;
            }
            let score = 1.0 / (1.0 + distance.max(0.0));
            hits.push(CapabilityIndexHit {
                kind: document.kind.clone(),
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
                lexical_score: lexical_score(&document, query),
                vector_score: Some(score),
                fused_score: score + trust_boost(&document.trust_tier),
                matched_by: "local_vector".to_owned(),
                snippet: snippet(&document.text, query),
                requires_inspect: document_requires_inspect(&document),
                recipe: document.recipe.clone(),
            });
        }
        hits.sort_by(|a, b| {
            b.fused_score
                .partial_cmp(&a.fused_score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.function_id.cmp(&b.function_id))
        });
        Ok(hits)
    }

    fn vector_count_for_documents(
        &self,
        documents: &[CapabilityIndexDocument],
    ) -> Result<usize, String> {
        if documents.is_empty() {
            return Ok(0);
        }
        if !self.vector_table_exists()? {
            return Ok(0);
        }
        let keys = documents.iter().map(document_key).collect::<Vec<_>>();
        let keys_json = serde_json::to_string(&keys)
            .map_err(|error| format!("serialize vector coverage keys: {error}"))?;
        self.conn
            .query_row(
                "SELECT COUNT(*)
                 FROM capability_index_documents d
                 JOIN capability_index_vectors v ON v.rowid = d.rowid
                 WHERE d.document_key IN (SELECT value FROM json_each(?1))",
                params![keys_json],
                |row| row.get::<_, i64>(0),
            )
            .map(|count| count.max(0) as usize)
            .map_err(|error| format!("count capability vector coverage: {error}"))
    }
}

fn query_json_column(conn: &Connection, sql: &str) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(sql)
        .map_err(|error| format!("prepare json query: {error}"))?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("query json rows: {error}"))?;
    let mut values = Vec::new();
    for row in rows {
        let raw = row.map_err(|error| format!("read json row: {error}"))?;
        values
            .push(serde_json::from_str(&raw).map_err(|error| format!("decode json row: {error}"))?);
    }
    Ok(values)
}

fn query_bindings(conn: &Connection) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT contract_id, scope_kind, scope_value, selected_implementation,
                    selection_policy, secondary_implementations_json, enabled, priority, updated_at
             FROM capability_bindings
             ORDER BY scope_kind, scope_value, contract_id, priority DESC",
        )
        .map_err(|error| format!("prepare binding query: {error}"))?;
    let rows = stmt
        .query_map([], |row| {
            let secondary_json: String = row.get(5)?;
            Ok(json!({
                "contractId": row.get::<_, String>(0)?,
                "scopeKind": row.get::<_, String>(1)?,
                "scopeValue": row.get::<_, String>(2)?,
                "selectedImplementation": row.get::<_, String>(3)?,
                "selectionPolicy": row.get::<_, String>(4)?,
                "secondaryImplementations": serde_json::from_str::<Value>(&secondary_json).unwrap_or_else(|_| json!([])),
                "enabled": row.get::<_, i64>(6)? == 1,
                "priority": row.get::<_, i64>(7)?,
                "updatedAt": row.get::<_, String>(8)?,
            }))
        })
        .map_err(|error| format!("query capability bindings: {error}"))?;
    collect_value_rows(rows)
}

fn query_implementations(conn: &Connection) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT implementation_id, contract_id, function_id, plugin_id, worker_id,
                    schema_digest, catalog_revision, trust_tier, health, visibility,
                    conformance_state, signature_status, updated_at
             FROM capability_implementations
             ORDER BY contract_id, implementation_id",
        )
        .map_err(|error| format!("prepare implementation query: {error}"))?;
    let rows = stmt
        .query_map([], implementation_row)
        .map_err(|error| format!("query implementations: {error}"))?;
    collect_value_rows(rows)
}

fn query_implementations_for_plugin(
    conn: &Connection,
    plugin_id: &str,
) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT implementation_id, contract_id, function_id, plugin_id, worker_id,
                    schema_digest, catalog_revision, trust_tier, health, visibility,
                    conformance_state, signature_status, updated_at
             FROM capability_implementations
             WHERE plugin_id = ?1
             ORDER BY contract_id, implementation_id",
        )
        .map_err(|error| format!("prepare plugin implementation query: {error}"))?;
    let rows = stmt
        .query_map(params![plugin_id], implementation_row)
        .map_err(|error| format!("query plugin implementations: {error}"))?;
    collect_value_rows(rows)
}

fn implementation_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "implementationId": row.get::<_, String>(0)?,
        "contractId": row.get::<_, String>(1)?,
        "functionId": row.get::<_, String>(2)?,
        "pluginId": row.get::<_, String>(3)?,
        "workerId": row.get::<_, String>(4)?,
        "schemaDigest": row.get::<_, String>(5)?,
        "catalogRevision": row.get::<_, i64>(6)?,
        "trustTier": row.get::<_, String>(7)?,
        "health": row.get::<_, String>(8)?,
        "visibility": row.get::<_, String>(9)?,
        "conformanceState": row.get::<_, String>(10)?,
        "signatureStatus": row.get::<_, String>(11)?,
        "updatedAt": row.get::<_, String>(12)?,
    }))
}

fn collect_value_rows<F>(rows: rusqlite::MappedRows<'_, F>) -> Result<Vec<Value>, String>
where
    F: FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<Value>,
{
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|error| format!("read value row: {error}"))?);
    }
    Ok(values)
}

fn json_from_row(raw: String) -> Value {
    serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null)
}

fn redact_audit_event(mut event: Value, reveal_payloads: bool) -> Value {
    if reveal_payloads {
        event["redacted"] = json!(false);
        return event;
    }
    let payload = event.get("payload").cloned().unwrap_or(Value::Null);
    event["payloadSummary"] = audit_payload_summary(&payload);
    event["payload"] = json!({
        "redacted": true,
        "keys": payload.as_object()
            .map(|object| object.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default()
    });
    event["redacted"] = json!(true);
    event
}

fn merge_record_payload(mut base: Value, extra: Value) -> Value {
    match (base.as_object_mut(), extra.as_object()) {
        (Some(base), Some(extra)) => {
            for (key, value) in extra {
                base.insert(key.clone(), value.clone());
            }
            Value::Object(base.clone())
        }
        _ => extra,
    }
}

fn redact_program_run(mut run: Value, reveal_payloads: bool) -> Value {
    if reveal_payloads {
        run["redacted"] = json!(false);
        return run;
    }
    let log_count = run
        .get("logs")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    let artifact_count = run
        .get("artifacts")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    let compensation_count = run
        .get("compensationAttempts")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    run["payloadSummary"] = json!({
        "programRunId": run.get("programRunId").cloned().unwrap_or(Value::Null),
        "status": run.get("status").cloned().unwrap_or(Value::Null),
        "traceId": run.get("traceId").cloned().unwrap_or(Value::Null),
        "parentInvocationId": run.get("parentInvocationId").cloned().unwrap_or(Value::Null),
        "rootInvocationId": run.get("rootInvocationId").cloned().unwrap_or(Value::Null),
        "bindingDecisionId": run.get("bindingDecisionId").cloned().unwrap_or(Value::Null),
        "codeHash": run.get("codeHash").cloned().unwrap_or(Value::Null),
        "argsHash": run.get("argsHash").cloned().unwrap_or(Value::Null),
        "childInvocations": run.get("childInvocations").cloned().unwrap_or_else(|| json!([])),
        "selectedImplementations": run.get("selectedImplementations").cloned().unwrap_or_else(|| json!([])),
        "approvalState": run.get("approvalState").cloned().unwrap_or(Value::Null),
        "logCount": log_count,
        "artifactCount": artifact_count,
        "compensationCount": compensation_count,
    });
    run["logs"] = json!({"redacted": true, "count": log_count});
    run["artifacts"] = json!({"redacted": true, "count": artifact_count});
    run["error"] = run
        .get("error")
        .cloned()
        .filter(|value| !value.is_null())
        .map(|error| audit_payload_summary(&error))
        .unwrap_or(Value::Null);
    run["compensationAttempts"] = json!({"redacted": true, "count": compensation_count});
    run["redacted"] = json!(true);
    run
}

fn audit_payload_summary(payload: &Value) -> Value {
    let Some(object) = payload.as_object() else {
        return json!({"type": payload_type(payload)});
    };
    let interesting = [
        "status",
        "contractId",
        "implementationId",
        "functionId",
        "pluginId",
        "workerId",
        "catalogRevision",
        "schemaDigest",
        "error",
    ];
    let mut summary = serde_json::Map::new();
    for key in interesting {
        if let Some(value) = object.get(key) {
            summary.insert(key.to_owned(), value.clone());
        }
    }
    summary.insert("keyCount".to_owned(), json!(object.len()));
    Value::Object(summary)
}

fn payload_type(payload: &Value) -> &'static str {
    match payload {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

const CAPABILITY_REGISTRY_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS capability_plugins (
  plugin_id TEXT PRIMARY KEY,
  manifest_json TEXT NOT NULL,
  trust_tier TEXT NOT NULL,
  signature_status TEXT NOT NULL,
  conformance_state TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_implementations (
  implementation_id TEXT PRIMARY KEY,
  contract_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  plugin_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  schema_digest TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  trust_tier TEXT NOT NULL,
  health TEXT NOT NULL,
  visibility TEXT NOT NULL,
  conformance_state TEXT NOT NULL,
  signature_status TEXT NOT NULL,
  function_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_index_documents (
  document_key TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  capability_id TEXT NOT NULL,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  plugin_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  schema_digest TEXT NOT NULL,
  trust_tier TEXT NOT NULL,
  health TEXT NOT NULL,
  visibility TEXT NOT NULL,
  effect_class TEXT NOT NULL,
  risk_level TEXT NOT NULL,
  text TEXT NOT NULL,
  text_hash TEXT NOT NULL DEFAULT '',
  document_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_vector_metadata (
  name TEXT PRIMARY KEY,
  dimension INTEGER NOT NULL,
  model_id TEXT NOT NULL,
  state TEXT NOT NULL,
  degraded_reason TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_bindings (
  contract_id TEXT NOT NULL,
  scope_kind TEXT NOT NULL,
  scope_value TEXT NOT NULL,
  selected_implementation TEXT NOT NULL,
  selection_policy TEXT NOT NULL,
  secondary_implementations_json TEXT NOT NULL DEFAULT '[]',
  enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
  priority INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(contract_id, scope_kind, scope_value, selected_implementation)
);

CREATE TABLE IF NOT EXISTS capability_inspection_handles (
  handle TEXT PRIMARY KEY,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  function_revision INTEGER NOT NULL,
  schema_digest TEXT NOT NULL,
  binding_decision_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_binding_decisions (
  id TEXT PRIMARY KEY,
  contract_id TEXT NOT NULL,
  selected_implementation TEXT NOT NULL,
  selected_function_id TEXT NOT NULL,
  selection_policy TEXT NOT NULL,
  rejected_candidates_json TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  schema_digest TEXT NOT NULL,
  plugin_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_audit_events (
  id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  trace_id TEXT,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_program_runs (
  program_run_id TEXT PRIMARY KEY,
  parent_invocation_id TEXT,
  root_invocation_id TEXT NOT NULL,
  binding_decision_id TEXT,
  status TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  args_hash TEXT NOT NULL,
  limits_json TEXT NOT NULL,
  allowed_contracts_json TEXT NOT NULL,
  allowed_implementations_json TEXT NOT NULL,
  child_invocations_json TEXT NOT NULL,
  selected_implementations_json TEXT NOT NULL,
  approval_state_json TEXT NOT NULL,
  artifacts_json TEXT NOT NULL,
  logs_json TEXT NOT NULL,
  error_json TEXT NOT NULL,
  compensation_attempts_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_pauses (
  pause_id TEXT PRIMARY KEY,
  invocation_id TEXT NOT NULL,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  plugin_id TEXT,
  worker_id TEXT,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  prompt_payload_json TEXT NOT NULL,
  resume_schema_json TEXT NOT NULL,
  answer_authority TEXT NOT NULL,
  expires_at TEXT,
  trace_id TEXT,
  root_invocation_id TEXT,
  binding_decision_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_runs (
  run_id TEXT PRIMARY KEY,
  invocation_id TEXT NOT NULL,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  plugin_id TEXT,
  worker_id TEXT,
  status TEXT NOT NULL,
  stream_topic TEXT,
  child_invocations_json TEXT NOT NULL,
  trace_id TEXT,
  root_invocation_id TEXT,
  binding_decision_id TEXT,
  details_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_capability_documents_contract
  ON capability_index_documents(contract_id);
CREATE INDEX IF NOT EXISTS idx_capability_documents_plugin
  ON capability_index_documents(plugin_id);
CREATE INDEX IF NOT EXISTS idx_capability_documents_kind
  ON capability_index_documents(kind);
CREATE INDEX IF NOT EXISTS idx_capability_program_runs_trace
  ON capability_program_runs(trace_id);
CREATE INDEX IF NOT EXISTS idx_capability_program_runs_status
  ON capability_program_runs(status);
CREATE INDEX IF NOT EXISTS idx_capability_program_runs_binding
  ON capability_program_runs(binding_decision_id);
CREATE INDEX IF NOT EXISTS idx_capability_pauses_invocation
  ON capability_pauses(invocation_id);
CREATE INDEX IF NOT EXISTS idx_capability_pauses_status
  ON capability_pauses(status);
CREATE INDEX IF NOT EXISTS idx_capability_runs_invocation
  ON capability_runs(invocation_id);
CREATE INDEX IF NOT EXISTS idx_capability_runs_status
  ON capability_runs(status);
"#;

/// Hybrid local index.
#[derive(Clone, Default)]
pub(crate) struct HybridLocalCapabilityIndex {
    policy: CapabilitySearchPolicy,
}

impl HybridLocalCapabilityIndex {
    pub(crate) fn new(policy: CapabilitySearchPolicy) -> Self {
        Self { policy }
    }

    #[cfg(test)]
    pub(crate) fn search(
        &self,
        query: &str,
        documents: Vec<CapabilityIndexDocument>,
        limit: usize,
    ) -> Result<CapabilityIndexSearchResult, String> {
        let provider = HashEmbeddingProvider::new(64);
        self.search_with_provider(query, documents, limit, &provider)
    }

    pub(crate) fn search_with_provider(
        &self,
        query: &str,
        documents: Vec<CapabilityIndexDocument>,
        limit: usize,
        embedding_provider: &dyn EmbeddingProvider,
    ) -> Result<CapabilityIndexSearchResult, String> {
        let mut lexical_hits = lexical_rank(query, &documents);
        let mut status = CapabilityIndexStatus {
            lexical: self.policy.lexical,
            local_vector: self.policy.local_vector,
            cloud_embeddings: false,
            vector_store: "sqlite-vec:vec0".to_owned(),
            embedding_model: embedding_provider.model_id().to_owned(),
            state: "ready".to_owned(),
            degraded_reason: None,
        };

        if self.policy.local_vector && !query.trim().is_empty() && !documents.is_empty() {
            match vector_rank_with_provider(query, &documents, embedding_provider) {
                Ok(vector_hits) => {
                    lexical_hits = fuse_hits(lexical_hits, vector_hits, &documents);
                }
                Err(error) => {
                    status.state = "unavailable".to_owned();
                    status.degraded_reason = Some(error.clone());
                    if self.policy.require_local_vector
                        && !self.policy.allow_lexical_only_when_degraded
                    {
                        return Err(format!("CAPABILITY_INDEX_UNAVAILABLE: {error}"));
                    }
                }
            }
        }

        lexical_hits.truncate(limit.min(self.policy.max_results.max(1)));
        Ok(CapabilityIndexSearchResult {
            hits: lexical_hits,
            status,
        })
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
    out.push_str("The model-facing primitive is `execute`. Known entries below may use target directly. For unknown work, start with intent alone; add target only from the user, prior execute, or a recipe. Put target-only fields in arguments; wrapper fields stay top-level. Freshness and approval happen inside execute.\n\n");
    for entry in entries.drain(..) {
        let recipe = entry.agent_recipe();
        let mut line = format!(
            "- `{}` — {}. Use when: {}",
            recipe.contract_id, recipe.display_name, recipe.use_when
        );
        if policy.include_compact_schemas {
            if !recipe.required_payload.is_empty() {
                line.push_str(&format!(
                    " Required arguments: {}",
                    recipe.required_payload.join("; ")
                ));
            }
            if !recipe.optional_payload.is_empty() {
                let optional = recipe
                    .optional_payload
                    .iter()
                    .take(6)
                    .cloned()
                    .collect::<Vec<_>>();
                line.push_str(&format!(" Optional: {}", optional.join("; ")));
            }
        }
        if policy.include_examples
            && let Ok(example) = serde_json::to_string(&recipe.execute_template)
        {
            line.push_str(&format!(" Execute: {example}"));
        }
        if recipe.inspect_required {
            line.push_str(" Execute prepares freshness before elevated-risk work.");
        } else if recipe.approval_behavior != "none" {
            line.push_str(&format!(" Approval: {}.", recipe.approval_behavior));
        } else if recipe.direct_execution == "conditional_safe_direct" {
            line.push_str(" Safe payloads run directly; risky payloads may pause for approval.");
        }
        line.push('\n');
        if estimated_tokens(out.len() + line.len()) > policy.max_tokens {
            out.push_str(
                "- Additional capabilities are available through the same `execute` primitive; provide intent or a target hint and the engine resolves the catalog entry.\n",
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

fn risk_rank(risk: &str) -> usize {
    match risk.to_ascii_lowercase().as_str() {
        "low" => 0,
        "medium" => 1,
        "high" => 2,
        "critical" => 3,
        _ => usize::MAX,
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

fn document_key(document: &CapabilityIndexDocument) -> String {
    format!("{}:{}", document.kind, document.capability_id)
}

fn document_text_hash(document: &CapabilityIndexDocument) -> String {
    let mut hasher = Sha256::new();
    hasher.update(document.text.as_bytes());
    if let Some(recipe) = &document.recipe
        && let Ok(serialized) = serde_json::to_vec(recipe)
    {
        hasher.update(serialized);
    }
    format!("{:x}", hasher.finalize())
}

fn ready_index_status(
    policy: &CapabilitySearchPolicy,
    embedding_provider: &dyn EmbeddingProvider,
) -> CapabilityIndexStatus {
    CapabilityIndexStatus {
        lexical: policy.lexical,
        local_vector: policy.local_vector,
        cloud_embeddings: false,
        vector_store: "sqlite-vec:vec0".to_owned(),
        embedding_model: embedding_provider.model_id().to_owned(),
        state: "ready".to_owned(),
        degraded_reason: None,
    }
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

fn lexical_rank(query: &str, documents: &[CapabilityIndexDocument]) -> Vec<CapabilityIndexHit> {
    let mut hits = documents
        .iter()
        .map(|document| {
            let lexical_score = lexical_score(document, query);
            CapabilityIndexHit {
                kind: document.kind.clone(),
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
                requires_inspect: document_requires_inspect(document),
                recipe: document.recipe.clone(),
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

fn document_requires_inspect(document: &CapabilityIndexDocument) -> bool {
    document
        .recipe
        .as_ref()
        .map(|recipe| recipe.inspect_required)
        .unwrap_or_else(|| document.kind == "implementation" || document.kind == "contract")
}

fn vector_rank_with_provider(
    query: &str,
    documents: &[CapabilityIndexDocument],
    embedding_provider: &dyn EmbeddingProvider,
) -> Result<Vec<CapabilityIndexHit>, String> {
    let texts = std::iter::once(query.to_owned())
        .chain(documents.iter().map(|document| document.text.clone()))
        .collect::<Vec<_>>();
    let embeddings = embedding_provider.embed(&texts)?;
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
                kind: document.kind.clone(),
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
                requires_inspect: document_requires_inspect(document),
                recipe: document.recipe.clone(),
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

fn conformance_state(function: &FunctionDefinition, trust_tier: &str) -> String {
    string_metadata(function, "conformanceState").unwrap_or_else(|| {
        if trust_tier == "first_party_signed" {
            "healthy".to_owned()
        } else {
            "candidate".to_owned()
        }
    })
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

fn agent_recipe_for_entry(entry: &CapabilityRegistryEntry) -> AgentCapabilityRecipe {
    let function = &entry.function;
    let required_payload = recipe_payload_fields(function.request_schema.as_ref(), true);
    let optional_payload = recipe_payload_fields(function.request_schema.as_ref(), false);
    let examples = recipe_examples(entry);
    let execute_template = examples
        .first()
        .cloned()
        .unwrap_or_else(|| recipe_execute_template(entry, recipe_payload_example(function)));
    let inspect_required = recipe_inspect_required(function);
    AgentCapabilityRecipe {
        contract_id: entry.contract_id.clone(),
        display_name: display_name(function),
        use_when: recipe_use_when(function),
        execute_template,
        required_payload,
        optional_payload,
        examples,
        direct_execution: recipe_direct_execution(function).to_owned(),
        inspect_required,
        approval_behavior: recipe_approval_behavior(function).to_owned(),
        lifecycle_kind: recipe_lifecycle_kind(function),
        result_summary: recipe_result_summary(function.response_schema.as_ref()),
        aliases: recipe_aliases(function),
    }
}

fn recipe_use_when(function: &FunctionDefinition) -> String {
    let description = compact_description(&function.description);
    if description.starts_with("Canonical domain capability ") {
        format!(
            "Use for {} work through the `{}` capability.",
            function.id.namespace(),
            function.id.as_str()
        )
    } else {
        description
    }
}

fn recipe_payload_fields(schema: Option<&Value>, required_only: bool) -> Vec<String> {
    let Some(schema) = schema else {
        return Vec::new();
    };
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
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return Vec::new();
    };
    properties
        .iter()
        .filter(|(name, _)| required.contains(name.as_str()) == required_only)
        .take(if required_only { 12 } else { 16 })
        .map(|(name, field)| recipe_field_summary(name, field))
        .collect()
}

fn recipe_field_summary(name: &str, field: &Value) -> String {
    let ty = recipe_schema_type(field);
    let mut summary = format!("{name}: {ty}");
    if let Some(values) = field.get("enum").and_then(Value::as_array) {
        let values = values
            .iter()
            .filter_map(Value::as_str)
            .take(8)
            .collect::<Vec<_>>();
        if !values.is_empty() {
            summary.push_str(&format!(" [{}]", values.join("|")));
        }
    }
    if let Some(description) = field.get("description").and_then(Value::as_str)
        && !description.trim().is_empty()
    {
        summary.push_str(&format!(" - {}", compact_description(description)));
    }
    summary
}

fn recipe_schema_type(field: &Value) -> String {
    if let Some(ty) = field.get("type") {
        if let Some(ty) = ty.as_str() {
            if ty == "array" {
                let item_ty = field
                    .get("items")
                    .map(recipe_schema_type)
                    .unwrap_or_else(|| "value".to_owned());
                return format!("array<{item_ty}>");
            }
            return ty.to_owned();
        }
        if let Some(types) = ty.as_array() {
            let types = types.iter().filter_map(Value::as_str).collect::<Vec<_>>();
            if !types.is_empty() {
                return types.join("|");
            }
        }
    }
    if field.get("oneOf").is_some() {
        return "oneOf".to_owned();
    }
    if field.get("anyOf").is_some() {
        return "anyOf".to_owned();
    }
    "value".to_owned()
}

fn recipe_examples(entry: &CapabilityRegistryEntry) -> Vec<Value> {
    let existing = examples(&entry.function)
        .into_iter()
        .filter_map(|example| normalize_recipe_example(entry, example))
        .take(4)
        .collect::<Vec<_>>();
    if existing.is_empty() {
        vec![recipe_execute_template(
            entry,
            recipe_payload_example(&entry.function),
        )]
    } else {
        existing
    }
}

fn normalize_recipe_example(entry: &CapabilityRegistryEntry, example: Value) -> Option<Value> {
    if example.get("mode").is_some() || example.get("payload").is_some() {
        let mut object = example.as_object()?.clone();
        let payload = object.remove("payload").unwrap_or_else(|| json!({}));
        let mut template = recipe_execute_template(entry, payload);
        if let Some(reason) = object.remove("reason") {
            template["reason"] = reason;
        }
        if let Some(idempotency_key) = object.remove("idempotencyKey") {
            template["idempotencyKey"] = idempotency_key;
        }
        return Some(template);
    }
    Some(recipe_execute_template(entry, example))
}

fn recipe_execute_template(entry: &CapabilityRegistryEntry, payload: Value) -> Value {
    json!({
        "intent": default_recipe_reason(entry),
        "target": entry.contract_id.clone(),
        "arguments": payload,
        "reason": default_recipe_reason(entry)
    })
}

fn default_recipe_reason(entry: &CapabilityRegistryEntry) -> String {
    format!("Use {} for the requested work.", entry.contract_id)
}

fn recipe_payload_example(function: &FunctionDefinition) -> Value {
    let Some(schema) = function.request_schema.as_ref() else {
        return json!({});
    };
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return json!({});
    };
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
    let mut payload = serde_json::Map::new();
    for name in &required {
        if let Some(field) = properties.get(*name) {
            payload.insert(
                (*name).to_owned(),
                recipe_example_value(name, field, function),
            );
        }
    }
    Value::Object(payload)
}

fn recipe_example_value(name: &str, field: &Value, function: &FunctionDefinition) -> Value {
    if let Some(values) = field.get("enum").and_then(Value::as_array)
        && let Some(value) = values.first()
    {
        return value.clone();
    }
    match name {
        "command" => Value::String("date".to_owned()),
        "path" | "filePath" | "file_path" => Value::String("README.md".to_owned()),
        "pattern" => Value::String("TODO".to_owned()),
        "query" => Value::String("project documentation".to_owned()),
        "url" => Value::String("https://example.com".to_owned()),
        "title" => Value::String("Tron update".to_owned()),
        "body" => Value::String("Task finished.".to_owned()),
        "content" | "newContent" => Value::String("example content".to_owned()),
        "oldString" => Value::String("old text".to_owned()),
        "newString" => Value::String("new text".to_owned()),
        "task" => Value::String("Investigate the requested topic and report findings.".to_owned()),
        "ids" => json!(["job-<id>"]),
        "questions" => json!([{
            "header": "Choice",
            "id": "choice",
            "question": "Which option should I use?",
            "options": [{"label": "Option A (Recommended)", "description": "Use this path."}]
        }]),
        "code" if function.id.as_str() == "program::run_javascript" => {
            Value::String("return args;".to_owned())
        }
        other => {
            let ty = field
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("string");
            match ty {
                "integer" | "number" => json!(1),
                "boolean" => json!(true),
                "array" => json!([]),
                "object" => json!({}),
                _ => Value::String(format!("<{other}>")),
            }
        }
    }
}

fn recipe_inspect_required(function: &FunctionDefinition) -> bool {
    if matches!(function.id.as_str(), "process::run" | "notifications::send") {
        return false;
    }
    requires_fresh_revision(function)
}

fn recipe_direct_execution(function: &FunctionDefinition) -> &'static str {
    if function.id.as_str() == "process::run" {
        "conditional_safe_direct"
    } else if function.id.as_str() == "notifications::send" || !requires_fresh_revision(function) {
        "direct"
    } else if direct_execution_allowed(function) {
        "direct_with_idempotency"
    } else {
        "inspect_first"
    }
}

fn recipe_approval_behavior(function: &FunctionDefinition) -> &'static str {
    if function.required_authority.approval_required {
        "always_pauses_for_user_approval"
    } else if !conditional_approval_contract(function).is_null() {
        "conditional; payloads classified as risky pause for user approval"
    } else {
        "none"
    }
}

fn recipe_lifecycle_kind(function: &FunctionDefinition) -> String {
    function
        .metadata
        .pointer("/lifecycle/kind")
        .and_then(Value::as_str)
        .or_else(|| {
            if function
                .metadata
                .get("streamTopics")
                .and_then(Value::as_array)
                .is_some_and(|topics| !topics.is_empty())
            {
                Some("stream")
            } else {
                None
            }
        })
        .unwrap_or("immediate")
        .to_owned()
}

fn recipe_result_summary(schema: Option<&Value>) -> String {
    let Some(schema) = schema else {
        return "Returns a structured capability result.".to_owned();
    };
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return "Returns a structured capability result.".to_owned();
    };
    let fields = properties.keys().take(8).cloned().collect::<Vec<_>>();
    if fields.is_empty() {
        "Returns a structured capability result.".to_owned()
    } else {
        format!("Returns fields: {}.", fields.join(", "))
    }
}

fn recipe_aliases(function: &FunctionDefinition) -> Vec<String> {
    let mut aliases = BTreeSet::new();
    aliases.insert(function.id.as_str().to_owned());
    aliases.insert(function.id.namespace().to_owned());
    if let Some((_, name)) = function.id.as_str().rsplit_once("::") {
        aliases.insert(name.replace('_', " "));
    }
    for tag in &function.tags {
        aliases.insert(tag.to_owned());
    }
    aliases.into_iter().take(24).collect()
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
    use std::sync::atomic::{AtomicUsize, Ordering};

    use serde_json::json;

    use super::*;
    use crate::engine::{FunctionId, VisibilityScope, WorkerId};

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
}
