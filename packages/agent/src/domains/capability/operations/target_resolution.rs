//! Target resolution helpers for `capability::execute`.
//!
//! # INVARIANT: target resolution heuristics stay classified
//!
//! The shared execute orchestrator owns the phase order: parse, resolve,
//! prepare, run, and observe. Deterministic routing, namespace clarification,
//! constraint filtering, and argument-schema fit scoring are classified here so
//! new target-specific resolution behavior cannot grow inside `execute.rs`
//! unnoticed.

use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

use super::execute::OrchestrationResolve;
use super::target_arguments::{
    intent_file_read_requests, intent_requests_filesystem_read, intent_requests_resource_inventory,
    intent_requests_worktree_diff, intent_resource_kind_requests, normalize_target_arguments,
    normalized_identifier_words, normalized_intent_words, schema_property_names,
    schema_required_property_names,
};
use super::{
    ResolvedCapabilityTarget, effect_class_from_str, effect_field, risk_field, risk_level_from_str,
    run, validate_target_payload,
};
use crate::domains::capability::registry::{
    CapabilityRegistryEntry, CapabilityRegistrySnapshot, requires_fresh_revision,
};
use crate::domains::capability::types::CapabilityIndexHit;
use crate::shared::server::errors::CapabilityError;

const MIN_UNANCHORED_INTENT_SCORE: f32 = 0.1;

pub(super) fn intent_strongly_matches_hit(intent: &str, hit: &CapabilityIndexHit) -> bool {
    let normalized_intent = normalized_intent_words(intent);
    let Some((namespace, function_name)) = hit.contract_id.split_once("::") else {
        return false;
    };
    let mut tokens = normalized_identifier_words(function_name);
    if tokens.is_empty() {
        return false;
    }
    let namespace_tokens = normalized_identifier_words(namespace);
    if namespace_tokens
        .iter()
        .any(|token| normalized_intent.contains(token))
    {
        tokens.extend(namespace_tokens);
    }
    tokens
        .iter()
        .filter(|token| token.len() > 1)
        .all(|token| normalized_intent.contains(token))
}

fn validate_orchestration_constraint_keys(constraints: &Value) -> Result<(), CapabilityError> {
    let Some(object) = constraints.as_object() else {
        return Err(CapabilityError::InvalidParams {
            message: "execute.constraints must be an object".to_owned(),
        });
    };
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "riskMax" | "effect" | "allowedContracts" | "allowedNamespaces"
        ) {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Unsupported execute.constraints field '{key}'. Supported fields: riskMax, effect, allowedContracts, allowedNamespaces"
                ),
            });
        }
    }
    Ok(())
}

pub(super) fn validate_orchestration_constraint_shape(
    constraints: &Value,
) -> Result<(), CapabilityError> {
    validate_orchestration_constraint_keys(constraints)?;
    let _ = risk_field(constraints, "riskMax")?;
    let _ = effect_field(constraints, "effect")?;
    let _ = optional_string_array_field(constraints, "allowedContracts")?;
    let _ = optional_string_array_field(constraints, "allowedNamespaces")?;
    Ok(())
}

pub(super) fn validate_orchestration_constraints(
    constraints: &Value,
    entry: &CapabilityRegistryEntry,
) -> Result<(), CapabilityError> {
    validate_orchestration_constraint_shape(constraints)?;
    if let Some(max_risk) = risk_field(constraints, "riskMax")?
        && entry.function.risk_level > max_risk
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "selected target {} has risk {:?}, above constraint riskMax {:?}",
                entry.contract_id, entry.function.risk_level, max_risk
            ),
        });
    }
    if let Some(effect) = effect_field(constraints, "effect")?
        && entry.function.effect_class != effect
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "selected target {} has effect {:?}, not requested effect {:?}",
                entry.contract_id, entry.function.effect_class, effect
            ),
        });
    }
    let allowed_contracts = optional_string_array_field(constraints, "allowedContracts")?;
    if let Some(contracts) = allowed_contracts
        && !contracts
            .iter()
            .any(|contract| contract == &entry.contract_id)
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "selected target {} is outside execute.constraints.allowedContracts",
                entry.contract_id
            ),
        });
    }
    let allowed_namespaces = optional_string_array_field(constraints, "allowedNamespaces")?;
    if let Some(namespaces) = allowed_namespaces {
        let namespace = entry
            .contract_id
            .split_once("::")
            .map(|(namespace, _)| namespace)
            .unwrap_or(entry.contract_id.as_str());
        if !namespaces.iter().any(|allowed| allowed == namespace) {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "selected target {} is outside execute.constraints.allowedNamespaces",
                    entry.contract_id
                ),
            });
        }
    }
    Ok(())
}

