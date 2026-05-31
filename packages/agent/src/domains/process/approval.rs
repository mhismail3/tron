//! Conditional approval policy for process-owned capabilities.
//!
//! `process::run` is intentionally a broad capability: it can be a harmless
//! read such as `date`, a normal developer check such as `cargo test`, or a
//! host mutation such as deleting files. The contract therefore must not carry
//! a blanket approval requirement. This module owns the payload-sensitive gate
//! used by `capability::execute` before dispatching to the process worker.

use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Component, Path};

const READ_ONLY_LOW_RISK_MESSAGE: &str = "process::run read_only commands must be proven low-risk by the classifier; use executionMode=sandbox_materialized with expectedOutputs for mutating or unknown commands. To verify sandbox materialized output, use the returned materializedOutputs summary or read the returned materialized file path/resource instead of running an unknown interpreter";
const SANDBOX_OUTPUTS_REQUIRED_MESSAGE: &str = "process::run sandbox_materialized commands require expectedOutputs: [{\"path\":\"<relative-output-path>\"}] before approval";
const SANDBOX_OUTPUT_PATH_RELATIVE_MESSAGE: &str = "process::run sandbox_materialized expectedOutputs[].path must be a relative path inside the process sandbox; do not use absolute host paths, home-relative paths, or parent-directory escapes";
const SANDBOX_COMMAND_OUTPUT_PATH_MESSAGE: &str = "process::run sandbox_materialized command write targets must be declared relative expectedOutputs paths; do not write absolute host paths, home-relative paths, parent-directory escapes, shell-expanded paths, or undeclared output paths";
const SANDBOX_OUTPUT_COLLISION_MESSAGE: &str = "process::run sandbox_materialized expectedOutputs must not declare duplicate output paths or duplicate targetPath destinations";

/// Return true when a `process::run` payload should pause for user approval.
pub(crate) fn run_requires_approval(payload: &Value) -> bool {
    let Some(command) = payload.get("command").and_then(Value::as_str) else {
        // Schema validation reports missing command before approval creation.
        return false;
    };
    command_requires_approval(command)
}

/// Reject impossible process payloads before creating an approval request.
pub(crate) fn validate_run_payload_before_approval(payload: &Value) -> Result<(), &'static str> {
    if payload.get("executionMode").and_then(Value::as_str) == Some("read_only")
        && run_requires_approval(payload)
    {
        return Err(READ_ONLY_LOW_RISK_MESSAGE);
    }
    if payload.get("executionMode").and_then(Value::as_str) == Some("sandbox_materialized")
        && payload
            .get("expectedOutputs")
            .and_then(Value::as_array)
            .is_none_or(Vec::is_empty)
    {
        return Err(SANDBOX_OUTPUTS_REQUIRED_MESSAGE);
    }
    validate_sandbox_output_paths(payload)?;
    validate_sandbox_command_write_targets(payload)?;
    Ok(())
}

/// Stable policy message for sandbox output path shape errors.
pub(crate) fn sandbox_output_path_relative_message() -> &'static str {
    SANDBOX_OUTPUT_PATH_RELATIVE_MESSAGE
}

/// Return true when a validated `process::run` payload should pause for approval.
pub(crate) fn run_execution_requires_approval(payload: &Value) -> bool {
    validate_run_payload_before_approval(payload).is_ok()
        && payload.get("executionMode").and_then(Value::as_str) == Some("sandbox_materialized")
        && run_requires_approval(payload)
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

fn validate_sandbox_output_paths(payload: &Value) -> Result<(), &'static str> {
    if payload.get("executionMode").and_then(Value::as_str) != Some("sandbox_materialized") {
        return Ok(());
    }
    let Some(outputs) = payload.get("expectedOutputs").and_then(Value::as_array) else {
        return Ok(());
    };
    let mut output_paths = BTreeSet::new();
    let mut target_paths = BTreeSet::new();
    for output in outputs {
        let Some(path) = output
            .get("path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|path| !path.is_empty())
        else {
            return Err(SANDBOX_OUTPUTS_REQUIRED_MESSAGE);
        };
        let path = Path::new(path);
        if path_text_is_home_relative(path.to_string_lossy().as_ref())
            || path.is_absolute()
            || path.components().any(|component| {
                matches!(
                    component,
                    Component::ParentDir | Component::Prefix(_) | Component::RootDir
                )
            })
        {
            return Err(SANDBOX_OUTPUT_PATH_RELATIVE_MESSAGE);
        }
        let path_text = path.to_string_lossy();
        let Some(normalized_path) = normalized_relative_path(path_text.as_ref()) else {
            return Err(SANDBOX_OUTPUT_PATH_RELATIVE_MESSAGE);
        };
        if !output_paths.insert(normalized_path.clone()) {
            return Err(SANDBOX_OUTPUT_COLLISION_MESSAGE);
        }
        let target = output
            .get("targetPath")
            .and_then(Value::as_str)
            .unwrap_or(path_text.as_ref());
        if let Some(normalized_target) = normalized_relative_path(target)
            && !target_paths.insert(normalized_target)
        {
            return Err(SANDBOX_OUTPUT_COLLISION_MESSAGE);
        }
    }
    Ok(())
}

fn validate_sandbox_command_write_targets(payload: &Value) -> Result<(), &'static str> {
    if payload.get("executionMode").and_then(Value::as_str) != Some("sandbox_materialized") {
        return Ok(());
    }
    let Some(command) = payload.get("command").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(outputs) = payload.get("expectedOutputs").and_then(Value::as_array) else {
        return Ok(());
    };
    let declared = outputs
        .iter()
        .filter_map(|output| output.get("path").and_then(Value::as_str))
        .map(normalized_relative_path)
        .collect::<Option<BTreeSet<_>>>()
        .ok_or(SANDBOX_COMMAND_OUTPUT_PATH_MESSAGE)?;
    if declared.is_empty() {
        return Ok(());
    }
    for target in command_write_targets(command) {
        let Some(normalized) = normalized_relative_path(&target) else {
            return Err(SANDBOX_COMMAND_OUTPUT_PATH_MESSAGE);
        };
        if !declared.contains(&normalized) {
            return Err(SANDBOX_COMMAND_OUTPUT_PATH_MESSAGE);
        }
    }
    Ok(())
}

