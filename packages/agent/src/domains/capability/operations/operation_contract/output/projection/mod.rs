//! Provider-visible model-context evidence projection.
//!
//! The turn runner stores full capability details for UI, audit, and replay,
//! but providers only receive this bounded projection appended to result text.
//! Model-facing projections are agent-first: operation results should expose the
//! exact bounded contract data the model needs to choose the next capability call
//! before optimizing for UI readability. Keep the field allowlists narrow: ids,
//! lifecycle/status, refs, truncation metadata, preflight selectors, required
//! fields, and schema failure coordinates are useful to the model; raw content,
//! local paths, commands, process ids, secrets, grant ids, and authority ids
//! stay out of this channel. Trace projections also preserve bounded top-level proof metadata so
//! the model can verify redaction and status semantics without inferring from
//! missing raw fields.
//! Context-control action lists expose exact provider-safe inspect arguments for
//! each returned action so the model can drill into durable audit records without
//! guessing resource ids.
//! Catalog projections expose immediately callable matches and effect-excluded
//! matches as separate bounded lists. Both include exact inspect ids, while
//! effect-excluded rows omit direct invocation arguments. The broader merged
//! target list remains durable audit data instead of duplicating the same rows
//! in provider context.
//! Broad cockpit projections are a compact operation directory by default;
//! exact `targetOperation` cockpit calls keep the deep readiness, preflight,
//! binding, shadow, route, rollback, and agent-path detail. This keeps the
//! capability map discoverable without flooding the next provider turn.
//! Routed Git projections preserve the bounded route mode/source and live-code
//! execution facts needed to distinguish accepted-shadow replay from a built-in
//! call, while route-event and runtime resource identifiers remain audit-only.
//! Git status also projects repository-tree inputs as explicitly non-durable,
//! content-free navigation facts; complete copy-ready ref objects remain JSON
//! strings so the generic evidence normalizer cannot misclassify them as
//! resource-store records.
//! Filesystem reads use an operation-specific projection rather than the
//! generic metadata allowlist: bounded text chunks, directory/path matches,
//! search previews, and read-only diffs remain useful to the provider while
//! relative-path validation, credential redaction, and explicit source/provider
//! truncation keep local data under the provider boundary. Source owners report
//! actual result/walk overflow, while canonical normalized collections own final
//! provider item counts after structural byte-budget reduction. Filesystem mutations
//! retain the metadata/resource-only projection and never echo proposed file
//! bodies or diffs.
//! Filesystem text redaction preserves a slash literal only when explicit source
//! syntax owns it as a quoted route-call argument (for example,
//! `router.get("/api/users")`). Generic quoted, unquoted, Markdown-code, Windows,
//! UNC, and ambiguous absolute paths fail closed as local paths.

use std::sync::LazyLock;

use crate::shared::foundation::redaction::redact_sensitive_content;
#[cfg(test)]
use crate::shared::protocol::model_capabilities::CapabilityResult;
use regex::Regex;
use serde_json::{Map, Value, json};

use super::spec::OutputProfile;

mod filesystem;

#[cfg(test)]
fn extract_model_context_result_text(result: &CapabilityResult) -> String {
    super::provider_result_text(tested_operation(result), result)
}

#[cfg(test)]
fn tested_operation(result: &CapabilityResult) -> &str {
    result
        .details
        .as_ref()
        .and_then(|details| {
            details
                .get("primitiveOperation")
                .or_else(|| details.get("operation"))
                .and_then(Value::as_str)
        })
        .unwrap_or("unknown")
}

const MODEL_CONTEXT_STRING_MAX_CHARS: usize = 800;
const MODEL_CONTEXT_ARRAY_MAX_ITEMS: usize = 20;
const MODEL_CONTEXT_OPERATION_DIRECTORY_MAX_ITEMS: usize = 12;
const MODEL_CONTEXT_OBJECT_MAX_KEYS: usize = 80;

pub(super) fn project_evidence(
    operation: &str,
    profile: OutputProfile,
    details: Option<&Value>,
) -> Option<Value> {
    let details = details?;
    let mut projected = if let Some(projected) = project_error_evidence(details) {
        projected
    } else {
        match profile {
            OutputProfile::Catalog => project_catalog_evidence(details),
            OutputProfile::Git => project_git_evidence(details),
            OutputProfile::TraceAudit => match operation {
                "log_recent" => project_log_evidence(details),
                "trace_list" | "trace_get" => project_trace_evidence(details),
                _ => project_metadata_operation_evidence(operation, details),
            },
            OutputProfile::Context => project_context_control_evidence(operation, details),
            OutputProfile::Resource => match operation {
                "goal_create" | "goal_list" | "goal_inspect" | "goal_cancel"
                | "question_create" | "question_list" | "question_inspect" | "question_answer" => {
                    project_goal_question_evidence(operation, details)
                }
                _ => project_metadata_operation_evidence(operation, details),
            },
            OutputProfile::Governance if operation == "capability_binding_cockpit_overview" => {
                project_capability_cockpit_evidence(details)
            }
            OutputProfile::Web => project_web_evidence(operation, details),
            OutputProfile::Filesystem => filesystem::project_evidence(operation, details)
                .or_else(|| project_metadata_operation_evidence(operation, details)),
            OutputProfile::Summary | OutputProfile::Runtime | OutputProfile::Governance => {
                project_metadata_operation_evidence(operation, details)
            }
        }?
    };
    if let (Value::Object(projected), Some(outcome)) =
        (&mut projected, details.get("engineOutcome"))
    {
        projected.insert("engineOutcome".to_owned(), project_engine_outcome(outcome));
    }
    Some(projected)
}

fn project_web_evidence(operation: &str, details: &Value) -> Option<Value> {
    let web = details.get("web")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    projected.insert("operation".to_owned(), json!(operation));

    let mut web_projected = Map::new();
    for key in ["schemaVersion", "operation"] {
        copy_key(&mut web_projected, web, key);
    }
    match operation {
        "web_robots_check" => {
            for key in [
                "targetUrl",
                "httpStatus",
                "missing",
                "webRobotsPolicyResourceId",
                "webRobotsPolicyVersionId",
            ] {
                copy_key(&mut web_projected, web, key);
            }
            copy_web_object(&mut web_projected, web, "policy", &["decision", "reason"]);
            copy_web_object(
                &mut web_projected,
                web,
                "bodyEvidence",
                &[
                    "capturedBytes",
                    "maxRobotsBytes",
                    "robotsBytesTruncated",
                    "malformedUtf8",
                ],
            );
            copy_web_object(
                &mut web_projected,
                web,
                "redirects",
                &["maxRedirects", "observedRedirects", "finalUrlChanged"],
            );
            copy_web_object(&mut web_projected, web, "cache", &["hit", "resourceId"]);
            copy_web_collection(
                &mut web_projected,
                web,
                "resourceRefs",
                project_web_reference,
            );
        }
        "web_fetch" | "web_source_archive" => {
            for key in [
                "webSourceResourceId",
                "webSourceVersionId",
                "webRobotsPolicyResourceId",
                "webRobotsPolicyVersionId",
            ] {
                copy_key(&mut web_projected, web, key);
            }
            copy_web_object(&mut web_projected, web, "cache", &["hit", "resourceId"]);
            copy_web_collection(
                &mut web_projected,
                web,
                "resourceRefs",
                project_web_reference,
            );
            copy_web_collection(
                &mut web_projected,
                web,
                "robotsPolicyRefs",
                project_web_reference,
            );
        }
        "web_source_inspect" => {
            if let Some(source) = web.get("source") {
                web_projected.insert("source".to_owned(), project_web_source(source));
            }
            copy_web_object(
                &mut web_projected,
                web,
                "network",
                &["performed", "requiredPolicy"],
            );
        }
        "web_source_list" => {
            if let Some(sources) = web.get("sources").and_then(Value::as_array) {
                web_projected.insert(
                    "sources".to_owned(),
                    bounded_web_collection(sources, project_web_source),
                );
            }
            copy_key(&mut web_projected, web, "limits");
            copy_web_object(
                &mut web_projected,
                web,
                "network",
                &["performed", "requiredPolicy"],
            );
        }
        _ => return project_metadata_operation_evidence(operation, details),
    }
    projected.insert("web".to_owned(), Value::Object(web_projected));
    Some(Value::Object(projected))
}

