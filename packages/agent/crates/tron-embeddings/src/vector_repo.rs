//! Vector repository with `SQLite` BLOB storage and brute-force KNN search.

use rusqlite::{Connection, params};
use tracing::warn;

use crate::errors::{EmbeddingError, Result};
use crate::normalize::cosine_similarity;

/// Convert an f32 slice to a byte blob for storage.
pub fn f32_slice_to_blob(v: &[f32]) -> Vec<u8> {
    bytemuck::cast_slice::<f32, u8>(v).to_vec()
}

/// Convert a byte blob back to an f32 vector.
pub fn blob_to_f32_vec(blob: &[u8]) -> Vec<f32> {
    bytemuck::cast_slice::<u8, f32>(blob).to_vec()
}

/// Reinterpret a byte blob as an f32 slice (zero-copy, zero-allocation).
///
/// Returns `None` if `blob.len()` is not a multiple of 4.
pub fn blob_as_f32_slice(blob: &[u8]) -> Option<&[f32]> {
    if blob.is_empty() {
        return Some(&[]);
    }
    if blob.len() % 4 != 0 {
        return None;
    }
    Some(bytemuck::cast_slice(blob))
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
    /// Filter by entry type (e.g., "feature", "bugfix").
    pub entry_type: Option<String>,
    /// Only include entries created after this ISO8601 timestamp.
    pub created_after: Option<String>,
    /// Only include entries created before this ISO8601 timestamp.
    pub created_before: Option<String>,
}

