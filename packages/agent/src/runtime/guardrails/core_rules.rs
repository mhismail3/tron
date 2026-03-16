//! Built-in guardrail rules.
//!
//! Defines all core (immutable) and standard (configurable) rules that ship
//! with the guardrail engine. Core rules cannot be disabled by configuration.
//!
//! ## Core Rules (8)
//! - `core.destructive-commands` — blocks rm -rf /, fork bombs, dd to devices, etc.
//! - `core.tron-no-delete` — prevents deletion of files in ~/.tron
//! - `core.tron-app-protection` — protects ~/.tron/app/
//! - `core.tron-db-protection` — protects ~/.tron/database/
//! - `core.tron-auth-protection` — protects ~/.tron/auth.json
//! - `core.synology-drive-protection` — protects Synology Drive cloud storage
//! - `core.system-protection` — blocks writes to OS-critical paths (/System, /usr, /etc, etc.)
//! - `core.dotfiles-protection` — read-only access to dotfiles (~/.ssh, ~/.aws, ~/.config, etc.)
//!
//! ## Standard Rules (3)
//! - `path.traversal` — blocks `..` sequences in filesystem operations
//! - `path.hidden-mkdir` — blocks hidden directory creation in Bash
//! - `bash.timeout` — enforces 10-minute bash timeout limit

use regex::Regex;

use super::rules::GuardrailRule;
use super::rules::RuleBase;
use super::rules::path::PathRule;
use super::rules::pattern::PatternRule;
use super::rules::resource::ResourceRule;
use super::types::{RuleTier, Scope, Severity};

/// IDs of all core rules (cannot be disabled).
pub const CORE_RULE_IDS: &[&str] = &[
    "core.destructive-commands",
    "core.tron-no-delete",
    "core.tron-app-protection",
    "core.tron-db-protection",
    "core.tron-auth-protection",
    "core.synology-drive-protection",
    "core.system-protection",
    "core.dotfiles-protection",
];

/// Check if a rule ID is a core rule.
pub fn is_core_rule(rule_id: &str) -> bool {
    CORE_RULE_IDS.contains(&rule_id)
}

/// Get the home directory for rule path construction.
fn homedir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".to_string())
}

/// Escape special regex characters in a string.
fn escape_regex(s: &str) -> String {
    regex::escape(s)
}

/// Build all default rules (core + standard).
pub fn default_rules() -> Vec<GuardrailRule> {
    vec![
        // Core rules
        core_destructive_commands(),
        core_tron_no_delete(),
        core_tron_app_protection(),
        core_tron_db_protection(),
        core_tron_auth_protection(),
        core_synology_drive_protection(),
        core_system_protection(),
        core_dotfiles_protection(),
        // Standard rules
        path_traversal(),
        path_hidden_mkdir(),
        bash_timeout(),
    ]
}

/// Core rule: Block destructive shell commands.
fn core_destructive_commands() -> GuardrailRule {
    GuardrailRule::Pattern(PatternRule {
        base: RuleBase {
            id: "core.destructive-commands".into(),
            name: "Destructive Commands".into(),
            description: "Blocks extremely dangerous shell commands that could destroy the system"
                .into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "system-protection".into()],
        },
        target_argument: "command".into(),
        // INVARIANT: All patterns below are compile-time literals, validated by tests.
        patterns: vec![
            // rm -rf / or rm -rf /* (with or without sudo)
            Regex::new(r"(?i)^(sudo\s+)?rm\s+(-rf?|--force)\s+/\s*$").unwrap(),
            Regex::new(r"(?i)^(sudo\s+)?rm\s+-rf?\s+/\s*$").unwrap(),
            Regex::new(r"(?i)(sudo\s+)?rm\s+-rf?\s+/\*").unwrap(),
            // Fork bomb
            Regex::new(r"^:\(\)\s*\{\s*:\|\s*:\s*&\s*\}\s*;\s*:").unwrap(),
            // dd to raw devices
            Regex::new(r"(?i)(sudo\s+)?dd\s+if=.*of=/dev/[sh]d[a-z]").unwrap(),
            // Write to raw disk devices
            Regex::new(r"(?i)>\s*/dev/[sh]d[a-z]").unwrap(),
            // mkfs (filesystem formatting)
            Regex::new(r"(?i)^(sudo\s+)?mkfs\.").unwrap(),
            // chmod 777 on root
            Regex::new(r"(?i)^(sudo\s+)?chmod\s+777\s+/\s*$").unwrap(),
            // Dangerous system modifications with sudo
            Regex::new(r"(?i)^sudo\s+rm\s+-rf?\s+/(usr|var|etc|boot|bin|sbin|lib)\b").unwrap(),
        ],
    })
}

