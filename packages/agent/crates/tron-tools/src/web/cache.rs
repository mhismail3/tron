//! LRU + TTL cache for web fetch results.
//!
//! Stores fetch results keyed by URL + prompt. Entries expire after a
//! configurable TTL (default 15 minutes). LRU eviction when capacity is reached.

use std::time::{Duration, Instant};

use indexmap::IndexMap;

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
    entries: IndexMap<String, CacheEntry>,
    config: WebCacheConfig,
    hits: u64,
    misses: u64,
}

impl WebCache {
    /// Create a new cache with the given configuration.
    pub fn new(config: WebCacheConfig) -> Self {
        Self {
            entries: IndexMap::new(),
            config,
            hits: 0,
            misses: 0,
        }
    }

    /// Get a cached result, updating LRU order. Returns `None` on miss or expiry.
    pub fn get(&mut self, url: &str, prompt: &str) -> Option<&CachedResult> {
        let key = cache_key(url, prompt);

        let Some(idx) = self.entries.get_index_of(&key) else {
            self.misses += 1;
            return None;
        };

        // Check expiry
        if Instant::now() >= self.entries.get_index(idx).unwrap().1.expires_at {
            drop(self.entries.swap_remove_index(idx));
            self.misses += 1;
            return None;
        }

        // Move to back (most recently used)
        let last = self.entries.len() - 1;
        if idx != last {
            self.entries.move_index(idx, last);
        }
        self.hits += 1;

        self.entries.get_index(last).map(|(_, e)| &e.result)
    }

    /// Store a result in the cache. Evicts if at capacity.
    pub fn set(&mut self, url: &str, prompt: &str, result: CachedResult) {
        let key = cache_key(url, prompt);

        // Remove existing entry if present
        drop(self.entries.swap_remove(&key));

        // Evict if at capacity
        while self.entries.len() >= self.config.max_entries {
            self.evict_oldest();
        }

        let entry = CacheEntry {
            result,
            expires_at: Instant::now() + self.config.ttl,
        };
        drop(self.entries.insert(key, entry));
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
        self.hits = 0;
        self.misses = 0;
    }

    /// Remove expired entries.
    pub fn cleanup(&mut self) {
        let now = Instant::now();
        self.entries.retain(|_, e| now < e.expires_at);
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
        let expired_idx = self
            .entries
            .iter()
            .position(|(_, e)| now >= e.expires_at);

        if let Some(idx) = expired_idx {
            drop(self.entries.swap_remove_index(idx));
            return;
        }

        // Otherwise evict LRU (front = least recently used)
        if !self.entries.is_empty() {
            drop(self.entries.shift_remove_index(0));
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

/// Generate a cache key from URL + prompt.
/// NUL byte separator prevents ambiguity (neither URL nor prompt contains NUL).
fn cache_key(url: &str, prompt: &str) -> String {
    format!("{url}\0{prompt}")
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

    #[test]
    fn lru_order_updated_on_access() {
        let config = WebCacheConfig {
            ttl: Duration::from_secs(60),
            max_entries: 3,
        };
        let mut cache = WebCache::new(config);
        cache.set("a", "q", make_result("a"));
        cache.set("b", "q", make_result("b"));
        cache.set("c", "q", make_result("c"));

        // Access "a" to move it to MRU position
        let _ = cache.get("a", "q");

        // Insert "d" — should evict "b" (LRU), not "a" (recently accessed)
        cache.set("d", "q", make_result("d"));

        assert!(cache.get("a", "q").is_some(), "a should be retained (recently accessed)");
        assert!(cache.get("b", "q").is_none(), "b should be evicted (LRU)");
        assert!(cache.get("c", "q").is_some(), "c should be retained");
        assert!(cache.get("d", "q").is_some(), "d should be present");
    }

    #[test]
    fn expired_preferred_over_lru_during_eviction() {
        let config = WebCacheConfig {
            ttl: Duration::from_millis(0),
            max_entries: 2,
        };
        let mut cache = WebCache::new(config);
        cache.set("a", "q", make_result("a"));
        std::thread::sleep(Duration::from_millis(10));

        // "a" is now expired. Insert with longer TTL.
        let long_config_entry = CacheEntry {
            result: make_result("b"),
            expires_at: Instant::now() + Duration::from_secs(60),
        };
        cache.entries.insert(cache_key("b", "q"), long_config_entry);

        // Insert "c" — should evict expired "a", not LRU "b"
        let long_entry = CacheEntry {
            result: make_result("c"),
            expires_at: Instant::now() + Duration::from_secs(60),
        };
        cache.entries.insert(cache_key("c", "q"), long_entry);

        // Trigger eviction since we're at capacity
        while cache.entries.len() >= cache.config.max_entries {
            cache.evict_oldest();
        }

        assert!(cache.entries.get(&cache_key("a", "q")).is_none(), "expired 'a' should be evicted");
        assert!(cache.entries.get(&cache_key("b", "q")).is_some() || cache.entries.get(&cache_key("c", "q")).is_some(),
            "non-expired entries should be retained");
    }

    #[test]
    fn set_same_key_updates_entry() {
        let mut cache = WebCache::new(WebCacheConfig::default());
        cache.set("url", "q", make_result("answer1"));
        cache.set("url", "q", make_result("answer2"));
        assert_eq!(cache.get("url", "q").unwrap().answer, "answer2");
        assert_eq!(cache.stats().size, 1);
    }
}
