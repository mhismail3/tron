//! LRU + TTL cache for web fetch results.
//!
//! Stores fetch results keyed by URL + prompt hash. Entries expire after a
//! configurable TTL (default 15 minutes). LRU eviction when capacity is reached.

use std::collections::HashMap;
use std::time::{Duration, Instant};

const DEFAULT_TTL_SECS: u64 = 15 * 60;
const DEFAULT_MAX_ENTRIES: usize = 100;

/// Configuration for the web cache.
pub struct WebCacheConfig {
    /// TTL for cache entries.
    pub ttl: Duration,
    /// Maximum number of cached entries.
    pub max_entries: usize,
}

impl Default for WebCacheConfig {
    fn default() -> Self {
        Self {
            ttl: Duration::from_secs(DEFAULT_TTL_SECS),
            max_entries: DEFAULT_MAX_ENTRIES,
        }
    }
}

/// A cached fetch result.
#[derive(Clone, Debug)]
pub struct CachedResult {
    /// The summarized answer.
    pub answer: String,
    /// Source URL.
    pub url: String,
    /// Page title.
    pub title: String,
    /// Subagent session ID.
    pub subagent_session_id: String,
}

struct CacheEntry {
    result: CachedResult,
    expires_at: Instant,
}

/// LRU + TTL cache for web fetch results.
pub struct WebCache {
    entries: HashMap<String, CacheEntry>,
    access_order: Vec<String>,
    config: WebCacheConfig,
    hits: u64,
    misses: u64,
}

impl WebCache {
    /// Create a new cache with the given configuration.
    pub fn new(config: WebCacheConfig) -> Self {
        Self {
            entries: HashMap::new(),
            access_order: Vec::new(),
            config,
            hits: 0,
            misses: 0,
        }
    }

    /// Get a cached result, updating LRU order. Returns `None` on miss or expiry.
    pub fn get(&mut self, url: &str, prompt: &str) -> Option<&CachedResult> {
        let key = cache_key(url, prompt);

        // Check expiry first
        if let Some(entry) = self.entries.get(&key) {
            if Instant::now() >= entry.expires_at {
                drop(self.entries.remove(&key));
                self.access_order.retain(|k| k != &key);
                self.misses += 1;
                return None;
            }
        } else {
            self.misses += 1;
            return None;
        }

        // Update LRU order
        self.access_order.retain(|k| k != &key);
        self.access_order.push(key.clone());
        self.hits += 1;

        self.entries.get(&key).map(|e| &e.result)
    }

    /// Store a result in the cache. Evicts if at capacity.
    pub fn set(&mut self, url: &str, prompt: &str, result: CachedResult) {
        let key = cache_key(url, prompt);

        // If already exists, remove from access order
        self.access_order.retain(|k| k != &key);

        // Evict if at capacity
        while self.entries.len() >= self.config.max_entries {
            self.evict_oldest();
        }

        let entry = CacheEntry {
            result,
            expires_at: Instant::now() + self.config.ttl,
        };
        drop(self.entries.insert(key.clone(), entry));
        self.access_order.push(key);
    }

    /// Check if a result exists (non-destructive, checks TTL).
    pub fn has(&self, url: &str, prompt: &str) -> bool {
        let key = cache_key(url, prompt);
        self.entries
            .get(&key)
            .is_some_and(|e| Instant::now() < e.expires_at)
    }

    /// Remove all entries and reset stats.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.access_order.clear();
        self.hits = 0;
        self.misses = 0;
    }

    /// Remove expired entries.
    pub fn cleanup(&mut self) {
        let now = Instant::now();
        let expired_keys: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| now >= e.expires_at)
            .map(|(k, _)| k.clone())
            .collect();
        for key in &expired_keys {
            drop(self.entries.remove(key));
            self.access_order.retain(|k| k != key);
        }
    }

    /// Get cache statistics.
    pub fn stats(&self) -> CacheStats {
        let total = self.hits + self.misses;
        CacheStats {
            size: self.entries.len(),
            hits: self.hits,
            misses: self.misses,
            #[allow(clippy::cast_precision_loss)]
            hit_rate: if total == 0 {
                0.0
            } else {
                self.hits as f64 / total as f64
            },
        }
    }

    fn evict_oldest(&mut self) {
        // Prefer expired entries over LRU
        let now = Instant::now();
        let expired_key = self
            .entries
            .iter()
            .find(|(_, e)| now >= e.expires_at)
            .map(|(k, _)| k.clone());

        if let Some(key) = expired_key {
            drop(self.entries.remove(&key));
            self.access_order.retain(|k| k != &key);
            return;
        }

        // Otherwise evict LRU
        if let Some(oldest) = self.access_order.first().cloned() {
            drop(self.entries.remove(&oldest));
            drop(self.access_order.remove(0));
        }
    }
}

