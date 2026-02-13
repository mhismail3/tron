//! Retry configuration and backoff calculation.
//!
//! Provides the types and math for retry logic. The actual async retry
//! execution lives in `tron-runtime` (which has access to tokio), while
//! this module contains the portable, sync-only building blocks:
//!
//! - [`RetryConfig`]: Retry parameters (max retries, backoff, jitter)
//! - [`RetryResult`]: Outcome of a retried operation
//! - [`calculate_backoff_delay`]: Exponential backoff with jitter
//! - [`parse_retry_after_header`]: Parse `Retry-After` HTTP header

use serde::{Deserialize, Serialize};

use crate::errors::parse::ParsedError;

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Default maximum retries.
pub const DEFAULT_MAX_RETRIES: u32 = 5;
/// Default base delay in milliseconds.
pub const DEFAULT_BASE_DELAY_MS: u64 = 1000;
/// Default maximum delay in milliseconds.
pub const DEFAULT_MAX_DELAY_MS: u64 = 60_000;
/// Default jitter factor (0.0–1.0).
pub const DEFAULT_JITTER_FACTOR: f64 = 0.2;

/// Configuration for retry logic.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RetryConfig {
    /// Maximum number of retry attempts (default: 5).
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    /// Base delay for exponential backoff in ms (default: 1000).
    #[serde(default = "default_base_delay_ms")]
    pub base_delay_ms: u64,
    /// Maximum delay between retries in ms (default: 60000).
    #[serde(default = "default_max_delay_ms")]
    pub max_delay_ms: u64,
    /// Jitter factor 0.0–1.0 (default: 0.2).
    #[serde(default = "default_jitter_factor")]
    pub jitter_factor: f64,
}

fn default_max_retries() -> u32 {
    DEFAULT_MAX_RETRIES
}
fn default_base_delay_ms() -> u64 {
    DEFAULT_BASE_DELAY_MS
}
fn default_max_delay_ms() -> u64 {
    DEFAULT_MAX_DELAY_MS
}
fn default_jitter_factor() -> f64 {
    DEFAULT_JITTER_FACTOR
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_retries: DEFAULT_MAX_RETRIES,
            base_delay_ms: DEFAULT_BASE_DELAY_MS,
            max_delay_ms: DEFAULT_MAX_DELAY_MS,
            jitter_factor: DEFAULT_JITTER_FACTOR,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result
// ─────────────────────────────────────────────────────────────────────────────

/// Outcome of a retried operation.
#[derive(Clone, Debug)]
pub struct RetryResult<T> {
    /// Whether the operation succeeded.
    pub success: bool,
    /// The value on success.
    pub value: Option<T>,
    /// The last error on failure.
    pub error: Option<ParsedError>,
    /// Total number of attempts made (1-based).
    pub attempts: u32,
    /// Total delay spent waiting in ms.
    pub total_delay_ms: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Backoff calculation
// ─────────────────────────────────────────────────────────────────────────────

/// Calculate exponential backoff delay with jitter.
///
/// Formula: `min(max_delay, base_delay * 2^attempt) * (1 + random * jitter)`
///
/// The jitter factor is applied symmetrically: a factor of 0.2 means the
/// delay varies by ±20% from the base exponential value.
///
/// # Arguments
///
/// * `attempt` — zero-based attempt index (0 for first retry)
/// * `base_delay_ms` — base delay in milliseconds
/// * `max_delay_ms` — maximum delay cap
/// * `jitter_factor` — jitter range (0.0–1.0)
///
/// # Note
///
/// This function uses a deterministic formula for the jitter seed. For
/// production use, the runtime crate wraps this with actual randomness.
#[must_use]
#[allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn calculate_backoff_delay(
    attempt: u32,
    base_delay_ms: u64,
    max_delay_ms: u64,
    jitter_factor: f64,
) -> u64 {
    // Exponential backoff: base * 2^attempt
    let exponential = base_delay_ms.saturating_mul(1u64 << attempt.min(31));

    // Cap at max delay
    let capped = exponential.min(max_delay_ms);

    // Apply jitter (without actual randomness — callers add their own).
    // Returns the base capped value plus the jitter range.
    let jitter_range = (capped as f64) * jitter_factor;
    let with_jitter = (capped as f64) + jitter_range;

    with_jitter.round() as u64
}

/// Calculate backoff delay with explicit randomness.
///
/// `random` should be a value in `[0.0, 1.0)` from a PRNG.
#[must_use]
#[allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn calculate_backoff_delay_with_random(
    attempt: u32,
    base_delay_ms: u64,
    max_delay_ms: u64,
    jitter_factor: f64,
    random: f64,
) -> u64 {
    let exponential = base_delay_ms.saturating_mul(1u64 << attempt.min(31));
    let capped = exponential.min(max_delay_ms);

    // Jitter: (1 + (random * 2 - 1) * jitter_factor)
    // Maps random [0,1) to [-jitter, +jitter]
    let jitter = 1.0 + (random * 2.0 - 1.0) * jitter_factor;
    let with_jitter = (capped as f64) * jitter;

    with_jitter.round().max(0.0) as u64
}

