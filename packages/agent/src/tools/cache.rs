//! General-purpose server cache for skill-guided Bash calls.
//!
//! Provides a thread-safe, TTL-based in-memory cache with LRU eviction.
//! Skills declare caching behavior in their `guards.cache` frontmatter,
//! and the Bash tool uses this cache transparently.
//!
//! Cache keys are namespaced by skill name to prevent cross-skill collision.
//! Key extraction modes: `url` (extract URL from curl/wget), `command` (full
//! command string), or `auto` (try URL first, fall back to command).

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use dashmap::DashMap;

/// How to extract a cache key from a bash command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyExtractor {
    /// Extract URL from curl/wget commands.
    Url,
    /// Use the full command string as key.
    Command,
    /// Try URL extraction first, fall back to command.
    Auto,
}

impl KeyExtractor {
    /// Parse from a string value (from skill frontmatter).
    pub fn from_str_value(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "url" => Self::Url,
            "command" => Self::Command,
            _ => Self::Auto,
        }
    }

    /// Extract a cache key from a command string.
    pub fn extract(&self, command: &str) -> String {
        match self {
            Self::Url => extract_url(command).unwrap_or_else(|| command.to_string()),
            Self::Command => command.to_string(),
            Self::Auto => extract_url(command).unwrap_or_else(|| command.to_string()),
        }
    }
}

/// A namespaced cache key.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CacheKey {
    /// Skill name (namespace).
    pub skill: String,
    /// Extracted key.
    pub key: String,
}

impl CacheKey {
    /// Create a new cache key from skill name, command, and extractor.
    pub fn new(skill: &str, command: &str, extractor: &KeyExtractor) -> Self {
        Self {
            skill: skill.to_string(),
            key: extractor.extract(command),
        }
    }
}

impl std::fmt::Display for CacheKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}::{}", self.skill, self.key)
    }
}

struct CacheEntry {
    value: String,
    created_at: Instant,
    /// Monotonic counter for LRU ordering.
    access_order: u64,
}

/// Thread-safe, TTL-based in-memory cache with LRU eviction.
pub struct ServerCache {
    entries: DashMap<CacheKey, CacheEntry>,
    /// Maximum number of entries before eviction.
    max_entries: usize,
    /// Maximum size per entry in bytes.
    max_entry_bytes: usize,
    /// Monotonic counter for LRU tracking.
    counter: AtomicU64,
}

impl ServerCache {
    /// Create a new server cache with the given limits.
    pub fn new(max_entries: usize, max_entry_bytes: usize) -> Self {
        Self {
            entries: DashMap::new(),
            max_entries,
            max_entry_bytes,
            counter: AtomicU64::new(0),
        }
    }

    /// Create with default limits (1000 entries, 1MB per entry).
    pub fn with_defaults() -> Self {
        Self::new(1000, 1_048_576)
    }

    /// Get a cached value if it exists and hasn't expired.
    ///
    /// Returns `None` if the key doesn't exist or the entry has expired
    /// beyond the given TTL (in seconds).
    pub fn get(&self, key: &CacheKey, ttl_secs: u64) -> Option<String> {
        let entry = self.entries.get(key)?;
        let elapsed = entry.created_at.elapsed().as_secs();
        if elapsed >= ttl_secs {
            drop(entry);
            let _ = self.entries.remove(key);
            return None;
        }
        Some(entry.value.clone())
    }

    /// Store a value in the cache.
    ///
    /// Returns `false` if the value exceeds `max_entry_bytes`.
    /// Evicts the least-recently-used entry if at capacity.
    pub fn set(&self, key: CacheKey, value: &str) -> bool {
        if value.len() > self.max_entry_bytes {
            return false;
        }

        // Evict if at capacity (before inserting).
        if self.entries.len() >= self.max_entries && !self.entries.contains_key(&key) {
            self.evict_lru();
        }

        let order = self.counter.fetch_add(1, Ordering::Relaxed);
        let _ = self.entries.insert(
            key,
            CacheEntry {
                value: value.to_string(),
                created_at: Instant::now(),
                access_order: order,
            },
        );
        true
    }

    /// Number of entries currently in the cache.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Evict the entry with the lowest access_order (LRU).
    fn evict_lru(&self) {
        let mut min_order = u64::MAX;
        let mut min_key = None;

        for entry in self.entries.iter() {
            if entry.value().access_order < min_order {
                min_order = entry.value().access_order;
                min_key = Some(entry.key().clone());
            }
        }

        if let Some(key) = min_key {
            let _ = self.entries.remove(&key);
        }
    }
}

