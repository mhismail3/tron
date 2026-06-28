use serde_json::Value;

use crate::shared::server::errors::CapabilityError;

const FORBIDDEN_FIELDS: &[&str] = &[
    "html",
    "rawHtml",
    "pageHtml",
    "pageDump",
    "browserLog",
    "browserLogs",
    "consoleLog",
    "networkLog",
    "cookies",
    "cookie",
    "credential",
    "credentials",
    "authorization",
    "rawSource",
    "sourceCode",
    "code",
    "prompt",
    "messages",
    "command",
    "rawCommand",
    "shell",
    "argv",
    "env",
    "fileContents",
    "rawFileContents",
    "absolutePath",
    "localPath",
    "path",
    "paths",
    "grantId",
    "authorityId",
    "rawGrantId",
    "rawAuthorityId",
    "debugPayload",
    "chainOfThought",
    "packageManagerOutput",
    "rawDependencyArtifact",
];

pub(super) fn reject_unsafe_payload(payload: &Value) -> Result<(), CapabilityError> {
    reject_forbidden_fields(payload)?;
    reject_unsafe_strings(payload)
}

fn reject_forbidden_fields(value: &Value) -> Result<(), CapabilityError> {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                if FORBIDDEN_FIELDS
                    .iter()
                    .any(|forbidden| forbidden.eq_ignore_ascii_case(key))
                {
                    return Err(invalid(format!(
                        "{key} is not accepted; web research records store bounded metadata and refs only"
                    )));
                }
                reject_forbidden_fields(child)?;
            }
        }
        Value::Array(items) => {
            for child in items {
                reject_forbidden_fields(child)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn reject_unsafe_strings(value: &Value) -> Result<(), CapabilityError> {
    match value {
        Value::String(text) => {
            reject_secret_like("payload", text)?;
            reject_prompt_like("payload", text)?;
            reject_path_like("payload", text)
        }
        Value::Array(items) => {
            for child in items {
                reject_unsafe_strings(child)?;
            }
            Ok(())
        }
        Value::Object(object) => {
            for child in object.values() {
                reject_unsafe_strings(child)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

pub(super) fn reject_path_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let trimmed = value.trim();
    let lower = trimmed.to_ascii_lowercase();
    if trimmed == "/"
        || trimmed.starts_with('/')
        || trimmed.starts_with('~')
        || trimmed.starts_with("./")
        || trimmed.contains("..")
        || trimmed.contains('\\')
        || lower.contains("packages/agent/skills")
        || lower.contains("/users/")
    {
        return Err(invalid(format!(
            "{field} must not contain unsafe path-like material"
        )));
    }
    Ok(())
}

pub(super) fn reject_secret_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("bearer ")
        || lowered.starts_with("sk-")
        || lowered.starts_with("ghp_")
        || lowered.starts_with("xox")
        || lowered.contains("api_key")
        || lowered.contains("apikey")
        || lowered.contains("password=")
        || lowered.contains("secret=")
        || lowered.contains("authorization:")
        || lowered.contains("token:")
        || lowered.contains("\"token\"")
        || lowered.contains("grant-")
        || lowered.contains("grant_")
        || lowered.contains("grant:")
        || looks_like_email(value.trim())
    {
        return Err(invalid(format!(
            "{field} must not contain credential-like material"
        )));
    }
    Ok(())
}

pub(super) fn reject_provider_visible_token_like(
    field: &str,
    value: &str,
) -> Result<(), CapabilityError> {
    if contains_github_token_like(value)
        || contains_jwt_like(value)
        || contains_aws_access_key_like(value)
    {
        return Err(invalid(format!(
            "{field} must not contain token-like material"
        )));
    }
    Ok(())
}

fn contains_github_token_like(value: &str) -> bool {
    let lowered = value.to_ascii_lowercase();
    ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"]
        .iter()
        .any(|prefix| token_like_run_after_prefix(&lowered, prefix, 20))
}

fn token_like_run_after_prefix(value: &str, prefix: &str, min_suffix_len: usize) -> bool {
    value.match_indices(prefix).any(|(index, _)| {
        let after_prefix = &value[index + prefix.len()..];
        after_prefix
            .bytes()
            .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
            .count()
            >= min_suffix_len
    })
}

fn contains_jwt_like(value: &str) -> bool {
    value.match_indices("eyJ").any(|(index, _)| {
        let candidate = &value[index..];
        let mut parts = candidate.splitn(3, '.');
        let (Some(header), Some(payload), Some(signature_and_suffix)) =
            (parts.next(), parts.next(), parts.next())
        else {
            return false;
        };
        if !is_base64url_part(header) || !is_base64url_part(payload) {
            return false;
        }
        signature_and_suffix
            .bytes()
            .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
            .count()
            >= 8
    })
}

fn is_base64url_part(part: &str) -> bool {
    part.len() >= 8
        && part
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn contains_aws_access_key_like(value: &str) -> bool {
    value.as_bytes().windows(20).any(|window| {
        matches!(&window[..4], b"AKIA" | b"ASIA")
            && window
                .iter()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
    })
}

pub(super) fn reject_prompt_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("ignore previous")
        || lowered.contains("system prompt")
        || lowered.contains("hidden chain")
        || lowered.contains("chain-of-thought")
        || lowered.contains("developer message")
    {
        return Err(invalid(format!(
            "{field} must not contain prompt-injection-like material"
        )));
    }
    Ok(())
}

fn looks_like_email(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && domain.contains('.')
        && domain
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
