//! Target argument affordances for `capability::execute`.
//!
//! # INVARIANT: target-specific normalization stays classified
//!
//! This module is the capability-owned affordance boundary for target-shaped
//! argument repairs that cross the generic execute wrapper and a selected
//! domain schema. The shared `execute` orchestrator may decide when to apply
//! these affordances, but per-target shape knowledge belongs here until it can
//! move into a domain-owned recipe or schema affordance.

use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use crate::engine::resources::{
    ACTIVATION_RECORD_KIND, MODULE_CONFIG_KIND, UI_SURFACE_KIND, WORKER_PACKAGE_KIND,
};
use crate::engine::{FunctionDefinition, Invocation};

const ARTIFACT_RESOURCE_KIND: &str = "artifact";
const MATERIALIZED_FILE_RESOURCE_KIND: &str = "materialized_file";

pub(super) fn normalize_target_arguments(
    function: &FunctionDefinition,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    normalize_target_specific_arguments(function, arguments, corrections);
    normalize_schema_property_name_aliases(function, arguments, corrections);
}

pub(super) fn normalize_intent_target_arguments(
    function: &FunctionDefinition,
    intent: Option<&str>,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    let Some(intent) = intent else {
        return;
    };
    let Some(object) = arguments.as_object_mut() else {
        return;
    };

    match function.id.as_str() {
        "filesystem::read_file" => {
            if !object.contains_key("path") {
                let requests = intent_file_read_requests(intent);
                if requests.len() == 1 {
                    let request = &requests[0];
                    object.insert("path".to_owned(), json!(request.path));
                    apply_intent_line_bounds(
                        object,
                        request.start_line,
                        request.end_line,
                        corrections,
                    );
                    corrections.push(correction_record(
                        "intent_file_path_to_target_argument",
                        "bound safe relative file path from execute intent into filesystem::read_file arguments",
                        0.92,
                    ));
                }
            }

            if object.contains_key("path")
                && let Some((start_line, end_line)) = intent_line_bounds(intent)
            {
                apply_intent_line_bounds(object, Some(start_line), Some(end_line), corrections);
            }
        }
        "resource::list" => {
            if !object.contains_key("kind") {
                let requests = intent_resource_kind_requests(intent);
                if requests.len() == 1 {
                    object.insert("kind".to_owned(), json!(requests[0].kind));
                    corrections.push(correction_record(
                        "intent_resource_kind_to_target_argument",
                        format!(
                            "bound resource kind {} from execute intent into resource::list arguments",
                            requests[0].kind
                        ),
                        0.95,
                    ));
                }
            }
        }
        _ => {}
    }
}

pub(super) fn normalize_contextual_target_arguments(
    function: &FunctionDefinition,
    invocation: &Invocation,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    let Some(schema) = function.request_schema.as_ref() else {
        return;
    };
    let Some(object) = arguments.as_object_mut() else {
        return;
    };

    let required = schema_required_property_names(schema);
    let properties = schema_property_names(schema);
    if required.contains("sessionId") && !object.contains_key("sessionId") {
        if let Some(session_id) = invocation
            .causal_context
            .session_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            object.insert("sessionId".to_owned(), json!(session_id));
            corrections.push(correction_record(
                "runtime_session_id_to_target_argument",
                format!(
                    "bound trusted current sessionId into {} arguments",
                    function.id.as_str()
                ),
                1.0,
            ));
        }
    }

    if function.id.as_str() == "worktree::is_git_repo"
        && required.contains("path")
        && !object.contains_key("path")
    {
        if let Some(working_directory) = invocation
            .causal_context
            .runtime_metadata(crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            object.insert("path".to_owned(), json!(working_directory));
            corrections.push(correction_record(
                "runtime_working_directory_to_target_path",
                "bound trusted current session working directory into worktree::is_git_repo path",
                1.0,
            ));
        }
    }

    if required.contains("sessionId")
        && !properties.contains("path")
        && object
            .get("path")
            .and_then(Value::as_str)
            .is_some_and(|path| path_is_current_session_worktree_hint(invocation, path))
    {
        object.remove("path");
        corrections.push(correction_record(
            "current_worktree_path_hint_removed",
            format!(
                "removed path because {} is scoped by trusted current sessionId",
                function.id.as_str()
            ),
            1.0,
        ));
    }
}