/// Core rule: Prevent deletion of files in ~/.tron.
fn core_tron_no_delete() -> GuardrailRule {
    let home = homedir();
    let tron_path = format!("{home}/.tron");
    let escaped = escape_regex(&tron_path);

    GuardrailRule::Pattern(PatternRule {
        base: RuleBase {
            id: "core.tron-no-delete".into(),
            name: "Tron No Delete".into(),
            description: "Prevents deletion of any files in ~/.tron directory".into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "config-protection".into()],
        },
        target_argument: "command".into(),
        patterns: vec![
            // rm commands targeting ~/.tron or $HOME/.tron
            Regex::new(&format!(r"(?i)rm\s+.*{escaped}")).unwrap(),
            Regex::new(r"(?i)rm\s+.*~/\.tron").unwrap(),
            Regex::new(r"(?i)rm\s+.*\$HOME/\.tron").unwrap(),
            // trash commands
            Regex::new(&format!(r"(?i)trash\s+.*{escaped}")).unwrap(),
            Regex::new(r"(?i)trash\s+.*~/\.tron").unwrap(),
        ],
    })
}

/// Core rule: Protect ~/.tron/app directory.
fn core_tron_app_protection() -> GuardrailRule {
    let home = homedir();
    let app_path = format!("{home}/.tron/app");

    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "core.tron-app-protection".into(),
            name: "Tron App Protection".into(),
            description: "Protects the ~/.tron/app directory from agent modifications".into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Write".into(), "Edit".into(), "Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "config-protection".into()],
        },
        path_arguments: vec!["file_path".into(), "path".into(), "command".into()],
        protected_paths: vec![app_path.clone(), format!("{app_path}/**")],
        block_traversal: false,
        block_hidden: false,
    })
}

/// Core rule: Protect ~/.tron/database directory.
fn core_tron_db_protection() -> GuardrailRule {
    let home = homedir();
    let db_path = format!("{home}/.tron/database");

    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "core.tron-db-protection".into(),
            name: "Tron DB Protection".into(),
            description: "Protects the ~/.tron/database directory from agent modifications".into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Write".into(), "Edit".into(), "Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "config-protection".into()],
        },
        path_arguments: vec!["file_path".into(), "path".into(), "command".into()],
        protected_paths: vec![db_path.clone(), format!("{db_path}/**")],
        block_traversal: false,
        block_hidden: false,
    })
}

/// Core rule: Protect ~/.tron/auth.json.
fn core_tron_auth_protection() -> GuardrailRule {
    let home = homedir();
    let auth_path = format!("{home}/.tron/auth.json");

    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "core.tron-auth-protection".into(),
            name: "Tron Auth Protection".into(),
            description: "Protects the ~/.tron/auth.json file from agent modifications".into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Write".into(), "Edit".into(), "Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "config-protection".into()],
        },
        path_arguments: vec!["file_path".into(), "path".into(), "command".into()],
        protected_paths: vec![auth_path],
        block_traversal: false,
        block_hidden: false,
    })
}

/// Core rule: Protect Synology Drive cloud storage.
fn core_synology_drive_protection() -> GuardrailRule {
    let home = homedir();
    let synology_path = format!("{home}/Library/CloudStorage/SynologyDrive-SynologyDrive");

    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "core.synology-drive-protection".into(),
            name: "Synology Drive Protection".into(),
            description: "Protects Synology Drive cloud storage from agent modifications".into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Write".into(), "Edit".into(), "Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "cloud-storage-protection".into()],
        },
        path_arguments: vec!["file_path".into(), "path".into(), "command".into()],
        protected_paths: vec![synology_path.clone(), format!("{synology_path}/**")],
        block_traversal: false,
        block_hidden: false,
    })
}

/// Core rule: Block writes to OS-critical paths.
fn core_system_protection() -> GuardrailRule {
    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "core.system-protection".into(),
            name: "System Protection".into(),
            description: "Blocks writes to OS-critical system paths".into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Write".into(), "Edit".into(), "Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "system-protection".into()],
        },
        path_arguments: vec!["file_path".into(), "path".into(), "command".into()],
        protected_paths: vec![
            "/System".into(),
            "/System/**".into(),
            "/Library".into(),
            "/Library/**".into(),
            "/usr".into(),
            "/usr/**".into(),
            "/bin".into(),
            "/bin/**".into(),
            "/sbin".into(),
            "/sbin/**".into(),
            "/etc".into(),
            "/etc/**".into(),
            "/var".into(),
            "/var/**".into(),
            "/private/etc".into(),
            "/private/etc/**".into(),
            "/private/var".into(),
            "/private/var/**".into(),
            "/Applications".into(),
            "/Applications/**".into(),
            "/opt".into(),
            "/opt/**".into(),
            "/Volumes".into(),
            "/Volumes/**".into(),
        ],
        block_traversal: false,
        block_hidden: false,
    })
}

