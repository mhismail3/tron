//! Resource-backed persistence for retained memory outputs.
//!
//! Retain writes durable truth as substrate resources, then materializes
//! markdown files as projections. The markdown locations remain useful for
//! operators, but resource versions and links are the inspectable source of
//! truth for retention outcomes.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::server::errors::CapabilityError;

use super::RetainDeps;
use super::parsing::{ArgumentContent, CoreMemoryUpdate, slugify};
use super::writer::{
    argument_file_path, core_memory_file_path, format_argument_document, format_core_memory_entry,
    format_core_memory_frontmatter, format_session_frontmatter, format_session_section,
    session_file_path,
};

const JOURNAL_ARTIFACT_PREFIX: &str = "artifact:memory-journal:";
const RULE_ARTIFACT_PREFIX: &str = "artifact:memory-rule:";
const ARGUMENT_ARTIFACT_PREFIX: &str = "artifact:memory-argument:";
const SESSION_MATERIALIZED_PREFIX: &str = "materialized_file:memory-session:";
const RULE_MATERIALIZED_PREFIX: &str = "materialized_file:memory-rule:";
const ARGUMENT_MATERIALIZED_PREFIX: &str = "materialized_file:memory-argument:";

pub(super) struct RetainedMemoryPayload<'a> {
    pub session_id: &'a str,
    pub created_ts: &'a str,
    pub model: &'a str,
    pub start_ts: &'a str,
    pub end_ts: &'a str,
    pub title: &'a str,
    pub body: &'a str,
    pub source: &'a str,
    pub summarizer_failure: Option<&'a str>,
    pub core_memory: Option<&'a CoreMemoryUpdate>,
    pub argument: Option<&'a ArgumentContent>,
}

pub(super) struct RetainedMemoryOutputs {
    pub resource_refs: Vec<Value>,
    pub evidence_refs: Vec<Value>,
}

pub(super) async fn persist_retained_memory_outputs(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    payload: RetainedMemoryPayload<'_>,
) -> Result<RetainedMemoryOutputs, CapabilityError> {
    let range_hash = short_hash(&format!(
        "{}\n{}\n{}\n{}",
        payload.session_id, payload.start_ts, payload.end_ts, payload.body
    ));
    let session_segment = sanitize_resource_segment(payload.session_id);
    let journal_artifact_id = format!("{JOURNAL_ARTIFACT_PREFIX}{session_segment}:{range_hash}");
    let journal_body = format_session_section(
        payload.start_ts,
        payload.end_ts,
        payload.title,
        payload.body,
    );
    let journal_payload = json!({
        "title": payload.title,
        "body": journal_body.trim_start(),
        "format": "markdown",
        "summary": payload.body,
        "metadata": {
            "domain": "memory",
            "recordKind": "journal",
            "sessionId": payload.session_id,
            "rangeStart": payload.start_ts,
            "rangeEnd": payload.end_ts,
            "model": payload.model,
            "source": payload.source,
            "summarizerFailure": payload.summarizer_failure,
        }
    });

    let mut resource_refs = Vec::new();
    let mut evidence_refs = Vec::new();
    let journal_artifact = ensure_artifact(
        deps,
        parent,
        &journal_artifact_id,
        journal_payload,
        json!({"retention": "memory_journal"}),
        "journal-artifact",
    )
    .await?;
    resource_refs.extend(journal_artifact.refs);

    if let Some(reason) = payload.summarizer_failure {
        let evidence = ensure_recovery_evidence(
            deps,
            parent,
            &journal_artifact_id,
            &payload,
            reason,
            &range_hash,
        )
        .await?;
        evidence_refs.extend(evidence.refs);
    }

    if journal_artifact.created {
        let session_resource_id = format!("{SESSION_MATERIALIZED_PREFIX}{session_segment}");
        let session_content = append_materialized_section(
            deps,
            parent,
            &session_resource_id,
            &format_session_frontmatter(payload.session_id, payload.created_ts, payload.model),
            &journal_body,
        )
        .await?;
        let projection = persist_materialized_projection(
            deps,
            parent,
            &journal_artifact_id,
            &session_resource_id,
            &session_file_path(payload.session_id).to_string_lossy(),
            &session_content,
            "memory-journal-materialized",
            "journal-materializes",
        )
        .await?;
        resource_refs.extend(projection.resource_refs);
        evidence_refs.extend(projection.evidence_refs);
    }

    if let Some(core_memory) = payload.core_memory {
        let outputs = persist_core_memory(deps, parent, &payload, core_memory, &range_hash).await?;
        resource_refs.extend(outputs.resource_refs);
        evidence_refs.extend(outputs.evidence_refs);
    }

    if let Some(argument) = payload.argument {
        let outputs = persist_argument(deps, parent, argument, &range_hash).await?;
        resource_refs.extend(outputs.resource_refs);
        evidence_refs.extend(outputs.evidence_refs);
    }

    Ok(RetainedMemoryOutputs {
        resource_refs,
        evidence_refs,
    })
}

