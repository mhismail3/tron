use chrono::Utc;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::BTreeSet;

use super::super::super::embeddings::EmbeddingProvider;
use super::super::index::{
    CapabilityIndexSearchResult, document_key, ready_index_status, search_sqlite_documents,
};
use super::super::{
    CapabilityRegistryEntry, CapabilityRegistrySnapshot, CapabilitySearchFilters,
    CapabilitySearchPolicy, binding_scope_parts, conformance_state, plugin_manifest_for_entry,
    signature_status,
};
use super::projection::{
    json_from_row, merge_record_payload, query_bindings, query_implementations,
    query_implementations_for_plugin, query_json_column, redact_audit_event, redact_program_run,
};
use super::{CapabilityRegistryStore, SqliteCapabilityRegistryStore};
use crate::domains::capability::types::{
    CapabilityBindingDecision, CapabilityBindingRecord, CapabilityIndexStatus,
    CapabilityInspectionHandle, CapabilityPauseRecord, CapabilityPluginManifest,
    CapabilityProgramRunRecord, CapabilityRunRecord,
};

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