fn project_web_source(source: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "requestedUrl",
        "finalUrl",
        "state",
        "fetchedAt",
        "status",
        "contentType",
        "title",
        "capturedBytes",
        "outputTextBytes",
        "snippet",
    ] {
        copy_key(&mut projected, source, key);
    }
    copy_web_object(
        &mut projected,
        source,
        "byteEvidence",
        &[
            "capturedBytes",
            "maxResponseBytes",
            "responseBytesTruncated",
        ],
    );
    copy_web_object(
        &mut projected,
        source,
        "textEvidence",
        &[
            "snippet",
            "snippetBytes",
            "maxSnippetBytes",
            "snippetTruncated",
            "storedTextBytes",
            "storedMaxOutputBytes",
            "storedOutputTextTruncated",
            "extractedTextBytes",
            "extractedTextTruncated",
            "binaryBodyOmitted",
        ],
    );
    copy_web_object(
        &mut projected,
        source,
        "extraction",
        &[
            "mode",
            "extractorId",
            "extractorVersion",
            "title",
            "titleBytes",
            "maxTitleBytes",
            "titleTruncated",
            "extractedTextBytes",
            "extractedTextTruncated",
        ],
    );
    copy_web_object(
        &mut projected,
        source,
        "truncation",
        &[
            "responseBytesTruncated",
            "maxResponseBytes",
            "storedOutputTextTruncated",
            "storedMaxOutputBytes",
            "binaryBodyOmitted",
            "snippetBytes",
            "maxPreviewBytes",
            "snippetTruncated",
        ],
    );
    copy_web_object(
        &mut projected,
        source,
        "redaction",
        &["applied", "replacementCount", "policy"],
    );
    copy_web_object(
        &mut projected,
        source,
        "redirects",
        &["maxRedirects", "observedRedirects", "finalUrlChanged"],
    );
    copy_web_object(
        &mut projected,
        source,
        "archive",
        &["state", "reason", "archivedAt"],
    );
    for key in [
        "traceRefs",
        "replayRefs",
        "robotsPolicyRefs",
        "resourceRefs",
    ] {
        copy_web_collection(&mut projected, source, key, project_web_reference);
    }
    if let Some(reference) = source.pointer("/resourceRefs/0") {
        if let Some(resource_id) = reference.get("resourceId") {
            projected.insert(
                "webSourceResourceId".to_owned(),
                bounded_model_context_value(resource_id),
            );
        }
        if let Some(version_id) = reference.get("versionId") {
            projected.insert(
                "webSourceVersionId".to_owned(),
                bounded_model_context_value(version_id),
            );
        }
        if let (Some(resource_id), Some(version_id)) = (
            reference.get("resourceId").and_then(Value::as_str),
            reference.get("versionId").and_then(Value::as_str),
        ) {
            projected.insert(
                "inspectArguments".to_owned(),
                json!({
                    "operation": "web_source_inspect",
                    "webSourceResourceId": resource_id,
                    "webSourceVersionId": version_id
                }),
            );
        }
    }
    Value::Object(projected)
}

fn copy_web_object(target: &mut Map<String, Value>, source: &Value, key: &str, fields: &[&str]) {
    let Some(object) = source.get(key) else {
        return;
    };
    let mut projected = Map::new();
    for field in fields {
        copy_key(&mut projected, object, field);
    }
    if !projected.is_empty() {
        target.insert(key.to_owned(), Value::Object(projected));
    }
}

fn project_web_reference(reference: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "role",
        "kind",
        "resourceId",
        "versionId",
        "schemaId",
        "lifecycle",
        "traceId",
        "invocationId",
        "functionId",
    ] {
        copy_key(&mut projected, reference, key);
    }
    Value::Object(projected)
}

fn copy_web_collection(
    target: &mut Map<String, Value>,
    source: &Value,
    key: &str,
    project: fn(&Value) -> Value,
) {
    if let Some(items) = source.get(key).and_then(Value::as_array) {
        target.insert(key.to_owned(), bounded_web_collection(items, project));
    }
}

fn bounded_web_collection(items: &[Value], project: fn(&Value) -> Value) -> Value {
    let projected = items
        .iter()
        .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
        .map(project)
        .collect::<Vec<_>>();
    json!({
        "total": items.len(),
        "returned": projected.len(),
        "truncated": items.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS,
        "omitted": items.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS),
        "items": projected
    })
}

fn project_engine_outcome(outcome: &Value) -> Value {
    let mut projected = Map::new();
    copy_key(&mut projected, outcome, "replayed");
    copy_key(&mut projected, outcome, "replaySourceInvocationRef");
    Value::Object(projected)
}