async fn persist_core_memory(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    payload: &RetainedMemoryPayload<'_>,
    core_memory: &CoreMemoryUpdate,
    range_hash: &str,
) -> Result<RetainedMemoryOutputs, CapabilityError> {
    let rule_slug = sanitize_resource_segment(core_memory.file.trim_end_matches(".md"));
    let artifact_id = format!("{RULE_ARTIFACT_PREFIX}{rule_slug}:{range_hash}");
    let entry = format_core_memory_entry(payload.created_ts, &core_memory.update);
    let artifact = ensure_artifact(
        deps,
        parent,
        &artifact_id,
        json!({
            "title": format!("Memory rule update: {}", core_memory.file),
            "body": entry.trim_start(),
            "format": "markdown",
            "summary": core_memory.update,
            "metadata": {
                "domain": "memory",
                "recordKind": "rule",
                "file": core_memory.file,
                "sessionId": payload.session_id,
                "rangeStart": payload.start_ts,
                "rangeEnd": payload.end_ts,
            }
        }),
        json!({"retention": "memory_rule"}),
        "rule-artifact",
    )
    .await?;
    let mut outputs = RetainedMemoryOutputs {
        resource_refs: artifact.refs,
        evidence_refs: Vec::new(),
    };
    if artifact.created {
        let materialized_id = format!("{RULE_MATERIALIZED_PREFIX}{rule_slug}");
        let content = append_materialized_section(
            deps,
            parent,
            &materialized_id,
            &format_core_memory_frontmatter(payload.created_ts),
            &entry,
        )
        .await?;
        let projection = persist_materialized_projection(
            deps,
            parent,
            &artifact_id,
            &materialized_id,
            &core_memory_file_path(&core_memory.file).to_string_lossy(),
            &content,
            "rule-materialized",
            "rule-materializes",
        )
        .await?;
        outputs.resource_refs.extend(projection.resource_refs);
        outputs.evidence_refs.extend(projection.evidence_refs);
    }
    Ok(outputs)
}

async fn persist_argument(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    argument: &ArgumentContent,
    range_hash: &str,
) -> Result<RetainedMemoryOutputs, CapabilityError> {
    let slug = slugify(&argument.title);
    let slug_segment = sanitize_resource_segment(&slug);
    let artifact_id = format!("{ARGUMENT_ARTIFACT_PREFIX}{slug_segment}:{range_hash}");
    let document = format_argument_document(argument);
    let artifact = ensure_artifact(
        deps,
        parent,
        &artifact_id,
        json!({
            "title": argument.title,
            "body": document,
            "format": "markdown",
            "summary": argument.thesis,
            "metadata": {
                "domain": "memory",
                "recordKind": "argument",
                "slug": slug,
                "topics": &argument.topics,
                "sources": &argument.sources,
            }
        }),
        json!({"retention": "memory_argument"}),
        "argument-artifact",
    )
    .await?;
    let mut outputs = RetainedMemoryOutputs {
        resource_refs: artifact.refs,
        evidence_refs: Vec::new(),
    };
    if artifact.created {
        let materialized_id = format!("{ARGUMENT_MATERIALIZED_PREFIX}{slug_segment}");
        let projection = persist_materialized_projection(
            deps,
            parent,
            &artifact_id,
            &materialized_id,
            &argument_file_path(&slug).to_string_lossy(),
            &format_argument_document(argument),
            "argument-materialized",
            "argument-materializes",
        )
        .await?;
        outputs.resource_refs.extend(projection.resource_refs);
        outputs.evidence_refs.extend(projection.evidence_refs);
    }
    Ok(outputs)
}

