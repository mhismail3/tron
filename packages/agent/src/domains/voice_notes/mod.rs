//! voice notes domain worker.
//!
//! This module owns canonical function execution for the voice notes namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Durable note state is represented by `artifact` and `materialized_file`
//! resources; the Markdown file path is a materialized location, not source
//! truth.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "voice_notes",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod service;

use base64::Engine;
use uuid::Uuid;

use crate::domains::voice_notes::service as voice_notes_service;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::server::params::{opt_string, opt_u64, require_string_param};

async fn list(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let limit = usize::try_from(opt_u64(Some(payload), "limit", 50)).unwrap_or(usize::MAX);
    let offset = usize::try_from(opt_u64(Some(payload), "offset", 0)).unwrap_or(0);
    let listed = invoke_resource_capability(
        deps,
        None,
        "resource::list",
        json!({"kind": "artifact", "limit": 10_000}),
        "voice_notes:list",
        "resource.read",
    )
    .await?;
    let mut notes = Vec::new();
    for resource in listed["resources"].as_array().cloned().unwrap_or_default() {
        if resource["lifecycle"] == "discarded" {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        if !resource_id.starts_with("artifact:voice-note:") {
            continue;
        }
        let inspection = invoke_resource_capability(
            deps,
            None,
            "resource::inspect",
            json!({"resourceId": resource_id}),
            &format!("voice_notes:list:{resource_id}"),
            "resource.read",
        )
        .await?;
        let payload = inspection
            .pointer("/inspection/versions")
            .and_then(Value::as_array)
            .and_then(|versions| {
                let current = inspection
                    .pointer("/inspection/resource/currentVersionId")
                    .and_then(Value::as_str)?;
                versions
                    .iter()
                    .find(|version| version["versionId"] == current)
            })
            .and_then(|version| version.get("payload"))
            .unwrap_or(&Value::Null);
        if let Some(note) = voice_notes_service::note_projection_from_payload(payload) {
            notes.push(note);
        }
    }
    notes.sort_by(|left, right| {
        right["createdAt"]
            .as_str()
            .unwrap_or_default()
            .cmp(left["createdAt"].as_str().unwrap_or_default())
    });
    let total_count = notes.len();
    let has_more = offset + limit < total_count;
    let notes = notes
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect::<Vec<_>>();
    Ok(json!({
        "notes": notes,
        "totalCount": total_count,
        "hasMore": has_more,
    }))
}

async fn save(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let audio_base64 = require_string_param(Some(payload), "audioBase64")?;
    let mime_type_owned = opt_string(Some(payload), "mimeType");
    let mime_type = mime_type_owned.as_deref().unwrap_or("audio/wav");
    let dir = voice_notes_service::notes_dir();
    let now = chrono::Utc::now();
    let filename = build_voice_note_filename(now);
    let filepath = format!("{dir}/{filename}");
    let audio_base64 = super::transcription::normalize_base64(&audio_base64);
    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(audio_base64)
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid base64 audio data: {error}"),
        })?;
    let result =
        super::transcription::transcribe_audio(&deps.transcription_engine, &audio_bytes, mime_type)
            .await;

    let content = format!(
        "---\ntype: voice-note\ncreated: {}\nduration: {:.1}\nlanguage: {}\n---\n\n{}\n",
        now.to_rfc3339(),
        result.duration_seconds,
        result.language,
        result.text,
    );
    let materialized = invoke_child_resource_capability(
        deps,
        invocation,
        "materialized_file::update",
        json!({
            "resourceId": materialized_file_resource_id(&filename),
            "path": filepath,
            "content": content,
            "scope": "workspace",
            "policy": {"retention": "voice_note"}
        }),
        "materialized_file",
        "resource.write",
    )
    .await?;
    let artifact_payload = json!({
        "title": format!("Voice Note {filename}"),
        "body": result.text,
        "format": "markdown",
        "summary": "Transcribed voice note",
        "filename": filename,
        "filepath": filepath,
        "createdAt": now.to_rfc3339(),
        "durationSeconds": result.duration_seconds,
        "language": result.language,
        "metadata": {
            "domain": "voice_notes",
            "mimeType": mime_type,
            "materializedFileResourceId": materialized["resourceRefs"][0]["resourceId"]
        }
    });
    let artifact = invoke_child_resource_capability(
        deps,
        invocation,
        "artifact::create",
        json!({
            "resourceId": artifact_resource_id(&filename),
            "scope": "workspace",
            "lifecycle": "promoted",
            "payload": artifact_payload,
            "policy": {"retention": "voice_note"}
        }),
        "artifact",
        "resource.write",
    )
    .await?;
    let _ = invoke_child_resource_capability(
        deps,
        invocation,
        "resource::link",
        json!({
            "sourceResourceId": materialized["resourceRefs"][0]["resourceId"],
            "targetResourceId": artifact["resourceRefs"][0]["resourceId"],
            "relation": "materializes",
            "metadata": {"domain": "voice_notes"}
        }),
        "link",
        "resource.write",
    )
    .await?;
    let mut resource_refs = Vec::new();
    resource_refs.extend(
        materialized["resourceRefs"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
    );
    resource_refs.extend(
        artifact["resourceRefs"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
    );

    Ok(json!({
        "success": true,
        "filename": filename,
        "filepath": filepath,
        "transcription": {
            "text": result.text,
            "language": result.language,
            "durationSeconds": result.duration_seconds,
        },
        "resourceRefs": resource_refs,
    }))
}

async fn delete(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let filename = require_string_param(Some(payload), "filename")?;
    let artifact_id = artifact_resource_id(&filename);
    let materialized = invoke_child_resource_capability(
        deps,
        invocation,
        "materialized_file::discard",
        json!({"resourceId": materialized_file_resource_id(&filename)}),
        "materialized_file",
        "resource.write",
    )
    .await?;
    let artifact = invoke_child_resource_capability(
        deps,
        invocation,
        "artifact::discard",
        json!({"resourceId": artifact_id}),
        "artifact",
        "resource.write",
    )
    .await?;
    let mut refs = Vec::new();
    refs.extend(
        artifact["resourceRefs"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
    );
    refs.extend(
        materialized["resourceRefs"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
    );
    Ok(json!({
        "success": true,
        "filename": filename,
        "resourceRefs": refs,
    }))
}

fn build_voice_note_filename(now: chrono::DateTime<chrono::Utc>) -> String {
    format!(
        "{}-{}-voice-note.md",
        now.format("%Y-%m-%d-%H%M%S-%3f"),
        Uuid::now_v7()
    )
}

fn artifact_resource_id(filename: &str) -> String {
    format!("artifact:voice-note:{filename}")
}

fn materialized_file_resource_id(filename: &str) -> String {
    format!("materialized_file:voice-note:{filename}")
}

async fn invoke_child_resource_capability(
    deps: &Deps,
    parent: &Invocation,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
    scope: &str,
) -> Result<Value, CapabilityError> {
    invoke_resource_capability(
        deps,
        Some(parent),
        function_id,
        payload,
        &format!("{}:{idempotency_label}", parent.id.as_str()),
        scope,
    )
    .await
}

async fn invoke_resource_capability(
    deps: &Deps,
    parent: Option<&Invocation>,
    function_id: &str,
    payload: Value,
    idempotency_key: &str,
    scope: &str,
) -> Result<Value, CapabilityError> {
    let mut causal = CausalContext::new(
        ActorId::new("system:voice_notes").map_err(engine_capability_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_capability_error)?,
        TraceId::new(
            parent
                .map(|invocation| invocation.causal_context.trace_id.as_str())
                .unwrap_or("voice-notes-resource"),
        )
        .map_err(engine_capability_error)?,
    )
    .with_scope(scope)
    .with_idempotency_key(idempotency_key.to_owned());
    if let Some(parent) = parent {
        causal.parent_invocation_id = Some(parent.id.clone());
        if let Some(session_id) = &parent.causal_context.session_id {
            causal = causal.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &parent.causal_context.workspace_id {
            causal = causal.with_workspace_id(workspace_id.clone());
        }
    } else {
        causal = causal
            .with_session_id("voice-notes")
            .with_workspace_id("voice-notes");
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

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "VOICE_NOTE_RESOURCE_OPERATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}