// ─────────────────────────────────────────────────────────────────────────────
// Retry-After header parsing
// ─────────────────────────────────────────────────────────────────────────────

/// Parse a `Retry-After` HTTP header value.
///
/// The value can be either:
/// - A number of seconds (e.g. `"120"`)
/// - An HTTP-date (e.g. `"Thu, 01 Dec 2025 16:00:00 GMT"`)
///
/// Returns the delay in milliseconds, or `None` if parsing fails.
#[must_use]
pub fn parse_retry_after_header(value: &str) -> Option<u64> {
    // Try parsing as integer seconds first
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(seconds * 1000);
    }

    // Try parsing as HTTP date
    if let Ok(date) = chrono::DateTime::parse_from_rfc2822(value) {
        let now = chrono::Utc::now();
        let delay = date.signed_duration_since(now);
        let delay_ms = delay.num_milliseconds();
        return Some(if delay_ms > 0 {
            #[allow(clippy::cast_sign_loss)]
            let ms = delay_ms as u64;
            ms
        } else {
            0
        });
    }

    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // -- RetryConfig --

    #[test]
    fn retry_config_defaults() {
        let config = RetryConfig::default();
        assert_eq!(config.max_retries, 5);
        assert_eq!(config.base_delay_ms, 1000);
        assert_eq!(config.max_delay_ms, 60_000);
        assert!((config.jitter_factor - 0.2).abs() < f64::EPSILON);
    }

    #[test]
    fn retry_config_serde_roundtrip() {
        let config = RetryConfig {
            max_retries: 3,
            base_delay_ms: 500,
            max_delay_ms: 30_000,
            jitter_factor: 0.1,
        };
        let json = serde_json::to_string(&config).unwrap();
        let back: RetryConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(config.max_retries, back.max_retries);
        assert_eq!(config.base_delay_ms, back.base_delay_ms);
    }

    #[test]
    fn retry_config_serde_defaults() {
        let json = "{}";
        let config: RetryConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.max_retries, 5);
        assert_eq!(config.base_delay_ms, 1000);
    }

    // -- calculate_backoff_delay --

    #[test]
    fn backoff_exponential_growth() {
        // Without jitter (jitter_factor = 0), delays should be exact powers of 2
        let d0 = calculate_backoff_delay(0, 1000, 60_000, 0.0);
        let d1 = calculate_backoff_delay(1, 1000, 60_000, 0.0);
        let d2 = calculate_backoff_delay(2, 1000, 60_000, 0.0);
        let d3 = calculate_backoff_delay(3, 1000, 60_000, 0.0);
        assert_eq!(d0, 1000);
        assert_eq!(d1, 2000);
        assert_eq!(d2, 4000);
        assert_eq!(d3, 8000);
    }

    #[test]
    fn backoff_caps_at_max() {
        let delay = calculate_backoff_delay(10, 1000, 60_000, 0.0);
        assert_eq!(delay, 60_000);
    }

    #[test]
    fn backoff_with_jitter_increases() {
        // With jitter_factor = 0.2, delay should be up to 20% higher
        let delay = calculate_backoff_delay(0, 1000, 60_000, 0.2);
        assert!(delay >= 1000);
        assert!(delay <= 1200);
    }

    #[test]
    fn backoff_high_attempt_no_overflow() {
        // Should not panic with very high attempt numbers
        let delay = calculate_backoff_delay(100, 1000, 60_000, 0.2);
        assert!(delay > 0);
        assert!(delay <= 72_000); // 60_000 * 1.2
    }

    // -- calculate_backoff_delay_with_random --

    #[test]
    fn backoff_with_random_zero() {
        // random = 0.0 → jitter = 1 + (0*2-1)*0.2 = 1 - 0.2 = 0.8
        let delay = calculate_backoff_delay_with_random(0, 1000, 60_000, 0.2, 0.0);
        assert_eq!(delay, 800);
    }

    #[test]
    fn backoff_with_random_half() {
        // random = 0.5 → jitter = 1 + (1-1)*0.2 = 1.0
        let delay = calculate_backoff_delay_with_random(0, 1000, 60_000, 0.2, 0.5);
        assert_eq!(delay, 1000);
    }

    #[test]
    fn backoff_with_random_one() {
        // random = 1.0 → jitter = 1 + (2-1)*0.2 = 1.2
        let delay = calculate_backoff_delay_with_random(0, 1000, 60_000, 0.2, 1.0);
        assert_eq!(delay, 1200);
    }

    #[test]
    fn backoff_with_random_capped() {
        let delay = calculate_backoff_delay_with_random(20, 1000, 60_000, 0.2, 0.5);
        assert_eq!(delay, 60_000);
    }

    // -- parse_retry_after_header --

    #[test]
    fn parse_retry_after_seconds() {
        assert_eq!(parse_retry_after_header("120"), Some(120_000));
        assert_eq!(parse_retry_after_header("0"), Some(0));
        assert_eq!(parse_retry_after_header("1"), Some(1000));
    }

    #[test]
    fn parse_retry_after_invalid() {
        assert_eq!(parse_retry_after_header("not-a-number"), None);
        assert_eq!(parse_retry_after_header(""), None);
    }

    #[test]
    fn parse_retry_after_http_date() {
        // A date far in the future should return a positive delay
        use chrono::{TimeZone, Utc};
        let future_dt = Utc.with_ymd_and_hms(2099, 1, 1, 0, 0, 0).unwrap();
        let future = future_dt.to_rfc2822();
        let result = parse_retry_after_header(&future);
        assert!(result.is_some());
        assert!(result.unwrap() > 0);
    }

    #[test]
    fn parse_retry_after_past_date() {
        // A past date should return 0
        use chrono::{TimeZone, Utc};
        let past_dt = Utc.with_ymd_and_hms(2020, 1, 1, 0, 0, 0).unwrap();
        let past = past_dt.to_rfc2822();
        let result = parse_retry_after_header(&past);
        assert_eq!(result, Some(0));
    }

    // -- RetryResult --

    #[test]
    fn retry_result_success() {
        let result = RetryResult {
            success: true,
            value: Some(42),
            error: None,
            attempts: 1,
            total_delay_ms: 0,
        };
        assert!(result.success);
        assert_eq!(result.value, Some(42));
    }

    #[test]
    fn retry_result_failure() {
        let result: RetryResult<i32> = RetryResult {
            success: false,
            value: None,
            error: Some(ParsedError {
                category: crate::errors::parse::ErrorCategory::RateLimit,
                message: "too many requests".into(),
                details: None,
                is_retryable: true,
                suggestion: Some("wait and retry".into()),
            }),
            attempts: 6,
            total_delay_ms: 31_000,
        };
        assert!(!result.success);
        assert_eq!(result.attempts, 6);
    }
}