fn project_catalog_evidence(details: &Value) -> Option<Value> {
    let discovery = details.get("catalogDiscovery")?;
    let operation = details
        .get("primitiveOperation")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    copy_key(&mut projected, discovery, "kind");
    copy_key(&mut projected, discovery, "id");
    copy_key(&mut projected, discovery, "aliasResolvedFrom");
    copy_key(&mut projected, discovery, "operation");
    copy_key(&mut projected, discovery, "providerCallable");
    copy_key(&mut projected, discovery, "providerCallableReason");
    copy_key(&mut projected, discovery, "summary");
    if operation == "catalog_inspect" {
        copy_key(&mut projected, discovery, "inputSchema");
        copy_key(&mut projected, discovery, "outputSchema");
        copy_key(&mut projected, discovery, "modelFacingInvocation");
        copy_key(&mut projected, discovery, "capabilityPool");
        copy_key(&mut projected, discovery, "agentUsage");
        copy_key(&mut projected, discovery, "schema");
    }
    copy_key(&mut projected, discovery, "executeOperationSearch");
    if let Some(matches) = discovery
        .get("executeOperationMatches")
        .and_then(Value::as_array)
    {
        projected.insert(
            "executeOperationMatches".to_owned(),
            Value::Array(
                matches
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_execute_operation_match)
                    .collect(),
            ),
        );
        if matches.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "executeOperationMatchesOmitted".to_owned(),
                json!(matches.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    if let Some(excluded) = discovery
        .get("effectClassExcludedOperationMatches")
        .and_then(Value::as_array)
    {
        projected.insert(
            "effectClassExcludedOperationMatches".to_owned(),
            Value::Array(
                excluded
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_effect_class_excluded_operation_match)
                    .collect(),
            ),
        );
        if excluded.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "effectClassExcludedOperationMatchesOmitted".to_owned(),
                json!(excluded.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    if let Some(next_step) = discovery.get("agentNextStep") {
        projected.insert(
            "agentNextStep".to_owned(),
            project_catalog_agent_next_step(next_step),
        );
    }
    copy_key(&mut projected, discovery, "unsupportedOperationCandidate");
    if let Some(recovery) = discovery.get("unsupportedOperationRecovery") {
        projected.insert(
            "unsupportedOperationRecovery".to_owned(),
            project_unsupported_operation_recovery(recovery),
        );
    }
    if let Some(functions) = discovery.get("functions").and_then(Value::as_array) {
        projected.insert(
            "functions".to_owned(),
            Value::Array(
                functions
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_catalog_function)
                    .collect(),
            ),
        );
        if functions.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "functionsOmitted".to_owned(),
                json!(functions.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    Some(Value::Object(projected))
}

fn project_catalog_agent_next_step(next_step: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["priority", "reason", "thenFollow", "completionRule"] {
        copy_key(&mut projected, next_step, key);
    }
    if let Some(primary) = next_step.get("primaryInspection") {
        projected.insert(
            "primaryInspection".to_owned(),
            bounded_model_context_value(primary),
        );
    }
    Value::Object(projected)
}

fn project_unsupported_operation_recovery(recovery: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["query", "canonicalQuery", "supportedOperation", "guidance"] {
        copy_key(&mut projected, recovery, key);
    }
    if let Some(alternatives) = recovery
        .get("closestReadOnlyAlternatives")
        .and_then(Value::as_array)
    {
        projected.insert(
            "closestReadOnlyAlternatives".to_owned(),
            Value::Array(
                alternatives
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(|alternative| {
                        let mut item = Map::new();
                        for key in [
                            "operation",
                            "tool",
                            "arguments",
                            "readOnlyInspectionSafe",
                            "reason",
                        ] {
                            copy_key(&mut item, alternative, key);
                        }
                        Value::Object(item)
                    })
                    .collect(),
            ),
        );
    }
    Value::Object(projected)
}

fn project_catalog_function(function: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "id",
        "name",
        "description",
        "ownerWorkerId",
        "visibility",
        "effectClass",
        "riskLevel",
        "modelFacingInvocation",
    ] {
        copy_key(&mut projected, function, key);
    }
    Value::Object(projected)
}

fn project_execute_operation_match(operation: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "operation",
        "tool",
        "arguments",
        "catalogInspectId",
        "schemaInspection",
        "matchKind",
        "score",
    ] {
        copy_key(&mut projected, operation, key);
    }
    if let Some(pool) = operation.get("capabilityPool") {
        projected.insert("capabilityPool".to_owned(), project_cockpit_pool(pool));
    }
    if let Some(agent_usage) = operation.get("agentUsage") {
        projected.insert(
            "agentUsage".to_owned(),
            project_cockpit_agent_usage_summary(agent_usage),
        );
    }
    Value::Object(projected)
}

fn project_effect_class_excluded_operation_match(operation: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "operation",
        "tool",
        "catalogInspectId",
        "schemaInspection",
        "matchKind",
        "score",
        "capabilityPool",
        "excludedByEffectClass",
        "exclusionReason",
    ] {
        copy_key(&mut projected, operation, key);
    }
    if let Some(agent_usage) = operation.get("agentUsage") {
        projected.insert(
            "agentUsage".to_owned(),
            project_effect_class_excluded_agent_usage(agent_usage),
        );
    }
    projected.insert(
        "invokeArgumentsOmitted".to_owned(),
        json!("excluded_by_active_effect_filter"),
    );
    Value::Object(projected)
}

fn project_effect_class_excluded_agent_usage(agent_usage: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "operation",
        "tool",
        "audience",
        "callable",
        "defaultUse",
        "effect",
        "preflight",
        "failureRecovery",
    ] {
        copy_key(&mut projected, agent_usage, key);
    }
    projected.insert("currentSearchCallable".to_owned(), Value::Bool(false));
    projected.insert(
        "invokeArgumentsOmitted".to_owned(),
        json!("excluded_by_active_effect_filter"),
    );
    Value::Object(projected)
}

fn project_git_evidence(details: &Value) -> Option<Value> {
    let git = details.get("git")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    let mut git_projected = Map::new();
    for key in ["schemaVersion", "operation", "status", "dirty"] {
        copy_key(&mut git_projected, git, key);
    }
    copy_pointer_as_key(
        &mut git_projected,
        git,
        "/path/relativePath",
        "relativePath",
    );
    copy_pointer_as_key(
        &mut git_projected,
        git,
        "/repository/repositoryRoot/relativePath",
        "repositoryRelativePath",
    );
    for (pointer, key) in [
        ("/repository/branch", "branch"),
        ("/repository/detachedHead", "detachedHead"),
        ("/repository/hasUpstream", "hasUpstream"),
        ("/repository/ahead", "ahead"),
        ("/repository/behind", "behind"),
        ("/repository/indexTreeTruncated", "indexTreeTruncated"),
        (
            "/repository/indexTreeOidUnavailable",
            "indexTreeOidUnavailable",
        ),
    ] {
        copy_pointer_as_key(&mut git_projected, git, pointer, key);
    }
    if let Some(summary) = git.get("summary") {
        let mut summary_projected = Map::new();
        for key in [
            "stagedCount",
            "unstagedCount",
            "untrackedCount",
            "conflictedCount",
        ] {
            copy_key(&mut summary_projected, summary, key);
        }
        if !summary_projected.is_empty() {
            git_projected.insert("summary".to_owned(), Value::Object(summary_projected));
        }
    }
    let mut navigation = Map::from_iter([
        ("available".to_owned(), Value::Bool(false)),
        (
            "referenceClass".to_owned(),
            Value::String("not_returned".to_owned()),
        ),
        ("durableResource".to_owned(), Value::Bool(false)),
        ("resourceCreationPerformed".to_owned(), Value::Bool(false)),
        (
            "consumerOperation".to_owned(),
            Value::String("repository_tree_snapshot".to_owned()),
        ),
    ]);
    if let Some(snapshot_input) = git
        .pointer("/repository/repositoryTreeSnapshotInput")
        .and_then(Value::as_object)
    {
        navigation.insert("available".to_owned(), Value::Bool(true));
        for key in [
            "referenceClass",
            "durableResource",
            "resourceCreationPerformed",
            "consumerOperation",
            "copySemantics",
            "contentFree",
            "rawRepositoryContentsIncluded",
            "pathEntrySource",
            "treeObjectRef",
        ] {
            if let Some(value) = snapshot_input.get(key) {
                navigation.insert(key.to_owned(), bounded_model_context_value(value));
            }
        }
        for (key, projected_key) in [
            ("repositoryRef", "repositoryRefJson"),
            ("rootRef", "rootRefJson"),
            ("headRef", "headRefJson"),
        ] {
            if let Some(value) = snapshot_input.get(key)
                && !value.is_null()
                && let Ok(encoded) = serde_json::to_string(value)
            {
                navigation.insert(
                    projected_key.to_owned(),
                    Value::String(truncate_model_context_string(&encoded)),
                );
            }
        }
        navigation.insert("completeRefObjectsRequired".to_owned(), Value::Bool(true));
        navigation.insert("bareIdsAccepted".to_owned(), Value::Bool(false));
    }
    git_projected.insert("repositoryNavigation".to_owned(), Value::Object(navigation));
    if let Some(evidence) = git.get("evidence") {
        let mut evidence_projected = Map::new();
        copy_key(&mut evidence_projected, evidence, "statusTruncated");
        copy_key(&mut evidence_projected, evidence, "statusLimitBytes");
        if let Some(porcelain) = evidence.get("statusPorcelainV1Z").and_then(Value::as_str) {
            evidence_projected.insert(
                "statusPorcelainEmpty".to_owned(),
                json!(porcelain.is_empty()),
            );
        }
        if let Some(refs) = evidence.get("resourceRefs").and_then(Value::as_array) {
            evidence_projected.insert(
                "resourceRefs".to_owned(),
                json!({
                    "total": refs.len(),
                    "returned": refs
                        .iter()
                        .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                        .map(bounded_model_context_value)
                        .collect::<Vec<_>>(),
                    "truncated": refs.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS,
                    "omitted": refs.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS),
                }),
            );
        }
        if !evidence_projected.is_empty() {
            git_projected.insert("evidence".to_owned(), Value::Object(evidence_projected));
        }
    }
    if let Some(dynamic_replacement) = details.get("dynamicReplacement") {
        let mut replacement_projected = Map::new();
        for key in [
            "operation",
            "routeState",
            "routeVersion",
            "candidateOwner",
            "candidateLabel",
            "projectionBoundaryEvaluated",
            "projectionBoundaryState",
            "acceptedProjectionReplayed",
            "routeExecutionMode",
            "candidateProjectionSource",
            "liveModuleCodeExecutionSupported",
            "liveModuleCodeExecuted",
            "builtInProjectionUsed",
            "networkPolicy",
            "failClosed",
            "failureKind",
        ] {
            copy_key(&mut replacement_projected, dynamic_replacement, key);
        }
        if !replacement_projected.is_empty() {
            projected.insert(
                "dynamicReplacement".to_owned(),
                Value::Object(replacement_projected),
            );
        }
    }
    projected.insert("git".to_owned(), Value::Object(git_projected));
    Some(Value::Object(projected))
}

