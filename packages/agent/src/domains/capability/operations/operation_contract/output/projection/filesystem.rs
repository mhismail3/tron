//! Operation-specific provider projection for filesystem reads.
//!
//! The filesystem domain returns bounded but still audit-rich result objects.
//! This boundary admits only the read evidence an agent needs to continue:
//! validated relative paths, bounded/redacted text or diff chunks, bounded
//! entry/match rows, and explicit source/provider truncation facts. Mutation
//! previews stay on the generic metadata projection so proposed bodies and
//! diffs are never echoed into provider context.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value, json};

use super::{copy_key, sanitize_provider_text};

const MAX_TEXT_CHUNKS: usize = 8;
const MAX_TEXT_CHUNK_BYTES: usize = 500;
const MAX_PREVIEW_BYTES: usize = 360;

struct TextProjection {
    value: Value,
    redaction_performed: bool,
    provider_truncated: bool,
}

struct TextChunk {
    text: String,
    byte_start: usize,
    line_start: usize,
    line_end: usize,
}

pub(super) fn project_evidence(operation: &str, details: &Value) -> Option<Value> {
    match operation {
        "filesystem_read" => project_read(details),
        "filesystem_list" => project_entries(details, "entries"),
        "filesystem_find" | "filesystem_glob" => project_entries(details, "matches"),
        "filesystem_search_text" => project_search(details),
        "filesystem_diff" => project_diff(details),
        // Write/edit/apply-patch intentionally retain the generic
        // metadata/resource-only projection owned by the parent module.
        _ => None,
    }
}

