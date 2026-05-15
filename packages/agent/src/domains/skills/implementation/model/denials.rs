//! Convert skill frontmatter to contract denial configuration.
//!
//! Supports two mutually exclusive modes:
//! - **Deny-list** (`deniedContracts`): directly specifies denied contracts
//! - **Allow-list** (`allowedContracts`): inverts to denied (all contracts not in allow list)
//!
//! If both are specified, `deniedContracts` takes precedence with a warning.
//!
//! For inline skills on the main agent, restrictions are soft-enforced via prompt
//! XML hints. For subagent skills and cron jobs, restrictions are hard-enforced via
//! child-agent execution policy constraints in `AgentFactory`.
//!
//! Callers:
//! - `runtime::orchestrator::subagent_manager::SubagentManager::compute_denied_contracts`
//!   — subagents spawned via `agent::spawn_subagent` (honors `SubagentConfig.skills`)

use std::collections::HashSet;

use tracing::debug;

use crate::domains::skills::types::{ContractDenialConfig, SkillFrontmatter, SkillSubagentMode};

/// Convert skill frontmatter contract restrictions to a [`ContractDenialConfig`].
///
/// Returns `None` if no contract restrictions are specified.
pub fn skill_frontmatter_to_denials(
    frontmatter: &SkillFrontmatter,
    all_available_contracts: &[String],
) -> Option<ContractDenialConfig> {
    let has_denied = frontmatter
        .denied_contracts
        .as_ref()
        .is_some_and(|d| !d.is_empty());
    let has_allowed = frontmatter
        .allowed_contracts
        .as_ref()
        .is_some_and(|a| !a.is_empty());

    if has_denied && has_allowed {
        debug!("Skill specifies both deniedContracts and allowedContracts; using deniedContracts");
    }

    if has_denied {
        let denied_contracts = frontmatter.denied_contracts.clone().unwrap_or_default();
        return Some(ContractDenialConfig { denied_contracts });
    }

    if let Some(allowed_list) = frontmatter
        .allowed_contracts
        .as_ref()
        .filter(|a| !a.is_empty())
    {
        let allowed: HashSet<&str> = allowed_list.iter().map(String::as_str).collect();
        let denied_contracts: Vec<String> = all_available_contracts
            .iter()
            .filter(|contract| !allowed.contains(contract.as_str()))
            .cloned()
            .collect();
        return Some(ContractDenialConfig { denied_contracts });
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

    fn all_contracts() -> Vec<String> {
        vec![
            "filesystem::read_file".to_string(),
            "filesystem::write_file".to_string(),
            "filesystem::edit_file".to_string(),
            "process::run".to_string(),
            "filesystem::search_text".to_string(),
            "filesystem::glob".to_string(),
        ]
    }

    #[test]
    fn test_denied_contracts() {
        let fm = SkillFrontmatter {
            denied_contracts: Some(vec![
                "process::run".to_string(),
                "filesystem::write_file".to_string(),
            ]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_contracts()).unwrap();
        assert_eq!(
            config.denied_contracts,
            vec!["process::run", "filesystem::write_file"]
        );
    }

    #[test]
    fn test_allowed_contracts_inverted() {
        let fm = SkillFrontmatter {
            allowed_contracts: Some(vec![
                "filesystem::read_file".to_string(),
                "filesystem::search_text".to_string(),
            ]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_contracts()).unwrap();
        assert!(
            config
                .denied_contracts
                .contains(&"process::run".to_string())
        );
        assert!(
            config
                .denied_contracts
                .contains(&"filesystem::write_file".to_string())
        );
        assert!(
            config
                .denied_contracts
                .contains(&"filesystem::edit_file".to_string())
        );
        assert!(
            config
                .denied_contracts
                .contains(&"filesystem::glob".to_string())
        );
        assert!(
            !config
                .denied_contracts
                .contains(&"filesystem::read_file".to_string())
        );
        assert!(
            !config
                .denied_contracts
                .contains(&"filesystem::search_text".to_string())
        );
    }

    #[test]
    fn test_both_specified_denied_wins() {
        let fm = SkillFrontmatter {
            denied_contracts: Some(vec!["process::run".to_string()]),
            allowed_contracts: Some(vec!["filesystem::read_file".to_string()]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_contracts()).unwrap();
        assert_eq!(config.denied_contracts, vec!["process::run"]);
    }

    #[test]
    fn test_neither_specified_returns_none() {
        let fm = SkillFrontmatter::default();
        assert!(skill_frontmatter_to_denials(&fm, &all_contracts()).is_none());
    }

    #[test]
    fn test_empty_denied_contracts_returns_none() {
        let fm = SkillFrontmatter {
            denied_contracts: Some(Vec::new()),
            ..Default::default()
        };
        assert!(skill_frontmatter_to_denials(&fm, &all_contracts()).is_none());
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