pub(super) fn normalize_target_specific_arguments(
    function: &FunctionDefinition,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    match function.id.as_str() {
        "process::run" => normalize_process_run_arguments(arguments, corrections),
        "filesystem::list_dir" => normalize_filesystem_list_dir_arguments(arguments, corrections),
        "web::search" => normalize_web_search_arguments(arguments, corrections),
        "filesystem::apply_patch" => {
            normalize_filesystem_apply_patch_arguments(arguments, corrections)
        }
        _ => {}
    }
}

pub(super) fn normalize_target_idempotency_argument(
    function: &FunctionDefinition,
    arguments: &mut Value,
    wrapper_idempotency_key: Option<&str>,
    corrections: &mut Vec<Value>,
) {
    let Some(idempotency_key) = wrapper_idempotency_key
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return;
    };
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if object.contains_key("idempotencyKey") || object.contains_key("idempotency_key") {
        return;
    }
    let Some(schema) = function.request_schema.as_ref() else {
        return;
    };
    if !schema_property_names(schema).contains("idempotencyKey") {
        return;
    }

    object.insert("idempotencyKey".to_owned(), json!(idempotency_key));
    corrections.push(correction_record(
        "wrapper_idempotency_key_to_target_argument",
        format!(
            "copied execute.idempotencyKey into {} arguments because the selected target schema requires idempotencyKey",
            function.id.as_str()
        ),
        1.0,
    ));
}

pub(super) fn schema_property_names(schema: &Value) -> BTreeSet<&str> {
    schema
        .get("properties")
        .and_then(Value::as_object)
        .map(|properties| properties.keys().map(String::as_str).collect())
        .unwrap_or_default()
}

