//! Embedding controller — orchestrates service and vector repository.

use std::fmt::Write;
use std::sync::Arc;

use parking_lot::Mutex;
use tracing::{debug, warn};

use crate::config::EmbeddingConfig;
use crate::errors::{EmbeddingError, Result};
use crate::hybrid::{reciprocal_rank_fusion, HybridResult, HybridSearchOptions};
use crate::service::EmbeddingService;
use crate::text::{
    build_embedding_text_from_json, build_lesson_texts, with_document_prefix, with_query_prefix,
};
use tron_events::types::payloads::memory::MemoryLedgerPayload;
use crate::vector_repo::{SearchOptions, VectorRepository, VectorSearchResult};

/// Workspace memory loaded from ledger entries.
pub struct WorkspaceMemory {
    /// Formatted markdown content for injection into system prompt.
    pub content: String,
    /// Number of ledger entries included.
    pub count: usize,
    /// Estimated token count (`content.len() / 4`).
    pub tokens: u64,
}

/// Result of a backfill operation.
#[derive(Clone, Debug)]
pub struct BackfillResult {
    /// Number of entries successfully embedded.
    pub succeeded: usize,
    /// Number of entries that failed.
    pub failed: usize,
    /// Number of entries skipped (empty text).
    pub skipped: usize,
}

/// Entry to be backfilled.
pub struct BackfillEntry {
    /// Event ID.
    pub event_id: String,
    /// Workspace ID.
    pub workspace_id: String,
    /// Payload as JSON.
    pub payload: serde_json::Value,
}

type SharedRepo = Arc<Mutex<VectorRepository>>;

/// Orchestrates embedding service and vector repository.
pub struct EmbeddingController {
    service: Option<Arc<dyn EmbeddingService>>,
    vector_repo: Option<SharedRepo>,
    config: EmbeddingConfig,
}

impl EmbeddingController {
    /// Create a new controller with the given config.
    pub fn new(config: EmbeddingConfig) -> Self {
        Self {
            service: None,
            vector_repo: None,
            config,
        }
    }

    /// Set the embedding service.
    pub fn set_service(&mut self, service: Arc<dyn EmbeddingService>) {
        self.service = Some(service);
    }

    /// Set the vector repository.
    pub fn set_vector_repo(&mut self, repo: SharedRepo) {
        self.vector_repo = Some(repo);
    }

    /// Whether both the service and repo are ready.
    pub fn is_ready(&self) -> bool {
        self.service.as_ref().is_some_and(|s| s.is_ready()) && self.vector_repo.is_some()
    }

    /// Get the config.
    pub fn config(&self) -> &EmbeddingConfig {
        &self.config
    }

    /// Returns the service and repo refs, or `NotReady` if either is missing/unready.
    fn ready_parts(&self) -> Result<(&Arc<dyn EmbeddingService>, &SharedRepo)> {
        let service = self.service.as_ref().ok_or(EmbeddingError::NotReady)?;
        if !service.is_ready() {
            return Err(EmbeddingError::NotReady);
        }
        let repo = self.vector_repo.as_ref().ok_or(EmbeddingError::NotReady)?;
        Ok((service, repo))
    }

    /// Embed a memory ledger entry and store its vectors.
    ///
    /// Creates 1 summary vector plus per-lesson vectors if the entry has >1 lesson.
    pub async fn embed_memory(
        &self,
        event_id: &str,
        workspace_id: &str,
        payload: &serde_json::Value,
    ) -> Result<()> {
        let (service, repo) = self.ready_parts()?;

        let text = build_embedding_text_from_json(payload.clone());
        if text.is_empty() {
            debug!(event_id, "skipping embedding: empty text");
            return Ok(());
        }

        // Delete existing vectors for this event (clean upsert)
        let repo_del = Arc::clone(repo);
        let eid_del = event_id.to_owned();
        let _ = tokio::task::spawn_blocking(move || repo_del.lock().delete_by_event(&eid_del))
            .await
            .map_err(|e| EmbeddingError::Internal(format!("join: {e}")))?;

        // 1. Summary vector
        let prefixed = with_document_prefix(&text);
        let embedding = service.embed_single(&prefixed).await?;

        let repo_s = Arc::clone(repo);
        let id_s = format!("{event_id}-summary");
        let eid_s = event_id.to_owned();
        let ws_s = workspace_id.to_owned();
        let _ = tokio::task::spawn_blocking(move || {
            repo_s
                .lock()
                .store(&id_s, &eid_s, &ws_s, "summary", 0, None, None, &embedding)
        })
        .await
        .map_err(|e| EmbeddingError::Internal(format!("join: {e}")))?;

        // 2. Per-lesson vectors (only if >1 lesson — with 1 lesson the summary covers it)
        if let Ok(parsed) = serde_json::from_value::<MemoryLedgerPayload>(payload.clone()) {
            let lesson_texts = build_lesson_texts(&parsed);
            if lesson_texts.len() > 1 {
                for (i, lesson_text) in lesson_texts.iter().enumerate() {
                    let prefixed_lesson = with_document_prefix(lesson_text);
                    if let Ok(lesson_emb) = service.embed_single(&prefixed_lesson).await {
                        let repo_l = Arc::clone(repo);
                        let id_l = format!("{event_id}-lesson-{}", i + 1);
                        let eid_l = event_id.to_owned();
                        let ws_l = workspace_id.to_owned();
                        let chunk_idx = (i + 1) as i64;
                        let _ = tokio::task::spawn_blocking(move || {
                            repo_l.lock().store(
                                &id_l,
                                &eid_l,
                                &ws_l,
                                "lesson",
                                chunk_idx,
                                None,
                                None,
                                &lesson_emb,
                            )
                        })
                        .await;
                    }
                }
            }
        }

        Ok(())
    }