fn project_capability_cockpit_evidence(details: &Value) -> Option<Value> {
    let cockpit = details.get("capabilityBinding")?;
    let targeted = cockpit
        .get("target")
        .is_some_and(|target| !target.is_null());
    let operations = if let Some(target) = cockpit.get("target").filter(|target| !target.is_null())
    {
        vec![target]
    } else {
        cockpit
            .get("operations")
            .and_then(Value::as_array)
            .map(|operations| operations.iter().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    if let Some(summary) = cockpit.get("summary") {
        projected.insert("summary".to_owned(), project_cockpit_summary(summary));
    }
    copy_key(&mut projected, cockpit, "operationList");
    projected.insert(
        "coverage".to_owned(),
        json!({
            "operationsReturned": operations.len(),
            "missingCapabilityPool": operations
                .iter()
                .filter(|operation| operation.get("capabilityPool").is_none())
                .count(),
            "missingAgentUsage": operations
                .iter()
                .filter(|operation| operation.get("agentUsage").is_none())
                .count(),
        }),
    );
    if !targeted {
        projected.insert(
            "agentUse".to_owned(),
            json!({
                "primaryUse": "Treat operationDirectory as the agent-facing capability map. Choose an operation, copy its capability::execute arguments, satisfy preflight authority/resource selectors and required payload fields, then call it directly.",
                "normalWork": "Prefer audience=session_work and callable=true operations for user tasks.",
                "diagnostics": "Use audience=agent_diagnostics operations to inspect traces, logs, catalog state, and verification evidence.",
                "governance": "Use audience=governance operations only for binding, shadow, route, module, or policy workflows; follow preflight exactly.",
                "kernelEvolution": "Kernel-evolution-only operations are inspectable and improvable through source-level review/integration, not runtime-routed.",
                "schemaRule": "Do not infer selectors, authority scopes, or required fields from names. Use the operation entry, catalog inspection, or schema before attempting a call."
            }),
        );
    }
    if !targeted && let Some(families) = cockpit.get("families").and_then(Value::as_array) {
        projected.insert(
            "families".to_owned(),
            Value::Array(
                families
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_cockpit_family)
                    .collect(),
            ),
        );
        if families.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "familiesOmitted".to_owned(),
                json!(families.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    projected.insert(
        "operationDirectory".to_owned(),
        project_cockpit_operation_directory(&operations),
    );
    Some(Value::Object(projected))
}

fn project_cockpit_summary(summary: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "title",
        "detail",
        "totalOperations",
        "returnedOperations",
        "operationListComplete",
        "operationListTruncated",
        "resourceScanComplete",
        "resourceScanTruncated",
        "kernelLocked",
        "governanceLocked",
        "recordPlane",
        "adapterReplaceable",
        "moduleOwned",
        "deferred",
        "activeRoutes",
        "routeCandidates",
        "routeEvents",
        "failedClosedRoutes",
        "rollbackAvailable",
    ] {
        copy_key(&mut projected, summary, key);
    }
    Value::Object(projected)
}

fn project_cockpit_family(family: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "family",
        "label",
        "operations",
        "kernelLocked",
        "governanceLocked",
        "recordPlane",
        "adapterReplaceable",
        "moduleOwned",
        "deferred",
        "bindingActivity",
        "routeActivity",
        "shadowActivity",
    ] {
        copy_key(&mut projected, family, key);
    }
    Value::Object(projected)
}

fn project_cockpit_operation_directory(operations: &[&Value]) -> Value {
    let detailed = operations.len() <= 1;
    json!({
        "total": operations.len(),
        "returned": operations.len().min(MODEL_CONTEXT_OPERATION_DIRECTORY_MAX_ITEMS),
        "truncated": operations.len() > MODEL_CONTEXT_OPERATION_DIRECTORY_MAX_ITEMS,
        "omitted": operations.len().saturating_sub(MODEL_CONTEXT_OPERATION_DIRECTORY_MAX_ITEMS),
        "maxItems": MODEL_CONTEXT_OPERATION_DIRECTORY_MAX_ITEMS,
        "detailPolicy": if detailed {
            "single operation row includes detailed readiness path"
        } else {
            "broad directory is compact; call capability_binding_cockpit_overview with targetOperation for one exact operation when detailed readiness, preflight, binding, shadow, route, rollback, or agentPath data is needed"
        },
        "operations": operations
            .iter()
            .take(MODEL_CONTEXT_OPERATION_DIRECTORY_MAX_ITEMS)
            .map(|operation| project_cockpit_operation_for_agent(operation, detailed))
            .collect::<Vec<_>>()
    })
}

fn project_cockpit_operation_for_agent(operation: &Value, detailed: bool) -> Value {
    let mut projected = Map::new();
    for key in ["name", "family", "familyLabel"] {
        copy_key(&mut projected, operation, key);
    }
    if detailed && let Some(route) = operation.get("route") {
        projected.insert("route".to_owned(), project_cockpit_route(route));
    }
    if let Some(pool) = operation.get("capabilityPool") {
        projected.insert("capabilityPool".to_owned(), project_cockpit_pool(pool));
    }
    if let Some(agent_usage) = operation.get("agentUsage") {
        projected.insert(
            "agentUsage".to_owned(),
            if detailed {
                project_cockpit_agent_usage(agent_usage)
            } else {
                project_cockpit_agent_usage_summary(agent_usage)
            },
        );
    }
    if let Some(readiness) = operation.get("readiness") {
        projected.insert("readiness".to_owned(), project_cockpit_readiness(readiness));
    }
    if let Some(replacement) = operation.get("replacement") {
        projected.insert(
            "replacement".to_owned(),
            project_cockpit_replacement(replacement),
        );
    }
    if let Some(status) = operation.get("status") {
        projected.insert("status".to_owned(), project_cockpit_status(status));
    }
    if detailed {
        if let Some(binding) = operation.get("binding") {
            projected.insert("binding".to_owned(), project_cockpit_binding(binding));
        }
        if let Some(shadow_trial) = operation.get("shadowTrial") {
            projected.insert(
                "shadowTrial".to_owned(),
                project_cockpit_shadow_trial(shadow_trial),
            );
        }
        if let Some(rollback) = operation.get("rollback") {
            projected.insert("rollback".to_owned(), project_cockpit_rollback(rollback));
        }
        if let Some(agent_path) = operation.get("agentPath") {
            projected.insert(
                "agentPath".to_owned(),
                project_cockpit_agent_path(agent_path),
            );
        }
    } else {
        projected.insert(
            "detailNextStep".to_owned(),
            json!({
                "operation": "capability_binding_cockpit_overview",
                "arguments": {
                    "operation": "capability_binding_cockpit_overview",
                    "targetOperation": operation.get("name").cloned().unwrap_or(Value::Null)
                },
                "reason": "Use the exact targetOperation projection for detailed preflight, readiness, binding, shadow, route, rollback, and agentPath data."
            }),
        );
    }
    Value::Object(projected)
}

fn project_cockpit_pool(pool: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "surface",
        "audience",
        "replacementClass",
        "agentDefaultVisibility",
        "minimalityDecision",
        "evolutionPath",
    ] {
        copy_key(&mut projected, pool, key);
    }
    Value::Object(projected)
}

