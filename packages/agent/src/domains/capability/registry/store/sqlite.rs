use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

use super::super::super::embeddings::EmbeddingProvider;
use super::super::index::{
    document_key, document_requires_inspect, document_text_hash, lexical_score,
    register_sqlite_vec_extension, snippet, trust_boost,
};
use super::super::{CapabilityIndexDocument, CapabilitySearchFilters};
use super::projection::json_from_row;
use super::schema::CAPABILITY_REGISTRY_SCHEMA;
use crate::domains::capability::types::{
    CapabilityIndexHit, CapabilityPauseRecord, CapabilityRunRecord,
};

pub(crate) struct SqliteCapabilityRegistryStore {
    pub(in crate::domains::capability::registry) conn: Connection,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct DocumentUpsert {
    pub(super) rowid: i64,
    pub(super) vector_stale: bool,
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

    pub(super) fn read_pause(
        &self,
        pause_id: &str,
    ) -> Result<Option<CapabilityPauseRecord>, String> {
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

    pub(super) fn read_run(&self, run_id: &str) -> Result<Option<CapabilityRunRecord>, String> {
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

    pub(super) fn ensure_vector_table(
        &self,
        dimensions: usize,
        model_id: &str,
    ) -> Result<(), String> {
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

    pub(super) fn record_vector_unavailable(
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

    pub(super) fn upsert_document(
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

    pub(super) fn load_documents(
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

impl SqliteCapabilityRegistryStore {
    pub(super) fn write_vectors(
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

    pub(in crate::domains::capability::registry) fn vector_search(
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