pub(super) fn schema_required_property_names(schema: &Value) -> BTreeSet<&str> {
    schema
        .get("required")
        .and_then(Value::as_array)
        .map(|required| required.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

pub(super) fn normalized_identifier_words(value: &str) -> Vec<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter_map(|token| {
            let token = token.trim().to_ascii_lowercase();
            (!token.is_empty()).then_some(token)
        })
        .collect()
}

pub(super) fn normalized_intent_words(value: &str) -> BTreeSet<String> {
    normalized_identifier_words(value).into_iter().collect()
}

pub(super) fn intent_requests_filesystem_read(intent: &str, arguments: &Value) -> bool {
    let words = normalized_intent_words(intent);
    let asks_for_read = ["read", "open", "cat", "content", "line", "lines"]
        .iter()
        .any(|word| words.contains(*word));
    let asks_for_write = [
        "write",
        "edit",
        "modify",
        "delete",
        "remove",
        "create",
        "overwrite",
        "patch",
    ]
    .iter()
    .any(|word| words.contains(*word));
    if !asks_for_read || asks_for_write {
        return false;
    }
    arguments
        .get("path")
        .and_then(Value::as_str)
        .is_some_and(|path| !path.trim().is_empty())
        || !intent_file_read_requests(intent).is_empty()
}

pub(super) fn intent_requests_resource_inventory(intent: &str, arguments: &Value) -> bool {
    arguments
        .get("kind")
        .and_then(Value::as_str)
        .is_some_and(|kind| !kind.trim().is_empty())
        || !intent_resource_kind_requests(intent).is_empty()
}

pub(super) fn intent_requests_worktree_diff(intent: &str) -> bool {
    let words = normalized_intent_words(intent);
    let asks_for_diff = words.contains("diff") || words.contains("difference");
    let asks_for_changes = words.contains("changes") || words.contains("uncommitted");
    if !(asks_for_diff || asks_for_changes) {
        return false;
    }
    let strong_worktree_or_git = [
        "worktree",
        "git",
        "repo",
        "repository",
        "branch",
        "uncommitted",
        "status",
    ]
    .iter()
    .any(|word| words.contains(*word));
    asks_for_diff && (strong_worktree_or_git || words.contains("current"))
        || asks_for_changes && strong_worktree_or_git
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct IntentResourceKindRequest {
    pub(super) kind: &'static str,
}

pub(super) fn intent_resource_kind_requests(intent: &str) -> Vec<IntentResourceKindRequest> {
    let normalized = intent
        .to_ascii_lowercase()
        .replace(['_', '-'], " ")
        .replace('\n', " ");
    let words = normalized_intent_words(intent);
    let asks_for_inventory = [
        "resource",
        "resources",
        "record",
        "records",
        "existing",
        "current",
        "list",
        "inventory",
        "whether",
        "present",
        "available",
    ]
    .iter()
    .any(|word| words.contains(*word));
    if !asks_for_inventory {
        return Vec::new();
    }

    let mut requests = Vec::new();
    let mut seen = BTreeSet::new();
    for (kind, phrases) in [
        (
            WORKER_PACKAGE_KIND,
            &[
                "worker package",
                "worker packages",
                "module package",
                "module packages",
                "package resource",
                "package resources",
                "package record",
                "package records",
            ][..],
        ),
        (
            ACTIVATION_RECORD_KIND,
            &[
                "activation record",
                "activation records",
                "module activation",
                "module activations",
                "activation resource",
                "activation resources",
            ][..],
        ),
        (
            MODULE_CONFIG_KIND,
            &[
                "module config",
                "module configs",
                "module configuration",
                "module configurations",
                "config resource",
                "configuration resource",
            ][..],
        ),
        (UI_SURFACE_KIND, &["ui surface", "ui surfaces"][..]),
        (
            MATERIALIZED_FILE_RESOURCE_KIND,
            &["materialized file", "materialized files"][..],
        ),
        (ARTIFACT_RESOURCE_KIND, &["artifact", "artifacts"][..]),
    ] {
        if phrases.iter().any(|phrase| normalized.contains(phrase)) && seen.insert(kind) {
            requests.push(IntentResourceKindRequest { kind });
        }
    }
    requests
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct IntentFileReadRequest {
    pub(super) path: String,
    pub(super) start_line: Option<u64>,
    pub(super) end_line: Option<u64>,
}

pub(super) fn intent_file_read_requests(intent: &str) -> Vec<IntentFileReadRequest> {
    let mut requests = Vec::new();
    let mut seen = BTreeSet::new();
    for clause in intent_read_clauses(intent) {
        let line_bounds = intent_line_bounds(&clause);
        for path in intent_file_path_candidates(&clause) {
            if !seen.insert(path.clone()) {
                continue;
            }
            requests.push(IntentFileReadRequest {
                path,
                start_line: line_bounds.map(|bounds| bounds.0),
                end_line: line_bounds.map(|bounds| bounds.1),
            });
        }
    }
    requests
}

fn normalize_schema_property_name_aliases(
    function: &FunctionDefinition,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    let Some(schema) = function.request_schema.as_ref() else {
        return;
    };
    let mut renames = Vec::new();
    normalize_schema_property_names_for_value(schema, arguments, &mut renames);
    if renames.is_empty() {
        return;
    }
    corrections.push(correction_record(
        "schema_property_name_alias",
        format!(
            "normalized target argument key casing to {} schema property names: {}",
            function.id.as_str(),
            renames.join(", ")
        ),
        1.0,
    ));
}

fn normalize_schema_property_names_for_value(
    schema: &Value,
    value: &mut Value,
    renames: &mut Vec<String>,
) {
    if let (Some(properties), Some(object)) = (
        schema.get("properties").and_then(Value::as_object),
        value.as_object_mut(),
    ) {
        normalize_object_property_names(properties, object, renames);
        for (property, property_schema) in properties {
            if let Some(child) = object.get_mut(property) {
                normalize_schema_property_names_for_value(property_schema, child, renames);
            }
        }
    }

    if let (Some(items_schema), Some(array)) = (schema.get("items"), value.as_array_mut()) {
        for item in array {
            normalize_schema_property_names_for_value(items_schema, item, renames);
        }
    }
}

fn normalize_object_property_names(
    properties: &Map<String, Value>,
    object: &mut Map<String, Value>,
    renames: &mut Vec<String>,
) {
    let mut normalized_to_canonical: BTreeMap<String, Option<String>> = BTreeMap::new();
    for property in properties.keys() {
        let normalized = normalize_schema_property_key(property);
        normalized_to_canonical
            .entry(normalized)
            .and_modify(|existing| *existing = None)
            .or_insert_with(|| Some(property.clone()));
    }

    let keys = object.keys().cloned().collect::<Vec<_>>();
    for key in keys {
        if properties.contains_key(&key) {
            continue;
        }
        let normalized = normalize_schema_property_key(&key);
        let Some(Some(canonical)) = normalized_to_canonical.get(&normalized) else {
            continue;
        };
        if object.contains_key(canonical) {
            continue;
        }
        if let Some(value) = object.remove(&key) {
            object.insert(canonical.clone(), value);
            renames.push(format!("{key}->{canonical}"));
        }
    }
}

fn normalize_schema_property_key(key: &str) -> String {
    key.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect()
}

fn path_is_current_session_worktree_hint(invocation: &Invocation, path: &str) -> bool {
    let candidate = path.trim();
    if candidate == "." {
        return true;
    }
    let Some(working_directory) = invocation
        .causal_context
        .runtime_metadata(crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return false;
    };
    let candidate = lexical_clean_path(Path::new(candidate));
    let working_directory = lexical_clean_path(Path::new(working_directory));
    candidate == working_directory
}

fn lexical_clean_path(path: &Path) -> PathBuf {
    let mut cleaned = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                cleaned.pop();
            }
            other => cleaned.push(other.as_os_str()),
        }
    }
    cleaned
}

