//! Shared session-context data loading used by session capabilities.
//!
//! This domain-owned support module is intentionally split by responsibility:
//! `cache` owns the artifact cache, `dynamic` replays activated rule events,
//! `rules` loads project/global rule files, and `types` carries the DTOs shared
//! with agent/context domains.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Condvar;
use std::time::SystemTime;

use crate::domains::agent::runner::context::loader::{
    ContextLevel, ContextLoader, ContextLoaderConfig,
};
use crate::domains::agent::runner::context::rules_discovery::{
    RulesDiscoveryConfig, RulesDiscoveryResult, discover_rules_files_with_state,
};
use crate::domains::agent::runner::context::rules_index::RulesIndex;

mod cache;
mod dynamic;
mod rules;
pub(crate) mod types;

pub use cache::ContextArtifactsService;
#[cfg(test)]
pub(crate) use cache::load_session_context_artifacts_with_home;
pub(crate) use dynamic::collect_dynamic_rule_paths;
pub(crate) use types::{RuleFileLevel, SessionContextArtifacts};

#[cfg(test)]
mod tests;
