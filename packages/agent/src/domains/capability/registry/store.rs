//! Concrete registry persistence for capability projection state.
//!
//! The registry root owns catalog projection and selection semantics. This
//! module owns the durable and in-memory store implementations, schema,
//! redaction, and vector persistence details so persistence cannot accumulate
//! model-facing search or recipe policy.

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use super::super::embeddings::EmbeddingProvider;
use super::index::{
    CapabilityIndexSearchResult, HybridLocalCapabilityIndex, document_key,
    document_requires_inspect, document_text_hash, lexical_score, ready_index_status,
    register_sqlite_vec_extension, search_sqlite_documents, snippet, trust_boost,
};
use super::{
    CapabilityIndexDocument, CapabilityRegistryEntry, CapabilityRegistrySnapshot,
    CapabilitySearchFilters, CapabilitySearchPolicy, binding_scope_keys, binding_scope_parts,
    conformance_state, plugin_manifest_for_entry, preserve_existing_conformance_state,
    signature_status,
};
use crate::domains::capability::types::{
    CapabilityBindingDecision, CapabilityBindingRecord, CapabilityIndexHit, CapabilityIndexStatus,
    CapabilityInspectionHandle, CapabilityPauseRecord, CapabilityPluginManifest,
    CapabilityProgramRunRecord, CapabilityRunRecord,
};

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

pub(crate) struct SqliteCapabilityRegistryStore {
    pub(super) conn: Connection,
}

#[derive(Clone, Copy, Debug)]
struct DocumentUpsert {
    rowid: i64,
    vector_stale: bool,
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
        let live_implementation_ids = snapshot
            .entries
            .iter()
            .map(|entry| entry.implementation_id.clone())
            .collect::<BTreeSet<_>>();
        let live_plugin_ids = snapshot
            .entries
            .iter()
            .map(|entry| entry.plugin_id.clone())
            .collect::<BTreeSet<_>>();
        let live_implementation_ids_json =
            serde_json::to_string(&live_implementation_ids.iter().collect::<Vec<_>>())
                .map_err(|error| format!("serialize live implementation ids: {error}"))?;
        let live_plugin_ids_json =
            serde_json::to_string(&live_plugin_ids.iter().collect::<Vec<_>>())
                .map_err(|error| format!("serialize live plugin ids: {error}"))?;
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
                      WHEN capability_plugins.conformance_state IN ('degraded', 'quarantined', 'disabled')
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
                      WHEN capability_implementations.conformance_state IN ('degraded', 'quarantined', 'disabled')
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
        tx.execute(
            "DELETE FROM capability_implementations
             WHERE trust_tier = 'session_generated'
               AND signature_status = 'session_scoped'
               AND implementation_id NOT IN (SELECT value FROM json_each(?1))",
            params![live_implementation_ids_json],
        )
        .map_err(|error| format!("delete stale session capability implementations: {error}"))?;
        tx.execute(
            "DELETE FROM capability_plugins
             WHERE trust_tier = 'session_generated'
               AND signature_status = 'session_scoped'
               AND plugin_id NOT IN (SELECT value FROM json_each(?1))
               AND plugin_id NOT IN (SELECT DISTINCT plugin_id FROM capability_implementations)",
            params![live_plugin_ids_json],
        )
        .map_err(|error| format!("delete stale session capability plugins: {error}"))?;
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

    pub(super) fn vector_search(
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