    /// Search for similar vectors.
    pub async fn search(
        &self,
        query_text: &str,
        opts: &SearchOptions,
    ) -> Result<Vec<VectorSearchResult>> {
        let (service, repo) = self.ready_parts()?;

        if query_text.is_empty() {
            return Ok(vec![]);
        }

        let prefixed = with_query_prefix(query_text);
        let query_embedding = service.embed_single(&prefixed).await?;

        let repo = Arc::clone(repo);
        let opts = opts.clone();
        tokio::task::spawn_blocking(move || repo.lock().search(&query_embedding, &opts))
            .await
            .map_err(|e| EmbeddingError::Internal(format!("join: {e}")))?
    }

    /// Hybrid search: fuse vector similarity with FTS BM25 results via RRF.
    ///
    /// Runs vector search internally, then fuses with the provided FTS results.
    /// Returns results ranked by fused RRF score.
    pub async fn hybrid_search(
        &self,
        query_text: &str,
        fts_results: &[(String, f32)],
        hybrid_opts: &HybridSearchOptions,
        search_opts: &SearchOptions,
    ) -> Result<Vec<HybridResult>> {
        if query_text.is_empty() && fts_results.is_empty() {
            return Ok(vec![]);
        }

        // Vector search (may be empty if query is empty or service not ready)
        let vector_results = if !query_text.is_empty() {
            self.search(query_text, search_opts).await.unwrap_or_default()
        } else {
            vec![]
        };

        Ok(reciprocal_rank_fusion(
            &vector_results,
            fts_results,
            hybrid_opts,
        ))
    }