pub(super) fn orchestration_constraints_allow_hit(
    constraints: &Value,
    hit: &CapabilityIndexHit,
) -> Result<bool, CapabilityError> {
    validate_orchestration_constraint_shape(constraints)?;
    if let Some(max_risk) = risk_field(constraints, "riskMax")? {
        let hit_risk = risk_level_from_str(&hit.risk_level, "candidate riskLevel")?;
        if hit_risk > max_risk {
            return Ok(false);
        }
    }
    if let Some(effect) = effect_field(constraints, "effect")? {
        let hit_effect = effect_class_from_str(&hit.effect_class, "candidate effectClass")?;
        if hit_effect != effect {
            return Ok(false);
        }
    }
    if let Some(contracts) = optional_string_array_field(constraints, "allowedContracts")?
        && !contracts
            .iter()
            .any(|contract| contract == &hit.contract_id)
    {
        return Ok(false);
    }
    if let Some(namespaces) = optional_string_array_field(constraints, "allowedNamespaces")? {
        let namespace = hit
            .contract_id
            .split_once("::")
            .map(|(namespace, _)| namespace)
            .unwrap_or(hit.contract_id.as_str());
        if !namespaces.iter().any(|allowed| allowed == namespace) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn optional_string_array_field(
    value: &Value,
    key: &str,
) -> Result<Option<Vec<String>>, CapabilityError> {
    let Some(raw) = value.get(key) else {
        return Ok(None);
    };
    let Some(values) = raw.as_array() else {
        return Err(CapabilityError::InvalidParams {
            message: format!("execute.constraints.{key} must be an array of strings"),
        });
    };
    let mut strings = Vec::new();
    for item in values {
        let Some(item) = item.as_str().map(str::trim).filter(|item| !item.is_empty()) else {
            return Err(CapabilityError::InvalidParams {
                message: format!("execute.constraints.{key} must contain only non-empty strings"),
            });
        };
        strings.push(item.to_owned());
    }
    Ok(Some(strings))
}

fn positive_intent_words(value: &str) -> std::collections::BTreeSet<String> {
    value
        .split(|character| matches!(character, '.' | ';' | '\n' | ','))
        .flat_map(|clause| {
            let words = normalized_identifier_words(clause);
            if negative_guard_clause(&words) {
                Vec::new()
            } else {
                words
            }
        })
        .collect()
}

fn negative_guard_clause(words: &[String]) -> bool {
    let Some(first) = words.first().map(String::as_str) else {
        return false;
    };
    matches!(first, "avoid" | "never" | "without" | "no" | "dont")
        || (first == "don" && words.get(1).map(String::as_str) == Some("t"))
        || (first == "do" && words.get(1).map(String::as_str) == Some("not"))
}

pub(super) fn deterministic_intent_route(
    intent: &str,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
) -> Result<Option<CapabilityIndexHit>, CapabilityError> {
    if intent_requests_worktree_diff(intent) {
        return deterministic_hit_for_function(
            "worktree::get_diff",
            snapshot,
            constraints,
            "deterministic_worktree_diff",
        );
    }
    if let Some(hit) = deterministic_operator_status_route(intent, snapshot, constraints)? {
        return Ok(Some(hit));
    }
    if intent_requests_resource_inventory(intent, arguments) {
        return deterministic_hit_for_function(
            "resource::list",
            snapshot,
            constraints,
            "deterministic_resource_inventory",
        );
    }
    if intent_requests_filesystem_read(intent, arguments) {
        return deterministic_hit_for_function(
            "filesystem::read_file",
            snapshot,
            constraints,
            "deterministic_path_read",
        );
    }
    Ok(None)
}

pub(super) fn apply_deterministic_intent_route(
    intent: &str,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
    executable_hits: &mut Vec<CapabilityIndexHit>,
) -> Result<(), CapabilityError> {
    if let Some(routed) = deterministic_intent_route(intent, arguments, snapshot, constraints)? {
        executable_hits.retain(|hit| hit.function_id != routed.function_id);
        executable_hits.insert(0, routed);
    }
    Ok(())
}

pub(super) fn clarification_candidates_for_intent(
    intent: &str,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
) -> Result<Option<Vec<Value>>, CapabilityError> {
    let namespaces = namespaces_referenced_by_intent(intent, snapshot);
    if namespaces.is_empty() {
        return Ok(None);
    }

    let mut hits = Vec::new();
    for entry in &snapshot.entries {
        if entry.function_id == "capability::execute" {
            continue;
        }
        let Some((namespace, _)) = entry.function_id.split_once("::") else {
            continue;
        };
        if !namespaces.contains(namespace) {
            continue;
        }
        let hit = orchestration_hit_from_entry(entry, "namespace_clarification", 0.05);
        if orchestration_constraints_allow_hit(constraints, &hit)? {
            hits.push(hit);
        }
    }

    if hits.is_empty() {
        return Ok(None);
    }
    hits.sort_by(|left, right| {
        left.contract_id
            .cmp(&right.contract_id)
            .then_with(|| left.function_id.cmp(&right.function_id))
    });
    hits.truncate(8);
    Ok(Some(
        hits.iter()
            .map(orchestration_candidate_summary)
            .collect::<Vec<_>>(),
    ))
}

fn namespaces_referenced_by_intent(
    intent: &str,
    snapshot: &CapabilityRegistrySnapshot,
) -> BTreeSet<String> {
    let words = normalized_intent_words(intent);
    if words.is_empty() {
        return BTreeSet::new();
    }
    let mut namespaces = BTreeSet::new();
    for entry in &snapshot.entries {
        let Some((namespace, _)) = entry.function_id.split_once("::") else {
            continue;
        };
        if namespace_intent_match(namespace, &words) {
            namespaces.insert(namespace.to_owned());
        }
    }
    namespaces
}

fn namespace_intent_match(namespace: &str, words: &BTreeSet<String>) -> bool {
    let namespace_words = normalized_identifier_words(namespace);
    namespace_words
        .iter()
        .any(|word| words.contains(word) || words.contains(&singular_word(word)))
        || namespace_aliases(namespace)
            .iter()
            .any(|alias| words.contains(*alias))
}

fn singular_word(word: &str) -> String {
    word.strip_suffix('s').unwrap_or(word).to_owned()
}

fn namespace_aliases(namespace: &str) -> &'static [&'static str] {
    match namespace {
        "filesystem" => &[
            "file",
            "files",
            "folder",
            "folders",
            "directory",
            "directories",
        ],
        "process" => &["command", "commands", "shell", "terminal"],
        "prompt_library" => &["prompt", "prompts", "snippet", "snippets", "history"],
        "resource" => &["resource", "resources", "artifact", "artifacts"],
        "worker" => &["worker", "workers"],
        "grant" => &["grant", "grants", "permission", "permissions"],
        "approval" => &["approval", "approvals"],
        "module" => &["module", "modules", "package", "packages"],
        "settings" => &[
            "setting",
            "settings",
            "preference",
            "preferences",
            "profile",
        ],
        "model" => &["model", "models", "provider", "providers"],
        "logs" => &["log", "logs", "event", "events"],
        "observability" => &["metric", "metrics", "trace", "traces", "span", "spans"],
        _ => &[],
    }
}

pub(super) fn apply_argument_schema_fit_filter(
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    executable_hits: &mut Vec<CapabilityIndexHit>,
) -> Vec<Value> {
    if arguments.as_object().is_none_or(Map::is_empty) {
        return Vec::new();
    }

    let original_hits = std::mem::take(executable_hits);
    let mut compatible = Vec::new();
    let mut missing_required = Vec::new();
    let mut rejected = Vec::new();

    for hit in &original_hits {
        match argument_schema_fit_for_hit(hit, arguments, snapshot) {
            ArgumentSchemaFit::Compatible => compatible.push(hit.clone()),
            ArgumentSchemaFit::MissingRequired => missing_required.push(hit.clone()),
            ArgumentSchemaFit::Incompatible(reason) => {
                rejected.push(rejected_candidate_summary(
                    hit,
                    "argument_schema_mismatch",
                    reason,
                ));
            }
        }
    }

    if !compatible.is_empty() {
        for hit in &missing_required {
            rejected.push(rejected_candidate_summary(
                hit,
                "argument_missing_required",
                "candidate is missing required arguments while another candidate accepts the supplied arguments",
            ));
        }
        *executable_hits = compatible;
        return rejected;
    }

    if !missing_required.is_empty() {
        *executable_hits = missing_required;
        return rejected;
    }

    *executable_hits = original_hits;
    Vec::new()
}

pub(super) fn promote_argument_schema_fit_candidates(
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
    executable_hits: &mut Vec<CapabilityIndexHit>,
) -> Result<(), CapabilityError> {
    if arguments.as_object().is_none_or(Map::is_empty) {
        return Ok(());
    }

    let mut promoted = Vec::new();
    for entry in &snapshot.entries {
        if entry.function_id == "capability::execute"
            || executable_hits
                .iter()
                .any(|hit| hit.function_id == entry.function_id)
        {
            continue;
        }
        let hit = orchestration_hit_from_entry(entry, "argument_schema_fit", 0.0);
        if !orchestration_constraints_allow_hit(constraints, &hit)? {
            continue;
        }
        let Some(score) = argument_schema_promotion_score(entry, arguments) else {
            continue;
        };
        promoted.push(orchestration_hit_from_entry(
            entry,
            "argument_schema_fit",
            score,
        ));
    }

    if promoted.is_empty() {
        return Ok(());
    }

    executable_hits.extend(promoted);
    executable_hits.sort_by(|left, right| {
        right
            .fused_score
            .partial_cmp(&left.fused_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.function_id.cmp(&right.function_id))
    });
    executable_hits.dedup_by(|left, right| left.function_id == right.function_id);
    Ok(())
}

fn argument_schema_promotion_score(
    entry: &CapabilityRegistryEntry,
    arguments: &Value,
) -> Option<f32> {
    let mut normalized_arguments = arguments.clone();
    let mut ignored_corrections = Vec::new();
    normalize_target_arguments(
        &entry.function,
        &mut normalized_arguments,
        &mut ignored_corrections,
    );
    let supplied = normalized_arguments
        .as_object()
        .filter(|object| !object.is_empty())?;
    if validate_target_payload(entry, &normalized_arguments).is_err() {
        return None;
    }

    let properties = schema_property_names(entry.function.request_schema.as_ref()?);
    if properties.is_empty() {
        return None;
    }
    let matched = supplied
        .keys()
        .filter(|key| properties.contains(key.as_str()))
        .count();
    if matched == 0 {
        return None;
    }
    let required = schema_required_property_names(entry.function.request_schema.as_ref()?);
    let required_matched = required
        .iter()
        .filter(|key| supplied.contains_key(**key))
        .count();
    Some(50.0 + (matched as f32) + (required_matched as f32 * 2.0))
}

enum ArgumentSchemaFit {
    Compatible,
    MissingRequired,
    Incompatible(String),
}

fn argument_schema_fit_for_hit(
    hit: &CapabilityIndexHit,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
) -> ArgumentSchemaFit {
    let Some(entry) = snapshot
        .entries
        .iter()
        .find(|entry| entry.function_id == hit.function_id)
    else {
        return ArgumentSchemaFit::Incompatible(
            "candidate is not present in the live registry snapshot".to_owned(),
        );
    };
    let mut normalized_arguments = arguments.clone();
    let mut ignored_corrections = Vec::new();
    normalize_target_arguments(
        &entry.function,
        &mut normalized_arguments,
        &mut ignored_corrections,
    );
    match validate_target_payload(entry, &normalized_arguments) {
        Ok(()) => ArgumentSchemaFit::Compatible,
        Err(error) if run::is_missing_required_argument_error(&error) => {
            ArgumentSchemaFit::MissingRequired
        }
        Err(error) => ArgumentSchemaFit::Incompatible(error.to_string()),
    }
}

fn rejected_candidate_summary(
    hit: &CapabilityIndexHit,
    reason: &str,
    message: impl Into<String>,
) -> Value {
    let mut summary = orchestration_candidate_summary(hit);
    if let Some(object) = summary.as_object_mut() {
        object.insert("rejectionReason".to_owned(), json!(reason));
        object.insert("rejectionMessage".to_owned(), json!(message.into()));
    }
    summary
}

fn deterministic_operator_status_route(
    intent: &str,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
) -> Result<Option<CapabilityIndexHit>, CapabilityError> {
    for function_id in intent_operator_status_targets(intent) {
        if let Some(hit) = deterministic_hit_for_function(
            function_id,
            snapshot,
            constraints,
            "deterministic_operator_status",
        )? {
            return Ok(Some(hit));
        }
    }
    Ok(None)
}

fn intent_operator_status_targets(intent: &str) -> Vec<&'static str> {
    let words = positive_intent_words(intent);
    if words.is_empty() {
        return Vec::new();
    }
    let status_words = [
        "current",
        "status",
        "summary",
        "available",
        "list",
        "inspect",
        "report",
        "count",
        "recent",
    ];
    if !status_words.iter().any(|word| words.contains(*word)) {
        return Vec::new();
    }

    let mut targets = Vec::new();
    if ["model", "models", "provider", "providers"]
        .iter()
        .any(|word| words.contains(*word))
    {
        targets.push("model::list");
    }
    if [
        "setting",
        "settings",
        "preference",
        "preferences",
        "profile",
        "configuration",
        "config",
    ]
    .iter()
    .any(|word| words.contains(*word))
    {
        targets.push("settings::get");
    }
    if ["log", "logs"].iter().any(|word| words.contains(*word)) {
        targets.push("logs::recent");
    }
    if [
        "metric",
        "metrics",
        "server",
        "engine",
        "invocation",
        "invocations",
        "trace",
        "traces",
    ]
    .iter()
    .any(|word| words.contains(*word))
        || (words.contains("event") || words.contains("events")) && words.contains("count")
    {
        targets.push("observability::metrics_snapshot");
    }
    targets
}