/// Cache statistics.
pub struct CacheStats {
    /// Number of entries in the cache.
    pub size: usize,
    /// Number of cache hits.
    pub hits: u64,
    /// Number of cache misses.
    pub misses: u64,
    /// Hit rate (0.0 to 1.0).
    pub hit_rate: f64,
}

/// Generate a cache key from URL + prompt using djb2 hash.
fn cache_key(url: &str, prompt: &str) -> String {
    let combined = format!("{url}::{prompt}");
    let hash = djb2_hash(&combined);
    format!("{url}::{hash}")
}

fn djb2_hash(s: &str) -> u32 {
    let mut hash: u32 = 5381;
    for byte in s.bytes() {
        hash = hash.wrapping_mul(33).wrapping_add(u32::from(byte));
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_result(answer: &str) -> CachedResult {
        CachedResult {
            answer: answer.into(),
            url: "https://example.com".into(),
            title: "Test".into(),
            subagent_session_id: "s1".into(),
        }
    }

    #[test]
    fn set_and_get() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("https://example.com", "what is it?", make_result("answer"));
        let r = cache.get("https://example.com", "what is it?");
        assert!(r.is_some());
        assert_eq!(r.unwrap().answer, "answer");
    }

    #[test]
    fn get_after_ttl_expired() {
        let config = WebCacheConfig {
            ttl: Duration::from_millis(0),
            max_entries: 100,
        };
        let mut cache = WebCache::new(config);
        cache.set("https://example.com", "q", make_result("a"));
        std::thread::sleep(Duration::from_millis(10));
        let r = cache.get("https://example.com", "q");
        assert!(r.is_none());
    }

    #[test]
    fn lru_eviction() {
        let config = WebCacheConfig {
            ttl: Duration::from_secs(60),
            max_entries: 2,
        };
        let mut cache = WebCache::new(config);
        cache.set("url1", "q", make_result("a1"));
        cache.set("url2", "q", make_result("a2"));
        cache.set("url3", "q", make_result("a3"));

        assert!(cache.get("url1", "q").is_none());
        assert!(cache.get("url2", "q").is_some());
        assert!(cache.get("url3", "q").is_some());
    }

    #[test]
    fn different_urls_different_keys() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("url1", "q", make_result("a1"));
        cache.set("url2", "q", make_result("a2"));
        assert_eq!(cache.get("url1", "q").unwrap().answer, "a1");
        assert_eq!(cache.get("url2", "q").unwrap().answer, "a2");
    }

    #[test]
    fn different_prompts_different_keys() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("url", "q1", make_result("a1"));
        cache.set("url", "q2", make_result("a2"));
        assert_eq!(cache.get("url", "q1").unwrap().answer, "a1");
        assert_eq!(cache.get("url", "q2").unwrap().answer, "a2");
    }

    #[test]
    fn same_url_same_prompt_cache_hit() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("url", "q", make_result("a"));
        let _ = cache.get("url", "q");
        let _ = cache.get("url", "q");
        let s = cache.stats();
        assert_eq!(s.hits, 2);
    }

    #[test]
    fn hit_miss_stats() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("url", "q", make_result("a"));
        let _ = cache.get("url", "q");
        let _ = cache.get("url", "missing");
        let s = cache.stats();
        assert_eq!(s.hits, 1);
        assert_eq!(s.misses, 1);
    }

    #[test]
    fn clear_empties_cache() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("url", "q", make_result("a"));
        cache.clear();
        assert!(cache.get("url", "q").is_none());
        let s = cache.stats();
        assert_eq!(s.size, 0);
        assert_eq!(s.hits, 0);
    }

    #[test]
    fn cleanup_removes_expired() {
        let config = WebCacheConfig {
            ttl: Duration::from_millis(0),
            max_entries: 100,
        };
        let mut cache = WebCache::new(config);
        cache.set("url", "q", make_result("a"));
        std::thread::sleep(Duration::from_millis(10));
        cache.cleanup();
        assert_eq!(cache.stats().size, 0);
    }

    #[test]
    fn hit_rate_calculation() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("url", "q", make_result("a"));
        let _ = cache.get("url", "q"); // hit
        let _ = cache.get("url", "miss"); // miss
        let s = cache.stats();
        assert!((s.hit_rate - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn default_ttl_15_minutes() {
        let config = WebCacheConfig::default();
        assert_eq!(config.ttl, Duration::from_secs(900));
    }

    #[test]
    fn default_max_entries_100() {
        let config = WebCacheConfig::default();
        assert_eq!(config.max_entries, 100);
    }
}