    /// Load workspace memory from ledger entries for injection into system prompt.
    ///
    /// When `session_context` is provided and embeddings are ready, uses semantic
    /// search to find the most relevant entries. Always includes
    /// `recency_anchor_count` most-recent entries, then fills remaining slots
    /// with semantically relevant entries (or chronological backfill).
    pub async fn load_workspace_memory(
        &self,
        event_store: &tron_events::EventStore,
        workspace_id: &str,
        count: usize,
        session_context: Option<&str>,
        recency_anchor_count: usize,
    ) -> Option<WorkspaceMemory> {
        if workspace_id.is_empty() {
            return None;
        }

        // 1. Fetch `count` newest memory.ledger events (newest first)
        #[allow(clippy::cast_possible_wrap)]
        let events = event_store
            .get_events_by_workspace_and_types(
                workspace_id,
                &["memory.ledger"],
                Some(count as i64),
                None,
            )
            .unwrap_or_default();

        if events.is_empty() {
            return None;
        }

        // 2. Parse payloads into (event_id, timestamp, Value) — keep newest-first order
        let parsed: Vec<(String, String, serde_json::Value)> = events
            .iter()
            .filter_map(|e| {
                serde_json::from_str::<serde_json::Value>(&e.payload)
                    .map(|v| (e.id.clone(), e.timestamp.clone(), v))
                    .map_err(|err| {
                        warn!(event_id = %e.id, error = %err, "failed to parse ledger payload");
                    })
                    .ok()
            })
            .collect();

        if parsed.is_empty() {
            return None;
        }

        // 3. Identify recency anchor (first N in newest-first order)
        let anchor_count = recency_anchor_count.min(parsed.len());

        // 4. Decide which entries to include
        let trimmed_ctx = session_context.map(|s| s.trim()).unwrap_or("");
        let semantic_slots = count.saturating_sub(anchor_count);

        let selected: Vec<(String, String, serde_json::Value)> =
            if !trimmed_ctx.is_empty() && semantic_slots > 0 && self.is_ready() {
                // Semantic path: search for relevant entries
                let search_result = self
                    .search(
                        trimmed_ctx,
                        &SearchOptions {
                            limit: count,
                            workspace_id: Some(workspace_id.to_owned()),
                            ..Default::default()
                        },
                    )
                    .await;

                match search_result {
                    Ok(results) => {
                        // Recency anchor event IDs
                        let anchor_ids: std::collections::HashSet<&str> = parsed
                            .iter()
                            .take(anchor_count)
                            .map(|(id, _, _)| id.as_str())
                            .collect();

                        // Chronological event IDs (for backfill)
                        let chrono_ids: std::collections::HashSet<&str> =
                            parsed.iter().map(|(id, _, _)| id.as_str()).collect();

                        // Semantic results not already in recency set
                        let semantic_ids: Vec<String> = results
                            .iter()
                            .filter(|r| !anchor_ids.contains(r.event_id.as_str()))
                            .take(semantic_slots)
                            .map(|r| r.event_id.clone())
                            .collect();

                        let semantic_filled = semantic_ids.len();
                        let backfill_needed = semantic_slots.saturating_sub(semantic_filled);

                        // Collect all selected event IDs
                        let mut selected_ids: Vec<String> = parsed
                            .iter()
                            .take(anchor_count)
                            .map(|(id, _, _)| id.clone())
                            .collect();
                        selected_ids.extend(semantic_ids.clone());

                        // Backfill from chronological (skip anchors and semantic)
                        if backfill_needed > 0 {
                            let already: std::collections::HashSet<&str> =
                                selected_ids.iter().map(String::as_str).collect();
                            let backfill: Vec<String> = parsed
                                .iter()
                                .skip(anchor_count)
                                .filter(|(id, _, _)| !already.contains(id.as_str()))
                                .take(backfill_needed)
                                .map(|(id, _, _)| id.clone())
                                .collect();
                            selected_ids.extend(backfill);
                        }

                        let selected_set: std::collections::HashSet<&str> =
                            selected_ids.iter().map(String::as_str).collect();

                        // Fetch any semantic results not in our pre-fetched set
                        let missing: Vec<&str> = semantic_ids
                            .iter()
                            .filter(|id| !chrono_ids.contains(id.as_str()))
                            .map(String::as_str)
                            .collect();

                        let extra_events = if !missing.is_empty() {
                            event_store
                                .get_events_by_ids(&missing)
                                .unwrap_or_default()
                        } else {
                            std::collections::HashMap::new()
                        };

                        // Build final list from pre-fetched + extra
                        let mut result: Vec<(String, String, serde_json::Value)> = parsed
                            .iter()
                            .filter(|(id, _, _)| selected_set.contains(id.as_str()))
                            .cloned()
                            .collect();

                        for (eid, row) in &extra_events {
                            if selected_set.contains(eid.as_str())
                                && !result.iter().any(|(id, _, _)| id == eid)
                            {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(
                                    &row.payload,
                                ) {
                                    result.push((
                                        eid.clone(),
                                        row.timestamp.clone(),
                                        v,
                                    ));
                                }
                            }
                        }

                        result
                    }
                    Err(e) => {
                        warn!(error = %e, "semantic search failed, falling back to chronological");
                        parsed
                    }
                }
            } else {
                // Chronological fallback
                parsed
            };

        if selected.is_empty() {
            return None;
        }

        // 5. Sort by timestamp (oldest first) for natural reading order
        let mut sorted = selected;
        sorted.sort_by(|a, b| a.1.cmp(&b.1));

        // 6. Format as markdown sections
        let mut sections = Vec::new();
        sections.push("# Memory\n\n## Recent sessions in this workspace".to_string());

        for (_, _, entry) in &sorted {
            let title = entry
                .get("title")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Untitled");

            let mut section = format!("\n### {title}");

            if let Some(lessons) = entry.get("lessons").and_then(serde_json::Value::as_array) {
                for lesson in lessons {
                    if let Some(text) = lesson.as_str() {
                        if !text.is_empty() {
                            write!(section, "\n- {text}").unwrap();
                        }
                    }
                }
            }

            if let Some(decisions) = entry.get("decisions").and_then(serde_json::Value::as_array) {
                for decision in decisions {
                    let choice = decision
                        .get("choice")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    let reason = decision
                        .get("reason")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    if !choice.is_empty() {
                        write!(section, "\n- {choice}: {reason}").unwrap();
                    }
                }
            }

            sections.push(section);
        }

        // 7. Truncate to max_workspace_lessons_tokens budget
        let max_tokens = self.config.max_workspace_lessons_tokens as u64;
        let mut content = sections.join("\n");
        let count_fn = |text: &str| -> u64 {
            self.service
                .as_ref()
                .filter(|s| s.is_ready())
                .map_or_else(
                    || (text.len() as u64) / 4,
                    |s| s.count_tokens(text) as u64,
                )
        };
        let mut tokens = count_fn(&content);

        if tokens > max_tokens && sections.len() > 2 {
            while tokens > max_tokens && sections.len() > 2 {
                let _ = sections.remove(2);
                content = sections.join("\n");
                tokens = count_fn(&content);
            }
        }

        let entry_count = sections.len().saturating_sub(1); // exclude header

        Some(WorkspaceMemory {
            content,
            count: entry_count,
            tokens,
        })
    }