fn project_cockpit_agent_usage(agent_usage: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "tool",
        "operation",
        "arguments",
        "audience",
        "callable",
        "defaultUse",
        "effect",
        "failureRecovery",
    ] {
        copy_key(&mut projected, agent_usage, key);
    }
    if let Some(preflight) = agent_usage.get("preflight") {
        let mut projected_preflight = Map::new();
        for key in [
            "agentStateInherited",
            "authority",
            "authorityScopes",
            "beforeCalling",
            "evidence",
            "example",
            "networkPolicy",
            "readOnlyInstruction",
            "requiredPayloadFields",
            "resourceSelectors",
        ] {
            copy_key(&mut projected_preflight, preflight, key);
        }
        if !projected_preflight.is_empty() {
            projected.insert("preflight".to_owned(), Value::Object(projected_preflight));
        }
    }
    Value::Object(projected)
}

fn project_cockpit_agent_usage_summary(agent_usage: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["tool", "operation", "arguments", "callable", "defaultUse"] {
        copy_key(&mut projected, agent_usage, key);
    }
    if let Some(effect) = agent_usage.get("effect") {
        let mut projected_effect = Map::new();
        for key in [
            "mode",
            "readOnlyInspectionSafe",
            "mutatesState",
            "readOnlyInstruction",
        ] {
            copy_key(&mut projected_effect, effect, key);
        }
        if !projected_effect.is_empty() {
            projected.insert("effect".to_owned(), Value::Object(projected_effect));
        }
    }
    Value::Object(projected)
}

fn project_cockpit_readiness(readiness: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["state", "label", "nextActionLabel", "nextActionDetail"] {
        copy_key(&mut projected, readiness, key);
    }
    Value::Object(projected)
}

fn project_cockpit_replacement(replacement: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "label",
        "canExtend",
        "canReplace",
        "canShadow",
        "governanceBoundary",
    ] {
        copy_key(&mut projected, replacement, key);
    }
    if let Some(target) = replacement.get("target") {
        let mut projected_target = Map::new();
        for key in ["label", "detail"] {
            copy_key(&mut projected_target, target, key);
        }
        if !projected_target.is_empty() {
            projected.insert("target".to_owned(), Value::Object(projected_target));
        }
    }
    Value::Object(projected)
}

fn project_cockpit_status(status: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["kind", "label", "locked", "builtIn", "moduleOwned"] {
        copy_key(&mut projected, status, key);
    }
    Value::Object(projected)
}

fn project_cockpit_binding(binding: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "requested",
        "approved",
        "rejected",
        "activePolicies",
        "failedReplacementAttempts",
        "latestState",
    ] {
        copy_key(&mut projected, binding, key);
    }
    Value::Object(projected)
}

fn project_cockpit_shadow_trial(shadow_trial: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "requested",
        "approved",
        "rejected",
        "runs",
        "passed",
        "failed",
        "aborted",
        "disabled",
        "latestState",
        "evidenceInspectReady",
        "availableForThisOperation",
    ] {
        copy_key(&mut projected, shadow_trial, key);
    }
    if let Some(evidence_refs) = shadow_trial.get("evidenceRefs").and_then(Value::as_array) {
        projected.insert(
            "evidenceRefs".to_owned(),
            Value::Array(
                evidence_refs
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(bounded_model_context_value)
                    .collect(),
            ),
        );
    }
    Value::Object(projected)
}

fn project_cockpit_route(route: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "executionMode",
        "candidateProjectionSource",
        "liveModuleCodeExecutionSupported",
        "executionBoundaryDetail",
        "candidates",
        "bindings",
        "activeRoutes",
        "routeEvents",
        "routedInvocations",
        "failedClosed",
        "disabled",
        "rolledBack",
        "rollbackRecords",
        "rollbackAvailable",
        "disableAvailable",
        "latestState",
        "state",
    ] {
        copy_key(&mut projected, route, key);
    }
    Value::Object(projected)
}

fn project_cockpit_rollback(rollback: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["available", "disableAvailable", "abortAvailable"] {
        copy_key(&mut projected, rollback, key);
    }
    Value::Object(projected)
}

fn project_cockpit_agent_path(agent_path: &Value) -> Value {
    let mut projected = Map::new();
    copy_key(&mut projected, agent_path, "purpose");
    copy_key(&mut projected, agent_path, "adapterExecutionGuidance");
    copy_key(&mut projected, agent_path, "evidenceGuidance");
    if let Some(completion) = agent_path.get("completion") {
        projected.insert(
            "completion".to_owned(),
            project_cockpit_agent_path_completion(completion),
        );
    }
    Value::Object(projected)
}

fn project_cockpit_agent_path_completion(completion: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["state", "action", "finalAnswerGuidance", "readinessVerdict"] {
        copy_key(&mut projected, completion, key);
    }
    if let Some(boundary) = completion.get("readOnlyBoundary") {
        let mut projected_boundary = Map::new();
        for key in [
            "capabilityRequestedMutation",
            "engineAuditPersistence",
            "requiredFinalAnswerSuffix",
        ] {
            copy_key(&mut projected_boundary, boundary, key);
        }
        projected.insert(
            "readOnlyBoundary".to_owned(),
            Value::Object(projected_boundary),
        );
    }
    if let Some(steps) = completion
        .get("governedNextSteps")
        .and_then(Value::as_array)
    {
        projected.insert(
            "governedNextSteps".to_owned(),
            Value::Array(
                steps
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(|step| {
                        let mut projected_step = Map::new();
                        for key in ["order", "operation", "effect", "requiresApproval"] {
                            copy_key(&mut projected_step, step, key);
                        }
                        Value::Object(projected_step)
                    })
                    .collect(),
            ),
        );
    }
    if let Some(blocked) = completion.get("doNotInspect").and_then(Value::as_array) {
        projected.insert(
            "doNotInspect".to_owned(),
            Value::Array(
                blocked
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(bounded_model_context_value)
                    .collect(),
            ),
        );
    }
    Value::Object(projected)
}

fn project_log_evidence(details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    let entries = details.get("entries")?.as_array()?;
    projected.insert(
        "entries".to_owned(),
        Value::Array(
            entries
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .map(|entry| {
                    let mut projected = Map::new();
                    for key in [
                        "id",
                        "timestamp",
                        "level",
                        "component",
                        "message",
                        "sessionId",
                        "traceId",
                        "errorMessage",
                    ] {
                        copy_key(&mut projected, entry, key);
                    }
                    Value::Object(projected)
                })
                .collect(),
        ),
    );
    if entries.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
        projected.insert(
            "entriesOmitted".to_owned(),
            json!(entries.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
        );
    }
    Some(Value::Object(projected))
}

