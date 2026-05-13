//! Convert skill frontmatter to capability denial configuration.
//!
//! Supports two mutually exclusive modes:
//! - **Deny-list** (`deniedCapabilities`): directly specifies denied capabilities
//! - **Allow-list** (`allowedCapabilities`): inverts to denied (all capabilities not in allow list)
//!
//! If both are specified, `deniedCapabilities` takes precedence with a warning.
//!
//! For inline skills on the main agent, restrictions are soft-enforced via prompt
//! XML hints. For subagent skills and cron jobs, restrictions are hard-enforced via
//! live capability catalog removal in `AgentFactory`.
//!
//! Callers:
//! - `cron::impls::to_denied_list` — cron-job skill denials
//! - `runtime::orchestrator::subagent_manager::SubagentManager::compute_denied_capabilities`
//!   — subagents spawned via `agent::spawn_subagent` (honors `SubagentConfig.skills`)

use std::collections::HashSet;

use tracing::debug;

use crate::domains::skills::types::{CapabilityDenialConfig, SkillFrontmatter, SkillSubagentMode};

/// Convert skill frontmatter capability restrictions to a [`CapabilityDenialConfig`].
///
/// Returns `None` if no capability restrictions are specified.
pub fn skill_frontmatter_to_denials(
    frontmatter: &SkillFrontmatter,
    all_available_capabilities: &[String],
) -> Option<CapabilityDenialConfig> {
    let has_denied = frontmatter
        .denied_capabilities
        .as_ref()
        .is_some_and(|d| !d.is_empty());
    let has_allowed = frontmatter
        .allowed_capabilities
        .as_ref()
        .is_some_and(|a| !a.is_empty());

    if has_denied && has_allowed {
        debug!(
            "Skill specifies both deniedCapabilities and allowedCapabilities; using deniedCapabilities"
        );
    }

    if has_denied {
        let denied_capabilities = frontmatter.denied_capabilities.clone().unwrap_or_default();
        return Some(CapabilityDenialConfig {
            denied_capabilities,
        });
    }

    if let Some(allowed_list) = frontmatter
        .allowed_capabilities
        .as_ref()
        .filter(|a| !a.is_empty())
    {
        let allowed: HashSet<&str> = allowed_list.iter().map(String::as_str).collect();
        let denied_capabilities: Vec<String> = all_available_capabilities
            .iter()
            .filter(|capability| !allowed.contains(capability.as_str()))
            .cloned()
            .collect();
        return Some(CapabilityDenialConfig {
            denied_capabilities,
        });
    }

    None
}

/// Get the subagent execution mode from skill frontmatter.
///
/// Defaults to [`SkillSubagentMode::No`] if not specified.
pub fn get_skill_subagent_mode(frontmatter: &SkillFrontmatter) -> SkillSubagentMode {
    frontmatter.subagent.unwrap_or(SkillSubagentMode::No)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_capabilities() -> Vec<String> {
        vec![
            "filesystem::read_file".to_string(),
            "filesystem::write_file".to_string(),
            "filesystem::edit_file".to_string(),
            "process::run".to_string(),
            "Grep".to_string(),
            "Glob".to_string(),
        ]
    }

    #[test]
    fn test_denied_capabilities() {
        let fm = SkillFrontmatter {
            denied_capabilities: Some(vec![
                "process::run".to_string(),
                "filesystem::write_file".to_string(),
            ]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_capabilities()).unwrap();
        assert_eq!(
            config.denied_capabilities,
            vec!["process::run", "filesystem::write_file"]
        );
    }

    #[test]
    fn test_allowed_capabilities_inverted() {
        let fm = SkillFrontmatter {
            allowed_capabilities: Some(vec![
                "filesystem::read_file".to_string(),
                "Grep".to_string(),
            ]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_capabilities()).unwrap();
        assert!(
            config
                .denied_capabilities
                .contains(&"process::run".to_string())
        );
        assert!(
            config
                .denied_capabilities
                .contains(&"filesystem::write_file".to_string())
        );
        assert!(
            config
                .denied_capabilities
                .contains(&"filesystem::edit_file".to_string())
        );
        assert!(config.denied_capabilities.contains(&"Glob".to_string()));
        assert!(
            !config
                .denied_capabilities
                .contains(&"filesystem::read_file".to_string())
        );
        assert!(!config.denied_capabilities.contains(&"Grep".to_string()));
    }

    #[test]
    fn test_both_specified_denied_wins() {
        let fm = SkillFrontmatter {
            denied_capabilities: Some(vec!["process::run".to_string()]),
            allowed_capabilities: Some(vec!["filesystem::read_file".to_string()]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_capabilities()).unwrap();
        assert_eq!(config.denied_capabilities, vec!["process::run"]);
    }

    #[test]
    fn test_neither_specified_returns_none() {
        let fm = SkillFrontmatter::default();
        assert!(skill_frontmatter_to_denials(&fm, &all_capabilities()).is_none());
    }

    #[test]
    fn test_empty_denied_capabilities_returns_none() {
        let fm = SkillFrontmatter {
            denied_capabilities: Some(Vec::new()),
            ..Default::default()
        };
        assert!(skill_frontmatter_to_denials(&fm, &all_capabilities()).is_none());
    }

    #[test]
    fn test_get_subagent_mode_default() {
        let fm = SkillFrontmatter::default();
        assert_eq!(get_skill_subagent_mode(&fm), SkillSubagentMode::No);
    }

    #[test]
    fn test_get_subagent_mode_ask() {
        let fm = SkillFrontmatter {
            subagent: Some(SkillSubagentMode::Ask),
            ..Default::default()
        };
        assert_eq!(get_skill_subagent_mode(&fm), SkillSubagentMode::Ask);
    }

    #[test]
    fn test_get_subagent_mode_yes() {
        let fm = SkillFrontmatter {
            subagent: Some(SkillSubagentMode::Yes),
            ..Default::default()
        };
        assert_eq!(get_skill_subagent_mode(&fm), SkillSubagentMode::Yes);
    }
}