fn normalize_filesystem_list_dir_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if object.contains_key("maxEntries") {
        if !object.contains_key("maxResults")
            && let Some(value) = object.remove("maxEntries")
        {
            object.insert("maxResults".to_owned(), value);
        } else {
            object.remove("maxEntries");
        }
        corrections.push(correction_record(
            "filesystem_list_dir_max_entries_alias",
            "normalized maxEntries to maxResults; filesystem::list_dir uses maxResults to bound directory entries",
            1.0,
        ));
    }
}

fn normalize_web_search_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    let alias = ["maxResults", "limit", "numResults"]
        .into_iter()
        .find(|alias| object.contains_key(*alias));
    let Some(alias) = alias else {
        return;
    };
    if !object.contains_key("count")
        && let Some(value) = object.remove(alias)
    {
        object.insert("count".to_owned(), value);
    } else {
        object.remove(alias);
    }
    for other_alias in ["maxResults", "limit", "numResults"] {
        if other_alias != alias {
            object.remove(other_alias);
        }
    }
    corrections.push(correction_record(
        "web_search_count_alias",
        "normalized web search result-limit alias to count; web::search uses count to bound ranked results",
        1.0,
    ));
}

fn normalize_process_run_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    normalize_process_expected_output_aliases(arguments, corrections);
    let Some(outputs) = arguments
        .get_mut("expectedOutputs")
        .and_then(Value::as_array_mut)
    else {
        return;
    };
    let mut removed = false;
    for output in outputs.iter_mut() {
        if let Some(path) = output
            .as_str()
            .map(str::trim)
            .filter(|path| !path.is_empty())
        {
            *output = json!({ "path": path });
            removed = true;
            continue;
        }
        if let Some(object) = output.as_object_mut() {
            removed |= object.remove("kind").is_some();
            removed |= object.remove("role").is_some();
            removed |= object.remove("type").is_some();
        }
    }
    if removed {
        corrections.push(correction_record(
            "process_expected_outputs_shape",
            "normalized expectedOutputs entries; process::run expects objects with path and optional targetPath only",
            1.0,
        ));
    }
}

