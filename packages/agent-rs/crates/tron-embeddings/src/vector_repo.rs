//! Vector repository with `SQLite` BLOB storage and brute-force KNN search.

use rusqlite::{Connection, params};
use tracing::warn;

use crate::errors::{EmbeddingError, Result};
use crate::normalize::cosine_similarity;

/// Convert an f32 slice to a byte blob for storage.
pub fn f32_slice_to_blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

/// Convert a byte blob back to an f32 vector.
pub fn blob_to_f32_vec(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect()
}

/// Options for vector search.
#[derive(Clone, Debug)]
pub struct SearchOptions {
    /// Maximum number of results to return.
    pub limit: usize,
    /// Filter to a specific workspace.
    pub workspace_id: Option<String>,
    /// Exclude a specific workspace.
    pub exclude_workspace_id: Option<String>,
    /// Minimum similarity threshold (results below this are excluded).
    pub min_similarity: f32,
}

impl Default for SearchOptions {
    fn default() -> Self {
        Self {
            limit: 0,
            workspace_id: None,
            exclude_workspace_id: None,
            min_similarity: -1.0,
        }
    }
}

/// A single search result.
#[derive(Clone, Debug)]
pub struct VectorSearchResult {
    /// The event ID of the matched vector.
    pub event_id: String,
    /// The workspace ID.
    pub workspace_id: String,
    /// Cosine similarity score (higher = more similar).
    pub similarity: f32,
}

/// Vector repository using regular `SQLite` tables with brute-force KNN.
pub struct VectorRepository {
    conn: Connection,
    dims: usize,
}

impl VectorRepository {
    /// Create a new repository with the given connection and expected dimensions.
    pub fn new(conn: Connection, dims: usize) -> Self {
        Self { conn, dims }
    }