struct EnsureArtifactResult {
    refs: Vec<Value>,
    created: bool,
}

async fn ensure_recovery_evidence(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    journal_artifact_id: &str,
    payload: &RetainedMemoryPayload<'_>,
    reason: &str,
    range_hash: &str,
) -> Result<EnsureArtifactResult, CapabilityError> {
    let session_segment = sanitize_resource_segment(payload.session_id);
    let evidence_id = format!("evidence:memory-retain-recovery:{session_segment}:{range_hash}");
    if let Some(inspection) = inspect_resource(deps, parent, &evidence_id).await? {
        return Ok(EnsureArtifactResult {
            refs: vec![resource_ref_from_inspection(&inspection, "existing")?],
            created: false,
        });
    }
    let evidence = invoke_resource_capability(
        deps,
        parent,
        "evidence::attach",
        json!({
            "resourceId": evidence_id,
            "targetResourceId": journal_artifact_id,
            "relation": "evidence_for",
            "scope": "system",
            "lifecycle": "accepted",
            "payload": {
                "summary": "Memory retain used bounded recovery output after summarizer failure.",
                "source": "memory::retain",
                "resourceRef": journal_artifact_id,
                "metadata": {
                    "domain": "memory",
                    "evidenceType": "memory_retain_recovery",
                    "sessionId": payload.session_id,
                    "rangeStart": payload.start_ts,
                    "rangeEnd": payload.end_ts,
                    "reason": reason,
                    "recoverySource": payload.source,
                }
            },
            "metadata": {
                "domain": "memory",
                "evidenceType": "memory_retain_recovery"
            }
        }),
        "recovery-evidence",
        "resource.write",
    )
    .await?;
    Ok(EnsureArtifactResult {
        refs: resource_refs(&evidence),
        created: true,
    })
}

async fn ensure_artifact(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    resource_id: &str,
    payload: Value,
    policy: Value,
    idempotency_label: &str,
) -> Result<EnsureArtifactResult, CapabilityError> {
    if let Some(inspection) = inspect_resource(deps, parent, resource_id).await? {
        return Ok(EnsureArtifactResult {
            refs: vec![resource_ref_from_inspection(&inspection, "existing")?],
            created: false,
        });
    }
    let created = invoke_resource_capability(
        deps,
        parent,
        "artifact::create",
        json!({
            "resourceId": resource_id,
            "scope": "system",
            "lifecycle": "promoted",
            "payload": payload,
            "policy": policy
        }),
        idempotency_label,
        "resource.write",
    )
    .await?;
    Ok(EnsureArtifactResult {
        refs: resource_refs(&created),
        created: true,
    })
}

async fn append_materialized_section(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    resource_id: &str,
    frontmatter: &str,
    section: &str,
) -> Result<String, CapabilityError> {
    let base = match inspect_resource(deps, parent, resource_id).await? {
        Some(inspection) => current_payload(&inspection)?
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        None => frontmatter.to_owned(),
    };
    Ok(format!("{base}{section}"))
}

