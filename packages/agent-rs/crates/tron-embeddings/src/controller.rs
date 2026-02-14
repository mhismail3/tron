//! Embedding controller — orchestrates service and vector repository.

use std::sync::Arc;

use parking_lot::Mutex;
use tracing::{debug, warn};

use crate::config::EmbeddingConfig;
use crate::errors::{EmbeddingError, Result};
use crate::service::EmbeddingService;
use crate::text::build_embedding_text_from_json;
use crate::vector_repo::{SearchOptions, VectorRepository, VectorSearchResult};

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

/// Orchestrates embedding service and vector repository.
pub struct EmbeddingController {
    service: Option<Arc<dyn EmbeddingService>>,
    vector_repo: Option<Arc<Mutex<VectorRepository>>>,
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
    pub fn set_vector_repo(&mut self, repo: Arc<Mutex<VectorRepository>>) {
        self.vector_repo = Some(repo);
    }

    /// Whether both the service and repo are ready.
    pub fn is_ready(&self) -> bool {
        self.service
            .as_ref()
            .is_some_and(|s| s.is_ready())
            && self.vector_repo.is_some()
    }

    /// Get the config.
    pub fn config(&self) -> &EmbeddingConfig {
        &self.config
    }

    /// Embed a memory ledger entry and store its vector.
    pub async fn embed_memory(
        &self,
        event_id: &str,
        workspace_id: &str,
        payload: &serde_json::Value,
    ) -> Result<()> {
        let service = self.service.as_ref().ok_or(EmbeddingError::NotReady)?;
        if !service.is_ready() {
            return Err(EmbeddingError::NotReady);
        }
        let repo = self.vector_repo.as_ref().ok_or(EmbeddingError::NotReady)?;

        let text = build_embedding_text_from_json(payload);
        if text.is_empty() {
            debug!(event_id, "skipping embedding: empty text");
            return Ok(());
        }

        let embedding = service.embed_single(&text).await?;
        repo.lock().store(event_id, workspace_id, &embedding)?;
        debug!(event_id, "embedded memory entry");
        Ok(())
    }

    /// Search for similar vectors.
    pub async fn search(
        &self,
        query_text: &str,
        opts: &SearchOptions,
    ) -> Result<Vec<VectorSearchResult>> {
        let service = self.service.as_ref().ok_or(EmbeddingError::NotReady)?;
        if !service.is_ready() {
            return Err(EmbeddingError::NotReady);
        }
        let repo = self.vector_repo.as_ref().ok_or(EmbeddingError::NotReady)?;

        if query_text.is_empty() {
            return Ok(vec![]);
        }

        let query_embedding = service.embed_single(query_text).await?;
        repo.lock().search(&query_embedding, opts)
    }

    /// Backfill embeddings for entries that don't have vectors yet.
    pub async fn backfill(&self, entries: Vec<BackfillEntry>) -> Result<BackfillResult> {
        let service = self.service.as_ref().ok_or(EmbeddingError::NotReady)?;
        if !service.is_ready() {
            return Err(EmbeddingError::NotReady);
        }
        let repo = self.vector_repo.as_ref().ok_or(EmbeddingError::NotReady)?;

        let mut result = BackfillResult {
            succeeded: 0,
            failed: 0,
            skipped: 0,
        };

        for entry in entries {
            let text = build_embedding_text_from_json(&entry.payload);
            if text.is_empty() {
                result.skipped += 1;
                continue;
            }
            match service.embed_single(&text).await {
                Ok(embedding) => {
                    match repo
                        .lock()
                        .store(&entry.event_id, &entry.workspace_id, &embedding)
                    {
                        Ok(()) => result.succeeded += 1,
                        Err(e) => {
                            warn!(event_id = %entry.event_id, error = %e, "backfill store failed");
                            result.failed += 1;
                        }
                    }
                }
                Err(e) => {
                    warn!(event_id = %entry.event_id, error = %e, "backfill embed failed");
                    result.failed += 1;
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
            .search("test query", &SearchOptions { limit: 5, ..Default::default() })
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
    }

    #[tokio::test]
    async fn search_not_ready_error() {
        let ctrl = make_controller(512);
        let result = ctrl
            .search("test", &SearchOptions { limit: 5, ..Default::default() })
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
            .search("", &SearchOptions { limit: 5, ..Default::default() })
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
            .search("Test entry", &SearchOptions { limit: 5, ..Default::default() })
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
            .search("Test entry", &SearchOptions { limit: 10, ..Default::default() })
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
}
