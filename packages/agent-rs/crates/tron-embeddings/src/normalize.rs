//! Vector normalization and similarity functions.

/// Compute the L2 (Euclidean) norm of a vector.
pub fn l2_norm(v: &[f32]) -> f32 {
    v.iter().map(|x| x * x).sum::<f32>().sqrt()
}

/// L2-normalize a vector in-place. Zero vectors remain zero.
pub fn l2_normalize(v: &mut [f32]) {
    let norm = l2_norm(v);
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
}

/// Matryoshka truncation: slice to `target_dims`, then L2 re-normalize.
///
/// If `target_dims >= v.len()`, returns a re-normalized copy of the full vector.
pub fn matryoshka_truncate(v: &[f32], target_dims: usize) -> Vec<f32> {
    let end = target_dims.min(v.len());
    let mut truncated = v[..end].to_vec();
    l2_normalize(&mut truncated);
    truncated
}

/// Cosine similarity between two L2-normalized vectors (dot product).
///
/// For non-normalized vectors, this computes the dot product divided by
/// the product of their norms.
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    assert_eq!(a.len(), b.len(), "vectors must have equal dimensions");
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a = l2_norm(a);
    let norm_b = l2_norm(b);
    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }
    dot / (norm_a * norm_b)
}

/// Euclidean distance between two vectors.
pub fn euclidean_distance(a: &[f32], b: &[f32]) -> f32 {
    assert_eq!(a.len(), b.len(), "vectors must have equal dimensions");
    a.iter()
        .zip(b.iter())
        .map(|(x, y)| (x - y) * (x - y))
        .sum::<f32>()
        .sqrt()
}

/// Truncate and normalize a batch of flattened embeddings.
///
/// `data` is a flat array of `batch_size` * `full_dim` floats.
/// Returns `batch_size` vectors, each of length `target_dim`, L2-normalized.
pub fn batch_truncate_normalize(
    data: &[f32],
    batch_size: usize,
    full_dim: usize,
    target_dim: usize,
) -> Vec<Vec<f32>> {
    (0..batch_size)
        .map(|i| {
            let start = i * full_dim;
            let end = (start + full_dim).min(data.len());
            if start >= data.len() {
                return vec![];
            }
            matryoshka_truncate(&data[start..end], target_dim)
        })
        .collect()
}

#[cfg(test)]
#[allow(clippy::cast_precision_loss)]
mod tests {
    use super::*;

    const EPSILON: f32 = 1e-6;

    fn approx_eq(a: f32, b: f32) -> bool {
        (a - b).abs() < EPSILON
    }

    #[test]
    fn l2_norm_known() {
        assert!(approx_eq(l2_norm(&[3.0, 4.0]), 5.0));
    }

    #[test]
    fn l2_norm_empty() {
        assert!(approx_eq(l2_norm(&[]), 0.0));
    }

    #[test]
    fn l2_normalize_known_vector() {
        let mut v = vec![3.0, 4.0];
        l2_normalize(&mut v);
        assert!(approx_eq(v[0], 0.6));
        assert!(approx_eq(v[1], 0.8));
    }

    #[test]
    fn l2_normalize_unit_stays_unit() {
        let mut v = vec![1.0, 0.0, 0.0];
        l2_normalize(&mut v);
        assert!(approx_eq(l2_norm(&v), 1.0));
    }

    #[test]
    fn l2_normalize_zero_vector() {
        let mut v = vec![0.0, 0.0, 0.0];
        l2_normalize(&mut v);
        assert!(v.iter().all(|x| *x == 0.0), "zero vector stays zero");
        assert!(!v.iter().any(|x| x.is_nan()), "no NaN");
    }

    #[test]
    fn matryoshka_reduces_dims() {
        let v: Vec<f32> = (0..1024).map(|i| i as f32).collect();
        let result = matryoshka_truncate(&v, 512);
        assert_eq!(result.len(), 512);
    }

    #[test]
    fn matryoshka_renormalizes() {
        let v: Vec<f32> = (0..1024).map(|i| (i as f32) + 1.0).collect();
        let result = matryoshka_truncate(&v, 512);
        assert!(approx_eq(l2_norm(&result), 1.0));
    }

    #[test]
    fn matryoshka_identity() {
        let mut v = vec![3.0, 4.0];
        let result = matryoshka_truncate(&v, 2);
        assert_eq!(result.len(), 2);
        l2_normalize(&mut v);
        assert!(approx_eq(result[0], v[0]));
        assert!(approx_eq(result[1], v[1]));
    }