pub(super) fn lacks_sufficient_intent_resolution_evidence(
    intent: &str,
    arguments: &Value,
    selected: &CapabilityIndexHit,
) -> bool {
    if intent_strongly_matches_hit(intent, selected) {
        return false;
    }
    if arguments
        .as_object()
        .is_some_and(|object| !object.is_empty())
    {
        return false;
    }
    if selected.matched_by == "local_lexical" {
        return true;
    }
    if selected.fused_score >= MIN_UNANCHORED_INTENT_SCORE {
        return false;
    }
    true
}

pub(super) fn decomposition_phase_details(
    resolve: &OrchestrationResolve,
    target: &ResolvedCapabilityTarget,
    intent: Option<&str>,
    arguments: &Value,
) -> Option<Value> {
    if target.entry.function.id.as_str() == "resource::list" {
        if arguments
            .get("kind")
            .and_then(Value::as_str)
            .is_some_and(|kind| !kind.trim().is_empty())
        {
            return None;
        }
        let requests = intent_resource_kind_requests(intent?);
        if requests.len() <= 1 {
            return None;
        }
        let suggested_calls = requests
            .iter()
            .map(|request| {
                json!({
                    "intent": format!("List {} resources", request.kind),
                    "target": "resource::list",
                    "arguments": { "kind": request.kind }
                })
            })
            .collect::<Vec<_>>();
        return Some(json!({
            "phase": "prepare",
            "resolveMode": resolve.mode,
            "candidates": resolve.candidates,
            "rejectedCandidates": resolve.rejected_candidates,
            "searchStatus": resolve.search_status,
            "selectedTarget": {
                "contractId": target.entry.contract_id.as_str(),
                "implementationId": target.entry.implementation_id.as_str(),
                "functionId": target.entry.function.id.as_str(),
                "catalogRevision": target.entry.catalog_revision,
                "schemaDigest": target.entry.schema_digest.as_str(),
            },
            "decomposition": {
                "reason": "multiple_resource_kinds_for_single_inventory_request",
                "targetCount": requests.len(),
            },
            "guidance": {
                "kind": "one_resource_kind_per_execute",
                "message": "resource inventory requests should list one resource kind per execute call so the result stays bounded and auditable. The suggested calls are guidance, not automatic retries.",
                "suggestedCalls": suggested_calls,
            },
            "suggestedCalls": suggested_calls,
        }));
    }
    if target.entry.function.id.as_str() != "filesystem::read_file" {
        return None;
    }
    if arguments
        .get("path")
        .and_then(Value::as_str)
        .is_some_and(|path| !path.trim().is_empty())
    {
        return None;
    }
    let requests = intent_file_read_requests(intent?);
    if requests.len() <= 1 {
        return None;
    }
    let suggested_calls = requests
        .iter()
        .map(|request| {
            let mut arguments = json!({ "path": request.path });
            if let Some(object) = arguments.as_object_mut() {
                if let Some(start_line) = request.start_line {
                    object.insert("startLine".to_owned(), json!(start_line));
                }
                if let Some(end_line) = request.end_line {
                    object.insert("endLine".to_owned(), json!(end_line));
                }
            }
            json!({
                "intent": format!("Read {}", request.path),
                "target": "filesystem::read_file",
                "arguments": arguments
            })
        })
        .collect::<Vec<_>>();
    Some(json!({
        "phase": "prepare",
        "resolveMode": resolve.mode,
        "candidates": resolve.candidates,
        "rejectedCandidates": resolve.rejected_candidates,
        "searchStatus": resolve.search_status,
        "selectedTarget": {
            "contractId": target.entry.contract_id.as_str(),
            "implementationId": target.entry.implementation_id.as_str(),
            "functionId": target.entry.function.id.as_str(),
            "catalogRevision": target.entry.catalog_revision,
            "schemaDigest": target.entry.schema_digest.as_str(),
        },
        "decomposition": {
            "reason": "multiple_files_for_single_target",
            "targetCount": requests.len(),
        },
        "guidance": {
            "kind": "one_target_per_execute",
            "message": "filesystem::read_file reads one path per execute call. The suggested calls are guidance, not automatic retries. If the user still wants the reads performed, call execute separately for each suggested request so every child invocation is explicit and auditable; if the user asked only to report the decomposition, stop and report this result.",
            "suggestedCalls": suggested_calls,
        },
        "suggestedCalls": suggested_calls,
    }))
}

