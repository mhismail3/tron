//! Hybrid search via Reciprocal Rank Fusion (RRF).
//!
//! Fuses vector cosine similarity results with FTS5 BM25 results
//! into a single ranked list. Each result source contributes a score
//! of `weight / (rank + k)`, and scores are summed per event.

use std::collections::HashMap;

use crate::vector_repo::VectorSearchResult;

/// Options for hybrid search.
#[derive(Clone, Debug)]
pub struct HybridSearchOptions {
    /// Maximum number of results.
    pub limit: usize,
    /// RRF constant (default 60.0). Higher values reduce the impact of rank position.
    pub rrf_k: f32,
    /// Weight for vector results (default 1.0).
    pub vector_weight: f32,
    /// Weight for FTS results (default 1.0).
    pub fts_weight: f32,
}

impl Default for HybridSearchOptions {
    fn default() -> Self {
        Self {
            limit: 10,
            rrf_k: 60.0,
            vector_weight: 1.0,
            fts_weight: 1.0,
        }
    }
}

/// A single hybrid search result after RRF fusion.
#[derive(Clone, Debug)]
pub struct HybridResult {
    /// The event ID.
    pub event_id: String,
    /// The workspace ID.
    pub workspace_id: String,
    /// Fused RRF score (higher = more relevant).
    pub score: f32,
    /// Vector similarity score (if present in vector results).
    pub vector_similarity: Option<f32>,
    /// FTS rank position (if present in FTS results).
    pub fts_rank: Option<usize>,
    /// Which chunk type matched in vector search.
    pub chunk_type: Option<String>,
}

/// Reciprocal Rank Fusion: fuse vector and FTS results.
///
/// For each unique `event_id` across both lists:
/// `rrf_score = (vector_weight / (vector_rank + k)) + (fts_weight / (fts_rank + k))`
///
/// Vector results are expected to be pre-deduplicated by event_id (one per event).
/// FTS results are `(event_id, bm25_score)` pairs sorted by score descending.
pub fn reciprocal_rank_fusion(
    vector_results: &[VectorSearchResult],
    fts_results: &[(String, f32)],
    opts: &HybridSearchOptions,
) -> Vec<HybridResult> {
    let mut entries: HashMap<String, HybridResult> = HashMap::new();

    // Score vector results by rank
    for (rank, vr) in vector_results.iter().enumerate() {
        let score = opts.vector_weight / (rank as f32 + opts.rrf_k);
        let entry = entries
            .entry(vr.event_id.clone())
            .or_insert_with(|| HybridResult {
                event_id: vr.event_id.clone(),
                workspace_id: vr.workspace_id.clone(),
                score: 0.0,
                vector_similarity: None,
                fts_rank: None,
                chunk_type: None,
            });
        entry.score += score;
        entry.vector_similarity = Some(vr.similarity);
        entry.chunk_type = Some(vr.chunk_type.clone());
    }

    // Score FTS results by rank
    for (rank, (event_id, _bm25_score)) in fts_results.iter().enumerate() {
        let score = opts.fts_weight / (rank as f32 + opts.rrf_k);
        let entry = entries
            .entry(event_id.clone())
            .or_insert_with(|| HybridResult {
                event_id: event_id.clone(),
                workspace_id: String::new(),
                score: 0.0,
                vector_similarity: None,
                fts_rank: None,
                chunk_type: None,
            });
        entry.score += score;
        entry.fts_rank = Some(rank);
    }

    let mut results: Vec<HybridResult> = entries.into_values().collect();
    results.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    results.truncate(opts.limit);
    results
}