/// Extract a URL from a curl or wget command.
///
/// Looks for common URL patterns in the command string.
fn extract_url(command: &str) -> Option<String> {
    // Split on whitespace and find tokens that look like URLs.
    for token in command.split_whitespace() {
        // Strip surrounding quotes.
        let cleaned = token
            .trim_start_matches('"')
            .trim_end_matches('"')
            .trim_start_matches('\'')
            .trim_end_matches('\'');

        if cleaned.starts_with("http://") || cleaned.starts_with("https://") {
            return Some(cleaned.to_string());
        }
    }
    None
}

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;

    #[test]
    fn test_set_and_get() {
        let cache = ServerCache::with_defaults();
        let key = CacheKey {
            skill: "test".into(),
            key: "k1".into(),
        };
        assert!(cache.set(key.clone(), "hello"));
        assert_eq!(cache.get(&key, 60), Some("hello".to_string()));
    }

    #[test]
    fn test_get_missing_key() {
        let cache = ServerCache::with_defaults();
        let key = CacheKey {
            skill: "test".into(),
            key: "missing".into(),
        };
        assert_eq!(cache.get(&key, 60), None);
    }

    #[test]
    fn test_ttl_expiry() {
        let cache = ServerCache::with_defaults();
        let key = CacheKey {
            skill: "test".into(),
            key: "k1".into(),
        };
        cache.set(key.clone(), "val");
        // TTL of 0 means immediately expired.
        assert_eq!(cache.get(&key, 0), None);
    }

    #[test]
    fn test_ttl_not_expired() {
        let cache = ServerCache::with_defaults();
        let key = CacheKey {
            skill: "test".into(),
            key: "k1".into(),
        };
        cache.set(key.clone(), "val");
        // TTL of 3600 (1 hour) — should not be expired.
        assert_eq!(cache.get(&key, 3600), Some("val".to_string()));
    }

    #[test]
    fn test_lru_eviction() {
        let cache = ServerCache::new(2, 1_048_576);
        let k1 = CacheKey {
            skill: "s".into(),
            key: "1".into(),
        };
        let k2 = CacheKey {
            skill: "s".into(),
            key: "2".into(),
        };
        let k3 = CacheKey {
            skill: "s".into(),
            key: "3".into(),
        };

        cache.set(k1.clone(), "a");
        cache.set(k2.clone(), "b");
        assert_eq!(cache.len(), 2);

        // Adding k3 should evict k1 (oldest by access_order).
        cache.set(k3.clone(), "c");
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.get(&k1, 3600), None); // evicted
        assert_eq!(cache.get(&k2, 3600), Some("b".to_string()));
        assert_eq!(cache.get(&k3, 3600), Some("c".to_string()));
    }

    #[test]
    fn test_entry_size_limit() {
        let cache = ServerCache::new(100, 10); // 10 bytes max per entry
        let key = CacheKey {
            skill: "test".into(),
            key: "k1".into(),
        };
        assert!(!cache.set(key.clone(), "this is way too long for the limit"));
        assert_eq!(cache.get(&key, 60), None);
    }

    #[test]
    fn test_namespace_isolation() {
        let cache = ServerCache::with_defaults();
        let k1 = CacheKey {
            skill: "web-fetch".into(),
            key: "https://example.com".into(),
        };
        let k2 = CacheKey {
            skill: "web-search".into(),
            key: "https://example.com".into(),
        };
        cache.set(k1.clone(), "fetch result");
        cache.set(k2.clone(), "search result");
        assert_eq!(cache.get(&k1, 3600), Some("fetch result".to_string()));
        assert_eq!(cache.get(&k2, 3600), Some("search result".to_string()));
    }

    #[test]
    fn test_key_extract_url() {
        assert_eq!(
            KeyExtractor::Url.extract("curl https://example.com/path?q=x"),
            "https://example.com/path?q=x"
        );
    }

    #[test]
    fn test_key_extract_url_with_headers() {
        assert_eq!(
            KeyExtractor::Url.extract("curl -H \"Auth: Bearer tok\" https://example.com"),
            "https://example.com"
        );
    }

    #[test]
    fn test_key_extract_url_wget() {
        assert_eq!(
            KeyExtractor::Url.extract("wget https://example.com/file.txt"),
            "https://example.com/file.txt"
        );
    }

    #[test]
    fn test_key_extract_url_no_url() {
        // No URL found — falls back to full command.
        let cmd = "echo hello world";
        assert_eq!(KeyExtractor::Url.extract(cmd), cmd);
    }

    #[test]
    fn test_key_extract_command() {
        let cmd = "curl https://example.com";
        assert_eq!(KeyExtractor::Command.extract(cmd), cmd);
    }

    #[test]
    fn test_key_extract_auto() {
        // Auto tries URL first.
        assert_eq!(
            KeyExtractor::Auto.extract("curl https://example.com"),
            "https://example.com"
        );
        // Falls back to command when no URL.
        let cmd = "echo hello";
        assert_eq!(KeyExtractor::Auto.extract(cmd), cmd);
    }

    #[test]
    fn test_concurrent_access() {
        use std::sync::Arc;
        use std::thread;

        let cache = Arc::new(ServerCache::new(1000, 1_048_576));
        let mut handles = vec![];

        for i in 0..10 {
            let cache = Arc::clone(&cache);
            handles.push(thread::spawn(move || {
                let key = CacheKey {
                    skill: "test".into(),
                    key: format!("k{i}"),
                };
                cache.set(key.clone(), &format!("v{i}"));
                assert_eq!(cache.get(&key, 3600), Some(format!("v{i}")));
            }));
        }

        for h in handles {
            h.join().unwrap();
        }
        assert_eq!(cache.len(), 10);
    }

    #[test]
    fn test_overwrite_existing_key() {
        let cache = ServerCache::with_defaults();
        let key = CacheKey {
            skill: "test".into(),
            key: "k1".into(),
        };
        cache.set(key.clone(), "old");
        cache.set(key.clone(), "new");
        assert_eq!(cache.get(&key, 3600), Some("new".to_string()));
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn test_key_extract_url_quoted() {
        assert_eq!(
            KeyExtractor::Url.extract("curl 'https://example.com/api'"),
            "https://example.com/api"
        );
    }

    #[test]
    fn test_cache_key_display() {
        let key = CacheKey {
            skill: "web-fetch".into(),
            key: "https://example.com".into(),
        };
        assert_eq!(key.to_string(), "web-fetch::https://example.com");
    }

    #[test]
    fn test_from_str_value() {
        assert_eq!(KeyExtractor::from_str_value("url"), KeyExtractor::Url);
        assert_eq!(
            KeyExtractor::from_str_value("command"),
            KeyExtractor::Command
        );
        assert_eq!(KeyExtractor::from_str_value("auto"), KeyExtractor::Auto);
        assert_eq!(
            KeyExtractor::from_str_value("unknown"),
            KeyExtractor::Auto
        );
    }
}