fn normalize_filesystem_apply_patch_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if !object.contains_key("oldString")
        && object
            .get("newString")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
    {
        object.insert("oldString".to_owned(), Value::String(String::new()));
        corrections.push(correction_record(
            "filesystem_apply_patch_append_shape",
            "set oldString to an empty string so filesystem::apply_patch appends newString exactly",
            1.0,
        ));
    }
}

fn normalize_process_expected_output_aliases(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if object.get("expectedOutputs").is_some() {
        return;
    }
    let Some(alias) = object
        .remove("expectedOutputPaths")
        .or_else(|| object.remove("expectedOutputPath"))
        .or_else(|| object.remove("outputPaths"))
        .or_else(|| object.remove("outputPath"))
    else {
        return;
    };
    let outputs = match alias {
        Value::String(path) => vec![json!({ "path": path })],
        Value::Array(values) => values
            .into_iter()
            .filter_map(|value| match value {
                Value::String(path) => Some(json!({ "path": path })),
                Value::Object(mut object) => {
                    if !object.contains_key("path")
                        && let Some(path) = object.remove("targetPath")
                    {
                        object.insert("path".to_owned(), path);
                    }
                    Some(Value::Object(object))
                }
                _ => None,
            })
            .collect::<Vec<_>>(),
        Value::Object(object) => vec![Value::Object(object)],
        _ => Vec::new(),
    };
    if outputs.is_empty() {
        return;
    }
    object.insert("expectedOutputs".to_owned(), Value::Array(outputs));
    corrections.push(correction_record(
        "process_expected_outputs_alias",
        "converted expected output path alias into expectedOutputs",
        1.0,
    ));
}

fn intent_read_clauses(intent: &str) -> Vec<String> {
    let mut clauses = Vec::new();
    for clause in intent.split(|character: char| matches!(character, ',' | ';' | '\n')) {
        clauses.extend(split_read_clause_connectors(clause));
    }
    clauses
}

fn split_read_clause_connectors(clause: &str) -> Vec<String> {
    let lower = clause.to_ascii_lowercase();
    let markers = [
        (" and read ", 5usize),
        (" and open ", 5usize),
        (" and cat ", 5usize),
        (" then read ", 6usize),
        (" then open ", 6usize),
        (" then cat ", 6usize),
        (" also read ", 6usize),
        (" plus read ", 6usize),
    ];
    let mut parts = Vec::new();
    let mut start = 0usize;
    loop {
        let Some((marker_start, marker_offset)) = markers
            .iter()
            .filter_map(|(marker, verb_offset)| {
                lower[start..]
                    .find(marker)
                    .map(|index| (start + index, *verb_offset))
            })
            .min_by_key(|(index, _)| *index)
        else {
            break;
        };
        let before = clause[start..marker_start].trim();
        if !before.is_empty() {
            parts.push(before.to_owned());
        }
        start = marker_start + marker_offset;
    }
    let tail = clause[start..].trim();
    if !tail.is_empty() {
        parts.push(tail.to_owned());
    }
    parts
}

fn intent_file_path_candidates(intent: &str) -> Vec<String> {
    intent
        .split_whitespace()
        .filter_map(|token| {
            let token = clean_intent_path_token(token)?;
            safe_relative_intent_path(&token).then_some(token)
        })
        .collect()
}

fn clean_intent_path_token(token: &str) -> Option<String> {
    let mut value = token
        .trim_matches(|character: char| {
            matches!(
                character,
                '"' | '\'' | '`' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
            )
        })
        .trim_end_matches(|character: char| {
            matches!(
                character,
                '"' | '\'' | '`' | ')' | ']' | '}' | ',' | ':' | ';'
            )
        })
        .to_owned();
    while value.ends_with('.') && value[..value.len().saturating_sub(1)].contains('.') {
        value.pop();
    }
    while let Some(stripped) = value.strip_prefix("./") {
        value = stripped.to_owned();
    }
    (!value.is_empty()).then_some(value)
}