fn project_trace_evidence(details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    copy_key(&mut projected, details, "projectionBoundary");
    copy_key(&mut projected, details, "statusSummary");
    copy_key(&mut projected, details, "filters");
    if let Some(records) = details.get("records").and_then(Value::as_array) {
        projected.insert(
            "records".to_owned(),
            Value::Array(
                records
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_trace_record)
                    .collect(),
            ),
        );
        if records.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "recordsOmitted".to_owned(),
                json!(records.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    if let Some(record) = details.get("record") {
        projected.insert("record".to_owned(), project_trace_record(record));
    }
    Some(Value::Object(projected))
}

fn project_trace_record(record: &Value) -> Value {
    let mut projected = Map::new();
    let metadata = record
        .get("metadata")
        .and_then(|metadata| metadata.get("dev.tron"))
        .unwrap_or(&Value::Null);
    if let Some(trace_record_id) = record
        .get("traceRecordId")
        .or_else(|| record.get("id"))
        .or_else(|| metadata.get("traceRecordId"))
        .or_else(|| metadata.get("id"))
    {
        projected.insert("traceRecordId".to_owned(), trace_record_id.clone());
    }
    for key in [
        "schemaVersion",
        "version",
        "traceId",
        "invocationId",
        "parentInvocationId",
        "modelPrimitiveName",
        "operation",
        "status",
        "timestamp",
        "startedAt",
        "completedAt",
        "durationMs",
        "sessionId",
        "sessionRef",
        "workspaceRef",
        "runId",
        "turn",
    ] {
        copy_key(&mut projected, record, key);
        copy_key(&mut projected, metadata, key);
    }
    for key in [
        "projectionBoundary",
        "redaction",
        "request",
        "result",
        "authority",
    ] {
        copy_key(&mut projected, record, key);
    }
    if let Some(error) = record.get("error").or_else(|| metadata.get("error")) {
        if let Some(error) = project_failure_value(error) {
            projected.insert("error".to_owned(), error);
        }
    }
    Value::Object(projected)
}

fn project_context_control_evidence(operation: &str, details: &Value) -> Option<Value> {
    let context = details.get("contextControl")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    projected.insert("operation".to_owned(), json!(operation));
    for key in [
        "schemaVersion",
        "sessionId",
        "contextControlSnapshotResourceId",
        "contextControlSnapshotVersionId",
        "contextControlActionResourceId",
        "contextControlActionVersionId",
    ] {
        copy_key(&mut projected, context, key);
    }
    if let Some(projection) = context.get("projection") {
        match operation {
            "context_control_action_list" => {
                if let Some(actions) = projection.pointer("/actions").and_then(Value::as_array) {
                    projected.insert(
                        "actions".to_owned(),
                        json!({
                            "total": actions.len(),
                            "returned": actions.len().min(MODEL_CONTEXT_ARRAY_MAX_ITEMS),
                            "truncated": actions.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS,
                            "omitted": actions.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS),
                            "items": actions
                                .iter()
                                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                                .map(project_context_control_action_summary)
                                .collect::<Vec<_>>()
                        }),
                    );
                    projected.insert(
                        "agentNextStep".to_owned(),
                        json!({
                            "inspectOperation": "context_control_action_inspect",
                            "argumentField": "contextControlActionResourceId",
                            "source": "actions.items[].contextControlActionResourceId",
                            "rule": "Use the exact contextControlActionResourceId returned by context_control_action_list when action audit detail is needed; do not invent ids."
                        }),
                    );
                }
                copy_pointer_as_key(&mut projected, projection, "/limit", "limit");
                copy_pointer_as_key(&mut projected, projection, "/providerSafe", "providerSafe");
            }
            "context_control_action_inspect"
            | "context_control_compact"
            | "context_control_clear" => {
                if let Some(action) = projection.get("action") {
                    projected.insert(
                        "action".to_owned(),
                        project_context_control_action_summary(action),
                    );
                }
                for key in ["preflight", "result", "auditRefs", "proof"] {
                    if let Some(value) = projection.get(key) {
                        projected.insert(key.to_owned(), bounded_model_context_value(value));
                    }
                }
            }
            "context_control_status" => {
                if let Some(status) = projection.get("status") {
                    projected.insert(
                        "statusProjection".to_owned(),
                        bounded_model_context_value(status),
                    );
                }
            }
            "context_control_snapshot" => {
                if let Some(snapshot) = projection.get("snapshot") {
                    projected.insert("snapshot".to_owned(), bounded_model_context_value(snapshot));
                }
            }
            _ => {}
        }
    }
    Some(Value::Object(projected))
}

fn project_context_control_action_summary(action: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "state",
        "kind",
        "reason",
        "actorKind",
        "createdAt",
        "updatedAt",
        "resultStatus",
    ] {
        copy_key(&mut projected, action, key);
    }
    if let Some(resource) = action.get("resource") {
        let mut projected_resource = Map::new();
        for key in [
            "kind",
            "resourceKind",
            "lifecycle",
            "resourceId",
            "versionId",
        ] {
            copy_key(&mut projected_resource, resource, key);
        }
        if let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) {
            projected.insert(
                "contextControlActionResourceId".to_owned(),
                json!(truncate_model_context_string(resource_id)),
            );
            projected.insert(
                "inspectArguments".to_owned(),
                json!({
                    "operation": "context_control_action_inspect",
                    "contextControlActionResourceId": truncate_model_context_string(resource_id)
                }),
            );
        }
        if !projected_resource.is_empty() {
            projected.insert("resource".to_owned(), Value::Object(projected_resource));
        }
    }
    Value::Object(projected)
}

fn project_error_evidence(details: &Value) -> Option<Value> {
    let failure = details.get("failure")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "modelPrimitiveName");
    copy_key(&mut projected, details, "primitiveTargetId");
    if let Some(failure) = project_failure_value(failure) {
        projected.extend(failure.as_object()?.clone());
    }
    Some(Value::Object(projected))
}

fn project_failure_value(failure: &Value) -> Option<Value> {
    let mut projected = Map::new();
    for key in [
        "code",
        "category",
        "origin",
        "retryable",
        "recoverable",
        "message",
        "suggestion",
    ] {
        copy_key(&mut projected, failure, key);
    }
    if let Some(details) = failure.get("details") {
        let mut failure_details = Map::new();
        copy_error_detail_keys(&mut failure_details, details);
        if !failure_details.is_empty() {
            projected.insert(
                "details".to_owned(),
                Value::Object(failure_details.into_iter().take(24).collect()),
            );
        }
    }
    Some(Value::Object(projected))
}

fn copy_error_detail_keys(projected: &mut Map<String, Value>, value: &Value) {
    let Some(object) = value.as_object() else {
        return;
    };
    for (key, field) in object {
        if key == "actual" {
            continue;
        }
        if matches!(
            key.as_str(),
            "code"
                | "path"
                | "field"
                | "functionId"
                | "direction"
                | "operation"
                | "required"
                | "requiredFields"
                | "missingFields"
                | "expected"
        ) {
            projected.insert(key.clone(), bounded_model_context_value(field));
        } else if field.is_object() {
            copy_error_detail_keys(projected, field);
        }
    }
}

fn project_metadata_operation_evidence(operation: &str, details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    let mut has_substantive_evidence = false;
    let has_common_evidence =
        details.get("primitiveOperation").is_some() || details.get("status").is_some();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    projected.insert("operation".to_owned(), json!(operation));
    for (key, value) in details.as_object()? {
        if key == "primitiveOperation" || key == "status" {
            continue;
        }
        if let Some(projected_value) = project_safe_metadata_value(key, value, 0) {
            projected.insert(key.clone(), projected_value);
            has_substantive_evidence = true;
        }
        if projected.len() >= MODEL_CONTEXT_OBJECT_MAX_KEYS {
            break;
        }
    }
    (has_common_evidence || has_substantive_evidence).then_some(Value::Object(projected))
}