impl Default for SearchOptions {
    fn default() -> Self {
        Self {
            limit: 0,
            workspace_id: None,
            exclude_workspace_id: None,
            min_similarity: -1.0,
            entry_type: None,
            created_after: None,
            created_before: None,
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
    /// Which chunk type matched ("summary" or "lesson").
    pub chunk_type: String,
    /// Chunk index (0 for summary, 1..N for lessons).
    pub chunk_index: i64,
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
    ///
    /// If an old schema is detected (no `chunk_type` column), drops and recreates.
    pub fn ensure_table(&self) -> Result<()> {
        if self.has_table() && !self.has_new_schema() {
            self.conn.execute_batch("DROP TABLE memory_vectors")?;
        }
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS memory_vectors (
                id TEXT PRIMARY KEY,
                event_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                chunk_type TEXT NOT NULL DEFAULT 'summary',
                chunk_index INTEGER NOT NULL DEFAULT 0,
                entry_type TEXT,
                created_at TEXT,
                embedding BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_mv_event ON memory_vectors(event_id);
            CREATE INDEX IF NOT EXISTS idx_mv_workspace ON memory_vectors(workspace_id);
            CREATE INDEX IF NOT EXISTS idx_mv_type ON memory_vectors(entry_type);",
        )?;
        Ok(())
    }

    /// Drop and recreate the `memory_vectors` table (for `--force` re-embedding).
    pub fn drop_and_recreate(&self) -> Result<()> {
        if self.has_table() {
            self.conn.execute_batch("DROP TABLE memory_vectors")?;
        }
        self.ensure_table()
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

    /// Check if the table uses the new multi-vector schema.
    fn has_new_schema(&self) -> bool {
        self.conn
            .prepare("SELECT chunk_type FROM memory_vectors LIMIT 0")
            .is_ok()
    }

    /// Store an embedding vector.
    pub fn store(
        &self,
        id: &str,
        event_id: &str,
        workspace_id: &str,
        chunk_type: &str,
        chunk_index: i64,
        entry_type: Option<&str>,
        created_at: Option<&str>,
        embedding: &[f32],
    ) -> Result<()> {
        if embedding.len() != self.dims {
            return Err(EmbeddingError::Storage(format!(
                "dimension mismatch: expected {}, got {}",
                self.dims,
                embedding.len()
            )));
        }
        let blob = f32_slice_to_blob(embedding);
        let _ = self.conn.execute(
            "DELETE FROM memory_vectors WHERE id = ?1",
            params![id],
        )?;
        let _ = self.conn.execute(
            "INSERT INTO memory_vectors (id, event_id, workspace_id, chunk_type, chunk_index, entry_type, created_at, embedding) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![id, event_id, workspace_id, chunk_type, chunk_index, entry_type, created_at, blob],
        )?;
        Ok(())
    }

    /// Delete all vectors for a given event ID.
    pub fn delete_by_event(&self, event_id: &str) -> Result<()> {
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
    ///
    /// Results are deduplicated by `event_id` — for each event, only the
    /// highest-scoring chunk is returned.
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

    fn load_vectors(
        &self,
        opts: &SearchOptions,
    ) -> Result<Vec<(String, String, String, String, i64, Vec<u8>)>> {
        let mut sql = String::from(
            "SELECT id, event_id, workspace_id, chunk_type, chunk_index, embedding FROM memory_vectors",
        );
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
        if let Some(et) = &opts.entry_type {
            conditions.push(format!("entry_type = ?{}", param_values.len() + 1));
            param_values.push(et.clone());
        }
        if let Some(after) = &opts.created_after {
            conditions.push(format!("created_at >= ?{}", param_values.len() + 1));
            param_values.push(after.clone());
        }
        if let Some(before) = &opts.created_before {
            conditions.push(format!("created_at <= ?{}", param_values.len() + 1));
            param_values.push(before.clone());
        }
        if !conditions.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&conditions.join(" AND "));
        }

        let mut stmt = self.conn.prepare_cached(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(|v| v as &dyn rusqlite::types::ToSql).collect();

        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Vec<u8>>(5)?,
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
        rows: Vec<(String, String, String, String, i64, Vec<u8>)>,
        limit: usize,
        min_similarity: f32,
    ) -> Vec<VectorSearchResult> {
        let mut results: Vec<VectorSearchResult> = rows
            .into_iter()
            .filter_map(|(_id, event_id, workspace_id, chunk_type, chunk_index, blob)| {
                let embedding = blob_as_f32_slice(&blob)?;
                let similarity = cosine_similarity(query, embedding)?;
                if similarity < min_similarity {
                    return None;
                }
                Some(VectorSearchResult {
                    event_id,
                    workspace_id,
                    similarity,
                    chunk_type,
                    chunk_index,
                })
            })
            .collect();

        results.sort_unstable_by(|a, b| {
            b.similarity
                .partial_cmp(&a.similarity)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Deduplicate by event_id — keep highest-scoring chunk per event
        let mut seen = std::collections::HashSet::with_capacity(results.len().min(limit * 2));
        results.retain(|r| seen.insert(r.event_id.clone()));

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

    fn store_simple(repo: &VectorRepository, event_id: &str, workspace_id: &str, v: &[f32]) {
        repo.store(
            &format!("{event_id}-summary"),
            event_id,
            workspace_id,
            "summary",
            0,
            None,
            None,
            v,
        )
        .unwrap();
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
    fn ensure_table_migrates_old_schema() {
        let conn = open_db();
        // Create old schema (event_id PK, no chunk_type)
        conn.execute_batch(
            "CREATE TABLE memory_vectors (
                event_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                embedding BLOB NOT NULL
            )",
        )
        .unwrap();
        let repo = VectorRepository::new(conn, 4);
        assert!(repo.has_table());
        assert!(!repo.has_new_schema());

        // ensure_table should drop and recreate
        repo.ensure_table().unwrap();
        assert!(repo.has_table());
        assert!(repo.has_new_schema());
    }

    #[test]
    fn store_and_count() {
        let repo = make_repo(4);
        let v = random_vector(4, 1);
        store_simple(&repo, "e1", "ws1", &v);
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn store_increments_count() {
        let repo = make_repo(4);
        store_simple(&repo, "e1", "ws1", &random_vector(4, 1));
        store_simple(&repo, "e2", "ws1", &random_vector(4, 2));
        assert_eq!(repo.count().unwrap(), 2);
    }

    #[test]
    fn store_multiple_chunks_per_event() {
        let repo = make_repo(4);
        repo.store("e1-summary", "e1", "ws1", "summary", 0, None, None, &random_vector(4, 1))
            .unwrap();
        repo.store("e1-lesson-1", "e1", "ws1", "lesson", 1, None, None, &random_vector(4, 2))
            .unwrap();
        repo.store("e1-lesson-2", "e1", "ws1", "lesson", 2, None, None, &random_vector(4, 3))
            .unwrap();
        assert_eq!(repo.count().unwrap(), 3);
    }

    #[test]
    fn delete_by_event_removes_all_chunks() {
        let repo = make_repo(4);
        repo.store("e1-summary", "e1", "ws1", "summary", 0, None, None, &random_vector(4, 1))
            .unwrap();
        repo.store("e1-lesson-1", "e1", "ws1", "lesson", 1, None, None, &random_vector(4, 2))
            .unwrap();
        repo.delete_by_event("e1").unwrap();
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn delete_by_event_nonexistent_noop() {
        let repo = make_repo(4);
        repo.delete_by_event("nonexistent").unwrap();
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
        store_simple(&repo, "e1", "ws1", &v);
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
        assert_eq!(results[0].chunk_type, "summary");
    }

    #[test]
    fn search_respects_limit() {
        let repo = make_repo(4);
        for i in 0_u8..5 {
            store_simple(&repo, &format!("e{i}"), "ws1", &random_vector(4, i));
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

        store_simple(&repo, "exact", "ws1", &query);
        store_simple(&repo, "different", "ws1", &different);

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
    fn search_deduplicates_by_event_id() {
        let repo = make_repo(4);
        let query = random_vector(4, 0);
        // Store two chunks for same event — one very similar, one less similar
        repo.store("e1-summary", "e1", "ws1", "summary", 0, None, None, &query)
            .unwrap();
        repo.store(
            "e1-lesson-1",
            "e1",
            "ws1",
            "lesson",
            1,
            None,
            None,
            &random_vector(4, 50),
        )
        .unwrap();

        let results = repo
            .search(
                &query,
                &SearchOptions {
                    limit: 10,
                    ..Default::default()
                },
            )
            .unwrap();
        // Should only return 1 result (deduplicated by event_id)
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "e1");
        assert_eq!(results[0].chunk_type, "summary"); // highest scoring chunk
    }

    #[test]
    fn search_filter_workspace() {
        let repo = make_repo(4);
        store_simple(&repo, "e1", "ws1", &random_vector(4, 1));
        store_simple(&repo, "e2", "ws2", &random_vector(4, 2));

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
        store_simple(&repo, "e1", "ws1", &random_vector(4, 1));
        store_simple(&repo, "e2", "ws2", &random_vector(4, 2));

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
    fn search_filter_entry_type() {
        let repo = make_repo(4);
        repo.store(
            "e1-s",
            "e1",
            "ws1",
            "summary",
            0,
            Some("feature"),
            None,
            &random_vector(4, 1),
        )
        .unwrap();
        repo.store(
            "e2-s",
            "e2",
            "ws1",
            "summary",
            0,
            Some("bugfix"),
            None,
            &random_vector(4, 2),
        )
        .unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    entry_type: Some("feature".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "e1");
    }

    #[test]
    fn search_filter_created_after() {
        let repo = make_repo(4);
        repo.store(
            "e1-s",
            "e1",
            "ws1",
            "summary",
            0,
            None,
            Some("2026-01-01T00:00:00Z"),
            &random_vector(4, 1),
        )
        .unwrap();
        repo.store(
            "e2-s",
            "e2",
            "ws1",
            "summary",
            0,
            None,
            Some("2026-02-15T00:00:00Z"),
            &random_vector(4, 2),
        )
        .unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    created_after: Some("2026-02-01T00:00:00Z".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "e2");
    }

    #[test]
    fn search_filter_created_before() {
        let repo = make_repo(4);
        repo.store(
            "e1-s",
            "e1",
            "ws1",
            "summary",
            0,
            None,
            Some("2026-01-01T00:00:00Z"),
            &random_vector(4, 1),
        )
        .unwrap();
        repo.store(
            "e2-s",
            "e2",
            "ws1",
            "summary",
            0,
            None,
            Some("2026-02-15T00:00:00Z"),
            &random_vector(4, 2),
        )
        .unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    created_before: Some("2026-02-01T00:00:00Z".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "e1");
    }

    #[test]
    fn search_date_range_after_before_inverted_returns_empty() {
        let repo = make_repo(4);
        repo.store(
            "e1-s",
            "e1",
            "ws1",
            "summary",
            0,
            None,
            Some("2026-01-15T00:00:00Z"),
            &random_vector(4, 1),
        )
        .unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    created_after: Some("2026-03-01T00:00:00Z".into()),
                    created_before: Some("2026-01-01T00:00:00Z".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn search_no_filter_all() {
        let repo = make_repo(4);
        store_simple(&repo, "e1", "ws1", &random_vector(4, 1));
        store_simple(&repo, "e2", "ws2", &random_vector(4, 2));

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
        store_simple(&repo, "same", "ws1", &query);

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
    fn blob_as_f32_slice_roundtrip() {
        let original = vec![1.0_f32, -2.5, 3.125, 0.0];
        let blob = f32_slice_to_blob(&original);
        let slice = blob_as_f32_slice(&blob).unwrap();
        assert_eq!(slice, &original[..]);
    }

    #[test]
    fn blob_as_f32_slice_512d() {
        let original: Vec<f32> = (0..512).map(|i| i as f32 * 0.001).collect();
        let blob = f32_slice_to_blob(&original);
        let slice = blob_as_f32_slice(&blob).unwrap();
        assert_eq!(slice, &original[..]);
    }

    #[test]
    fn blob_as_f32_slice_empty() {
        let blob: Vec<u8> = vec![];
        let slice = blob_as_f32_slice(&blob).unwrap();
        assert!(slice.is_empty());
    }

    #[test]
    fn blob_as_f32_slice_bad_length_returns_none() {
        let blob = vec![0u8, 1, 2]; // 3 bytes, not divisible by 4
        assert!(blob_as_f32_slice(&blob).is_none());
    }

    #[test]
    fn nearest_neighbor_accuracy() {
        let repo = make_repo(64);
        let query = random_vector(64, 0);
        let close = random_vector(64, 1);
        let far = random_vector(64, 50);

        store_simple(&repo, "close", "ws1", &close);
        store_simple(&repo, "far", "ws1", &far);
        store_simple(&repo, "exact", "ws1", &query);

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
            store_simple(
                &repo,
                &format!("e{i}"),
                &format!("ws{}", i % 10),
                &random_vector(64, (i % 256) as u8),
            );
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
        let result = repo.store("id1", "e1", "ws1", "summary", 0, None, None, &wrong_dims);
        assert!(result.is_err());
    }

    #[test]
    fn search_wrong_dimension_returns_error() {
        let repo = make_repo(4);
        let v = vec![0.5, 0.5, 0.5, 0.5];
        store_simple(&repo, "e1", "ws1", &v);
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
        store_simple(&repo, "e1", "ws1", &v);
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

        store_simple(&repo, "exact", "ws1", &query);
        store_simple(&repo, "different", "ws1", &different);

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
        store_simple(&repo, "e1", "ws1", &random_vector(4, 1));
        store_simple(&repo, "e2", "ws1", &random_vector(4, 2));

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

    #[test]
    fn search_entry_type_no_matches_returns_empty() {
        let repo = make_repo(4);
        repo.store(
            "e1-s",
            "e1",
            "ws1",
            "summary",
            0,
            Some("feature"),
            None,
            &random_vector(4, 1),
        )
        .unwrap();

        let results = repo
            .search(
                &random_vector(4, 0),
                &SearchOptions {
                    limit: 10,
                    entry_type: Some("nonexistent".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn store_with_all_metadata() {
        let repo = make_repo(4);
        repo.store(
            "id1",
            "e1",
            "ws1",
            "summary",
            0,
            Some("feature"),
            Some("2026-01-15T10:00:00Z"),
            &random_vector(4, 1),
        )
        .unwrap();
        assert_eq!(repo.count().unwrap(), 1);
    }
}
