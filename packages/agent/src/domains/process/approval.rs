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

    !lower
        .split([';', '&', '|'])
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .all(segment_is_low_risk)
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

fn segment_is_low_risk(segment: &str) -> bool {
    let tokens = shellish_tokens(segment);
    let Some(command) = tokens.first().map(String::as_str) else {
        return true;
    };

    if LOW_RISK_PURE_COMMANDS.contains(&command) {
        return true;
    }

    match command {
        "find" => find_invocation_is_read_only(&tokens),
        "git" => tokens
            .get(1)
            .is_some_and(|subcommand| git_subcommand_is_read_only(subcommand, &tokens)),
        "cargo" => tokens
            .get(1)
            .is_some_and(|subcommand| cargo_subcommand_is_low_risk(subcommand, &tokens)),
        "npm" | "pnpm" | "yarn" | "bun" => tokens
            .get(1)
            .is_some_and(|subcommand| LOW_RISK_PACKAGE_SUBCOMMANDS.contains(&subcommand.as_str())),
        "swift" => tokens
            .get(1)
            .is_some_and(|subcommand| LOW_RISK_BUILD_SUBCOMMANDS.contains(&subcommand.as_str())),
        "xcodebuild" => tokens
            .iter()
            .any(|token| matches!(token.as_str(), "build" | "build-for-testing" | "test")),
        "make" => tokens
            .get(1)
            .is_some_and(|subcommand| LOW_RISK_BUILD_SUBCOMMANDS.contains(&subcommand.as_str())),
        _ => tokens
            .get(1)
            .is_some_and(|arg| matches!(arg.as_str(), "--version" | "-v" | "-V" | "version")),
    }
}

fn find_invocation_is_read_only(tokens: &[String]) -> bool {
    !tokens.iter().any(|token| {
        matches!(
            token.as_str(),
            "-delete" | "-exec" | "-execdir" | "-ok" | "-okdir" | "-fdelete"
        )
    })
}

fn git_subcommand_is_read_only(subcommand: &str, tokens: &[String]) -> bool {
    if !LOW_RISK_GIT_SUBCOMMANDS.contains(&subcommand) {
        return false;
    }
    match subcommand {
        "branch" => !tokens.iter().any(|token| {
            matches!(
                token.as_str(),
                "-d" | "-D" | "--delete" | "-m" | "-M" | "--move" | "-c" | "-C" | "--copy"
            )
        }),
        "remote" => !tokens.iter().any(|token| {
            matches!(
                token.as_str(),
                "add" | "remove" | "rm" | "rename" | "set-url" | "prune" | "update"
            )
        }),
        _ => true,
    }
}

fn cargo_subcommand_is_low_risk(subcommand: &str, tokens: &[String]) -> bool {
    if subcommand == "fmt" {
        return tokens.iter().any(|token| token == "--check");
    }
    LOW_RISK_CARGO_SUBCOMMANDS.contains(&subcommand)
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

const LOW_RISK_PURE_COMMANDS: &[&str] = &[
    "date", "pwd", "ls", "rg", "grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "stat",
    "file", "du", "df", "echo", "printf", "true", "false", "sleep", "uname", "whoami", "id",
    "hostname", "which", "whereis",
];

const LOW_RISK_GIT_SUBCOMMANDS: &[&str] = &[
    "status",
    "log",
    "diff",
    "show",
    "branch",
    "rev-parse",
    "ls-files",
    "grep",
    "remote",
];

const LOW_RISK_CARGO_SUBCOMMANDS: &[&str] = &[
    "test", "check", "clippy", "fmt", "build", "metadata", "version",
];

const LOW_RISK_PACKAGE_SUBCOMMANDS: &[&str] = &["list", "ls", "version"];

const LOW_RISK_BUILD_SUBCOMMANDS: &[&str] = &["test", "check", "build", "build-for-testing"];

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
            "git branch --show-current",
            "git remote -v",
            "rg process::run packages/agent/src",
            "find packages/agent/src -maxdepth 2 -name '*.rs'",
            "cargo test capability_invocation",
            "cargo fmt -- --check",
            "npm list",
            "xcodebuild build-for-testing -scheme Tron",
            "echo hello",
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
            "git branch -D old-work",
            "git remote add origin https://example.invalid/repo.git",
            "npm install left-pad",
            "npm run build",
            "npm test",
            "echo secret > file.txt",
            "cat file | tee output.txt",
            "find . -delete",
            "find . -exec rm {} ;",
            "cargo fmt",
            "touch file.txt",
            "mkdir output",
            "cp a b",
            "python -c 'open(\"x\", \"w\").write(\"no\")'",
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