/// Apply temporal decay to hybrid scores.
///
/// Formula: `decayed_score = score * 0.5^(age_days / half_life_days)`
///
/// A 30-day-old memory with a 30-day half-life gets 50% weight.
/// Missing timestamps leave the score unchanged.
/// Future timestamps (negative age) are clamped to 1.0 (no boost).
/// A `half_life_days` of 0.0 or negative is treated as no decay.
pub fn apply_temporal_decay(
    results: &mut [HybridResult],
    event_timestamps: &HashMap<String, chrono::DateTime<chrono::Utc>>,
    half_life_days: f64,
    now: chrono::DateTime<chrono::Utc>,
) {
    if half_life_days <= 0.0 {
        return;
    }

    for result in results.iter_mut() {
        if let Some(ts) = event_timestamps.get(&result.event_id) {
            let age = now.signed_duration_since(*ts);
            let age_days = age.num_seconds() as f64 / 86_400.0;
            if age_days <= 0.0 {
                // Future timestamp — no boost, leave score unchanged
                continue;
            }
            let decay = 0.5_f64.powf(age_days / half_life_days);
            #[allow(clippy::cast_possible_truncation)]
            {
                result.score *= decay as f32;
            }
        }
        // Missing timestamp → no decay applied
    }

    // Re-sort by decayed score
    results.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_vector_results(event_ids: &[&str]) -> Vec<VectorSearchResult> {
        event_ids
            .iter()
            .enumerate()
            .map(|(i, id)| VectorSearchResult {
                event_id: (*id).to_string(),
                workspace_id: "ws1".to_string(),
                similarity: 1.0 - (i as f32 * 0.1),
                chunk_type: "summary".to_string(),
                chunk_index: 0,
            })
            .collect()
    }

    fn make_fts_results(event_ids: &[&str]) -> Vec<(String, f32)> {
        event_ids
            .iter()
            .enumerate()
            .map(|(i, id)| ((*id).to_string(), 10.0 - i as f32))
            .collect()
    }

    #[test]
    fn rrf_vector_only() {
        let vector = make_vector_results(&["e1", "e2", "e3"]);
        let fts: Vec<(String, f32)> = vec![];
        let opts = HybridSearchOptions::default();

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].event_id, "e1");
        assert!(results[0].vector_similarity.is_some());
        assert!(results[0].fts_rank.is_none());
    }

    #[test]
    fn rrf_fts_only() {
        let vector: Vec<VectorSearchResult> = vec![];
        let fts = make_fts_results(&["e1", "e2"]);
        let opts = HybridSearchOptions::default();

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].event_id, "e1");
        assert!(results[0].fts_rank.is_some());
        assert!(results[0].vector_similarity.is_none());
    }

    #[test]
    fn rrf_both_sources_boosts_shared() {
        // e1 appears in both, e2 only in vector, e3 only in fts
        let vector = make_vector_results(&["e1", "e2"]);
        let fts = make_fts_results(&["e1", "e3"]);
        let opts = HybridSearchOptions::default();

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        assert_eq!(results[0].event_id, "e1", "shared event should rank first");
        assert!(results[0].vector_similarity.is_some());
        assert!(results[0].fts_rank.is_some());
        // e1 should have higher score than either e2 or e3
        assert!(results[0].score > results[1].score);
    }

    #[test]
    fn rrf_k60_expected_scores() {
        let vector = make_vector_results(&["e1"]);
        let fts: Vec<(String, f32)> = vec![];
        let opts = HybridSearchOptions {
            rrf_k: 60.0,
            vector_weight: 1.0,
            ..Default::default()
        };

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        // rank 0 + k 60 = score 1/60
        let expected = 1.0 / 60.0;
        assert!((results[0].score - expected).abs() < 1e-6);
    }

    #[test]
    fn rrf_custom_weights() {
        let vector = make_vector_results(&["e1"]);
        let fts = make_fts_results(&["e2"]);
        let opts = HybridSearchOptions {
            rrf_k: 60.0,
            vector_weight: 2.0,
            fts_weight: 1.0,
            ..Default::default()
        };

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        // e1 score = 2.0/60.0, e2 score = 1.0/60.0
        assert_eq!(results[0].event_id, "e1");
        assert!(results[0].score > results[1].score);
    }

    #[test]
    fn rrf_empty_both() {
        let vector: Vec<VectorSearchResult> = vec![];
        let fts: Vec<(String, f32)> = vec![];
        let opts = HybridSearchOptions::default();

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        assert!(results.is_empty());
    }

    #[test]
    fn rrf_respects_limit() {
        let vector = make_vector_results(&["e1", "e2", "e3", "e4", "e5"]);
        let fts = make_fts_results(&["e6", "e7", "e8"]);
        let opts = HybridSearchOptions {
            limit: 3,
            ..Default::default()
        };

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        assert_eq!(results.len(), 3);
    }

    // ── Temporal decay tests ──

    fn make_hybrid_results(scores: &[(&str, f32)]) -> Vec<HybridResult> {
        scores
            .iter()
            .map(|(id, score)| HybridResult {
                event_id: (*id).to_string(),
                workspace_id: "ws1".to_string(),
                score: *score,
                vector_similarity: None,
                fts_rank: None,
                chunk_type: None,
            })
            .collect()
    }

    #[test]
    fn decay_zero_age_unchanged() {
        let mut results = make_hybrid_results(&[("e1", 1.0)]);
        let now = chrono::Utc::now();
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> =
            [("e1".to_string(), now)].into_iter().collect();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        // age ~0 → decay ~1.0
        assert!((results[0].score - 1.0).abs() < 0.01);
    }

    #[test]
    fn decay_30_day_half_life() {
        let mut results = make_hybrid_results(&[("e1", 1.0)]);
        let now = chrono::Utc::now();
        let thirty_days_ago = now - chrono::Duration::days(30);
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> =
            [("e1".to_string(), thirty_days_ago)].into_iter().collect();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        // 30 days / 30 day half-life → score * 0.5
        assert!((results[0].score - 0.5).abs() < 0.01);
    }

    #[test]
    fn decay_60_day_quartered() {
        let mut results = make_hybrid_results(&[("e1", 1.0)]);
        let now = chrono::Utc::now();
        let sixty_days_ago = now - chrono::Duration::days(60);
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> =
            [("e1".to_string(), sixty_days_ago)].into_iter().collect();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        assert!((results[0].score - 0.25).abs() < 0.01);
    }

    #[test]
    fn decay_365_day_near_zero() {
        let mut results = make_hybrid_results(&[("e1", 1.0)]);
        let now = chrono::Utc::now();
        let year_ago = now - chrono::Duration::days(365);
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> =
            [("e1".to_string(), year_ago)].into_iter().collect();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        assert!(results[0].score < 0.001);
    }

    #[test]
    fn decay_future_timestamp_no_boost() {
        let mut results = make_hybrid_results(&[("e1", 1.0)]);
        let now = chrono::Utc::now();
        let future = now + chrono::Duration::days(10);
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> =
            [("e1".to_string(), future)].into_iter().collect();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        assert!((results[0].score - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn decay_missing_timestamp_unchanged() {
        let mut results = make_hybrid_results(&[("e1", 1.0)]);
        let now = chrono::Utc::now();
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> = HashMap::new();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        assert!((results[0].score - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn decay_zero_half_life_no_op() {
        let mut results = make_hybrid_results(&[("e1", 1.0)]);
        let now = chrono::Utc::now();
        let old = now - chrono::Duration::days(100);
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> =
            [("e1".to_string(), old)].into_iter().collect();

        apply_temporal_decay(&mut results, &timestamps, 0.0, now);
        assert!((results[0].score - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn decay_preserves_relative_ordering_same_age() {
        let mut results = make_hybrid_results(&[("e1", 1.0), ("e2", 0.5)]);
        let now = chrono::Utc::now();
        let same_ts = now - chrono::Duration::days(15);
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> = [
            ("e1".to_string(), same_ts),
            ("e2".to_string(), same_ts),
        ]
        .into_iter()
        .collect();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        assert_eq!(results[0].event_id, "e1");
        assert!(results[0].score > results[1].score);
    }

    #[test]
    fn decay_reorders_by_recency() {
        // e1 has higher score but is old, e2 has lower score but is recent
        let mut results = make_hybrid_results(&[("e1", 1.0), ("e2", 0.8)]);
        let now = chrono::Utc::now();
        let timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> = [
            ("e1".to_string(), now - chrono::Duration::days(90)),
            ("e2".to_string(), now - chrono::Duration::days(1)),
        ]
        .into_iter()
        .collect();

        apply_temporal_decay(&mut results, &timestamps, 30.0, now);
        // e1: 1.0 * 0.5^3 ≈ 0.125; e2: 0.8 * ~0.977 ≈ 0.78
        assert_eq!(results[0].event_id, "e2");
    }

    // ── RRF tests ──

    #[test]
    fn rrf_large_result_set_linear() {
        // Performance check: 1000 results should be instant
        let event_ids: Vec<String> = (0..1000).map(|i| format!("e{i}")).collect();
        let vector: Vec<VectorSearchResult> = event_ids
            .iter()
            .enumerate()
            .map(|(i, id)| VectorSearchResult {
                event_id: id.clone(),
                workspace_id: "ws1".to_string(),
                similarity: 1.0 - (i as f32 * 0.001),
                chunk_type: "summary".to_string(),
                chunk_index: 0,
            })
            .collect();
        let fts: Vec<(String, f32)> = event_ids
            .iter()
            .enumerate()
            .map(|(i, id)| (id.clone(), 1000.0 - i as f32))
            .collect();
        let opts = HybridSearchOptions {
            limit: 10,
            ..Default::default()
        };

        let results = reciprocal_rank_fusion(&vector, &fts, &opts);
        assert_eq!(results.len(), 10);
        // First result should be e0 since it's rank 0 in both lists
        assert_eq!(results[0].event_id, "e0");
    }
}