/// Core rule: Read-only access to dotfiles.
fn core_dotfiles_protection() -> GuardrailRule {
    let home = homedir();

    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "core.dotfiles-protection".into(),
            name: "Dotfiles Protection".into(),
            description: "Prevents writing to dotfiles and config directories (read-only access)"
                .into(),
            severity: Severity::Block,
            scope: Scope::Global,
            tier: RuleTier::Core,
            tools: vec!["Write".into(), "Edit".into(), "Bash".into()],
            priority: 1000,
            enabled: true,
            tags: vec!["security".into(), "config-protection".into()],
        },
        path_arguments: vec!["file_path".into(), "path".into(), "command".into()],
        protected_paths: vec![
            format!("{home}/.ssh"),
            format!("{home}/.ssh/**"),
            format!("{home}/.gnupg"),
            format!("{home}/.gnupg/**"),
            format!("{home}/.aws"),
            format!("{home}/.aws/**"),
            format!("{home}/.config"),
            format!("{home}/.config/**"),
            format!("{home}/.zshrc"),
            format!("{home}/.bashrc"),
            format!("{home}/.bash_profile"),
            format!("{home}/.zprofile"),
            format!("{home}/.gitconfig"),
            format!("{home}/.npmrc"),
            format!("{home}/.kube"),
            format!("{home}/.kube/**"),
            format!("{home}/.docker"),
            format!("{home}/.docker/**"),
        ],
        block_traversal: false,
        block_hidden: false,
    })
}

/// Standard rule: Block path traversal in filesystem operations.
fn path_traversal() -> GuardrailRule {
    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "path.traversal".into(),
            name: "Path Traversal".into(),
            description: "Blocks path traversal sequences (..) in file paths".into(),
            severity: Severity::Block,
            scope: Scope::Tool,
            tier: RuleTier::Standard,
            tools: vec!["Write".into(), "Edit".into(), "Read".into()],
            priority: 800,
            enabled: true,
            tags: vec!["security".into(), "filesystem".into()],
        },
        path_arguments: vec!["file_path".into(), "path".into()],
        protected_paths: vec![],
        block_traversal: true,
        block_hidden: false,
    })
}

/// Standard rule: Block hidden directory creation.
fn path_hidden_mkdir() -> GuardrailRule {
    GuardrailRule::Path(PathRule {
        base: RuleBase {
            id: "path.hidden-mkdir".into(),
            name: "Hidden Directory Creation".into(),
            description: "Blocks creation of hidden directories via mkdir".into(),
            severity: Severity::Block,
            scope: Scope::Tool,
            tier: RuleTier::Standard,
            tools: vec!["Bash".into()],
            priority: 700,
            enabled: true,
            tags: vec!["filesystem".into()],
        },
        path_arguments: vec!["command".into()],
        protected_paths: vec![],
        block_traversal: false,
        block_hidden: true,
    })
}