fn command_write_targets(command: &str) -> Vec<String> {
    let tokens = write_target_tokens(command);
    let mut targets = Vec::new();
    let mut index = 0usize;
    while index < tokens.len() {
        let token = tokens[index].as_str();
        if let Some((target, consumed_next)) =
            redirection_target(token, tokens.get(index + 1).map(String::as_str))
        {
            if file_redirection_target(&target) {
                targets.push(clean_shell_path_token(&target));
            }
            index += if consumed_next { 2 } else { 1 };
            continue;
        }
        if token == "tee" {
            index += 1;
            while index < tokens.len() {
                let candidate = tokens[index].as_str();
                if shell_control_token(candidate) {
                    break;
                }
                if candidate.starts_with('-') {
                    index += 1;
                    continue;
                }
                targets.push(clean_shell_path_token(candidate));
                index += 1;
            }
            continue;
        }
        index += 1;
    }
    targets
}

fn write_target_tokens(command: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut token = String::new();
    let mut quote = None;
    let mut chars = command.chars().peekable();
    while let Some(ch) = chars.next() {
        if let Some(quote_ch) = quote {
            if ch == quote_ch {
                quote = None;
            } else {
                token.push(ch);
            }
            continue;
        }
        if matches!(ch, '"' | '\'' | '`') {
            quote = Some(ch);
            continue;
        }
        if ch.is_whitespace() || matches!(ch, '(' | ')') {
            if !token.is_empty() {
                tokens.push(std::mem::take(&mut token));
            }
            continue;
        }
        if matches!(ch, '|' | '&' | ';') {
            if !token.is_empty() {
                tokens.push(std::mem::take(&mut token));
            }
            if chars.peek() == Some(&ch) {
                chars.next();
                tokens.push(format!("{ch}{ch}"));
            } else {
                tokens.push(ch.to_string());
            }
            continue;
        }
        token.push(ch);
    }
    if !token.is_empty() {
        tokens.push(token);
    }
    tokens
}

fn redirection_target(token: &str, next: Option<&str>) -> Option<(String, bool)> {
    for operator in ["&>>", "&>", "2>>", "2>", "1>>", "1>", ">>", ">"] {
        if token == operator {
            return next.map(|target| (target.to_owned(), true));
        }
        if let Some(rest) = token.strip_prefix(operator)
            && !rest.is_empty()
        {
            return Some((rest.to_owned(), false));
        }
    }
    token.rfind('>').and_then(|position| {
        let target = &token[position + 1..];
        (!target.is_empty()).then(|| (target.to_owned(), false))
    })
}

fn file_redirection_target(target: &str) -> bool {
    let trimmed = target.trim();
    !trimmed.is_empty() && !trimmed.starts_with('&')
}

fn shell_control_token(token: &str) -> bool {
    matches!(token, "|" | "||" | "&" | "&&" | ";" | ";;")
}

fn clean_shell_path_token(token: &str) -> String {
    token
        .trim()
        .trim_matches(|ch: char| matches!(ch, '"' | '\'' | '`'))
        .trim_end_matches(|ch: char| matches!(ch, ';' | ','))
        .to_owned()
}

