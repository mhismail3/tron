//! Search index, ranking, and vector-fusion helpers for the capability registry.
//!
//! The registry store owns persistence and catalog synchronization. This module
//! owns document identity, lexical ranking, local vector ranking, degraded-index
//! status, and hybrid fusion so search behavior does not live in the store or
//! SQLite persistence code.

use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

use super::super::embeddings::EmbeddingProvider;
#[cfg(test)]
use super::super::embeddings::HashEmbeddingProvider;
use super::{CapabilityIndexDocument, CapabilitySearchPolicy, SqliteCapabilityRegistryStore};
use crate::domains::capability::types::{CapabilityIndexHit, CapabilityIndexStatus};

const TRUST_ORDER: &[&str] = &[
    "first_party_signed",
    "trusted_signed",
    "user_installed",
    "session_generated",
    "external_mcp",
    "external_openapi",
    "untrusted",
];

pub(super) fn search_sqlite_documents(
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

pub(super) fn risk_rank(risk: &str) -> usize {
    match risk.to_ascii_lowercase().as_str() {
        "low" => 0,
        "medium" => 1,
        "high" => 2,
        "critical" => 3,
        _ => usize::MAX,
    }
}

pub(super) fn document_key(document: &CapabilityIndexDocument) -> String {
    format!("{}:{}", document.kind, document.capability_id)
}

pub(super) fn document_text_hash(document: &CapabilityIndexDocument) -> String {
    let mut hasher = Sha256::new();
    hasher.update(document.text.as_bytes());
    if let Some(recipe) = &document.recipe
        && let Ok(serialized) = serde_json::to_vec(recipe)
    {
        hasher.update(serialized);
    }
    format!("{:x}", hasher.finalize())
}

pub(super) fn ready_index_status(
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

pub(super) fn lexical_rank(
    query: &str,
    documents: &[CapabilityIndexDocument],
) -> Vec<CapabilityIndexHit> {
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

pub(super) fn document_requires_inspect(document: &CapabilityIndexDocument) -> bool {
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
pub(super) fn register_sqlite_vec_extension() -> Result<(), String> {
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

pub(super) fn lexical_score(document: &CapabilityIndexDocument, query: &str) -> f32 {
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
        let function_id = document.function_id.to_ascii_lowercase();
        let contract_id = document.contract_id.to_ascii_lowercase();
        if function_id == *token {
            score += 100.0;
        } else if identifier_matches_token(&function_id, token) {
            score += 50.0;
        } else if contract_id == *token || identifier_matches_token(&contract_id, token) {
            score += 40.0;
        } else if haystack.contains(token) {
            score += 10.0;
        }
    }
    score / tokens.len() as f32
}

fn identifier_matches_token(identifier: &str, token: &str) -> bool {
    identifier
        .split("::")
        .flat_map(|component| {
            std::iter::once(component)
                .chain(component.split('_'))
                .filter(|part| !part.is_empty())
        })
        .any(|part| part == token)
}

pub(super) fn trust_boost(tier: &str) -> f32 {
    match tier {
        "first_party_signed" => 0.060,
        "trusted_signed" => 0.050,
        "user_installed" => 0.035,
        "session_generated" => 0.025,
        "external_mcp" | "external_openapi" => 0.015,
        _ => 0.0,
    }
}

pub(super) fn trust_rank(tier: &str) -> u8 {
    TRUST_ORDER
        .iter()
        .position(|candidate| *candidate == tier)
        .unwrap_or(TRUST_ORDER.len()) as u8
}

fn search_tokens(text: &str) -> Vec<String> {
    text.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_' && ch != ':')
        .filter(|token| !token.trim().is_empty())
        .map(|token| token.to_ascii_lowercase())
        .collect()
}

pub(super) fn snippet(text: &str, query: &str) -> String {
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