    /// Create the `memory_vectors` table if it doesn't exist.
    pub fn ensure_table(&self) -> Result<()> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS memory_vectors (
                    event_id TEXT PRIMARY KEY,
                    workspace_id TEXT NOT NULL,
                    embedding BLOB NOT NULL
                )",
        )?;
        Ok(())
    }

    /// Check if the `memory_vectors` table exists.
    pub fn has_table(&self) -> bool {
        self.conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='memory_vectors'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .is_ok_and(|c| c > 0)
    }

    /// Store an embedding (delete-then-insert for upsert).
    pub fn store(&self, event_id: &str, workspace_id: &str, embedding: &[f32]) -> Result<()> {
        if embedding.len() != self.dims {
            return Err(EmbeddingError::Storage(format!(
                "dimension mismatch: expected {}, got {}",
                self.dims,
                embedding.len()
            )));
        }
        let blob = f32_slice_to_blob(embedding);
        let _ = self.conn.execute(
            "DELETE FROM memory_vectors WHERE event_id = ?1",
            params![event_id],
        )?;
        let _ = self.conn.execute(
            "INSERT INTO memory_vectors (event_id, workspace_id, embedding) VALUES (?1, ?2, ?3)",
            params![event_id, workspace_id, blob],
        )?;
        Ok(())
    }

    /// Delete a vector by event ID.
    pub fn delete(&self, event_id: &str) -> Result<()> {
        let _ = self.conn.execute(
            "DELETE FROM memory_vectors WHERE event_id = ?1",
            params![event_id],
        )?;
        Ok(())
    }

    /// Count stored vectors.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    pub fn count(&self) -> Result<usize> {
        let count: i64 = self
            .conn
            .query_row("SELECT count(*) FROM memory_vectors", [], |row| row.get(0))?;
        Ok(count as usize)
    }

    /// Search for nearest neighbors using brute-force cosine similarity.
    pub fn search(&self, query: &[f32], opts: &SearchOptions) -> Result<Vec<VectorSearchResult>> {
        if query.is_empty() {
            return Err(EmbeddingError::Storage("Empty query vector".into()));
        }
        if query.len() != self.dims {
            return Err(EmbeddingError::Storage(format!(
                "Query dimension mismatch: expected {}, got {}",
                self.dims,
                query.len()
            )));
        }
        let limit = if opts.limit == 0 { 10 } else { opts.limit };
        let rows = self.load_vectors(opts)?;
        Ok(Self::rank_results(query, rows, limit, opts.min_similarity))
    }

    fn load_vectors(&self, opts: &SearchOptions) -> Result<Vec<(String, String, Vec<u8>)>> {
        let mut sql =
            String::from("SELECT event_id, workspace_id, embedding FROM memory_vectors");
        let mut conditions = Vec::new();
        let mut param_values: Vec<String> = Vec::new();

        if let Some(ws) = &opts.workspace_id {
            conditions.push(format!("workspace_id = ?{}", param_values.len() + 1));
            param_values.push(ws.clone());
        }
        if let Some(excl) = &opts.exclude_workspace_id {
            conditions.push(format!("workspace_id != ?{}", param_values.len() + 1));
            param_values.push(excl.clone());
        }
        if !conditions.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&conditions.join(" AND "));
        }

        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(|v| v as &dyn rusqlite::types::ToSql).collect();

        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                ))
            })?
            .filter_map(|row_result| match row_result {
                Ok(row) => Some(row),
                Err(e) => {
                    warn!(error = %e, "failed to deserialize vector row");
                    None
                }
            })
            .collect();

        Ok(rows)
    }

    fn rank_results(
        query: &[f32],
        rows: Vec<(String, String, Vec<u8>)>,
        limit: usize,
        min_similarity: f32,
    ) -> Vec<VectorSearchResult> {
        let mut results: Vec<VectorSearchResult> = rows
            .into_iter()
            .filter_map(|(event_id, workspace_id, blob)| {
                let embedding = blob_to_f32_vec(&blob);
                cosine_similarity(query, &embedding).map(|similarity| VectorSearchResult {
                    event_id,
                    workspace_id,
                    similarity,
                })
            })
            .collect();

        results.retain(|r| r.similarity >= min_similarity);
        results.sort_by(|a, b| {
            b.similarity
                .partial_cmp(&a.similarity)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        results.truncate(limit);
        results
    }
}

#[cfg(test)]
#[allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
mod tests {
    use super::*;
    use crate::normalize::l2_normalize;

    fn open_db() -> Connection {
        Connection::open_in_memory().unwrap()
    }

    fn make_repo(dims: usize) -> VectorRepository {
        let conn = open_db();
        let repo = VectorRepository::new(conn, dims);
        repo.ensure_table().unwrap();
        repo
    }

    fn random_vector(dims: usize, seed: u8) -> Vec<f32> {
        let mut v: Vec<f32> = (0..dims)
            .map(|i| (i as f32 + f32::from(seed) * 7.3).sin())
            .collect();
        l2_normalize(&mut v);
        v
    }

    #[test]
    fn ensure_table_creates() {
        let conn = open_db();
        let repo = VectorRepository::new(conn, 4);
        assert!(!repo.has_table());
        repo.ensure_table().unwrap();
        assert!(repo.has_table());
    }

    #[test]
    fn ensure_table_idempotent() {
        let repo = make_repo(4);
        repo.ensure_table().unwrap();
        assert!(repo.has_table());
    }

    #[test]
    fn store_and_count() {
        let repo = make_repo(4);
        let v = random_vector(4, 1);
        repo.store("e1", "ws1", &v).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn store_increments_count() {
        let repo = make_repo(4);
        repo.store("e1", "ws1", &random_vector(4, 1)).unwrap();
        repo.store("e2", "ws1", &random_vector(4, 2)).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
    }

    #[test]
    fn store_upsert_replaces() {
        let repo = make_repo(4);
        repo.store("e1", "ws1", &random_vector(4, 1)).unwrap();
        repo.store("e1", "ws1", &random_vector(4, 2)).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn delete_removes() {
        let repo = make_repo(4);
        repo.store("e1", "ws1", &random_vector(4, 1)).unwrap();
        repo.delete("e1").unwrap();
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn delete_nonexistent_noop() {
        let repo = make_repo(4);
        repo.delete("nonexistent").unwrap();
    }

    #[test]
    fn has_table_false_initially() {
        let conn = open_db();
        let repo = VectorRepository::new(conn, 4);
        assert!(!repo.has_table());
    }

    #[test]
    fn has_table_true_after_ensure() {
        let repo = make_repo(4);
        assert!(repo.has_table());
    }

    #[test]
    fn count_empty() {
        let repo = make_repo(4);
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn search_empty_returns_empty() {
        let repo = make_repo(4);
        let query = random_vector(4, 0);
        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn search_single() {
        let repo = make_repo(4);
        let v = random_vector(4, 1);
        repo.store("e1", "ws1", &v).unwrap();
        let results = repo
            .search(
                &v,
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "e1");
        assert!((results[0].similarity - 1.0).abs() < 1e-5);
    }

    #[test]
    fn search_respects_limit() {
        let repo = make_repo(4);
        for i in 0_u8..5 {
            repo.store(&format!("e{i}"), "ws1", &random_vector(4, i))
                .unwrap();
        }
        let query = random_vector(4, 0);
        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 2,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn search_orders_by_similarity() {
        let repo = make_repo(4);
        let query = random_vector(4, 0);
        let different = random_vector(4, 100);

        repo.store("exact", "ws1", &query).unwrap();
        repo.store("different", "ws1", &different).unwrap();

        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results[0].event_id, "exact");
        assert!(results[0].similarity > results[1].similarity);
    }

    #[test]
    fn search_filter_workspace() {
        let repo = make_repo(4);
        repo.store("e1", "ws1", &random_vector(4, 1)).unwrap();
        repo.store("e2", "ws2", &random_vector(4, 2)).unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    workspace_id: Some("ws1".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].workspace_id, "ws1");
    }

    #[test]
    fn search_exclude_workspace() {
        let repo = make_repo(4);
        repo.store("e1", "ws1", &random_vector(4, 1)).unwrap();
        repo.store("e2", "ws2", &random_vector(4, 2)).unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    exclude_workspace_id: Some("ws1".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].workspace_id, "ws2");
    }

    #[test]
    fn search_no_filter_all() {
        let repo = make_repo(4);
        repo.store("e1", "ws1", &random_vector(4, 1)).unwrap();
        repo.store("e2", "ws2", &random_vector(4, 2)).unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn search_correct_distances() {
        let repo = make_repo(4);
        let query = random_vector(4, 0);
        repo.store("same", "ws1", &query).unwrap();

        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert!((results[0].similarity - 1.0).abs() < 1e-5);
    }

    #[test]
    fn blob_roundtrip_f32() {
        let original = vec![1.0_f32, -2.5, 3.125, 0.0];
        let blob = f32_slice_to_blob(&original);
        let recovered = blob_to_f32_vec(&blob);
        assert_eq!(original, recovered);
    }

    #[test]
    fn blob_roundtrip_512d() {
        let original: Vec<f32> = (0..512).map(|i| i as f32 * 0.001).collect();
        let blob = f32_slice_to_blob(&original);
        let recovered = blob_to_f32_vec(&blob);
        assert_eq!(original, recovered);
    }

    #[test]
    fn nearest_neighbor_accuracy() {
        let repo = make_repo(64);
        let query = random_vector(64, 0);
        let close = random_vector(64, 1);
        let far = random_vector(64, 50);

        repo.store("close", "ws1", &close).unwrap();
        repo.store("far", "ws1", &far).unwrap();
        repo.store("exact", "ws1", &query).unwrap();

        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 3,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results[0].event_id, "exact");
    }

    #[test]
    fn store_many_search_completes() {
        let repo = make_repo(64);
        for i in 0_u16..1000 {
            repo.store(
                &format!("e{i}"),
                &format!("ws{}", i % 10),
                &random_vector(64, (i % 256) as u8),
            )
            .unwrap();
        }
        assert_eq!(repo.count().unwrap(), 1000);

        let query = random_vector(64, 0);
        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 5,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 5);
    }

    #[test]
    fn dimensions_mismatch_handling() {
        let repo = make_repo(4);
        let wrong_dims = vec![1.0, 2.0];
        let result = repo.store("e1", "ws1", &wrong_dims);
        assert!(result.is_err());
    }

    #[test]
    fn search_wrong_dimension_returns_error() {
        let repo = make_repo(4);
        let v = vec![0.5, 0.5, 0.5, 0.5];
        repo.store("e1", "ws1", &v).unwrap();
        // Query with wrong dimensions
        let wrong_query = vec![1.0; 8];
        let result = repo.search(
            &wrong_query,
            &SearchOptions {
                limit: 5,
                ..Default::default()
            },
        );
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("dimension mismatch")
        );
    }

    #[test]
    fn search_correct_dimension_succeeds() {
        let repo = make_repo(4);
        let v = vec![0.5, 0.5, 0.5, 0.5];
        repo.store("e1", "ws1", &v).unwrap();
        let query = vec![0.5, 0.5, 0.5, 0.5];
        let result = repo.search(
            &query,
            &SearchOptions {
                limit: 5,
                ..Default::default()
            },
        );
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 1);
    }

    #[test]
    fn search_empty_query_returns_error() {
        let repo = make_repo(4);
        let result = repo.search(
            &[],
            &SearchOptions {
                limit: 5,
                ..Default::default()
            },
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Empty"));
    }

    #[test]
    fn search_min_similarity_filters() {
        let repo = make_repo(4);
        let query = random_vector(4, 0);
        let different = random_vector(4, 100);

        repo.store("exact", "ws1", &query).unwrap();
        repo.store("different", "ws1", &different).unwrap();

        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 10,
                    min_similarity: 0.99,
                    ..Default::default()
                },
            )
            .unwrap();
        // Only the exact match should pass the threshold
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "exact");
    }

    #[test]
    fn search_default_min_similarity_returns_all() {
        let repo = make_repo(4);
        repo.store("e1", "ws1", &random_vector(4, 1)).unwrap();
        repo.store("e2", "ws1", &random_vector(4, 2)).unwrap();

        // Default min_similarity (-1.0) returns everything including negative similarities
        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn search_options_default_min_similarity() {
        let opts = SearchOptions::default();
        assert_eq!(opts.min_similarity, -1.0);
    }
}