fn normalized_relative_path(path: &str) -> Option<String> {
    let path = clean_shell_path_token(path);
    if path.is_empty()
        || path.starts_with('~')
        || path.starts_with('$')
        || path.contains("://")
        || path
            .chars()
            .any(|ch| matches!(ch, '*' | '?' | '[' | ']' | '{' | '}'))
    {
        return None;
    }
    let path = Path::new(&path);
    if path.is_absolute() {
        return None;
    }
    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().to_string()),
            Component::CurDir => {}
            Component::ParentDir | Component::Prefix(_) | Component::RootDir => return None,
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

fn path_text_is_home_relative(path: &str) -> bool {
    path.starts_with('~')
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
    tokens.iter().enumerate().any(|(index, token)| {
        token == "git"
            && git_effective_subcommand(&tokens[index..])
                .is_some_and(|subcommand| HIGH_RISK_GIT_SUBCOMMANDS.contains(&subcommand))
    })
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
        "cd" => cd_invocation_is_low_risk(&tokens),
        "find" => find_invocation_is_read_only(&tokens),
        "sed" => sed_invocation_is_read_only(&tokens),
        "git" => git_effective_subcommand(&tokens)
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

fn cd_invocation_is_low_risk(tokens: &[String]) -> bool {
    matches!(tokens.len(), 1 | 2)
}

fn find_invocation_is_read_only(tokens: &[String]) -> bool {
    !tokens.iter().any(|token| {
        matches!(
            token.as_str(),
            "-delete" | "-exec" | "-execdir" | "-ok" | "-okdir" | "-fdelete"
        )
    })
}

fn sed_invocation_is_read_only(tokens: &[String]) -> bool {
    let mut scripts = Vec::new();
    let mut index = 1;
    let mut script_seen = false;
    while index < tokens.len() {
        let token = tokens[index].as_str();
        if token == "-i" || token.starts_with("-i.") || token == "--in-place" {
            return false;
        }
        if token == "-f" || token == "--file" || token.starts_with("--file=") {
            return false;
        }
        if token == "-e" || token == "--expression" {
            let Some(script) = tokens.get(index + 1) else {
                return false;
            };
            scripts.push(script.as_str());
            script_seen = true;
            index += 2;
            continue;
        }
        if let Some(script) = token.strip_prefix("-e") {
            if script.is_empty() {
                return false;
            }
            scripts.push(script);
            script_seen = true;
            index += 1;
            continue;
        }
        if let Some(script) = token.strip_prefix("--expression=") {
            if script.is_empty() {
                return false;
            }
            scripts.push(script);
            script_seen = true;
            index += 1;
            continue;
        }
        if token.starts_with('-') {
            index += 1;
            continue;
        }
        if !script_seen {
            scripts.push(token);
            script_seen = true;
        }
        index += 1;
    }

    !scripts.is_empty() && scripts.iter().all(|script| sed_script_is_read_only(script))
}

fn sed_script_is_read_only(script: &str) -> bool {
    script
        .split([';', '\n'])
        .map(str::trim)
        .filter(|command| !command.is_empty())
        .all(|command| {
            let command = command.trim_start_matches(|ch: char| {
                ch.is_ascii_digit() || matches!(ch, '$' | ',' | '!' | '+' | '-' | '~')
            });
            let Some(command_char) = command.chars().find(|ch| ch.is_ascii_alphabetic()) else {
                return true;
            };
            command_char != 'w' && !sed_substitution_writes(command)
        })
}

fn sed_substitution_writes(command: &str) -> bool {
    let mut chars = command.chars();
    if chars.next() != Some('s') {
        return false;
    }
    let Some(delimiter) = chars.next() else {
        return false;
    };
    let mut escaped = false;
    let mut delimiters_seen = 0;
    for ch in chars {
        if escaped {
            escaped = false;
            continue;
        }
        if ch == '\\' {
            escaped = true;
            continue;
        }
        if ch == delimiter {
            delimiters_seen += 1;
            if delimiters_seen == 2 {
                continue;
            }
        }
        if delimiters_seen >= 2 && ch == 'w' {
            return true;
        }
    }
    false
}

fn git_effective_subcommand(tokens: &[String]) -> Option<&str> {
    if tokens.first().map(String::as_str) != Some("git") {
        return None;
    }
    let mut index = 1;
    while index < tokens.len() {
        let token = tokens[index].as_str();
        if token == "--version" || token == "version" {
            return Some("version");
        }
        if matches!(token, "--no-pager" | "--paginate" | "--bare") {
            index += 1;
            continue;
        }
        if matches!(token, "-c" | "--git-dir" | "--work-tree") {
            index += 2;
            continue;
        }
        if token.starts_with("--git-dir=") || token.starts_with("--work-tree=") {
            index += 1;
            continue;
        }
        if token.starts_with('-') {
            index += 1;
            continue;
        }
        return Some(token);
    }
    None
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
    "hostname", "which", "whereis", "test",
];

const LOW_RISK_GIT_SUBCOMMANDS: &[&str] = &[
    "status",
    "log",
    "diff",
    "show",
    "branch",
    "version",
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
            "git -C . status --short",
            "git --no-pager log --oneline -3",
            "git branch --show-current",
            "git remote -v",
            "rg process::run packages/agent/src",
            "find packages/agent/src -maxdepth 2 -name '*.rs'",
            "cargo test capability_invocation",
            "cargo fmt -- --check",
            "npm list",
            "xcodebuild build-for-testing -scheme Tron",
            "echo hello",
            "test ! -e should_not_exist.txt",
            "test -f README.md",
            "sed -n '1,3p' README.md",
            "pwd && printf 'hi\n' && test ! -e should_not_exist.txt && test -f README.md && sed -n '1,3p' README.md",
            "cd . && git status --short && git log --oneline -3",
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
            "git -C /tmp reset --hard",
            "cd /tmp && git reset --hard",
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
            "sed -i '' 's/a/b/' README.md",
            "sed --in-place 's/a/b/' README.md",
            "sed -n '1,3w out.txt' README.md",
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

    #[test]
    fn missing_execution_mode_is_left_to_schema_validation() {
        let payload = json!({"command": "rm -rf target"});

        assert!(run_requires_approval(&payload));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn read_only_mutating_payload_is_invalid_before_approval() {
        let payload = json!({
            "command": "echo hi > should_not_exist.txt",
            "executionMode": "read_only"
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("sandbox_materialized"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_missing_outputs_is_invalid_before_approval() {
        let payload = json!({
            "command": "echo hi > result.txt",
            "executionMode": "sandbox_materialized"
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("expectedOutputs"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_absolute_output_path_is_invalid_before_approval() {
        let payload = json!({
            "command": "echo hi > /tmp/result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "/tmp/result.txt"}]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("relative path inside the process sandbox"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_home_relative_output_path_is_invalid_before_approval() {
        let payload = json!({
            "command": "echo hi > ~/.tron/result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "~/.tron/result.txt"}]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("home-relative paths"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_parent_output_path_is_invalid_before_approval() {
        let payload = json!({
            "command": "echo hi > ../result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "../result.txt"}]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("parent-directory escapes"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_home_relative_command_write_is_invalid_before_approval() {
        let payload = json!({
            "command": "printf 'hi\\n' > ~/.tron/workspace/reports/high-risk-test.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "reports/high-risk-test.txt"}]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("command write targets"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_undeclared_command_write_is_invalid_before_approval() {
        let payload = json!({
            "command": "printf 'hi\\n' > other.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt"}]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("command write targets"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_declared_nested_command_write_is_valid_before_approval() {
        let payload = json!({
            "command": "printf 'hi\\n' > reports/high-risk-test.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "reports/high-risk-test.txt"}]
        });

        assert_eq!(validate_run_payload_before_approval(&payload), Ok(()));
        assert!(run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_duplicate_output_path_is_invalid_before_approval() {
        let payload = json!({
            "command": "printf 'hi\\n' > result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [
                {"path": "result.txt"},
                {"path": "./result.txt"}
            ]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("duplicate"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_duplicate_target_path_is_invalid_before_approval() {
        let payload = json!({
            "command": "printf one > one.txt && printf two > two.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [
                {"path": "one.txt", "targetPath": "shared.txt"},
                {"path": "two.txt", "targetPath": "./shared.txt"}
            ]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("duplicate"));
        assert!(!run_execution_requires_approval(&payload));
    }

    #[test]
    fn sandbox_materialized_tee_target_must_be_declared() {
        let payload = json!({
            "command": "printf 'hi\\n' | tee leaked.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt"}]
        });

        let err = validate_run_payload_before_approval(&payload).unwrap_err();
        assert!(err.contains("command write targets"));
    }

    #[test]
    fn sandbox_materialized_declared_tee_pipeline_is_valid_before_approval() {
        let payload = json!({
            "command": "printf 'hi\\n' | tee reports/result.txt | wc -c",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "reports/result.txt"}]
        });

        assert_eq!(validate_run_payload_before_approval(&payload), Ok(()));
    }

    #[test]
    fn sandbox_materialized_mutating_payload_still_requires_approval() {
        let payload = json!({
            "command": "echo hi > result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt"}]
        });

        assert_eq!(validate_run_payload_before_approval(&payload), Ok(()));
        assert!(run_execution_requires_approval(&payload));
    }
}