    /// Backfill embeddings for entries that don't have vectors yet.
    ///
    /// Creates multi-vector embeddings: 1 summary + per-lesson vectors.
    pub async fn backfill(&self, entries: Vec<BackfillEntry>) -> Result<BackfillResult> {
        let (service, repo) = self.ready_parts()?;

        let mut result = BackfillResult {
            succeeded: 0,
            failed: 0,
            skipped: 0,
        };

        for entry in entries {
            let payload_clone = entry.payload.clone();
            let text = build_embedding_text_from_json(entry.payload);
            if text.is_empty() {
                result.skipped += 1;
                continue;
            }

            // Delete existing vectors for clean re-embed
            let _ = repo.lock().delete_by_event(&entry.event_id);

            // Summary vector
            let prefixed = with_document_prefix(&text);
            match service.embed_single(&prefixed).await {
                Ok(embedding) => {
                    let id = format!("{}-summary", entry.event_id);
                    match repo.lock().store(
                        &id,
                        &entry.event_id,
                        &entry.workspace_id,
                        "summary",
                        0,
                        None,
                        None,
                        &embedding,
                    ) {
                        Ok(()) => result.succeeded += 1,
                        Err(e) => {
                            warn!(event_id = %entry.event_id, error = %e, "backfill store failed");
                            result.failed += 1;
                            continue;
                        }
                    }
                }
                Err(e) => {
                    warn!(event_id = %entry.event_id, error = %e, "backfill embed failed");
                    result.failed += 1;
                    continue;
                }
            }

            // Per-lesson vectors
            if let Ok(parsed) = serde_json::from_value::<MemoryLedgerPayload>(payload_clone) {
                let lesson_texts = build_lesson_texts(&parsed);
                if lesson_texts.len() > 1 {
                    for (i, lesson_text) in lesson_texts.iter().enumerate() {
                        let prefixed_lesson = with_document_prefix(lesson_text);
                        if let Ok(lesson_emb) = service.embed_single(&prefixed_lesson).await {
                            let id = format!("{}-lesson-{}", entry.event_id, i + 1);
                            let _ = repo.lock().store(
                                &id,
                                &entry.event_id,
                                &entry.workspace_id,
                                "lesson",
                                (i + 1) as i64,
                                None,
                                None,
                                &lesson_emb,
                            );
                        }
                    }
                }
            }
        }

        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::service::MockEmbeddingService;
    use crate::vector_repo::VectorRepository;
    use rusqlite::Connection;

    fn make_controller(dims: usize) -> EmbeddingController {
        let config = EmbeddingConfig {
            dimensions: dims,
            ..EmbeddingConfig::default()
        };
        EmbeddingController::new(config)
    }

    fn make_service(dims: usize) -> Arc<MockEmbeddingService> {
        Arc::new(MockEmbeddingService::new(dims))
    }

    fn make_repo(dims: usize) -> Arc<Mutex<VectorRepository>> {
        let conn = Connection::open_in_memory().unwrap();
        let repo = VectorRepository::new(conn, dims);
        repo.ensure_table().unwrap();
        Arc::new(Mutex::new(repo))
    }

    fn test_payload() -> serde_json::Value {
        serde_json::json!({
            "eventRange": {"firstEventId": "e1", "lastEventId": "e2"},
            "turnRange": {"firstTurn": 1, "lastTurn": 2},
            "title": "Test entry",
            "entryType": "feature",
            "status": "completed",
            "tags": ["test"],
            "input": "test input",
            "actions": ["did stuff"],
            "files": [],
            "decisions": [{"choice": "A", "reason": "better"}],
            "lessons": ["learned things"],
            "thinkingInsights": [],
            "tokenCost": {"input": 100, "output": 50},
            "model": "claude",
            "workingDirectory": "/tmp"
        })
    }

    #[test]
    fn new_not_ready() {
        let ctrl = make_controller(512);
        assert!(!ctrl.is_ready());
    }

    #[test]
    fn set_service_makes_ready() {
        let mut ctrl = make_controller(512);
        ctrl.set_service(make_service(512));
        // Still not ready without repo
        assert!(!ctrl.is_ready());
        ctrl.set_vector_repo(make_repo(512));
        assert!(ctrl.is_ready());
    }

    #[tokio::test]
    async fn embed_memory_stores_vector() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        ctrl.embed_memory("evt1", "ws1", &test_payload())
            .await
            .unwrap();
        assert_eq!(repo.lock().count().unwrap(), 1);
    }

    #[tokio::test]
    async fn embed_memory_not_ready_error() {
        let ctrl = make_controller(512);
        let result = ctrl.embed_memory("evt1", "ws1", &test_payload()).await;
        assert!(matches!(result, Err(EmbeddingError::NotReady)));
    }