fn safe_relative_intent_path(path: &str) -> bool {
    if path.is_empty()
        || path.len() > 240
        || path.starts_with('/')
        || path.starts_with('~')
        || path.contains("://")
        || !path
            .chars()
            .any(|character| character.is_ascii_alphabetic())
        || path.chars().any(|character| {
            !(character.is_ascii_alphanumeric() || matches!(character, '.' | '/' | '_' | '-' | '@'))
        })
    {
        return false;
    }
    let mut segments = path.split('/').peekable();
    if segments.peek().is_none() {
        return false;
    }
    if segments.any(|segment| segment.is_empty() || segment == "." || segment == "..") {
        return false;
    }
    let Some(file_name) = path.rsplit('/').next() else {
        return false;
    };
    path.contains('/') || file_name.contains('.') || is_common_file_name(file_name)
}

fn is_common_file_name(file_name: &str) -> bool {
    matches!(
        file_name,
        "README" | "LICENSE" | "Makefile" | "Dockerfile" | "Gemfile" | "Rakefile"
    )
}

fn intent_line_bounds(intent: &str) -> Option<(u64, u64)> {
    let words = normalized_identifier_words(intent);
    for (index, word) in words.iter().enumerate() {
        if word != "line" && word != "lines" {
            continue;
        }
        let Some(start) = words
            .get(index + 1)
            .and_then(|word| intent_number_word(word))
        else {
            continue;
        };
        let separator = words.get(index + 2).map(String::as_str);
        let Some(end) = words
            .get(index + 3)
            .and_then(|word| intent_number_word(word))
        else {
            continue;
        };
        if matches!(separator, Some("through" | "thru" | "to" | "until" | "and")) && start <= end {
            return Some((start, end));
        }
    }
    intent_first_line_count_from_words(&words).map(|count| (1, count))
}

fn intent_first_line_count_from_words(words: &[String]) -> Option<u64> {
    for (index, word) in words.iter().enumerate() {
        if word != "first" {
            continue;
        }
        match words.get(index + 1).map(String::as_str) {
            Some("line" | "lines") => return Some(1),
            Some(count_word) => {
                let Some(count) = intent_number_word(count_word) else {
                    continue;
                };
                if words
                    .get(index + 2)
                    .is_some_and(|next| next == "line" || next == "lines")
                {
                    return Some(count);
                }
            }
            None => {}
        }
    }
    None
}

fn apply_intent_line_bounds(
    object: &mut Map<String, Value>,
    start_line: Option<u64>,
    end_line: Option<u64>,
    corrections: &mut Vec<Value>,
) {
    let Some(end_line) = end_line else {
        return;
    };
    let start_line = start_line.unwrap_or(1);
    if !object.contains_key("startLine") {
        object.insert("startLine".to_owned(), json!(start_line));
    }
    if !object.contains_key("endLine") {
        object.insert("endLine".to_owned(), json!(end_line));
    }
    corrections.push(correction_record(
        "intent_line_bounds_to_target_arguments",
        format!("bound line range {start_line} through {end_line} from execute intent into filesystem::read_file arguments"),
        0.9,
    ));
}

fn intent_number_word(word: &str) -> Option<u64> {
    if let Ok(value) = word.parse::<u64>() {
        return (1..=200).contains(&value).then_some(value);
    }
    match word {
        "one" => Some(1),
        "two" => Some(2),
        "three" => Some(3),
        "four" => Some(4),
        "five" => Some(5),
        "six" => Some(6),
        "seven" => Some(7),
        "eight" => Some(8),
        "nine" => Some(9),
        "ten" => Some(10),
        "eleven" => Some(11),
        "twelve" => Some(12),
        "twenty" => Some(20),
        _ => None,
    }
}

fn correction_record(
    kind: impl Into<String>,
    message: impl Into<String>,
    confidence: f64,
) -> Value {
    json!({
        "kind": kind.into(),
        "message": message.into(),
        "confidence": confidence,
    })
}