/// Standard rule: Enforce bash timeout limits (10 minutes max).
fn bash_timeout() -> GuardrailRule {
    GuardrailRule::Resource(ResourceRule {
        base: RuleBase {
            id: "bash.timeout".into(),
            name: "Bash Timeout Limit".into(),
            description: "Enforces maximum timeout for bash commands (10 minutes)".into(),
            severity: Severity::Block,
            scope: Scope::Tool,
            tier: RuleTier::Standard,
            tools: vec!["Bash".into()],
            priority: 500,
            enabled: true,
            tags: vec!["resource-limits".into()],
        },
        target_argument: "timeout".into(),
        max_value: Some(600_000.0), // 10 minutes
        min_value: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_core_rule() {
        assert!(is_core_rule("core.destructive-commands"));
        assert!(is_core_rule("core.tron-no-delete"));
        assert!(is_core_rule("core.tron-app-protection"));
        assert!(is_core_rule("core.tron-db-protection"));
        assert!(is_core_rule("core.tron-auth-protection"));
        assert!(is_core_rule("core.synology-drive-protection"));
        assert!(is_core_rule("core.system-protection"));
        assert!(is_core_rule("core.dotfiles-protection"));
        assert!(!is_core_rule("path.traversal"));
        assert!(!is_core_rule("custom.my-rule"));
    }

    #[test]
    fn test_default_rules_count() {
        let rules = default_rules();
        assert_eq!(rules.len(), 11); // 8 core + 3 standard
    }

    #[test]
    fn test_all_core_rules_have_priority_1000() {
        let rules = default_rules();
        for rule in &rules {
            if rule.base().tier == RuleTier::Core {
                assert_eq!(
                    rule.base().priority,
                    1000,
                    "Core rule {} should have priority 1000",
                    rule.base().id
                );
            }
        }
    }

    #[test]
    fn test_all_core_rules_are_block_severity() {
        let rules = default_rules();
        for rule in &rules {
            if rule.base().tier == RuleTier::Core {
                assert_eq!(
                    rule.base().severity,
                    Severity::Block,
                    "Core rule {} should have block severity",
                    rule.base().id
                );
            }
        }
    }

    #[test]
    fn test_all_core_rules_are_enabled() {
        let rules = default_rules();
        for rule in &rules {
            if rule.base().tier == RuleTier::Core {
                assert!(
                    rule.base().enabled,
                    "Core rule {} should be enabled",
                    rule.base().id
                );
            }
        }
    }

    // ── system-protection tests ──────────────────────────────────

    use super::super::types::EvaluationContext;

    fn make_ctx(tool: &str, args: serde_json::Value) -> EvaluationContext {
        EvaluationContext {
            tool_name: tool.to_string(),
            tool_arguments: args,
            session_id: None,
            tool_call_id: None,
        }
    }

    fn find_rule(id: &str) -> GuardrailRule {
        default_rules()
            .into_iter()
            .find(|r| r.base().id == id)
            .unwrap()
    }

    #[test]
    fn system_protection_blocks_write_to_usr() {
        let rule = find_rule("core.system-protection");
        let ctx = make_ctx("Write", serde_json::json!({"file_path": "/usr/local/bin/test"}));
        let result = rule.evaluate(&ctx, None);
        assert!(result.triggered, "Write to /usr should be blocked");
    }

    #[test]
    fn system_protection_blocks_write_to_etc() {
        let rule = find_rule("core.system-protection");
        let ctx = make_ctx("Edit", serde_json::json!({"file_path": "/etc/hosts"}));
        let result = rule.evaluate(&ctx, None);
        assert!(result.triggered, "Write to /etc should be blocked");
    }

    #[test]
    fn system_protection_allows_tmp() {
        let rule = find_rule("core.system-protection");
        let ctx = make_ctx("Write", serde_json::json!({"file_path": "/tmp/scratch.txt"}));
        let result = rule.evaluate(&ctx, None);
        assert!(!result.triggered, "Write to /tmp should be allowed");
    }

    #[test]
    fn system_protection_blocks_bash_redirect_to_etc() {
        let rule = find_rule("core.system-protection");
        let ctx = make_ctx("Bash", serde_json::json!({"command": "echo test > /etc/hosts"}));
        let result = rule.evaluate(&ctx, None);
        assert!(result.triggered, "Bash redirect to /etc should be blocked");
    }

    // ── dotfiles-protection tests ────────────────────────────────

    #[test]
    fn dotfiles_blocks_write_to_ssh() {
        let rule = find_rule("core.dotfiles-protection");
        let home = homedir();
        let ctx = make_ctx(
            "Write",
            serde_json::json!({"file_path": format!("{home}/.ssh/config")}),
        );
        let result = rule.evaluate(&ctx, None);
        assert!(result.triggered, "Write to ~/.ssh should be blocked");
    }

    #[test]
    fn dotfiles_does_not_apply_to_read_tool() {
        let rule = find_rule("core.dotfiles-protection");
        assert!(
            !rule.base().tools.contains(&"Read".to_string()),
            "Dotfiles rule should not apply to Read tool"
        );
    }

    #[test]
    fn dotfiles_allows_write_to_workspace() {
        let rule = find_rule("core.dotfiles-protection");
        let home = homedir();
        let ctx = make_ctx(
            "Write",
            serde_json::json!({"file_path": format!("{home}/Workspace/project/file.rs")}),
        );
        let result = rule.evaluate(&ctx, None);
        assert!(!result.triggered, "Write to ~/Workspace should be allowed");
    }

    #[test]
    fn dotfiles_allows_write_to_desktop() {
        let rule = find_rule("core.dotfiles-protection");
        let home = homedir();
        let ctx = make_ctx(
            "Write",
            serde_json::json!({"file_path": format!("{home}/Desktop/file.txt")}),
        );
        let result = rule.evaluate(&ctx, None);
        assert!(!result.triggered, "Write to ~/Desktop should be allowed");
    }

    #[test]
    fn dotfiles_allows_write_to_tron_workspace() {
        let rule = find_rule("core.dotfiles-protection");
        let home = homedir();
        let ctx = make_ctx(
            "Write",
            serde_json::json!({"file_path": format!("{home}/.tron/workspace/scratch/file.txt")}),
        );
        let result = rule.evaluate(&ctx, None);
        assert!(
            !result.triggered,
            "Write to ~/.tron/workspace should be allowed"
        );
    }
}