    #[tokio::test]
    async fn embed_memory_empty_text_skips() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        let empty_payload = serde_json::json!({
            "eventRange": {"firstEventId": "", "lastEventId": ""},
            "turnRange": {"firstTurn": 0, "lastTurn": 0},
            "title": "",
            "entryType": "",
            "status": "",
            "tags": [],
            "input": "",
            "actions": [],
            "files": [],
            "decisions": [],
            "lessons": [],
            "thinkingInsights": [],
            "tokenCost": {"input": 0, "output": 0},
            "model": "",
            "workingDirectory": ""
        });
        ctrl.embed_memory("evt1", "ws1", &empty_payload)
            .await
            .unwrap();
        assert_eq!(repo.lock().count().unwrap(), 0);
    }

    #[tokio::test]
    async fn search_returns_results() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        ctrl.embed_memory("evt1", "ws1", &test_payload())
            .await
            .unwrap();
        let results = ctrl
            .search(
                "test query",
                &SearchOptions {
                    limit: 5,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
    }

    #[tokio::test]
    async fn search_not_ready_error() {
        let ctrl = make_controller(512);
        let result = ctrl
            .search(
                "test",
                &SearchOptions {
                    limit: 5,
                    ..Default::default()
                },
            )
            .await;
        assert!(matches!(result, Err(EmbeddingError::NotReady)));
    }

    #[tokio::test]
    async fn search_empty_query() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        ctrl.set_vector_repo(make_repo(dims));

        let results = ctrl
            .search(
                "",
                &SearchOptions {
                    limit: 5,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn backfill_all_succeed() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        let entries = vec![
            BackfillEntry {
                event_id: "e1".into(),
                workspace_id: "ws1".into(),
                payload: test_payload(),
            },
            BackfillEntry {
                event_id: "e2".into(),
                workspace_id: "ws1".into(),
                payload: test_payload(),
            },
        ];
        let result = ctrl.backfill(entries).await.unwrap();
        assert_eq!(result.succeeded, 2);
        assert_eq!(result.failed, 0);
        assert_eq!(result.skipped, 0);
        assert_eq!(repo.lock().count().unwrap(), 2);
    }

    #[tokio::test]
    async fn backfill_partial_failure() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        let entries = vec![
            BackfillEntry {
                event_id: "e1".into(),
                workspace_id: "ws1".into(),
                payload: test_payload(),
            },
            BackfillEntry {
                event_id: "e2".into(),
                workspace_id: "ws1".into(),
                payload: serde_json::json!({"invalid": true}), // will produce empty text
            },
        ];
        let result = ctrl.backfill(entries).await.unwrap();
        assert_eq!(result.succeeded, 1);
        assert_eq!(result.skipped, 1); // invalid payload → empty text → skip
    }

    #[tokio::test]
    async fn backfill_empty() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        ctrl.set_vector_repo(make_repo(dims));

        let result = ctrl.backfill(vec![]).await.unwrap();
        assert_eq!(result.succeeded, 0);
        assert_eq!(result.failed, 0);
        assert_eq!(result.skipped, 0);
    }

    #[tokio::test]
    async fn backfill_not_ready() {
        let ctrl = make_controller(512);
        let result = ctrl.backfill(vec![]).await;
        assert!(matches!(result, Err(EmbeddingError::NotReady)));
    }

    #[tokio::test]
    async fn embed_then_search_finds_it() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        // The mock service is deterministic, so embedding then searching with
        // similar text should find the entry
        ctrl.embed_memory("evt1", "ws1", &test_payload())
            .await
            .unwrap();

        let results = ctrl
            .search(
                "Test entry",
                &SearchOptions {
                    limit: 5,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "evt1");
    }

    #[tokio::test]
    async fn embed_multiple_search_ordered() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        let payload1 = test_payload();
        let mut payload2 = test_payload();
        payload2["title"] = serde_json::json!("Different topic entirely");

        ctrl.embed_memory("evt1", "ws1", &payload1).await.unwrap();
        ctrl.embed_memory("evt2", "ws1", &payload2).await.unwrap();

        let results = ctrl
            .search(
                "Test entry",
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 2);
        // Results should be ordered by similarity
        assert!(results[0].similarity >= results[1].similarity);
    }

    #[test]
    fn ready_requires_both_service_and_repo() {
        let mut ctrl = make_controller(512);

        // No service, no repo
        assert!(!ctrl.is_ready());

        // Service only
        ctrl.set_service(make_service(512));
        assert!(!ctrl.is_ready());

        // Both
        ctrl.set_vector_repo(make_repo(512));
        assert!(ctrl.is_ready());
    }

    // ── Workspace memory tests ──

    fn make_event_store() -> Arc<tron_events::EventStore> {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(tron_events::EventStore::new(pool))
    }

    #[tokio::test]
    async fn load_workspace_memory_no_entries_returns_none() {
        let ctrl = make_controller(512);
        let store = make_event_store();
        let result = ctrl.load_workspace_memory(&store, "/tmp/project", 5, None, 2).await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn load_workspace_memory_empty_workspace_returns_none() {
        let ctrl = make_controller(512);
        let store = make_event_store();
        let result = ctrl.load_workspace_memory(&store, "", 5, None, 2).await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn load_workspace_memory_formats_markdown() {
        let ctrl = make_controller(512);
        let store = make_event_store();

        // Create session and get workspace ID
        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None, None)
            .unwrap();
        let sid = result.root_event.session_id;
        let ws_id = store
            .get_workspace_by_path("/tmp/project")
            .unwrap()
            .unwrap()
            .id;

        let _ = store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: serde_json::json!({
                "title": "Added auth system",
                "entryType": "feature",
                "lessons": ["Use JWT for stateless auth", "Always hash passwords"],
                "decisions": [{"choice": "bcrypt", "reason": "industry standard"}],
            }),
            parent_id: None,
        });

        let wm = ctrl.load_workspace_memory(&store, &ws_id, 5, None, 2).await.unwrap();
        assert_eq!(wm.count, 1);
        assert!(wm.content.contains("# Memory"));
        assert!(wm.content.contains("### Added auth system"));
        assert!(wm.content.contains("Use JWT for stateless auth"));
        assert!(wm.content.contains("Always hash passwords"));
        assert!(wm.content.contains("bcrypt: industry standard"));
        assert!(wm.tokens > 0);
    }

    #[tokio::test]
    async fn load_workspace_memory_respects_count() {
        let ctrl = make_controller(512);
        let store = make_event_store();

        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None, None)
            .unwrap();
        let sid = result.root_event.session_id;
        let ws_id = store
            .get_workspace_by_path("/tmp/project")
            .unwrap()
            .unwrap()
            .id;

        for i in 0..5 {
            let _ = store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MemoryLedger,
                payload: serde_json::json!({
                    "title": format!("Entry {i}"),
                    "lessons": [format!("Lesson from entry {i}")],
                }),
                parent_id: None,
            });
        }

        // Request only 2
        let wm = ctrl.load_workspace_memory(&store, &ws_id, 2, None, 2).await.unwrap();
        assert_eq!(wm.count, 2);
    }

    #[test]
    fn config_propagated() {
        let config = EmbeddingConfig {
            dimensions: 256,
            model: "test-model".into(),
            ..EmbeddingConfig::default()
        };
        let ctrl = EmbeddingController::new(config.clone());
        assert_eq!(ctrl.config().dimensions, 256);
        assert_eq!(ctrl.config().model, "test-model");
    }

    #[test]
    fn ready_parts_not_ready_without_service() {
        let ctrl = make_controller(512);
        assert!(ctrl.ready_parts().is_err());
    }

    #[test]
    fn ready_parts_not_ready_without_repo() {
        let mut ctrl = make_controller(512);
        ctrl.set_service(make_service(512));
        assert!(ctrl.ready_parts().is_err());
    }

    #[test]
    fn ready_parts_ok_when_both_set() {
        let mut ctrl = make_controller(512);
        ctrl.set_service(make_service(512));
        ctrl.set_vector_repo(make_repo(512));
        assert!(ctrl.ready_parts().is_ok());
    }

    #[tokio::test]
    async fn load_workspace_memory_respects_token_limit() {
        // Use a low token limit to force truncation
        let config = EmbeddingConfig {
            dimensions: 512,
            max_workspace_lessons_tokens: 100,
            ..EmbeddingConfig::default()
        };
        let ctrl = EmbeddingController::new(config);
        let store = make_event_store();

        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None, None)
            .unwrap();
        let sid = result.root_event.session_id;
        let ws_id = store
            .get_workspace_by_path("/tmp/project")
            .unwrap()
            .unwrap()
            .id;

        for i in 0..20 {
            let _ = store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MemoryLedger,
                payload: serde_json::json!({
                    "title": format!("Entry {i} with some long title to increase token count"),
                    "lessons": [
                        format!("This is a fairly long lesson from entry {i} designed to take up tokens"),
                        format!("Another lesson from entry {i} to push the token count higher"),
                    ],
                    "decisions": [{"choice": format!("Decision {i}"), "reason": "some reason"}],
                }),
                parent_id: None,
            });
        }

        let wm = ctrl.load_workspace_memory(&store, &ws_id, 20, None, 2).await.unwrap();
        // Token limit should have kicked in, reducing entries below 20
        assert!(wm.tokens <= 100, "tokens {} should be <= 100", wm.tokens);
        assert!(wm.count < 20, "count {} should be < 20", wm.count);
    }

    // ── Multi-vector tests ──

    fn multi_lesson_payload() -> serde_json::Value {
        serde_json::json!({
            "eventRange": {"firstEventId": "e1", "lastEventId": "e2"},
            "turnRange": {"firstTurn": 1, "lastTurn": 2},
            "title": "Multi lesson entry",
            "entryType": "feature",
            "status": "completed",
            "tags": ["test"],
            "input": "test input",
            "actions": ["did stuff"],
            "files": [],
            "decisions": [],
            "lessons": ["lesson one", "lesson two", "lesson three"],
            "thinkingInsights": [],
            "tokenCost": {"input": 100, "output": 50},
            "model": "claude",
            "workingDirectory": "/tmp"
        })
    }

    #[tokio::test]
    async fn embed_memory_multi_lesson_creates_extra_vectors() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        ctrl.embed_memory("evt1", "ws1", &multi_lesson_payload())
            .await
            .unwrap();
        // 1 summary + 3 lesson vectors = 4 total
        assert_eq!(repo.lock().count().unwrap(), 4);
    }

    #[tokio::test]
    async fn embed_memory_single_lesson_no_extra_vectors() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        // test_payload() has exactly 1 lesson — no per-lesson vectors
        ctrl.embed_memory("evt1", "ws1", &test_payload())
            .await
            .unwrap();
        assert_eq!(repo.lock().count().unwrap(), 1);
    }

    #[tokio::test]
    async fn embed_memory_multi_lesson_search_deduplicates() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        ctrl.embed_memory("evt1", "ws1", &multi_lesson_payload())
            .await
            .unwrap();

        // Search should return only 1 result (deduplicated by event_id)
        let results = ctrl
            .search(
                "lesson one",
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "evt1");
    }

    #[tokio::test]
    async fn hybrid_search_fuses_vector_and_fts() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        ctrl.embed_memory("evt1", "ws1", &test_payload())
            .await
            .unwrap();
        ctrl.embed_memory("evt2", "ws1", &multi_lesson_payload())
            .await
            .unwrap();

        // FTS results include evt1 and a third event not in vectors
        let fts = vec![
            ("evt1".to_string(), 10.0),
            ("evt3".to_string(), 5.0),
        ];
        let hybrid_opts = HybridSearchOptions::default();
        let search_opts = SearchOptions {
            limit: 10,
            ..Default::default()
        };

        let results = ctrl
            .hybrid_search("test query", &fts, &hybrid_opts, &search_opts)
            .await
            .unwrap();

        // evt1 appears in both → highest score
        assert!(!results.is_empty());
        assert_eq!(results[0].event_id, "evt1");
        // All three events should appear
        let ids: Vec<&str> = results.iter().map(|r| r.event_id.as_str()).collect();
        assert!(ids.contains(&"evt1"));
        assert!(ids.contains(&"evt2"));
        assert!(ids.contains(&"evt3"));
    }

    #[tokio::test]
    async fn hybrid_search_empty_returns_empty() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        ctrl.set_vector_repo(make_repo(dims));

        let results = ctrl
            .hybrid_search("", &[], &HybridSearchOptions::default(), &SearchOptions::default())
            .await
            .unwrap();
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn backfill_multi_lesson_creates_extra_vectors() {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        let entries = vec![BackfillEntry {
            event_id: "e1".into(),
            workspace_id: "ws1".into(),
            payload: multi_lesson_payload(),
        }];
        let result = ctrl.backfill(entries).await.unwrap();
        assert_eq!(result.succeeded, 1);
        // 1 summary + 3 lesson = 4 vectors
        assert_eq!(repo.lock().count().unwrap(), 4);
    }

    // ── Semantic workspace memory tests ──

    /// Create a controller with service + repo, event store with N memory.ledger
    /// entries (each embedded), returning (controller, store, workspace_id, event_ids).
    /// Event IDs are in insertion order (oldest first).
    async fn setup_semantic_test(
        n: usize,
    ) -> (
        EmbeddingController,
        Arc<tron_events::EventStore>,
        String,
        Vec<String>,
    ) {
        let dims = 512;
        let mut ctrl = make_controller(dims);
        ctrl.set_service(make_service(dims));
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        let store = make_event_store();
        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None, None)
            .unwrap();
        let sid = result.root_event.session_id;
        let ws_id = store
            .get_workspace_by_path("/tmp/project")
            .unwrap()
            .unwrap()
            .id;

        let mut event_ids = Vec::new();
        for i in 0..n {
            let payload = serde_json::json!({
                "eventRange": {"firstEventId": "e1", "lastEventId": "e2"},
                "turnRange": {"firstTurn": 1, "lastTurn": 2},
                "title": format!("Entry {i}"),
                "entryType": "feature",
                "status": "completed",
                "tags": ["test"],
                "input": format!("input for entry {i}"),
                "actions": [format!("action {i}")],
                "files": [],
                "decisions": [],
                "lessons": [format!("Lesson from entry {i}")],
                "thinkingInsights": [],
                "tokenCost": {"input": 100, "output": 50},
                "model": "claude",
                "workingDirectory": "/tmp"
            });

            let evt = store
                .append(&tron_events::AppendOptions {
                    session_id: &sid,
                    event_type: tron_events::EventType::MemoryLedger,
                    payload: payload.clone(),
                    parent_id: None,
                })
                .unwrap();

            ctrl.embed_memory(&evt.id, &ws_id, &payload).await.unwrap();
            event_ids.push(evt.id);
        }

        (ctrl, store, ws_id, event_ids)
    }

    #[tokio::test]
    async fn semantic_with_context_mixes_results() {
        let (ctrl, store, ws_id, _ids) = setup_semantic_test(5).await;
        // Search for "Entry 0" — semantic should find it relevant
        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 5, Some("Entry 0"), 2)
            .await
            .unwrap();
        assert_eq!(wm.count, 5);
        // Recency anchors (newest = Entry 4, Entry 3) must be present
        assert!(wm.content.contains("Entry 4"), "missing recency anchor Entry 4");
        assert!(wm.content.contains("Entry 3"), "missing recency anchor Entry 3");
        // Entry 0 should be present (semantically relevant)
        assert!(wm.content.contains("Entry 0"), "missing semantic result Entry 0");
    }

    #[tokio::test]
    async fn semantic_fallback_not_ready() {
        // Controller without service — not ready
        let ctrl = make_controller(512);
        let store = make_event_store();
        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None, None)
            .unwrap();
        let sid = result.root_event.session_id;
        let ws_id = store
            .get_workspace_by_path("/tmp/project")
            .unwrap()
            .unwrap()
            .id;

        for i in 0..5 {
            let _ = store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MemoryLedger,
                payload: serde_json::json!({
                    "title": format!("Entry {i}"),
                    "lessons": [format!("Lesson {i}")],
                }),
                parent_id: None,
            });
        }

        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 5, Some("query"), 2)
            .await
            .unwrap();
        // Falls back to chronological — all 5 entries
        assert_eq!(wm.count, 5);
    }

    #[tokio::test]
    async fn semantic_fallback_empty_context() {
        let (ctrl, store, ws_id, _) = setup_semantic_test(5).await;
        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 5, Some(""), 2)
            .await
            .unwrap();
        assert_eq!(wm.count, 5);
    }

    #[tokio::test]
    async fn semantic_fallback_whitespace_context() {
        let (ctrl, store, ws_id, _) = setup_semantic_test(5).await;
        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 5, Some("   "), 2)
            .await
            .unwrap();
        assert_eq!(wm.count, 5);
    }

    #[tokio::test]
    async fn semantic_count_lte_anchor() {
        let (ctrl, store, ws_id, _) = setup_semantic_test(5).await;
        // count=2, anchor=2 → only recency, no semantic search
        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 2, Some("Entry 0"), 2)
            .await
            .unwrap();
        assert_eq!(wm.count, 2);
        // Should be the 2 newest
        assert!(wm.content.contains("Entry 4"));
        assert!(wm.content.contains("Entry 3"));
    }

    #[tokio::test]
    async fn semantic_dedup_no_duplicates() {
        let (ctrl, store, ws_id, _) = setup_semantic_test(5).await;
        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 5, Some("Entry 4"), 2)
            .await
            .unwrap();
        // Count unique titles — should have no duplicates
        let titles: Vec<&str> = wm
            .content
            .lines()
            .filter(|l| l.starts_with("### ") || l.starts_with("\n### "))
            .map(|l| l.trim_start_matches('\n').trim_start_matches("### "))
            .collect();
        let unique: std::collections::HashSet<&str> = titles.iter().copied().collect();
        assert_eq!(titles.len(), unique.len(), "duplicate titles found: {titles:?}");
    }

    #[tokio::test]
    async fn semantic_search_error_fallback() {
        // Embed entries with a ready controller, then disable it
        let dims = 512;
        let mut ctrl = make_controller(dims);
        let svc = make_service(dims);
        ctrl.set_service(Arc::clone(&svc) as Arc<dyn EmbeddingService>);
        let repo = make_repo(dims);
        ctrl.set_vector_repo(Arc::clone(&repo));

        let store = make_event_store();
        let result = store
            .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None, None)
            .unwrap();
        let sid = result.root_event.session_id;
        let ws_id = store
            .get_workspace_by_path("/tmp/project")
            .unwrap()
            .unwrap()
            .id;

        for i in 0..5 {
            let payload = serde_json::json!({
                "eventRange": {"firstEventId": "e1", "lastEventId": "e2"},
                "turnRange": {"firstTurn": 1, "lastTurn": 2},
                "title": format!("Entry {i}"),
                "entryType": "feature",
                "status": "completed",
                "tags": [],
                "input": format!("input {i}"),
                "actions": [],
                "files": [],
                "decisions": [],
                "lessons": [format!("Lesson {i}")],
                "thinkingInsights": [],
                "tokenCost": {"input": 100, "output": 50},
                "model": "claude",
                "workingDirectory": "/tmp"
            });

            let evt = store
                .append(&tron_events::AppendOptions {
                    session_id: &sid,
                    event_type: tron_events::EventType::MemoryLedger,
                    payload: payload.clone(),
                    parent_id: None,
                })
                .unwrap();
            ctrl.embed_memory(&evt.id, &ws_id, &payload).await.unwrap();
        }

        // Disable the service — is_ready() now returns false → chronological fallback
        svc.set_ready(false);

        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 5, Some("query"), 2)
            .await
            .unwrap();
        assert_eq!(wm.count, 5);
    }

    #[tokio::test]
    async fn semantic_fewer_events_than_count() {
        let (ctrl, store, ws_id, _) = setup_semantic_test(3).await;
        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 5, Some("query"), 2)
            .await
            .unwrap();
        assert_eq!(wm.count, 3);
    }

    #[tokio::test]
    async fn semantic_single_entry() {
        let (ctrl, store, ws_id, _) = setup_semantic_test(1).await;
        let wm = ctrl
            .load_workspace_memory(&store, &ws_id, 1, Some("query"), 2)
            .await
            .unwrap();
        assert_eq!(wm.count, 1);
        assert!(wm.content.contains("Entry 0"));
    }
}
