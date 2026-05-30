use chrono::Utc;
use serde_json::{Value, json};
use std::collections::BTreeMap;

use super::super::super::embeddings::EmbeddingProvider;
use super::super::index::{HybridLocalCapabilityIndex, document_key, ready_index_status};
use super::super::{
    CapabilityIndexDocument, CapabilityRegistryEntry, CapabilityRegistrySnapshot,
    CapabilitySearchFilters, CapabilitySearchPolicy, binding_scope_keys, conformance_state,
    plugin_manifest_for_entry, preserve_existing_conformance_state,
};
use super::projection::{merge_record_payload, redact_audit_event, redact_program_run};
use super::{CapabilityIndexSearchResult, CapabilityRegistryStore};
use crate::domains::capability::types::{
    CapabilityBindingDecision, CapabilityBindingRecord, CapabilityIndexStatus,
    CapabilityInspectionHandle, CapabilityPauseRecord, CapabilityPluginManifest,
    CapabilityProgramRunRecord, CapabilityRunRecord,
};

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
                .filter(|state| preserve_existing_conformance_state(state))
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
                .filter(|state| preserve_existing_conformance_state(state))
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