    #[test]
    fn matryoshka_larger_target_clamps() {
        let v = vec![3.0, 4.0];
        let result = matryoshka_truncate(&v, 100);
        assert_eq!(result.len(), 2);
        assert!(approx_eq(l2_norm(&result), 1.0));
    }

    #[test]
    fn cosine_identical() {
        let v = vec![0.6, 0.8];
        assert!(approx_eq(cosine_similarity(&v, &v), 1.0));
    }

    #[test]
    fn cosine_orthogonal() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        assert!(approx_eq(cosine_similarity(&a, &b), 0.0));
    }

    #[test]
    fn cosine_opposite() {
        let a = vec![1.0, 0.0];
        let b = vec![-1.0, 0.0];
        assert!(approx_eq(cosine_similarity(&a, &b), -1.0));
    }

    #[test]
    fn cosine_known_values() {
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![4.0, 5.0, 6.0];
        let dot = 4.0 + 10.0 + 18.0; // 32
        let norm_a = (1.0 + 4.0 + 9.0_f32).sqrt(); // sqrt(14)
        let norm_b = (16.0 + 25.0 + 36.0_f32).sqrt(); // sqrt(77)
        let expected = dot / (norm_a * norm_b);
        assert!(approx_eq(cosine_similarity(&a, &b), expected));
    }

    #[test]
    fn euclidean_zero() {
        let v = vec![1.0, 2.0, 3.0];
        assert!(approx_eq(euclidean_distance(&v, &v), 0.0));
    }

    #[test]
    fn euclidean_known() {
        let a = vec![0.0, 0.0];
        let b = vec![3.0, 4.0];
        assert!(approx_eq(euclidean_distance(&a, &b), 5.0));
    }

    #[test]
    fn batch_truncate_single() {
        let data: Vec<f32> = (0..8).map(|i| (i + 1) as f32).collect();
        let result = batch_truncate_normalize(&data, 1, 8, 4);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].len(), 4);
        assert!(approx_eq(l2_norm(&result[0]), 1.0));
    }

    #[test]
    fn batch_truncate_multiple() {
        let data: Vec<f32> = (0..16).map(|i| (i + 1) as f32).collect();
        let result = batch_truncate_normalize(&data, 2, 8, 4);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].len(), 4);
        assert_eq!(result[1].len(), 4);
        assert!(approx_eq(l2_norm(&result[0]), 1.0));
        assert!(approx_eq(l2_norm(&result[1]), 1.0));
    }

    #[test]
    fn batch_truncate_empty() {
        let result = batch_truncate_normalize(&[], 0, 8, 4);
        assert!(result.is_empty());
    }

    mod proptests {
        use super::*;
        use proptest::prelude::*;

        proptest! {
            #[test]
            fn normalize_produces_unit(v in proptest::collection::vec(-100.0f32..100.0, 1..64)) {
                let has_nonzero = v.iter().any(|x| *x != 0.0);
                let mut v = v;
                l2_normalize(&mut v);
                if has_nonzero {
                    prop_assert!((l2_norm(&v) - 1.0).abs() < 1e-4);
                }
            }

            #[test]
            fn matryoshka_preserves_unit(v in proptest::collection::vec(-100.0f32..100.0, 4..64)) {
                let has_nonzero = v.iter().any(|x| *x != 0.0);
                let target = v.len() / 2;
                let result = matryoshka_truncate(&v, target);
                if has_nonzero && result.iter().any(|x| *x != 0.0) {
                    prop_assert!((l2_norm(&result) - 1.0).abs() < 1e-4);
                }
            }

            #[test]
            fn cosine_symmetry(
                a in proptest::collection::vec(-100.0f32..100.0, 4..16),
                b in proptest::collection::vec(-100.0f32..100.0, 4..16),
            ) {
                let len = a.len().min(b.len());
                let a = &a[..len];
                let b = &b[..len];
                let ab = cosine_similarity(a, b);
                let ba = cosine_similarity(b, a);
                prop_assert!((ab - ba).abs() < 1e-5);
            }

            #[test]
            fn euclidean_non_negative(
                a in proptest::collection::vec(-100.0f32..100.0, 1..32),
                b in proptest::collection::vec(-100.0f32..100.0, 1..32),
            ) {
                let len = a.len().min(b.len());
                let a = &a[..len];
                let b = &b[..len];
                prop_assert!(euclidean_distance(a, b) >= 0.0);
            }
        }
    }
}