pub(super) fn decomposition_result_message(details: &Value) -> String {
    let mut message = "execute needs decomposition before child execution: the selected capability accepts one target per call. No child invocation was created. Suggested calls are available for a follow-up only if the user wants the work performed.".to_owned();
    let Some(calls) = details.get("suggestedCalls").and_then(Value::as_array) else {
        return message;
    };
    if calls.is_empty() {
        return message;
    }
    message.push_str("\nSuggested execute calls:");
    for (index, call) in calls.iter().take(5).enumerate() {
        let target = call
            .get("target")
            .and_then(Value::as_str)
            .unwrap_or("<target>");
        let arguments = call.get("arguments").cloned().unwrap_or_else(|| json!({}));
        message.push_str(&format!(
            "\n{}. target={} arguments={}",
            index + 1,
            target,
            compact_json(&arguments)
        ));
    }
    if calls.len() > 5 {
        message.push_str(&format!(
            "\n... {} additional calls omitted",
            calls.len() - 5
        ));
    }
    message
}

fn compact_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".to_owned())
}

fn deterministic_hit_for_function(
    function_id: &str,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
    matched_by: &str,
) -> Result<Option<CapabilityIndexHit>, CapabilityError> {
    let Some(entry) = snapshot
        .entries
        .iter()
        .find(|entry| entry.function_id == function_id)
    else {
        return Ok(None);
    };
    let hit = orchestration_hit_from_entry(entry, matched_by, 100.0);
    if !orchestration_constraints_allow_hit(constraints, &hit)? {
        return Ok(None);
    }
    Ok(Some(hit))
}

