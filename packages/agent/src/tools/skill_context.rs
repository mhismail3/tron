//! Skill context resolution for Bash tool guards.
//!
//! Provides the [`SkillContextResolver`] trait that the Bash tool uses to
//! look up skill metadata (display hints and guards) when the model includes
//! a `skill` parameter. This decouples the Bash tool from the skill registry
//! implementation.

use std::sync::Arc;
use std::time::Instant;

use dashmap::DashMap;

use crate::skills::types::{SkillDisplay, SkillGuards};

/// Resolved skill context containing display metadata and guards.
#[derive(Debug, Clone)]
pub struct ResolvedSkillContext {
    /// Skill name (folder name / registry key).
    pub name: String,
    /// Display metadata for iOS app (label, icon, color).
    pub display: Option<SkillDisplay>,
    /// Harness-level guards to apply.
    pub guards: Option<SkillGuards>,
}

/// Resolves a skill name to its display and guards metadata.
///
/// Implemented by the skill registry adapter. The Bash tool receives this
/// via dependency injection to avoid coupling to the registry module.
pub trait SkillContextResolver: Send + Sync {
    /// Look up a skill by name and return its context.
    /// Returns `None` if the skill is not found.
    fn resolve(&self, name: &str) -> Option<ResolvedSkillContext>;
}

/// Per-skill rate limiter using atomic timestamps.
///
/// Tracks the last call time for each skill and enforces minimum intervals.
pub struct RateLimiter {
    last_calls: DashMap<String, Instant>,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self {
            last_calls: DashMap::new(),
        }
    }

    /// Check if enough time has elapsed since the last call for this skill.
    ///
    /// Returns `Ok(())` if the call is allowed, or `Err(remaining_ms)` if
    /// rate-limited (with the number of milliseconds until the next allowed call).
    pub fn check(&self, skill_name: &str, min_interval_ms: u64) -> Result<(), u64> {
        if let Some(last) = self.last_calls.get(skill_name) {
            let elapsed_ms = last.elapsed().as_millis() as u64;
            if elapsed_ms < min_interval_ms {
                return Err(min_interval_ms - elapsed_ms);
            }
        }
        // Record this call.
        self.last_calls.insert(skill_name.to_string(), Instant::now());
        Ok(())
    }
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::new()
    }
}

/// Convenience: no-op resolver that always returns None.
/// Used when the Bash tool has no skill registry available.
pub struct NoOpResolver;

impl SkillContextResolver for NoOpResolver {
    fn resolve(&self, _name: &str) -> Option<ResolvedSkillContext> {
        None
    }
}

/// Wraps a closure as a `SkillContextResolver` (useful for tests).
pub struct FnResolver<F>(pub F);

impl<F> SkillContextResolver for FnResolver<F>
where
    F: Fn(&str) -> Option<ResolvedSkillContext> + Send + Sync,
{
    fn resolve(&self, name: &str) -> Option<ResolvedSkillContext> {
        (self.0)(name)
    }
}

/// Build a `SkillContextResolver` from an `Arc<RwLock<SkillRegistry>>`.
///
/// This is the production adapter that bridges the skills module to the
/// tools module without direct coupling.
pub fn resolver_from_registry(
    registry: Arc<std::sync::RwLock<crate::skills::registry::SkillRegistry>>,
) -> impl SkillContextResolver {
    FnResolver(move |name: &str| {
        let reg = registry.read().ok()?;
        let meta = reg.get(name)?;
        Some(ResolvedSkillContext {
            name: meta.name.clone(),
            display: meta.frontmatter.display.clone(),
            guards: meta.frontmatter.guards.clone(),
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rate_limiter_first_call_passes() {
        let rl = RateLimiter::new();
        assert!(rl.check("skill-a", 1000).is_ok());
    }

    #[test]
    fn test_rate_limiter_blocks_fast_calls() {
        let rl = RateLimiter::new();
        rl.check("skill-a", 60_000).unwrap(); // 60s interval
        let result = rl.check("skill-a", 60_000);
        assert!(result.is_err());
        let remaining = result.unwrap_err();
        assert!(remaining > 0);
        assert!(remaining <= 60_000);
    }

    #[test]
    fn test_rate_limiter_allows_after_interval() {
        let rl = RateLimiter::new();
        // Use 0ms interval — should always pass.
        rl.check("skill-a", 0).unwrap();
        assert!(rl.check("skill-a", 0).is_ok());
    }

    #[test]
    fn test_rate_limiter_per_skill() {
        let rl = RateLimiter::new();
        rl.check("skill-a", 60_000).unwrap();
        // Different skill should not be rate-limited.
        assert!(rl.check("skill-b", 60_000).is_ok());
    }

    #[test]
    fn test_noop_resolver() {
        let r = NoOpResolver;
        assert!(r.resolve("anything").is_none());
    }

    #[test]
    fn test_fn_resolver() {
        let r = FnResolver(|name: &str| {
            if name == "test" {
                Some(ResolvedSkillContext {
                    name: "test".into(),
                    display: None,
                    guards: None,
                })
            } else {
                None
            }
        });
        assert!(r.resolve("test").is_some());
        assert!(r.resolve("other").is_none());
    }
}
