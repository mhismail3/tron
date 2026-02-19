//! Convert skill frontmatter to tool denial configuration.
//!
//! Supports two modes:
//! - **Deny-list** (`deniedTools`): directly specifies denied tools
//! - **Allow-list** (`allowedTools`): inverts to denied (all tools not in allow list)
//!
//! If both are specified, `deniedTools` takes precedence with a warning.

use tracing::warn;

use crate::types::{SkillFrontmatter, SkillSubagentMode, ToolDenialConfig};

/// Convert skill frontmatter tool restrictions to a [`ToolDenialConfig`].
///
/// Returns `None` if no tool restrictions are specified.
pub fn skill_frontmatter_to_denials(
    frontmatter: &SkillFrontmatter,
    all_available_tools: &[String],
) -> Option<ToolDenialConfig> {
    let has_denied = frontmatter
        .denied_tools
        .as_ref()
        .is_some_and(|d| !d.is_empty());
    let has_allowed = frontmatter
        .allowed_tools
        .as_ref()
        .is_some_and(|a| !a.is_empty());

    if has_denied && has_allowed {
        warn!("Skill specifies both deniedTools and allowedTools; using deniedTools");
    }

    if has_denied {
        let denied_tools = frontmatter.denied_tools.clone().unwrap_or_default();
        let denied_patterns = frontmatter.denied_patterns.clone().unwrap_or_default();
        return Some(ToolDenialConfig {
            denied_tools,
            denied_patterns,
        });
    }

    if has_allowed {
        let allowed = frontmatter.allowed_tools.as_ref().unwrap();
        let denied_tools: Vec<String> = all_available_tools
            .iter()
            .filter(|tool| !allowed.contains(tool))
            .cloned()
            .collect();
        let denied_patterns = frontmatter.denied_patterns.clone().unwrap_or_default();
        return Some(ToolDenialConfig {
            denied_tools,
            denied_patterns,
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

    fn all_tools() -> Vec<String> {
        vec![
            "Read".to_string(),
            "Write".to_string(),
            "Edit".to_string(),
            "Bash".to_string(),
            "Grep".to_string(),
            "Glob".to_string(),
        ]
    }

    #[test]
    fn test_denied_tools() {
        let fm = SkillFrontmatter {
            denied_tools: Some(vec!["Bash".to_string(), "Write".to_string()]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_tools()).unwrap();
        assert_eq!(config.denied_tools, vec!["Bash", "Write"]);
    }

    #[test]
    fn test_allowed_tools_inverted() {
        let fm = SkillFrontmatter {
            allowed_tools: Some(vec!["Read".to_string(), "Grep".to_string()]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_tools()).unwrap();
        assert!(config.denied_tools.contains(&"Bash".to_string()));
        assert!(config.denied_tools.contains(&"Write".to_string()));
        assert!(config.denied_tools.contains(&"Edit".to_string()));
        assert!(config.denied_tools.contains(&"Glob".to_string()));
        assert!(!config.denied_tools.contains(&"Read".to_string()));
        assert!(!config.denied_tools.contains(&"Grep".to_string()));
    }

    #[test]
    fn test_both_specified_denied_wins() {
        let fm = SkillFrontmatter {
            denied_tools: Some(vec!["Bash".to_string()]),
            allowed_tools: Some(vec!["Read".to_string()]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_tools()).unwrap();
        assert_eq!(config.denied_tools, vec!["Bash"]);
    }

    #[test]
    fn test_neither_specified_returns_none() {
        let fm = SkillFrontmatter::default();
        assert!(skill_frontmatter_to_denials(&fm, &all_tools()).is_none());
    }

    #[test]
    fn test_empty_denied_tools_returns_none() {
        let fm = SkillFrontmatter {
            denied_tools: Some(Vec::new()),
            ..Default::default()
        };
        assert!(skill_frontmatter_to_denials(&fm, &all_tools()).is_none());
    }

    #[test]
    fn test_denied_patterns_included() {
        use crate::types::{DenyPattern, SkillDeniedPatternRule};
        let fm = SkillFrontmatter {
            denied_tools: Some(vec!["Bash".to_string()]),
            denied_patterns: Some(vec![SkillDeniedPatternRule {
                tool: "Bash".to_string(),
                deny_patterns: vec![DenyPattern {
                    parameter: "command".to_string(),
                    patterns: vec!["rm.*".to_string()],
                }],
                message: Some("No removing".to_string()),
            }]),
            ..Default::default()
        };
        let config = skill_frontmatter_to_denials(&fm, &all_tools()).unwrap();
        assert_eq!(config.denied_patterns.len(), 1);
        assert_eq!(config.denied_patterns[0].tool, "Bash");
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
