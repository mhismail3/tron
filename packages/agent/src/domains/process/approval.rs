//! Conditional approval policy for process-owned capabilities.
//!
//! `process::run` is intentionally a broad capability: it can be a harmless
//! read such as `date`, a normal developer check such as `cargo test`, or a
//! host mutation such as deleting files. The contract therefore must not carry
//! a blanket approval requirement. This module owns the payload-sensitive gate
//! used by `capability::execute` before dispatching to the process worker.

use serde_json::Value;

/// Return true when a `process::run` payload should pause for user approval.
pub(crate) fn run_requires_approval(payload: &Value) -> bool {
    let Some(command) = payload.get("command").and_then(Value::as_str) else {
        // Schema validation reports missing command before approval creation.
        return false;
    };
    command_requires_approval(command)
}

fn command_requires_approval(command: &str) -> bool {
    let normalized = command.trim();
    if normalized.is_empty() {
        return false;
    }

    let lower = normalized.to_ascii_lowercase();
    if has_redirection_or_mutating_pipe(&lower) {
        return true;
    }

    let tokens = shellish_tokens(&lower);
    if tokens.is_empty() {
        return false;
    }

    if tokens
        .iter()
        .any(|token| HIGH_RISK_TOKENS.contains(&token.as_str()))
    {
        return true;
    }

    if has_high_risk_git_operation(&tokens) || has_high_risk_package_operation(&tokens) {
        return true;
    }

    false
}

fn has_redirection_or_mutating_pipe(command: &str) -> bool {
    // Redirects and `tee` create or mutate files through the shell. Treat them
    // as approval-gated even when the command prefix is otherwise innocuous.
    command.contains(">")
        || command.contains(">>")
        || command.contains("2>")
        || command.split(['|', ';', '&']).any(|segment| {
            shellish_tokens(segment)
                .first()
                .is_some_and(|first| first == "tee")
        })
}

fn has_high_risk_git_operation(tokens: &[String]) -> bool {
    tokens
        .windows(2)
        .any(|pair| pair[0] == "git" && HIGH_RISK_GIT_SUBCOMMANDS.contains(&pair[1].as_str()))
}

fn has_high_risk_package_operation(tokens: &[String]) -> bool {
    tokens.windows(2).any(|pair| {
        matches!(pair[0].as_str(), "npm" | "pnpm" | "yarn" | "bun")
            && HIGH_RISK_PACKAGE_SUBCOMMANDS.contains(&pair[1].as_str())
    }) || tokens
        .windows(2)
        .any(|pair| pair[0] == "brew" && pair[1] == "install")
        || tokens
            .windows(2)
            .any(|pair| pair[0] == "cargo" && pair[1] == "install")
        || tokens
            .windows(3)
            .any(|triple| triple[0] == "pip" && triple[1] == "install" && triple[2] != "--dry-run")
}

fn shellish_tokens(command: &str) -> Vec<String> {
    command
        .split(|ch: char| ch.is_whitespace() || matches!(ch, ';' | '&' | '|' | '(' | ')' | '`'))
        .map(|token| {
            token.trim_matches(|ch: char| {
                matches!(ch, '"' | '\'' | ',' | ':' | '[' | ']' | '{' | '}')
            })
        })
        .filter(|token| !token.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

const HIGH_RISK_TOKENS: &[&str] = &[
    "sudo",
    "su",
    "rm",
    "rmdir",
    "mv",
    "chmod",
    "chown",
    "chgrp",
    "dd",
    "mkfs",
    "diskutil",
    "launchctl",
    "killall",
    "pkill",
    "shutdown",
    "reboot",
    "osascript",
    "security",
    "eval",
];

const HIGH_RISK_GIT_SUBCOMMANDS: &[&str] = &[
    "add", "commit", "push", "reset", "checkout", "switch", "merge", "rebase", "clean", "tag",
    "stash",
];

const HIGH_RISK_PACKAGE_SUBCOMMANDS: &[&str] =
    &["install", "add", "remove", "uninstall", "link", "publish"];

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn date_and_read_only_commands_do_not_require_approval() {
        for command in [
            "date",
            "date +%Y-%m-%d",
            "pwd",
            "git status --short",
            "rg process::run packages/agent/src",
            "cargo test capability_invocation",
        ] {
            assert!(
                !run_requires_approval(&json!({ "command": command })),
                "{command} should not require approval"
            );
        }
    }

    #[test]
    fn mutating_or_privileged_commands_require_approval() {
        for command in [
            "sudo date",
            "rm -rf target",
            "git commit -m test",
            "git reset --hard",
            "npm install left-pad",
            "echo secret > file.txt",
            "cat file | tee output.txt",
        ] {
            assert!(
                run_requires_approval(&json!({ "command": command })),
                "{command} should require approval"
            );
        }
    }

    #[test]
    fn missing_command_is_left_to_schema_validation() {
        assert!(!run_requires_approval(&json!({})));
    }
}