fn project_read(details: &Value) -> Option<Value> {
    let filesystem = details.get("filesystem")?;
    let file = filesystem.get("file")?;
    let mut projected = common_projection(details);
    let mut filesystem_projected = filesystem_header(filesystem);
    copy_safe_path(&mut filesystem_projected, filesystem);

    let mut file_projected = Map::new();
    for key in ["exists", "isBinary", "sizeBytes", "truncated"] {
        copy_key(&mut file_projected, file, key);
    }
    let source_truncated = file
        .get("truncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let text = file.get("content").and_then(Value::as_str);
    let content_projection = text_projection(text.unwrap_or_default(), source_truncated);
    let write_safe_from_projection = text.is_some()
        && !source_truncated
        && !content_projection.provider_truncated
        && !content_projection.redaction_performed;
    file_projected.insert(
        "contentHash".to_owned(),
        if write_safe_from_projection {
            file.get("contentHash").cloned().unwrap_or(Value::Null)
        } else {
            Value::Null
        },
    );
    file_projected.insert("contentProjection".to_owned(), content_projection.value);
    file_projected.insert("textAvailable".to_owned(), json!(text.is_some()));
    file_projected.insert(
        "writeSafeFromProjection".to_owned(),
        json!(write_safe_from_projection),
    );
    filesystem_projected.insert("file".to_owned(), Value::Object(file_projected));
    projected.insert("filesystem".to_owned(), Value::Object(filesystem_projected));
    Some(Value::Object(projected))
}

fn project_entries(details: &Value, collection_key: &str) -> Option<Value> {
    let filesystem = details.get("filesystem")?;
    let entries = filesystem
        .get(collection_key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let mut projected = common_projection(details);
    let mut filesystem_projected = filesystem_header(filesystem);
    copy_safe_path(&mut filesystem_projected, filesystem);
    copy_key(&mut filesystem_projected, filesystem, "limit");

    filesystem_projected.insert(
        collection_key.to_owned(),
        Value::Array(entries.iter().map(project_entry).collect()),
    );
    filesystem_projected.insert(
        "resultProjection".to_owned(),
        source_result_projection(filesystem),
    );
    projected.insert("filesystem".to_owned(), Value::Object(filesystem_projected));
    Some(Value::Object(projected))
}

fn project_search(details: &Value) -> Option<Value> {
    let filesystem = details.get("filesystem")?;
    let matches = filesystem
        .get("matches")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let mut projected = common_projection(details);
    let mut filesystem_projected = filesystem_header(filesystem);
    copy_safe_path(&mut filesystem_projected, filesystem);
    for key in ["skippedBinaryFiles", "truncatedInputFiles", "limit"] {
        copy_key(&mut filesystem_projected, filesystem, key);
    }
    if let Some(query) = filesystem.get("query").and_then(Value::as_str) {
        filesystem_projected.insert(
            "query".to_owned(),
            Value::String(bounded_sanitized_text(query, MAX_PREVIEW_BYTES).0),
        );
    }

    filesystem_projected.insert(
        "matches".to_owned(),
        Value::Array(matches.iter().map(project_search_match).collect()),
    );
    filesystem_projected.insert(
        "resultProjection".to_owned(),
        source_result_projection(filesystem),
    );
    projected.insert("filesystem".to_owned(), Value::Object(filesystem_projected));
    Some(Value::Object(projected))
}

fn project_diff(details: &Value) -> Option<Value> {
    let filesystem = details.get("filesystem")?;
    let mut projected = common_projection(details);
    let mut filesystem_projected = filesystem_header(filesystem);
    copy_safe_path(&mut filesystem_projected, filesystem);
    copy_key(&mut filesystem_projected, filesystem, "commit");

    for key in ["before", "after"] {
        if let Some(snapshot) = filesystem.get(key) {
            let mut snapshot_projected = Map::new();
            for field in [
                "exists",
                "isBinary",
                "sizeBytes",
                "contentHash",
                "truncated",
            ] {
                copy_key(&mut snapshot_projected, snapshot, field);
            }
            if !snapshot_projected.is_empty() {
                filesystem_projected.insert(key.to_owned(), Value::Object(snapshot_projected));
            }
        }
    }

    let source_truncated = filesystem
        .get("diffTruncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let diff_projection = text_projection(
        filesystem
            .get("diff")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        source_truncated,
    );
    filesystem_projected.insert("diffProjection".to_owned(), diff_projection.value);
    projected.insert("filesystem".to_owned(), Value::Object(filesystem_projected));
    Some(Value::Object(projected))
}

fn common_projection(details: &Value) -> Map<String, Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    projected
}

fn filesystem_header(filesystem: &Value) -> Map<String, Value> {
    let mut projected = Map::new();
    for key in ["schemaVersion", "operation", "status"] {
        copy_key(&mut projected, filesystem, key);
    }
    projected
}

fn copy_safe_path(projected: &mut Map<String, Value>, filesystem: &Value) {
    let Some(path) = filesystem.get("path") else {
        return;
    };
    let mut path_projected = Map::new();
    path_projected.insert("root".to_owned(), json!("working_directory"));
    if let Some(relative_path) = path.get("relativePath").and_then(Value::as_str) {
        path_projected.insert(
            "relativePath".to_owned(),
            Value::String(provider_safe_relative_path(relative_path)),
        );
    }
    projected.insert("path".to_owned(), Value::Object(path_projected));
}

fn project_entry(entry: &Value) -> Value {
    let mut projected = Map::new();
    if let Some(name) = entry.get("name").and_then(Value::as_str) {
        projected.insert(
            "name".to_owned(),
            Value::String(bounded_sanitized_text(name, MAX_PREVIEW_BYTES).0),
        );
    }
    if let Some(relative_path) = entry.get("relativePath").and_then(Value::as_str) {
        projected.insert(
            "relativePath".to_owned(),
            Value::String(provider_safe_relative_path(relative_path)),
        );
    }
    for key in [
        "isDirectory",
        "isFile",
        "isSymlink",
        "authorized",
        "sizeBytes",
    ] {
        copy_key(&mut projected, entry, key);
    }
    Value::Object(projected)
}

fn project_search_match(search_match: &Value) -> Value {
    let mut projected = Map::new();
    if let Some(relative_path) = search_match.get("relativePath").and_then(Value::as_str) {
        projected.insert(
            "relativePath".to_owned(),
            Value::String(provider_safe_relative_path(relative_path)),
        );
    }
    for key in ["lineNumber", "contentHash"] {
        copy_key(&mut projected, search_match, key);
    }
    if let Some(preview) = search_match.get("preview").and_then(Value::as_str) {
        let (preview, provider_truncated, redaction_performed) =
            bounded_sanitized_text(preview, MAX_PREVIEW_BYTES);
        let source_truncated = search_match
            .get("previewTruncated")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        projected.insert("preview".to_owned(), Value::String(preview));
        projected.insert(
            "previewProjection".to_owned(),
            json!({
                "bounded": true,
                "sourceBytes": search_match.get("previewSourceBytes").cloned().unwrap_or(Value::Null),
                "sourceReturnedBytes": search_match.get("previewReturnedBytes").cloned().unwrap_or(Value::Null),
                "sourceOmittedBytes": search_match.get("previewOmittedBytes").cloned().unwrap_or(Value::Null),
                "sourceTruncated": source_truncated,
                "providerTruncated": provider_truncated,
                "truncated": source_truncated || provider_truncated,
                "redactionPerformed": redaction_performed,
                "maxProviderBytes": MAX_PREVIEW_BYTES,
            }),
        );
    }
    Value::Object(projected)
}

fn source_result_projection(filesystem: &Value) -> Value {
    let mut projected = Map::new();
    projected.insert(
        "sourceTruncated".to_owned(),
        json!(
            filesystem
                .get("truncated")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        ),
    );
    projected.insert(
        "sourceResultLimitReached".to_owned(),
        json!(
            filesystem
                .get("resultLimitReached")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        ),
    );
    projected.insert(
        "sourceWalkLimitReached".to_owned(),
        json!(
            filesystem
                .get("walkLimitReached")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        ),
    );
    for (source, target) in [
        ("total", "sourceTotalItems"),
        ("returned", "sourceReturnedItems"),
        ("omitted", "sourceOmittedItems"),
    ] {
        if let Some(value) = filesystem
            .get(source)
            .filter(|value| value.as_u64().is_some())
        {
            projected.insert(target.to_owned(), value.clone());
        }
    }
    Value::Object(projected)
}

fn text_projection(text: &str, source_truncated: bool) -> TextProjection {
    let sanitized = sanitize_filesystem_content(text);
    let redaction_performed = sanitized != text;
    let available_bytes = sanitized.len();
    let chunks = split_text_chunks(&sanitized);
    let returned_bytes = chunks.iter().map(|chunk| chunk.text.len()).sum::<usize>();
    let provider_truncated = returned_bytes < available_bytes;
    TextProjection {
        value: json!({
            "availableSanitizedBytes": available_bytes,
            "returnedBytes": returned_bytes,
            "omittedSanitizedBytes": available_bytes.saturating_sub(returned_bytes),
            "sourceTruncated": source_truncated,
            "providerTruncated": provider_truncated,
            "truncated": source_truncated || provider_truncated,
            "redactionPerformed": redaction_performed,
            "maxChunks": MAX_TEXT_CHUNKS,
            "maxChunkBytes": MAX_TEXT_CHUNK_BYTES,
            "chunks": chunks
                .into_iter()
                .enumerate()
                .map(|(index, chunk)| json!({
                    "index": index,
                    "byteStart": chunk.byte_start,
                    "byteEnd": chunk.byte_start + chunk.text.len(),
                    "lineStart": chunk.line_start,
                    "lineEnd": chunk.line_end,
                    "text": chunk.text,
                }))
                .collect::<Vec<_>>(),
        }),
        redaction_performed,
        provider_truncated,
    }
}

fn split_text_chunks(text: &str) -> Vec<TextChunk> {
    let mut chunks = Vec::new();
    let mut remaining = text;
    let mut byte_start = 0usize;
    let mut line_start = 1usize;
    while !remaining.is_empty() && chunks.len() < MAX_TEXT_CHUNKS {
        let max_end = utf8_prefix_len(remaining, MAX_TEXT_CHUNK_BYTES);
        let end = if max_end < remaining.len() {
            remaining[..max_end]
                .rfind('\n')
                .map_or(max_end, |newline| newline + 1)
        } else {
            max_end
        };
        if end == 0 {
            break;
        }
        let chunk_text = remaining[..end].to_owned();
        let newline_count = chunk_text.bytes().filter(|byte| *byte == b'\n').count();
        let line_end =
            line_start + newline_count.saturating_sub(usize::from(chunk_text.ends_with('\n')));
        chunks.push(TextChunk {
            text: chunk_text,
            byte_start,
            line_start,
            line_end,
        });
        byte_start += end;
        line_start += newline_count;
        remaining = &remaining[end..];
    }
    chunks
}

fn bounded_sanitized_text(text: &str, max_bytes: usize) -> (String, bool, bool) {
    let sanitized = sanitize_filesystem_content(text);
    let redaction_performed = sanitized != text;
    let end = utf8_prefix_len(&sanitized, max_bytes);
    let truncated = end < sanitized.len();
    (sanitized[..end].to_owned(), truncated, redaction_performed)
}

fn utf8_prefix_len(text: &str, max_bytes: usize) -> usize {
    if text.len() <= max_bytes {
        return text.len();
    }
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    end
}

fn provider_safe_relative_path(path: &str) -> String {
    let normalized = path.replace('\\', "/");
    let has_drive_prefix = normalized
        .as_bytes()
        .get(1)
        .is_some_and(|separator| *separator == b':');
    let unsafe_path = normalized.starts_with('/')
        || normalized.starts_with("//")
        || has_drive_prefix
        || normalized.eq_ignore_ascii_case("file:")
        || normalized.to_ascii_lowercase().starts_with("file://")
        || normalized.split('/').any(|component| component == "..")
        || normalized.contains('\0');
    if unsafe_path {
        return "[redacted-path]".to_owned();
    }
    bounded_sanitized_text(&normalized, MAX_PREVIEW_BYTES).0
}

fn sanitize_filesystem_content(text: &str) -> String {
    static PRIVATE_KEY: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
        )
        .expect("valid private-key redaction regex")
    });
    static LOCAL_UNIX_PATH: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s\"'`=,\[(]|[+-])(/[^\s\"'`,}\]]+)"#)
            .expect("valid local Unix path redaction regex")
    });
    static LOCAL_WINDOWS_PATH: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?i)(^|[\s\"'`=,\[(]|[+-])[a-z]:\\[^\s\"'`,}\]]+"#)
            .expect("valid local Windows path redaction regex")
    });
    static UNC_PATH: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?i)(^|[\s\"'`=,\[(]|[+-])\\\\[^\\\s\"'`,}\]]+(?:\\[^\s\"'`,}\]]+)+"#)
            .expect("valid UNC path redaction regex")
    });
    static FILE_URI: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?i)\bfile://[^\s\"',}\]]+"#).expect("valid file URI redaction regex")
    });
    static LABELED_LOCAL_PATH: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?i)\b(path|directory|cwd|root)\s*[:=]\s*/[^\s\"',}\]]+"#)
            .expect("valid labeled local path redaction regex")
    });
    static LABELED_CREDENTIAL: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?i)\b(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|auth(?:orization)?[_ -]?code|client[_ -]?secret|token|password|secret|credential|authorization|bearer)\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;}\]]+)"#,
        )
        .expect("valid labeled credential redaction regex")
    });
    static AUTHORIZATION_HEADER: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\b(authorization)\s*[:=]\s*[^\r\n]*")
            .expect("valid authorization header redaction regex")
    });
    static CREDENTIAL_URI: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@")
            .expect("valid credential URI redaction regex")
    });

    let sanitized = text
        .chars()
        .map(|character| {
            if character.is_control() && !matches!(character, '\n' | '\r' | '\t') {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    // Whole-block and structured credential redaction must run before the
    // generic labeled-value pass; otherwise a label inside a PEM/header/JSON
    // value could leave the rest of the secret-bearing structure visible.
    let sanitized = PRIVATE_KEY
        .replace_all(&sanitized, "[redacted-private-key]")
        .to_string();
    let sanitized = redact_json_credential_values(&sanitized);
    let sanitized = sanitize_provider_text(&sanitized);
    let sanitized = LABELED_CREDENTIAL
        .replace_all(&sanitized, "${1}=[redacted-secret]")
        .to_string();
    let sanitized = AUTHORIZATION_HEADER
        .replace_all(&sanitized, "${1}: [redacted-secret]")
        .to_string();
    let sanitized = CREDENTIAL_URI
        .replace_all(&sanitized, "${1}[redacted-credentials]@")
        .to_string();
    let sanitized = FILE_URI
        .replace_all(&sanitized, "[redacted-path]")
        .to_string();
    let sanitized = LABELED_LOCAL_PATH
        .replace_all(&sanitized, "${1}:[redacted-path]")
        .to_string();
    let sanitized = LOCAL_UNIX_PATH
        .replace_all(&sanitized, |captures: &regex::Captures<'_>| {
            let prefix = captures.get(1).map_or("", |value| value.as_str());
            let path = captures.get(2).map_or("", |value| value.as_str());
            let start = captures.get(0).map_or(0, |value| value.start());
            if explicit_route_literal_context(&sanitized, start, prefix) {
                format!("{prefix}{path}")
            } else {
                format!("{prefix}[redacted-path]")
            }
        })
        .to_string();
    let sanitized = UNC_PATH
        .replace_all(&sanitized, "${1}[redacted-path]")
        .to_string();
    LOCAL_WINDOWS_PATH
        .replace_all(&sanitized, "${1}[redacted-path]")
        .to_string()
}

fn explicit_route_literal_context(text: &str, match_start: usize, prefix: &str) -> bool {
    if !matches!(prefix, "\"" | "'") {
        return false;
    }
    let before = text[..match_start].trim_end().to_ascii_lowercase();
    [
        ".get(",
        ".post(",
        ".put(",
        ".patch(",
        ".delete(",
        ".options(",
        ".head(",
        ".route(",
    ]
    .iter()
    .any(|syntax| before.ends_with(syntax))
}

fn redact_json_credential_values(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let mut copied_through = 0usize;
    let mut cursor = 0usize;
    while cursor < bytes.len() {
        if bytes[cursor] != b'\"' {
            cursor += 1;
            continue;
        }
        let Some(key_end) = json_string_end(bytes, cursor) else {
            break;
        };
        let key = &text[cursor + 1..key_end - 1];
        let mut separator = key_end;
        while separator < bytes.len() && bytes[separator].is_ascii_whitespace() {
            separator += 1;
        }
        if separator >= bytes.len() || bytes[separator] != b':' {
            cursor = key_end;
            continue;
        }
        separator += 1;
        while separator < bytes.len() && bytes[separator].is_ascii_whitespace() {
            separator += 1;
        }
        if separator >= bytes.len() || bytes[separator] != b'\"' || !json_credential_key(key) {
            cursor = key_end;
            continue;
        }
        let Some(value_end) = json_string_end(bytes, separator) else {
            break;
        };
        output.push_str(&text[copied_through..separator]);
        output.push_str("\"[redacted-secret]\"");
        copied_through = value_end;
        cursor = value_end;
    }
    output.push_str(&text[copied_through..]);
    output
}

fn json_string_end(bytes: &[u8], start: usize) -> Option<usize> {
    if bytes.get(start) != Some(&b'\"') {
        return None;
    }
    let mut cursor = start + 1;
    while cursor < bytes.len() {
        match bytes[cursor] {
            b'\\' => cursor = cursor.saturating_add(2),
            b'\"' => return Some(cursor + 1),
            _ => cursor += 1,
        }
    }
    None
}

fn json_credential_key(key: &str) -> bool {
    let normalized = key
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    matches!(
        normalized.as_str(),
        "apikey"
            | "accesstoken"
            | "refreshtoken"
            | "authorizationcode"
            | "authcode"
            | "oauthcode"
            | "clientsecret"
            | "token"
            | "password"
            | "secret"
            | "credential"
            | "authorization"
            | "bearer"
    )
}