pub(super) fn orchestration_hit_from_entry(
    entry: &CapabilityRegistryEntry,
    matched_by: &str,
    score: f32,
) -> CapabilityIndexHit {
    let document = entry.search_document();
    CapabilityIndexHit {
        kind: document.kind,
        capability_id: document.capability_id,
        contract_id: document.contract_id,
        implementation_id: document.implementation_id,
        plugin_id: document.plugin_id,
        worker_id: document.worker_id,
        function_id: document.function_id,
        catalog_revision: document.catalog_revision,
        schema_digest: document.schema_digest,
        trust_tier: document.trust_tier,
        health: document.health,
        visibility: document.visibility,
        effect_class: document.effect_class,
        risk_level: document.risk_level,
        lexical_score: score,
        vector_score: None,
        fused_score: score,
        matched_by: matched_by.to_owned(),
        snippet: bounded_snippet(&document.text),
        requires_inspect: requires_fresh_revision(&entry.function),
        recipe: document.recipe,
    }
}

pub(super) fn bounded_snippet(value: &str) -> String {
    const MAX: usize = 240;
    let mut snippet = value.chars().take(MAX).collect::<String>();
    if value.chars().count() > MAX {
        snippet.push_str("...");
    }
    snippet
}

pub(super) fn orchestration_candidate_summary(hit: &CapabilityIndexHit) -> Value {
    json!({
        "kind": hit.kind.as_str(),
        "contractId": hit.contract_id.as_str(),
        "implementationId": hit.implementation_id.as_str(),
        "functionId": hit.function_id.as_str(),
        "score": hit.fused_score,
        "matchedBy": hit.matched_by.as_str(),
        "riskLevel": hit.risk_level.as_str(),
        "effectClass": hit.effect_class.as_str(),
        "snippet": hit.snippet.as_str(),
    })
}