fn project_goal_question_evidence(operation: &str, details: &Value) -> Option<Value> {
    let Value::Object(mut projected) = project_metadata_operation_evidence(operation, details)?
    else {
        return None;
    };

    match operation {
        "goal_create" | "goal_inspect" | "goal_cancel" => {
            if let Some(goal_ref) = goal_action_ref(details) {
                projected.insert("agentGoalRef".to_owned(), goal_ref);
            }
            if let Some(goal) = details.get("goal").and_then(goal_action_ref) {
                projected.insert("agentGoalRef".to_owned(), goal);
            }
            projected.insert(
                "agentNextStep".to_owned(),
                json!("Use the returned goalResourceId exactly. Inspect with goal_inspect before cancellation or follow-up decisions; never invent goal ids."),
            );
        }
        "goal_list" => {
            if let Some(goals) = details.get("goals").and_then(Value::as_array) {
                projected.insert(
                    "agentInspectableGoals".to_owned(),
                    resource_action_list(
                        goals,
                        goal_action_ref,
                        "No goals were returned in the current scope.",
                    ),
                );
            }
            projected.insert(
                "agentNextStep".to_owned(),
                json!("Use an exact goalResourceId from agentInspectableGoals.items[].inspectArguments. If no item is returned, do not call goal_inspect or goal_cancel."),
            );
        }
        "question_create" | "question_inspect" | "question_answer" => {
            if let Some(question_ref) = question_action_ref(details) {
                projected.insert("agentQuestionRef".to_owned(), question_ref);
            }
            if let Some(question) = details.get("question").and_then(question_action_ref) {
                projected.insert("agentQuestionRef".to_owned(), question);
            }
            projected.insert(
                "agentNextStep".to_owned(),
                json!("Use the returned questionResourceId and questionVersionId exactly. Answer with question_answer only after inspecting or receiving the current questionVersionId; never invent question ids or versions."),
            );
        }
        "question_list" => {
            if let Some(questions) = details.get("questions").and_then(Value::as_array) {
                projected.insert(
                    "agentInspectableQuestions".to_owned(),
                    resource_action_list(
                        questions,
                        question_action_ref,
                        "No questions were returned in the current scope.",
                    ),
                );
            }
            projected.insert(
                "agentNextStep".to_owned(),
                json!("Use an exact questionResourceId from agentInspectableQuestions.items[].inspectArguments. If no item is returned, do not call question_inspect or question_answer."),
            );
        }
        _ => {}
    }

    Some(Value::Object(projected))
}

fn resource_action_list(
    records: &[Value],
    project: fn(&Value) -> Option<Value>,
    empty_guidance: &str,
) -> Value {
    let items = records
        .iter()
        .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
        .filter_map(project)
        .collect::<Vec<_>>();
    json!({
        "total": records.len(),
        "returned": items.len(),
        "truncated": records.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS,
        "omitted": records.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS),
        "emptyGuidance": empty_guidance,
        "items": items
    })
}

fn goal_action_ref(record: &Value) -> Option<Value> {
    let goal_resource_id = record.get("goalResourceId").and_then(Value::as_str)?;
    let mut projected = Map::new();
    copy_key(&mut projected, record, "goalResourceId");
    copy_key(&mut projected, record, "goalVersionId");
    copy_key(&mut projected, record, "state");
    copy_key(&mut projected, record, "status");
    copy_key(&mut projected, record, "summary");
    copy_key(&mut projected, record, "summaryTruncated");
    copy_key(&mut projected, record, "revision");
    copy_key(&mut projected, record, "queueRefCount");
    copy_key(&mut projected, record, "planRefCount");
    copy_key(&mut projected, record, "evidenceRefCount");
    copy_key(&mut projected, record, "resourceRefs");
    projected.insert(
        "inspectArguments".to_owned(),
        json!({
            "operation": "goal_inspect",
            "goalResourceId": goal_resource_id
        }),
    );
    if goal_is_cancellable(record) {
        projected.insert(
            "cancelArgumentsBase".to_owned(),
            json!({
                "operation": "goal_cancel",
                "goalResourceId": goal_resource_id
            }),
        );
        projected.insert(
            "cancelRequiredAdditionalFields".to_owned(),
            json!(["reason", "idempotencyKey"]),
        );
    }
    Some(Value::Object(projected))
}