async fn materialize_markdown(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    resource_id: &str,
    path: &str,
    content: &str,
    idempotency_label: &str,
) -> Result<Vec<Value>, CapabilityError> {
    if let Some(inspection) = inspect_resource(deps, parent, resource_id).await?
        && current_payload(&inspection)?
            .get("content")
            .and_then(Value::as_str)
            .is_some_and(|current| current == content)
    {
        return Ok(vec![resource_ref_from_inspection(&inspection, "existing")?]);
    }
    let materialized = invoke_resource_capability(
        deps,
        parent,
        "materialized_file::update",
        json!({
            "resourceId": resource_id,
            "path": path,
            "content": content,
            "scope": "system",
            "policy": {"retention": "memory_projection"}
        }),
        idempotency_label,
        "resource.write",
    )
    .await?;
    Ok(resource_refs(&materialized))
}

async fn persist_materialized_projection(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    artifact_resource_id: &str,
    materialized_resource_id: &str,
    path: &str,
    content: &str,
    materialize_idempotency_label: &str,
    link_idempotency_label: &str,
) -> Result<RetainedMemoryOutputs, CapabilityError> {
    let mut outputs = RetainedMemoryOutputs {
        resource_refs: Vec::new(),
        evidence_refs: Vec::new(),
    };
    match materialize_markdown(
        deps,
        parent,
        materialized_resource_id,
        path,
        content,
        materialize_idempotency_label,
    )
    .await
    {
        Ok(materialized_refs) => {
            outputs.resource_refs.extend(materialized_refs);
            if let Err(error) = link_materialization(
                deps,
                parent,
                materialized_resource_id,
                artifact_resource_id,
                link_idempotency_label,
            )
            .await
            {
                let evidence = ensure_projection_failure_evidence(
                    deps,
                    parent,
                    artifact_resource_id,
                    materialized_resource_id,
                    path,
                    "link_failed",
                    &error.to_string(),
                )
                .await?;
                outputs.evidence_refs.extend(evidence.refs);
            }
        }
        Err(error) => {
            let evidence = ensure_projection_failure_evidence(
                deps,
                parent,
                artifact_resource_id,
                materialized_resource_id,
                path,
                "materialization_failed",
                &error.to_string(),
            )
            .await?;
            outputs.evidence_refs.extend(evidence.refs);
        }
    }
    Ok(outputs)
}

async fn link_materialization(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    materialized_resource_id: &str,
    artifact_resource_id: &str,
    idempotency_label: &str,
) -> Result<(), CapabilityError> {
    let _ = invoke_resource_capability(
        deps,
        parent,
        "resource::link",
        json!({
            "sourceResourceId": materialized_resource_id,
            "targetResourceId": artifact_resource_id,
            "relation": "materializes",
            "metadata": {"domain": "memory", "recordKind": "projection"}
        }),
        idempotency_label,
        "resource.write",
    )
    .await?;
    Ok(())
}

async fn ensure_projection_failure_evidence(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    artifact_resource_id: &str,
    materialized_resource_id: &str,
    path: &str,
    failure_stage: &str,
    error: &str,
) -> Result<EnsureArtifactResult, CapabilityError> {
    let evidence_id = format!(
        "evidence:memory-projection-failure:{}:{}",
        sanitize_resource_segment(materialized_resource_id),
        short_hash(&format!("{artifact_resource_id}\n{failure_stage}\n{error}"))
    );
    if let Some(inspection) = inspect_resource(deps, parent, &evidence_id).await? {
        return Ok(EnsureArtifactResult {
            refs: vec![resource_ref_from_inspection(&inspection, "existing")?],
            created: false,
        });
    }
    let evidence = invoke_resource_capability(
        deps,
        parent,
        "evidence::attach",
        json!({
            "resourceId": evidence_id,
            "targetResourceId": artifact_resource_id,
            "relation": "evidence_for",
            "scope": "system",
            "lifecycle": "accepted",
            "payload": {
                "summary": "Memory retain resource truth was persisted, but markdown projection did not complete.",
                "source": "memory::retain",
                "resourceRef": artifact_resource_id,
                "metadata": {
                    "domain": "memory",
                    "evidenceType": "memory_projection_failure",
                    "materializedResourceId": materialized_resource_id,
                    "path": path,
                    "failureStage": failure_stage,
                    "error": error,
                }
            },
            "metadata": {
                "domain": "memory",
                "evidenceType": "memory_projection_failure"
            }
        }),
        "projection-failure-evidence",
        "resource.write",
    )
    .await?;
    Ok(EnsureArtifactResult {
        refs: resource_refs(&evidence),
        created: true,
    })
}

async fn inspect_resource(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    resource_id: &str,
) -> Result<Option<Value>, CapabilityError> {
    let value = invoke_resource_capability(
        deps,
        parent,
        "resource::inspect",
        json!({"resourceId": resource_id}),
        &format!("inspect:{}", short_hash(resource_id)),
        "resource.read",
    )
    .await?;
    Ok(value
        .get("inspection")
        .cloned()
        .filter(|value| !value.is_null()))
}

async fn invoke_resource_capability(
    deps: &RetainDeps,
    parent: Option<&Invocation>,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
    scope: &str,
) -> Result<Value, CapabilityError> {
    let root_trace = TraceId::new("memory-retain-resource").map_err(engine_capability_error)?;
    let mut causal = CausalContext::new(
        ActorId::new("system:memory").map_err(engine_capability_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_capability_error)?,
        parent
            .map(|invocation| invocation.causal_context.trace_id.clone())
            .unwrap_or(root_trace),
    )
    .with_scope(scope)
    .with_idempotency_key(format!(
        "memory_retain:{}:{idempotency_label}",
        parent
            .map(|invocation| invocation.id.as_str())
            .unwrap_or("background")
    ));
    if let Some(parent) = parent {
        causal.parent_invocation_id = Some(parent.id.clone());
        if let Some(session_id) = &parent.causal_context.session_id {
            causal = causal.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &parent.causal_context.workspace_id {
            causal = causal.with_workspace_id(workspace_id.clone());
        }
    }
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(engine_capability_error)?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_capability_error(error));
    }
    result.value.ok_or_else(|| CapabilityError::Internal {
        message: format!("{function_id} returned no value"),
    })
}

fn current_payload(inspection: &Value) -> Result<Value, CapabilityError> {
    let current = inspection
        .pointer("/resource/currentVersionId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource has no current version".to_owned(),
        })?;
    inspection
        .get("versions")
        .and_then(Value::as_array)
        .and_then(|versions| {
            versions
                .iter()
                .find(|version| version["versionId"] == current)
        })
        .and_then(|version| version.get("payload"))
        .cloned()
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource current payload is missing".to_owned(),
        })
}

fn resource_refs(value: &Value) -> Vec<Value> {
    value["resourceRefs"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn resource_ref_from_inspection(inspection: &Value, role: &str) -> Result<Value, CapabilityError> {
    let resource = inspection
        .get("resource")
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource inspection missing resource".to_owned(),
        })?;
    let resource_id = resource
        .get("resourceId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource inspection missing resourceId".to_owned(),
        })?;
    let kind = resource
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource inspection missing kind".to_owned(),
        })?;
    let current = resource
        .get("currentVersionId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource inspection missing currentVersionId".to_owned(),
        })?;
    let content_hash = inspection
        .get("versions")
        .and_then(Value::as_array)
        .and_then(|versions| {
            versions
                .iter()
                .find(|version| version["versionId"] == current)
        })
        .and_then(|version| version.get("contentHash"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    Ok(json!({
        "resourceId": resource_id,
        "kind": kind,
        "versionId": current,
        "contentHash": content_hash,
        "role": role,
    }))
}

fn short_hash(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    format!("{digest:x}").chars().take(32).collect()
}

fn sanitize_resource_segment(value: &str) -> String {
    let cleaned = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') {
                ch
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_owned();
    if cleaned.is_empty() {
        "unknown".to_owned()
    } else {
        cleaned
    }
}

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "MEMORY_RESOURCE_OPERATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}