fn goal_is_cancellable(record: &Value) -> bool {
    let state = record
        .get("state")
        .or_else(|| record.get("status"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    matches!(state, "open")
}

fn question_action_ref(record: &Value) -> Option<Value> {
    let question_resource_id = record.get("questionResourceId").and_then(Value::as_str)?;
    let mut projected = Map::new();
    copy_key(&mut projected, record, "questionResourceId");
    copy_key(&mut projected, record, "questionVersionId");
    copy_key(&mut projected, record, "state");
    copy_key(&mut projected, record, "status");
    copy_key(&mut projected, record, "summary");
    copy_key(&mut projected, record, "summaryTruncated");
    copy_key(&mut projected, record, "goalRef");
    copy_key(&mut projected, record, "expiresAt");
    copy_key(&mut projected, record, "revision");
    copy_key(&mut projected, record, "answerResourceId");
    copy_key(&mut projected, record, "answerVersionId");
    copy_key(&mut projected, record, "unblocksGoal");
    copy_key(&mut projected, record, "answerDoesNotMintAuthority");
    copy_key(&mut projected, record, "resourceRefs");
    projected.insert(
        "inspectArguments".to_owned(),
        json!({
            "operation": "question_inspect",
            "questionResourceId": question_resource_id
        }),
    );
    if question_is_answerable(record) {
        if let Some(question_version_id) = record.get("questionVersionId").and_then(Value::as_str) {
            projected.insert(
                "answerArgumentsBase".to_owned(),
                json!({
                    "operation": "question_answer",
                    "questionResourceId": question_resource_id,
                    "expectedQuestionVersionId": question_version_id
                }),
            );
            projected.insert(
                "answerRequiredAdditionalFields".to_owned(),
                json!(["answerText", "reason", "idempotencyKey"]),
            );
        }
    }
    Some(Value::Object(projected))
}

fn question_is_answerable(record: &Value) -> bool {
    let state = record
        .get("state")
        .or_else(|| record.get("status"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    matches!(state, "pending")
}

fn project_safe_metadata_value(key: &str, value: &Value, depth: usize) -> Option<Value> {
    if depth > 5 || denied_model_context_key(key) {
        return None;
    }
    if safe_scalar_metadata_key(key) {
        return bounded_safe_scalar_metadata_value(value);
    }
    match value {
        Value::Object(object) => {
            let mut projected = Map::new();
            for (child_key, child_value) in object {
                if let Some(value) = project_safe_metadata_value(child_key, child_value, depth + 1)
                {
                    projected.insert(child_key.clone(), value);
                }
                if projected.len() >= MODEL_CONTEXT_OBJECT_MAX_KEYS {
                    break;
                }
            }
            (!projected.is_empty()).then_some(Value::Object(projected))
        }
        Value::Array(items) if safe_array_metadata_key(key) => {
            let projected = items
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .filter_map(|item| project_array_item_metadata(item, depth + 1))
                .collect::<Vec<_>>();
            let mut wrapper = Map::new();
            wrapper.insert("total".to_owned(), json!(items.len()));
            wrapper.insert("returned".to_owned(), json!(projected.len()));
            wrapper.insert(
                "truncated".to_owned(),
                json!(items.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
            wrapper.insert(
                "omitted".to_owned(),
                json!(items.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS)),
            );
            wrapper.insert("items".to_owned(), Value::Array(projected));
            Some(Value::Object(wrapper))
        }
        _ => None,
    }
}

fn bounded_safe_scalar_metadata_value(value: &Value) -> Option<Value> {
    match value {
        Value::String(_) | Value::Bool(_) | Value::Number(_) | Value::Null => {
            Some(bounded_model_context_value(value))
        }
        Value::Array(items) => {
            let projected = items
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .filter_map(|item| match item {
                    Value::String(_) | Value::Bool(_) | Value::Number(_) | Value::Null => {
                        Some(bounded_model_context_value(item))
                    }
                    Value::Object(_) | Value::Array(_) => None,
                })
                .collect::<Vec<_>>();
            (!projected.is_empty()).then_some(Value::Array(projected))
        }
        Value::Object(_) => None,
    }
}

fn project_array_item_metadata(item: &Value, depth: usize) -> Option<Value> {
    match item {
        Value::Object(object) => {
            let mut projected = Map::new();
            for (key, value) in object {
                if let Some(value) = project_safe_metadata_value(key, value, depth + 1) {
                    projected.insert(key.clone(), value);
                }
            }
            (!projected.is_empty()).then_some(Value::Object(projected))
        }
        Value::String(value) => Some(Value::String(truncate_model_context_string(value))),
        Value::Bool(_) | Value::Number(_) | Value::Null => Some(bounded_model_context_value(item)),
        Value::Array(_) => None,
    }
}

fn safe_array_metadata_key(key: &str) -> bool {
    matches!(
        key,
        "records"
            | "entries"
            | "items"
            | "results"
            | "resourceRefs"
            | "resources"
            | "versions"
            | "modules"
            | "media"
            | "memories"
            | "queries"
            | "decisions"
            | "requests"
            | "reviews"
            | "sources"
            | "goals"
            | "questions"
            | "jobs"
            | "artifacts"
            | "programs"
            | "snapshots"
            | "reports"
            | "refs"
            | "traceRefs"
            | "replayRefs"
            | "bindingRequests"
            | "bindingDecisions"
            | "bindingPolicies"
            | "shadowTrialRequests"
            | "shadowTrialDecisions"
            | "shadowTrialRuns"
            | "shadowTrialEvidence"
            | "replacementCandidates"
            | "routeBindings"
            | "routeActivations"
            | "routeEvents"
            | "routeRollbacks"
    )
}

fn safe_scalar_metadata_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    matches!(
        key,
        "schemaVersion"
            | "primitiveOperation"
            | "operation"
            | "status"
            | "state"
            | "lifecycle"
            | "kind"
            | "type"
            | "role"
            | "title"
            | "summary"
            | "description"
            | "reason"
            | "decision"
            | "scope"
            | "namespace"
            | "key"
            | "mode"
            | "enabled"
            | "active"
            | "configured"
            | "createdAt"
            | "updatedAt"
            | "recordedAt"
            | "completedAt"
            | "startedAt"
            | "durationMs"
            | "exitCode"
            | "exitCodeKnown"
            | "timedOut"
            | "cancelled"
            | "outputTruncated"
            | "cleanupAfterSeconds"
            | "timeoutMs"
            | "maxOutputBytes"
            | "revision"
            | "requested"
            | "timestamp"
            | "count"
            | "total"
            | "returned"
            | "limit"
            | "truncated"
            | "omitted"
            | "hasMore"
            | "networkPolicy"
            | "remotePolicy"
            | "selector"
            | "selectors"
            | "resourceSelectors"
            | "requiredAuthorityScopes"
            | "requiredScopes"
            | "requiredSelectors"
            | "current"
            | "currentVersionId"
            | "versionId"
            | "expectedCurrentVersionId"
            | "targetOperation"
            | "sourceOperation"
            | "ownershipClass"
            | "replacementClass"
            | "bindingMode"
            | "routeState"
            | "executionMode"
            | "riskClass"
            | "reviewStatus"
            | "approvalStatus"
            | "validationStatus"
            | "verificationStatus"
            | "replayed"
            | "replaySourceInvocationRef"
    ) || safe_id_like_metadata_key(&lower)
}

fn safe_id_like_metadata_key(lower: &str) -> bool {
    (lower.ends_with("id")
        || lower.ends_with("ids")
        || lower.ends_with("versionid")
        || lower.ends_with("resourceid"))
        && !lower.contains("grant")
        && !lower.contains("authority")
        && !lower.contains("secret")
        && !lower.contains("token")
}

fn denied_model_context_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    lower == "authority"
        || lower == "pid"
        || lower.contains("processid")
        || lower.contains("processgroupid")
        || lower.contains("grant")
        || lower.contains("authoritygrant")
        || lower.contains("secret")
        || lower.contains("token")
        || lower.contains("credential")
        || lower.contains("password")
        || lower == "idempotency"
        || lower.contains("idempotencykey")
        || lower.contains("raw")
        || lower.contains("command")
        || lower == "cmd"
        || lower.contains("stdout")
        || lower.contains("stderr")
        || lower == "log"
        || lower == "logs"
        || lower.contains("package")
        || lower.contains("environment")
        || lower == "env"
        || lower.contains("promptbody")
        || lower == "prompt"
        || lower == "content"
        || lower.contains("content")
        || lower == "body"
        || lower == "payload"
        || lower == "filecontents"
        || lower == "diff"
        || lower == "preview"
        || lower == "path"
        || lower.ends_with("path")
        || lower == "uri"
}

fn copy_key(target: &mut Map<String, Value>, source: &Value, key: &str) {
    if let Some(value) = source.get(key) {
        target.insert(key.to_owned(), bounded_model_context_value(value));
    }
}

fn copy_pointer_as_key(target: &mut Map<String, Value>, source: &Value, pointer: &str, key: &str) {
    if let Some(value) = source.pointer(pointer) {
        target.insert(key.to_owned(), bounded_model_context_value(value));
    }
}

fn bounded_model_context_value(value: &Value) -> Value {
    match value {
        Value::String(text) => Value::String(truncate_model_context_string(text)),
        Value::Array(values) => Value::Array(
            values
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .map(bounded_model_context_value)
                .collect(),
        ),
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, value)| (key.clone(), bounded_model_context_value(value)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn truncate_model_context_string(text: &str) -> String {
    let redacted = sanitize_provider_text(text);
    if redacted.chars().count() <= MODEL_CONTEXT_STRING_MAX_CHARS {
        return redacted;
    }
    let mut truncated = redacted
        .chars()
        .take(MODEL_CONTEXT_STRING_MAX_CHARS)
        .collect::<String>();
    truncated.push_str("... [truncated]");
    truncated
}

pub(super) fn sanitize_provider_text(text: &str) -> String {
    static ABSOLUTE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(/(?:Users|home|private|tmp|var|Volumes)/[^\s"',}\]]+)"#)
            .expect("valid absolute path redaction regex")
    });
    static UNSAFE_RELATIVE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(\.\.(?:/|\\)[^\s"',}\]]*)"#)
            .expect("valid relative path redaction regex")
    });
    static AUTHORITY_REFERENCES: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"\b(authority grant|authorityGrantId|authority id|authorityId|grant id)\s*[:=]?\s+[A-Za-z0-9:_-]{8,}",
        )
        .expect("valid authority reference redaction regex")
    });
    static INTERNAL_INVOCATION_REFERENCES: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"\b(providerInvocationId|provider invocation id|tool call id|idempotencyKey|idempotency key)\s*[:=]?\s*[A-Za-z0-9:_-]{8,}",
        )
        .expect("valid internal invocation reference redaction regex")
    });
    static SECRET_REFERENCES: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\b(api key|apiKey|token|secret|password)\s*[:=]?\s*[A-Za-z0-9._:-]{8,}")
            .expect("valid secret reference redaction regex")
    });

    let redacted = redact_sensitive_content(text);
    let redacted = AUTHORITY_REFERENCES
        .replace_all(&redacted, "${1} [redacted-authority]")
        .to_string();
    let redacted = INTERNAL_INVOCATION_REFERENCES
        .replace_all(&redacted, "${1} [redacted-internal-ref]")
        .to_string();
    let redacted = SECRET_REFERENCES
        .replace_all(&redacted, "${1} [redacted-secret]")
        .to_string();
    let redacted = ABSOLUTE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string();
    UNSAFE_RELATIVE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string()
}

#[cfg(test)]
mod tests;
