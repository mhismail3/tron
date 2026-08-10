//! Shared query-side services for session read tools.
//!
//! `session::list` clamps every page to 200 rows and returns an opaque cursor
//! over immutable creation/session-ID keys beneath one server-issued
//! `snapshotAsOf` boundary. Mutable activity cannot move a row between pages,
//! and clients can assemble a generous bounded snapshot without one unbounded
//! database read. Ordinary listings exclude worker-owned child sessions, while
//! exact-ID audit reads and resume remain available. Row lookups and bounded
//! listing read `EventStore` directly; within this query path, `SessionManager`
//! remains only for resume/cache data. Provider-context pagination resolves
//! only rows returned to the caller; its look-ahead row is metadata-only so a
//! one-item mobile overview never reads a second large context manifest. The
//! opt-in detail read enriches its message inventory from immutable source
//! events in one bounded batch so clients can show model, tool, and turn facts.
//! Its closed projection keeps the product-facing Agent Context response small;
//! the exact provider audit crosses the wire only for Technical Details.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::domains::session::Deps;
use crate::domains::session::event_store::{
    AgentDeliverySourceKind, EventRow, ListSessionsOptions, session_organization_from_tags,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{self, ToolError};

pub(crate) struct SessionQueryService;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ContextRequestDetailProjection {
    AgentContext,
    Technical,
}

const SESSION_LIST_DEFAULT_LIMIT: usize = 50;
const SESSION_LIST_MAX_LIMIT: usize = 200;
const AGENT_UPDATE_PREVIEW_MAX_CHARS: usize = 1_024;

/// Project one provider-request audit into the bounded inventory used by
/// Session Context. Full manifests remain owned by
/// `session::context_request_detail`; transcript reconstruction and overview
/// reads must never put those potentially multi-megabyte bodies on the wire.
fn context_request_summary(row: &EventRow, payload: &Value) -> Value {
    let format = payload
        .get("format")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let manifest = payload.get("contextManifest");
    let messages = manifest
        .and_then(|manifest| manifest.get("messages"))
        .and_then(Value::as_array);
    let instruction_count = manifest
        .and_then(|manifest| manifest.get("systemContributions"))
        .and_then(Value::as_array)
        .map_or(0, Vec::len)
        + payload
            .get("providerAdditions")
            .and_then(Value::as_array)
            .map_or(0, Vec::len);
    let attachment_message_count = messages.map_or(0, |messages| {
        messages
            .iter()
            .filter(|message| {
                message
                    .get("contentKinds")
                    .and_then(Value::as_array)
                    .is_some_and(|kinds| {
                        kinds
                            .iter()
                            .any(|kind| matches!(kind.as_str(), Some("image" | "document")))
                    })
            })
            .count()
    });
    json!({
        "eventId":row.id,
        "sequence":row.sequence,
        "timestamp":row.timestamp,
        "format":format,
        "turn":payload.get("turn").cloned().unwrap_or(Value::Null),
        "providerType":payload.get("providerType").cloned().unwrap_or(Value::Null),
        "providerName":payload.get("providerName").cloned().unwrap_or(Value::Null),
        "model":payload.get("model").cloned().unwrap_or(Value::Null),
        "requestClassification":payload.get("requestClassification").cloned().unwrap_or_else(|| json!("legacy")),
        "messageCount":payload.get("messageCount").cloned().unwrap_or_else(|| json!(0)),
        "toolCount":payload.get("toolCount").cloned().unwrap_or_else(|| json!(0)),
        "automaticContextCount":manifest
            .and_then(|manifest| manifest.get("automaticContext"))
            .and_then(Value::as_array)
            .map_or(0, Vec::len),
        "instructionCount":instruction_count,
        "attachmentMessageCount":attachment_message_count,
        "agentDeliveryCount":manifest
            .and_then(|manifest| manifest.get("agentDeliveries"))
            .and_then(Value::as_array)
            .map_or(0, Vec::len),
        "environmentAvailable":manifest
            .and_then(|manifest| manifest.get("environment"))
            .and_then(|environment| environment.get("workingDirectory"))
            .is_some_and(|value| !value.is_null()),
        "manifestAvailable":manifest.is_some(),
        "provenanceAvailability":if crate::shared::protocol::model_audit::provider_audit_has_complete_provenance(format) {
            "complete"
        } else {
            "legacy_unavailable"
        },
    })
}

fn context_source_event_ids(manifest: &Value) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    manifest
        .get("messages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|message| {
            message
                .get("sourceEventIds")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(Value::as_str)
        .filter(|event_id| seen.insert((*event_id).to_owned()))
        .map(ToOwned::to_owned)
        .collect()
}

fn enrich_context_message_source_metadata(manifest: &mut Value, events: &[EventRow]) {
    let event_by_id = events
        .iter()
        .map(|event| (event.id.as_str(), event))
        .collect::<std::collections::HashMap<_, _>>();
    let Some(messages) = manifest.get_mut("messages").and_then(Value::as_array_mut) else {
        return;
    };

    for message in messages {
        let source_events = message
            .get("sourceEventIds")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter_map(|event_id| event_by_id.get(event_id).copied())
            .collect::<Vec<_>>();
        let Some(message) = message.as_object_mut() else {
            continue;
        };

        let unique_strings = |values: Vec<&String>| {
            let mut seen = std::collections::HashSet::new();
            values
                .into_iter()
                .filter(|value| seen.insert((*value).clone()))
                .cloned()
                .map(Value::String)
                .collect::<Vec<_>>()
        };
        let models = unique_strings(
            source_events
                .iter()
                .filter_map(|event| event.model.as_ref())
                .collect(),
        );
        let tools = unique_strings(
            source_events
                .iter()
                .filter_map(|event| event.tool_name.as_ref())
                .collect(),
        );
        let mut seen_turns = std::collections::HashSet::new();
        let turns = source_events
            .iter()
            .filter_map(|event| event.turn)
            .filter(|turn| seen_turns.insert(*turn))
            .map(|turn| Value::Number(turn.into()))
            .collect::<Vec<_>>();

        if !models.is_empty() {
            message.insert("sourceModels".to_owned(), Value::Array(models));
        }
        if !tools.is_empty() {
            message.insert("sourceTools".to_owned(), Value::Array(tools));
        }
        if !turns.is_empty() {
            message.insert("sourceTurns".to_owned(), Value::Array(turns));
        }
    }
}

/// Keep the product-facing context projection proportional to what it renders.
/// Exact schemas, hashes, omitted capabilities, and catalog evidence remain in
/// the immutable technical provider audit rather than crossing the wire twice.
fn project_agent_context_tool_surface(manifest: &mut Value) {
    const FIXED_FIELDS: &[&str] = &[
        "functionId",
        "modelName",
        "exposed",
        "audience",
        "accessPath",
        "selectionReason",
    ];
    const WORKER_FIELDS: &[&str] = &[
        "workerId",
        "modelName",
        "workerVersion",
        "projected",
        "selectionReason",
        "rankingMechanism",
        "relevanceScore",
        "routerExplanation",
    ];

    fn project_items(surface: &Value, key: &str, admitted: &str, fields: &[&str]) -> Vec<Value> {
        surface
            .get(key)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|item| item.get(admitted).and_then(Value::as_bool) == Some(true))
            .filter_map(Value::as_object)
            .map(|item| {
                Value::Object(
                    fields
                        .iter()
                        .filter_map(|field| {
                            item.get(*field)
                                .cloned()
                                .map(|value| ((*field).to_owned(), value))
                        })
                        .collect(),
                )
            })
            .collect()
    }

    let Some(manifest) = manifest.as_object_mut() else {
        return;
    };
    let Some(surface) = manifest.get("toolSurface") else {
        return;
    };
    let fixed_tools = project_items(surface, "fixedTools", "exposed", FIXED_FIELDS);
    let available_workers = project_items(surface, "availableWorkers", "projected", WORKER_FIELDS);
    manifest.insert(
        "toolSurface".to_owned(),
        json!({
            "fixedTools": fixed_tools,
            "availableWorkers": available_workers,
        }),
    );
}

fn worker_evidence_text(value: &Value) -> Option<&str> {
    ["preview", "summary", "message"]
        .into_iter()
        .find_map(|key| value.get(key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn worker_evidence_error(value: &Value) -> Option<&str> {
    ["error", "reason"]
        .into_iter()
        .find_map(|key| value.get(key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn readable_worker_evidence(status: &str, evidence: &Value) -> String {
    match status {
        "failed" => worker_evidence_error(evidence)
            .map(|detail| format!("Failed: {detail}"))
            .unwrap_or_else(|| "Worker execution failed.".to_owned()),
        "cancelled" => worker_evidence_error(evidence)
            .map(|detail| format!("Cancelled: {detail}"))
            .unwrap_or_else(|| "Worker execution was cancelled.".to_owned()),
        _ => match worker_evidence_text(evidence) {
            Some(preview) if preview.eq_ignore_ascii_case("empty") => {
                "Completed without a user-facing result summary.".to_owned()
            }
            Some(preview) => preview.to_owned(),
            None => "Worker completed. Open its result for full details.".to_owned(),
        },
    }
}

fn parsed_wait_evidence(value: &Value) -> Vec<Value> {
    value
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|result| {
            result
                .get("evidence")
                .and_then(Value::as_str)
                .and_then(|evidence| serde_json::from_str::<Value>(evidence).ok())
        })
        .collect()
}

fn agent_update_preview(
    is_worker_result: bool,
    content: &str,
) -> (String, Option<String>, Option<String>) {
    let parsed = is_worker_result
        .then(|| serde_json::from_str::<Value>(content).ok())
        .flatten();
    let wait_evidence = parsed
        .as_ref()
        .filter(|value| value.get("kind").and_then(Value::as_str) == Some("worker_wait"))
        .map(parsed_wait_evidence)
        .unwrap_or_default();
    let source_worker_ids = parsed
        .as_ref()
        .and_then(|value| value.get("workerId"))
        .and_then(Value::as_str)
        .into_iter()
        .chain(
            wait_evidence
                .iter()
                .filter_map(|value| value.get("workerId").and_then(Value::as_str)),
        )
        .collect::<std::collections::BTreeSet<_>>();
    let source_worker_id = (source_worker_ids.len() == 1)
        .then(|| source_worker_ids.first().copied().map(ToOwned::to_owned))
        .flatten();
    let source_worker_names = parsed
        .as_ref()
        .and_then(|value| value.get("workerName"))
        .and_then(Value::as_str)
        .into_iter()
        .chain(
            wait_evidence
                .iter()
                .filter_map(|value| value.get("workerName").and_then(Value::as_str)),
        )
        .collect::<std::collections::BTreeSet<_>>();
    let source_worker_name = (source_worker_names.len() == 1)
        .then(|| source_worker_names.first().copied().map(ToOwned::to_owned))
        .flatten();
    let readable = match parsed.as_ref().and_then(|value| value.get("kind")) {
        Some(Value::String(kind)) if kind == "worker_result" => {
            let value = parsed.as_ref().expect("parsed worker result");
            let status = value
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("completed");
            readable_worker_evidence(status, value.get("evidence").unwrap_or(&Value::Null))
        }
        Some(Value::String(kind)) if kind == "worker_wait" => {
            let result_count = wait_evidence.len();
            let failed = wait_evidence
                .iter()
                .filter(|evidence| evidence.get("status").and_then(Value::as_str) == Some("failed"))
                .count();
            let first = wait_evidence.first().map(|evidence| {
                let status = evidence
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("completed");
                readable_worker_evidence(status, evidence.get("evidence").unwrap_or(evidence))
            });
            if result_count <= 1 {
                first.unwrap_or_else(|| "The requested worker wait completed.".to_owned())
            } else {
                let outcome = if failed == 0 {
                    format!("{result_count} worker results are ready.")
                } else {
                    format!("{result_count} worker results are ready; {failed} failed.")
                };
                first.map_or(outcome.clone(), |first| format!("{outcome} {first}"))
            }
        }
        _ if is_worker_result => "A worker completed. Open its result for full details.".to_owned(),
        _ => content.to_owned(),
    };
    let preview = crate::shared::foundation::redaction::redact_sensitive_content(&readable)
        .chars()
        .take(AGENT_UPDATE_PREVIEW_MAX_CHARS)
        .collect();
    (preview, source_worker_id, source_worker_name)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionListCursor {
    version: u8,
    snapshot_as_of: String,
    before_created_at: String,
    before_session_id: String,
    include_archived: bool,
    working_directory: Option<String>,
}

mod operations;

pub(crate) use operations::{
    session_agent_updates_value, session_context_request_detail_value,
    session_context_requests_value, session_export_value, session_get_head_value,
    session_get_history_value, session_get_state_value, session_list_value,
    session_replay_manifest_value, session_resume_value,
};

impl SessionQueryService {
    pub(crate) async fn agent_updates(
        deps: &Deps,
        session_id: String,
        limit: Option<usize>,
    ) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        run_blocking_task("session.agent_updates", move || {
            let limit = limit.unwrap_or(100).clamp(1, 200);
            let deliveries = event_store
                .list_agent_deliveries_for_session(&session_id, limit)
                .map_err(|error| match error {
                    crate::domains::session::event_store::EventStoreError::SessionNotFound(_) => {
                        ToolError::NotFound {
                            code: errors::SESSION_NOT_FOUND.into(),
                            message: format!("Session '{session_id}' not found"),
                        }
                    }
                    other => ToolError::Internal {
                        message: other.to_string(),
                    },
                })?;
            let waits = event_store
                .list_agent_waits_for_session(&session_id, limit)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;
            let updates = deliveries
                .into_iter()
                .map(|delivery| {
                    let (preview, source_worker_id, source_worker_name) = agent_update_preview(
                        delivery.source_kind == AgentDeliverySourceKind::WorkerResult,
                        &delivery.content,
                    );
                    json!({
                        "deliveryId":delivery.delivery_id,
                        "status":delivery.projection_status(),
                        "sourceKind":delivery.source_kind,
                        "sourceWorkerId":source_worker_id,
                        "sourceWorkerName":source_worker_name,
                        "intent":delivery.intent,
                        "sourceSessionId":delivery.source_session_id,
                        "sourceInvocationId":delivery.source_invocation_id,
                        "sourceTraceId":delivery.source_trace_id,
                        "resultInvocationId":delivery.result_invocation_id,
                        "wakePolicy":delivery.wake_policy,
                        "boundary":delivery.boundary,
                        "causalDepth":delivery.causal_depth,
                        "redelivery":delivery.is_redelivery(),
                        "leaseCount":delivery.lease_count,
                        "wakeAttempts":delivery.wake_attempts,
                        "lastError":delivery.last_error,
                        "preview":preview,
                        "createdAt":delivery.created_at,
                        "preparedRunId":delivery.leased_run_id,
                        "preparedTurn":delivery.leased_turn,
                        "observedAt":delivery.observed_at,
                        "cancelledAt":delivery.cancelled_at,
                        "expiresAt":delivery.expires_at,
                    })
                })
                .collect::<Vec<_>>();
            let waits = waits
                .into_iter()
                .map(|wait| {
                    json!({
                        "waitId":wait.wait_id,
                        "mode":wait.mode,
                        "status":wait.disposition,
                        "deliveryId":wait.delivery_id,
                        "createdAt":wait.created_at,
                        "resolvedAt":wait.resolved_at,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"updates":updates,"waits":waits}))
        })
        .await
    }

    pub(crate) async fn context_requests(
        deps: &Deps,
        session_id: String,
        before_sequence: Option<i64>,
        limit: Option<usize>,
    ) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        run_blocking_task("session.context_requests", move || {
            let _ = event_store
                .get_session(&session_id)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id}' not found"),
                })?;
            let limit = limit.unwrap_or(10).clamp(1, 20);
            let (rows, has_more) = event_store
                .get_provider_request_audits(&session_id, before_sequence, limit)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;
            let next_before_sequence = has_more
                .then(|| rows.last().map(|(row, _)| row.sequence))
                .flatten();
            let requests = rows
                .into_iter()
                .map(|(row, payload)| context_request_summary(&row, &payload))
                .collect::<Vec<_>>();
            Ok(json!({
                "requests":requests,
                "hasMore":has_more,
                "nextBeforeSequence":next_before_sequence,
            }))
        })
        .await
    }

    pub(crate) async fn context_request_detail(
        deps: &Deps,
        session_id: String,
        event_id: String,
        projection: ContextRequestDetailProjection,
    ) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        run_blocking_task("session.context_request_detail", move || {
            let (row, payload) = event_store
                .get_provider_request_audit(&session_id, &event_id)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!(
                        "Provider request audit '{event_id}' was not found in session '{session_id}'"
                    ),
                })?;
            let format = payload
                .get("format")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let mut context_manifest = payload
                .get("contextManifest")
                .cloned()
                .unwrap_or(Value::Null);
            let source_event_ids = context_source_event_ids(&context_manifest);
            let source_events = event_store
                .get_events_by_ids_for_session(&session_id, &source_event_ids)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;
            enrich_context_message_source_metadata(&mut context_manifest, &source_events);
            if projection == ContextRequestDetailProjection::AgentContext {
                project_agent_context_tool_surface(&mut context_manifest);
            }
            let mut detail = json!({
                "eventId":row.id,
                "sequence":row.sequence,
                "timestamp":row.timestamp,
                "format":format,
                "contextManifest":context_manifest,
                "providerAdditions":payload.get("providerAdditions").cloned().unwrap_or_else(|| json!([])),
                "provenanceAvailability":if crate::shared::protocol::model_audit::provider_audit_has_complete_provenance(format) {
                    "complete"
                } else {
                    "legacy_unavailable"
                },
            });
            if projection == ContextRequestDetailProjection::Technical {
                detail["providerAudit"] = payload;
            }
            Ok(detail)
        })
        .await
    }

    pub(crate) async fn resume(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_resume = session_id.clone();
        run_blocking_task("session.resume", move || {
            let state = session_manager
                .resume_session(&session_id_for_resume)
                .map_err(|error| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: error.to_string(),
                })?;

            Ok(json!({
                "sessionId": session_id_for_resume,
                "model": state.model,
                "messageCount": state.messages.len(),
                "lastActivity": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            }))
        })
        .await
    }

    pub(crate) async fn list(
        deps: &Deps,
        include_archived: bool,
        limit: Option<usize>,
        working_directory: Option<String>,
        offset: Option<usize>,
        cursor: Option<SessionListCursor>,
    ) -> Result<Value, ToolError> {
        let limit = limit
            .unwrap_or(SESSION_LIST_DEFAULT_LIMIT)
            .clamp(1, SESSION_LIST_MAX_LIMIT);
        let fetch_limit = limit.saturating_add(1);
        let snapshot_as_of = cursor.as_ref().map_or_else(
            || chrono::Utc::now().to_rfc3339(),
            |cursor| cursor.snapshot_as_of.clone(),
        );
        let before_created_at = cursor
            .as_ref()
            .map(|cursor| cursor.before_created_at.clone());
        let before_session_id = cursor
            .as_ref()
            .map(|cursor| cursor.before_session_id.clone());
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let orchestrator = deps.orchestrator.clone();
        run_blocking_task("session.list", move || {
            let options = ListSessionsOptions {
                workspace_id: None,
                working_directory: working_directory.as_deref(),
                ended: if include_archived {
                    None
                } else {
                    Some(false)
                },
                include_worker_sessions: false,
                #[allow(clippy::cast_possible_wrap)]
                limit: Some(fetch_limit as i64),
                #[allow(clippy::cast_possible_wrap)]
                offset: offset.map(|value| value as i64),
                snapshot_created_at: Some(&snapshot_as_of),
                before_created_at: before_created_at.as_deref(),
                before_session_id: before_session_id.as_deref(),
            };
            let mut sessions = event_store.list_sessions(&options).map_err(|error| {
                ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                }
            })?;

            let has_more = sessions.len() > limit;
            sessions.truncate(limit);
            let next_cursor = if has_more {
                sessions.last().map(|session| {
                    serde_json::to_string(&SessionListCursor {
                        version: 1,
                        snapshot_as_of: snapshot_as_of.clone(),
                        before_created_at: session.created_at.clone(),
                        before_session_id: session.id.clone(),
                        include_archived,
                        working_directory: working_directory.clone(),
                    })
                    .expect("session list cursor serialization cannot fail")
                })
            } else {
                None
            };

            let session_ids: Vec<&str> = sessions.iter().map(|session| session.id.as_str()).collect();
            let previews = event_store
                .get_session_message_previews(&session_ids)
                .unwrap_or_default();

            let activity_summaries = event_store
                .get_session_activity_summaries_batch(&session_ids)
                .unwrap_or_default();

            let items: Vec<Value> = sessions
                .into_iter()
                .map(|session| {
                    let is_cached = session_manager.is_cached(&session.id);
                    let is_running = orchestrator.has_active_run(&session.id);
                    let preview = previews.get(&session.id);
                    let (labels, organization_group) =
                        session_organization_from_tags(&session.tags);
                    json!({
                        "sessionId": session.id,
                        "model": session.latest_model,
                        "title": session.title,
                        "workingDirectory": session.working_directory,
                        "createdAt": session.created_at,
                        "lastActivity": session.last_activity_at,
                        "endedAt": session.ended_at,
                        // `isActive` reports session-cache residency.
                        "isActive": is_cached,
                        "isRunning": is_running,
                        "isArchived": session.ended_at.is_some(),
                        "labels": labels,
                        "organizationGroup": organization_group,
                        "eventCount": session.event_count,
                        "turnCount": session.turn_count,
                        "messageCount": session.message_count,
                        "inputTokens": session.total_input_tokens,
                        "outputTokens": session.total_output_tokens,
                        "lastTurnInputTokens": session.last_turn_input_tokens,
                        "cacheReadTokens": session.total_cache_read_tokens,
                        "cacheCreationTokens": session.total_cache_creation_tokens,
                        "cost": session.total_cost,
                        "parentSessionId": session.parent_session_id,
                        "lastUserPrompt": preview.and_then(|p| p.last_user_prompt.as_deref()),
                        "lastAssistantResponse": preview.and_then(|p| p.last_assistant_response.as_deref()),
                        "activityLines": activity_summaries.get(&session.id).cloned().unwrap_or_default(),
                    })
                })
                .collect();

            Ok(json!({
                "sessions": items,
                "hasMore": has_more,
                "nextCursor": next_cursor,
                "snapshotAsOf": snapshot_as_of,
                "snapshotCanReconcile": include_archived && working_directory.is_none() && offset.is_none(),
            }))
        })
        .await
    }

    pub(crate) async fn get_head(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id_for_head = session_id.clone();
        run_blocking_task("session.get_head", move || {
            let session = event_store
                .get_session(&session_id_for_head)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_head}' not found"),
                })?;

            Ok(json!({
                "sessionId": session.id,
                "headEventId": session.head_event_id,
            }))
        })
        .await
    }

    pub(crate) async fn get_state(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let session_id_for_state = session_id.clone();
        run_blocking_task("session.get_state", move || {
            let session = event_store
                .get_session(&session_id_for_state)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_state}' not found"),
                })?;

            let state = session_manager
                .resume_session(&session_id_for_state)
                .map_err(|error| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: error.to_string(),
                })?;

            let event_count = event_store.count_events(&session_id_for_state).unwrap_or(0);

            Ok(json!({
                "sessionId": session_id_for_state,
                "headEventId": session.head_event_id,
                "model": state.model,
                "turnCount": state.turn_count,
                "isEnded": state.is_ended,
                "workingDirectory": state.working_directory,
                "workspaceId": session.working_directory,
                "eventCount": event_count,
                "lastTurnInputTokens": session.last_turn_input_tokens,
                "tokenUsage": {
                    "inputTokens": state.token_usage.input_tokens,
                    "outputTokens": state.token_usage.output_tokens,
                    "cacheReadTokens": session.total_cache_read_tokens,
                    "cacheCreationTokens": session.total_cache_creation_tokens,
                },
            }))
        })
        .await
    }

    /// Full session dump for backup / inspection / offline analysis.
    ///
    /// Returns the `sessions` row and every `events` row belonging to the
    /// session, ordered by sequence ascending, under a stable
    /// `format: "tron.session.v1"` envelope. Blob references in events stay
    /// as-is — callers resolve them via `blob.get`. The format version is
    /// the schema contract: additions are additive, removals bump the version.
    ///
    /// This is a single round-trip snapshot with no pagination. For
    /// sessions larger than ~50k events the export is large but not
    /// unbounded — the payload is serialized in memory before being
    /// returned, which matches how `session.reconstruct` already behaves.
    pub(crate) async fn export(deps: &Deps, session_id: String) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id_for_export = session_id.clone();
        run_blocking_task("session.export", move || {
            let session = event_store
                .get_session(&session_id_for_export)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_export}' not found"),
                })?;

            let opts = crate::domains::session::event_store::ListEventsOptions::default();
            let events = event_store
                .get_events_by_session(&session_id_for_export, &opts)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;

            let event_count = events.len();
            let session_value = serde_json::to_value(&session).map_err(|error| ToolError::Internal {
                message: format!("session serialization failed: {error}"),
            })?;
            let events_value = serde_json::to_value(&events).map_err(|error| ToolError::Internal {
                message: format!("events serialization failed: {error}"),
            })?;

            Ok(json!({
                "format": "tron.session.v1",
                "exportedAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                "session": session_value,
                "events": events_value,
                "eventCount": event_count,
            }))
        })
        .await
    }

    /// Canonical deterministic replay manifest for audit/reconstruction.
    pub(crate) async fn replay_manifest(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, ToolError> {
        crate::domains::session::replay::replay_manifest_value(
            crate::domains::session::replay::ReplayDeps::new(
                deps.event_store.clone(),
                deps.engine_host.clone(),
            ),
            session_id,
        )
        .await
    }

    pub(crate) async fn get_history(
        deps: &Deps,
        session_id: String,
        limit: Option<usize>,
        before_id: Option<String>,
    ) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id_for_history = session_id.clone();
        run_blocking_task("session.get_history", move || {
            let _ = event_store
                .get_session(&session_id_for_history)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id_for_history}' not found"),
                })?;

            let message_types = [
                "message.user",
                "message.assistant",
                "tool.invocation.completed",
            ];
            let type_strs: Vec<&str> = message_types.to_vec();
            let events = event_store
                .get_events_by_type(&session_id_for_history, &type_strs, None)
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;

            let events = if let Some(before_id) = before_id {
                events
                    .into_iter()
                    .take_while(|event| event.id != before_id)
                    .collect::<Vec<_>>()
            } else {
                events
            };

            let has_more = limit.is_some_and(|value| events.len() > value);
            let events = if let Some(limit) = limit {
                events.into_iter().take(limit).collect::<Vec<_>>()
            } else {
                events
            };

            let resolved_payloads =
                event_store
                    .resolve_event_payloads(&events)
                    .map_err(|error| ToolError::Internal {
                        message: format!("Failed to resolve event payloads: {error}"),
                    })?;

            let messages: Vec<Value> = events
                .iter()
                .zip(resolved_payloads)
                .map(|(event, content)| {
                    let role = match event.event_type.as_str() {
                        "message.user" => "user",
                        "message.assistant" => "assistant",
                        "tool.invocation.completed" => "tool",
                        _ => "unknown",
                    };
                    let mut message = json!({
                        "id": event.id,
                        "role": role,
                        "content": content,
                        "timestamp": event.timestamp,
                    });
                    if let Some(ref tool_name) = event.tool_name {
                        message["toolInvocation"] = json!({ "name": tool_name });
                    }
                    if event.event_type == "tool.invocation.completed" {
                        if let Some(invocation_id) = content.get("invocationId") {
                            message["invocationId"] = invocation_id.clone();
                        }
                        if let Some(is_error) = content.get("isError") {
                            message["isError"] = is_error.clone();
                        }
                    }
                    message
                })
                .collect();

            Ok(json!({
                "messages": messages,
                "hasMore": has_more,
            }))
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    //! Query-service unit tests. Handler-level coverage lives in
    //! `handlers/session_tests.rs`; here we exercise the service methods
    //! directly so invariants like "events ordered by sequence" and
    //! "format: tron.session.v1" aren't tied to the handler wire-up.

    use super::*;
    use crate::domains::session::event_store::{AppendOptions, EventType};
    use crate::shared::server::test_support::make_test_context;

    #[test]
    fn agent_context_tool_surface_keeps_only_rendered_capability_fields() {
        let mut manifest = json!({
            "toolSurface": {
                "catalogRevision": 42,
                "fixedTools": [
                    {
                        "functionId": "filesystem_read",
                        "modelName": "filesystem_read",
                        "exposed": true,
                        "selectionReason": "ordinary",
                        "inputSchema": {"type": "object"},
                        "inputSchemaSha256": "sha256:fixed"
                    },
                    {
                        "functionId": "hidden_tool",
                        "modelName": "hidden_tool",
                        "exposed": false,
                        "inputSchema": {"type": "object"}
                    }
                ],
                "availableWorkers": [
                    {
                        "workerId": "research",
                        "modelName": "research",
                        "workerVersion": "v1",
                        "projected": true,
                        "selectionReason": "relevant",
                        "outputSchema": {"type": "object"}
                    },
                    {
                        "workerId": "omitted",
                        "modelName": "omitted",
                        "projected": false,
                        "omissionReason": "not relevant"
                    }
                ],
                "tools": [{"large": "technical-only"}]
            }
        });

        project_agent_context_tool_surface(&mut manifest);

        let surface = &manifest["toolSurface"];
        assert_eq!(surface["fixedTools"].as_array().unwrap().len(), 1);
        assert_eq!(surface["availableWorkers"].as_array().unwrap().len(), 1);
        assert_eq!(surface["fixedTools"][0]["functionId"], "filesystem_read");
        assert!(surface["fixedTools"][0].get("inputSchema").is_none());
        assert!(surface["availableWorkers"][0].get("outputSchema").is_none());
        assert!(surface.get("catalogRevision").is_none());
        assert!(surface.get("tools").is_none());
    }

    #[test]
    fn agent_update_preview_projects_worker_result_evidence_without_raw_json() {
        let content = json!({
            "kind":"worker_result",
            "invocationId":"worker-run",
            "workerId":"research-curator",
            "status":"completed",
            "evidence":{
                "preview":"Three relevant findings are ready.",
                "reference":{"contentSha256":"sha256:secret-technical-evidence"}
            }
        })
        .to_string();

        let (preview, worker_id, worker_name) = agent_update_preview(true, &content);

        assert_eq!(preview, "Three relevant findings are ready.");
        assert_eq!(worker_id.as_deref(), Some("research-curator"));
        assert!(worker_name.is_none());
        assert!(!preview.contains("contentSha256"));
    }

    #[test]
    fn agent_update_preview_explains_empty_and_failed_worker_results() {
        let (empty, _, _) = agent_update_preview(
            true,
            &json!({
                "kind":"worker_result",
                "workerId":"continuity-curator",
                "status":"completed",
                "evidence":{"preview":"empty"}
            })
            .to_string(),
        );
        let (failed, _, _) = agent_update_preview(
            true,
            &json!({
                "kind":"worker_result",
                "workerId":"research-curator",
                "status":"failed",
                "evidence":{"error":"provider setup failed"}
            })
            .to_string(),
        );

        assert_eq!(empty, "Completed without a user-facing result summary.");
        assert_eq!(failed, "Failed: provider setup failed");
    }

    #[test]
    fn agent_update_preview_preserves_plain_delivery_content_and_bounds_it() {
        let content = "Useful peer update. ".repeat(100);
        let (preview, worker_id, worker_name) = agent_update_preview(false, &content);

        assert_eq!(preview.chars().count(), AGENT_UPDATE_PREVIEW_MAX_CHARS);
        assert!(worker_id.is_none());
        assert!(worker_name.is_none());
        assert!(preview.starts_with("Useful peer update."));
    }

    #[test]
    fn agent_update_preview_does_not_expose_unknown_worker_payload_shapes() {
        let content = json!({
            "unexpected":"internal payload",
            "reference":{"contentSha256":"sha256:technical-evidence"}
        })
        .to_string();

        let (preview, worker_id, worker_name) = agent_update_preview(true, &content);

        assert_eq!(
            preview,
            "A worker completed. Open its result for full details."
        );
        assert!(worker_id.is_none());
        assert!(worker_name.is_none());
        assert!(!preview.contains("contentSha256"));
    }

    #[test]
    fn agent_update_preview_projects_wait_evidence_and_worker_identity() {
        let content = json!({
            "kind":"worker_wait",
            "waitId":"wait-one",
            "mode":"all",
            "results":[{
                "invocationId":"worker-run",
                "status":"completed",
                "evidence":json!({
                    "workerId":"wait-ux-smoke",
                    "workerName":"Wait UX Smoke Test",
                    "status":"completed",
                    "evidence":{
                        "preview":"Background worker finished successfully."
                    }
                }).to_string()
            }]
        })
        .to_string();

        let (preview, worker_id, worker_name) = agent_update_preview(true, &content);

        assert_eq!(preview, "Background worker finished successfully.");
        assert_eq!(worker_id.as_deref(), Some("wait-ux-smoke"));
        assert_eq!(worker_name.as_deref(), Some("Wait UX Smoke Test"));
        assert!(!preview.contains("waitId"));
    }

    /// A freshly-created session always has exactly one event — the
    /// `session.start` event inserted inside the create transaction.
    /// Export includes it, so the minimum payload is `eventCount: 1`.
    /// If this ever regresses to 0 (or 2+), something has changed about
    /// session creation and the export contract needs to be re-verified.
    #[tokio::test]
    async fn export_of_fresh_session_returns_session_start_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), sid.clone())
            .await
            .unwrap();

        assert_eq!(result["format"].as_str().unwrap(), "tron.session.v1");
        assert_eq!(result["eventCount"].as_u64().unwrap(), 1);
        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"].as_str().unwrap(), "session.start");
        assert_eq!(events[0]["sequence"].as_i64().unwrap(), 0);
        assert_eq!(result["session"]["id"].as_str().unwrap(), sid);
    }

    /// Missing session → NotFound with SESSION_NOT_FOUND code. Downstream
    /// iOS maps this to "session was deleted" rather than a retry loop.
    #[tokio::test]
    async fn export_of_nonexistent_session_is_not_found() {
        let ctx = make_test_context();
        let err = SessionQueryService::export(
            &Deps::from_test_context(&ctx),
            "sess_does_not_exist".to_string(),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    /// Events in the export are ordered by sequence ASC. A downstream
    /// import or replay tool relies on this; shuffling by insertion order
    /// or ID would be a silent correctness bug.
    #[tokio::test]
    async fn export_events_are_ordered_by_sequence_asc() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // Append three user messages. Sequence auto-increments starting
        // from 1 (the create transaction already claimed 0 for session.start).
        for i in 0..3 {
            ctx.event_store
                .append(&AppendOptions {
                    session_id: &sid,
                    event_type: EventType::MessageUser,
                    payload: serde_json::json!({ "content": format!("msg-{i}"), "turn": i }),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
        }

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), sid)
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        // session.start (seq 0) + 3 user messages (seq 1..=3) = 4.
        assert_eq!(events.len(), 4);
        let seqs: Vec<i64> = events
            .iter()
            .map(|e| e["sequence"].as_i64().unwrap())
            .collect();
        let mut sorted = seqs.clone();
        sorted.sort_unstable();
        assert_eq!(
            seqs, sorted,
            "export events must be sequence-ASC — export was {seqs:?}"
        );
        assert_eq!(seqs, vec![0, 1, 2, 3]);
        assert_eq!(result["eventCount"].as_u64().unwrap(), 4);
    }

    /// `exportedAt` is an RFC3339 timestamp. Downstream tools parse it
    /// as-is — if this regresses to a raw `SystemTime` or a broken format,
    /// import tooling silently breaks.
    #[tokio::test]
    async fn export_exportedat_is_rfc3339() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = SessionQueryService::export(&Deps::from_test_context(&ctx), sid)
            .await
            .unwrap();
        let ts = result["exportedAt"].as_str().unwrap();
        chrono::DateTime::parse_from_rfc3339(ts).unwrap_or_else(|e| {
            panic!("exportedAt not RFC3339: value='{ts}' err={e}");
        });
    }

    #[tokio::test]
    async fn list_accepts_ios_session_pagination_payload() {
        let ctx = make_test_context();
        let first = ctx
            .session_manager
            .create_session("m", "/tmp/a", Some("a"))
            .unwrap();
        let second = ctx
            .session_manager
            .create_session("m", "/tmp/b", Some("b"))
            .unwrap();

        let result = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            Some(1),
            None,
            Some(0),
            None,
        )
        .await
        .unwrap();
        let sessions = result["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(result["hasMore"].as_bool(), Some(true));
        assert_eq!(result["snapshotCanReconcile"].as_bool(), Some(false));
        let snapshot_as_of = result["snapshotAsOf"].as_str().unwrap().to_owned();
        let cursor: SessionListCursor =
            serde_json::from_str(result["nextCursor"].as_str().unwrap()).unwrap();

        let next = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            Some(1),
            None,
            None,
            Some(cursor),
        )
        .await
        .unwrap();
        let next_sessions = next["sessions"].as_array().unwrap();
        assert_eq!(next_sessions.len(), 1);
        assert_ne!(
            sessions[0]["sessionId"].as_str(),
            next_sessions[0]["sessionId"].as_str()
        );
        assert_eq!(next["hasMore"].as_bool(), Some(false));
        assert_eq!(next["snapshotAsOf"].as_str(), Some(snapshot_as_of.as_str()));

        let filtered = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            false,
            None,
            Some("/tmp/a".to_string()),
            Some(0),
            None,
        )
        .await
        .unwrap();
        let sessions = filtered["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["sessionId"].as_str().unwrap(), first);
        assert_ne!(sessions[0]["sessionId"].as_str().unwrap(), second);
    }

    #[tokio::test]
    async fn ordinary_list_hides_worker_sessions_while_exact_audit_reads_remain_available() {
        let ctx = make_test_context();
        let user_session = ctx
            .session_manager
            .create_session("m", "/tmp/user", Some("User conversation"))
            .unwrap();
        let worker_session = ctx
            .session_manager
            .create_worker_session("m", "/tmp/worker", Some("Worker child"))
            .unwrap();

        let result = SessionQueryService::list(
            &Deps::from_test_context(&ctx),
            true,
            Some(20),
            None,
            None,
            None,
        )
        .await
        .unwrap();
        let ids = result["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|session| session["sessionId"].as_str())
            .collect::<Vec<_>>();
        assert!(ids.contains(&user_session.as_str()));
        assert!(!ids.contains(&worker_session.as_str()));

        let state =
            SessionQueryService::get_state(&Deps::from_test_context(&ctx), worker_session.clone())
                .await
                .unwrap();
        assert_eq!(state["sessionId"], worker_session);
    }

    #[tokio::test]
    async fn context_requests_page_only_provider_audits_and_label_legacy_provenance() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("context audit"))
            .unwrap();
        let legacy = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &sid,
                event_type: EventType::ModelProviderRequest,
                payload: json!({
                    "format":crate::shared::protocol::model_audit::LEGACY_MODEL_PROVIDER_REQUEST_AUDIT_FORMAT,
                    "providerType":"openai",
                    "providerName":"openai",
                    "model":"test",
                    "messageCount":1,
                    "toolCount":2,
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        let current = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &sid,
                event_type: EventType::ModelProviderRequest,
                payload: json!({
                    "format":crate::shared::protocol::model_audit::MODEL_PROVIDER_REQUEST_AUDIT_FORMAT,
                    "providerType":"openai",
                    "providerName":"openai",
                    "model":"test",
                    "messageCount":2,
                    "toolCount":3,
                    "contextManifest":{
                        "systemContributions":[{"kind":"base"}],
                        "messages":[
                            {"contentKinds":["text"]},
                            {"contentKinds":["image","text"]}
                        ],
                        "automaticContext":[],
                        "agentDeliveries":[{"deliveryId":"delivery-1"}],
                        "environment":{"workingDirectory":"/tmp"}
                    },
                    "providerAdditions":[{
                        "kind":"provider_system_prefix",
                        "label":"Provider instructions",
                        "content":"prefix",
                        "byteCount":6,
                        "sha256":"sha256:prefix"
                    }]
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        ctx.event_store
            .append(&AppendOptions {
                session_id: &sid,
                event_type: EventType::MessageUser,
                payload: json!({"role":"user","content":"not an audit"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let first = SessionQueryService::context_requests(
            &Deps::from_test_context(&ctx),
            sid.clone(),
            None,
            Some(1),
        )
        .await
        .unwrap();
        assert_eq!(first["requests"].as_array().unwrap().len(), 1);
        assert_eq!(first["requests"][0]["eventId"], current.id);
        assert_eq!(first["requests"][0]["provenanceAvailability"], "complete");
        assert_eq!(first["requests"][0]["instructionCount"], 2);
        assert_eq!(first["requests"][0]["attachmentMessageCount"], 1);
        assert_eq!(first["requests"][0]["agentDeliveryCount"], 1);
        assert_eq!(first["requests"][0]["environmentAvailable"], true);
        assert_eq!(first["hasMore"], true);

        let second = SessionQueryService::context_requests(
            &Deps::from_test_context(&ctx),
            sid.clone(),
            first["nextBeforeSequence"].as_i64(),
            Some(1),
        )
        .await
        .unwrap();
        assert_eq!(second["requests"][0]["eventId"], legacy.id);
        assert_eq!(
            second["requests"][0]["provenanceAvailability"],
            "legacy_unavailable"
        );
        assert_eq!(second["hasMore"], false);

        let detail = SessionQueryService::context_request_detail(
            &Deps::from_test_context(&ctx),
            sid.clone(),
            current.id.clone(),
            ContextRequestDetailProjection::AgentContext,
        )
        .await
        .unwrap();
        assert_eq!(detail["provenanceAvailability"], "complete");
        assert!(detail["contextManifest"].is_object());
        assert_eq!(
            detail["providerAdditions"][0]["kind"],
            "provider_system_prefix"
        );
        assert!(detail.get("providerAudit").is_none());

        let technical_detail = SessionQueryService::context_request_detail(
            &Deps::from_test_context(&ctx),
            sid,
            current.id,
            ContextRequestDetailProjection::Technical,
        )
        .await
        .unwrap();
        assert!(technical_detail["providerAudit"].is_object());
    }

    #[tokio::test]
    async fn context_request_detail_enforces_exact_session_ownership() {
        let ctx = make_test_context();
        let first = ctx
            .session_manager
            .create_session("m", "/tmp", Some("first"))
            .unwrap();
        let second = ctx
            .session_manager
            .create_session("m", "/tmp", Some("second"))
            .unwrap();
        let audit = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &first,
                event_type: EventType::ModelProviderRequest,
                payload: json!({"format":"tron.model_provider_request.v3"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let error = SessionQueryService::context_request_detail(
            &Deps::from_test_context(&ctx),
            second,
            audit.id,
            ContextRequestDetailProjection::Technical,
        )
        .await
        .expect_err("cross-session audit read must fail");
        assert!(matches!(error, ToolError::NotFound { .. }));
    }

    #[tokio::test]
    async fn context_request_detail_enriches_messages_from_batched_source_events() {
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("m", "/tmp", Some("source metadata"))
            .unwrap();
        let assistant = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::MessageAssistant,
                payload: json!({
                    "role":"assistant",
                    "content":"hello",
                    "model":"gpt-5.6-sol",
                    "providerType":"openai",
                    "turn":7
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        let tool = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::ToolInvocationCompleted,
                payload: json!({
                    "role":"tool",
                    "content":"done",
                    "toolName":"filesystem_read",
                    "invocationId":"call-1"
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        let audit = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::ModelProviderRequest,
                payload: json!({
                    "format":crate::shared::protocol::model_audit::MODEL_PROVIDER_REQUEST_AUDIT_FORMAT,
                    "contextManifest":{
                        "messages":[
                            {"sourceEventIds":[assistant.id]},
                            {"sourceEventIds":[tool.id]}
                        ]
                    }
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let detail = SessionQueryService::context_request_detail(
            &Deps::from_test_context(&ctx),
            session_id,
            audit.id,
            ContextRequestDetailProjection::AgentContext,
        )
        .await
        .unwrap();

        assert_eq!(
            detail["contextManifest"]["messages"][0]["sourceModels"],
            json!(["gpt-5.6-sol"])
        );
        assert_eq!(
            detail["contextManifest"]["messages"][0]["sourceTurns"],
            json!([7])
        );
        assert_eq!(
            detail["contextManifest"]["messages"][1]["sourceTools"],
            json!(["filesystem_read"])
        );
    }

    #[tokio::test]
    async fn list_rejects_mixed_cursor_and_offset_pagination() {
        let ctx = make_test_context();
        let cursor = serde_json::to_string(&SessionListCursor {
            version: 1,
            snapshot_as_of: "2026-07-01T12:00:01Z".into(),
            before_created_at: "2026-07-01T12:00:00Z".into(),
            before_session_id: "sess_cursor".into(),
            include_archived: false,
            working_directory: None,
        })
        .unwrap();
        let params = json!({
            "limit": 20,
            "offset": 0,
            "cursor": cursor,
        });

        let error = session_list_value(Some(&params), &Deps::from_test_context(&ctx))
            .await
            .unwrap_err();
        assert!(matches!(error, ToolError::InvalidParams { .. }));
    }

    #[tokio::test]
    async fn list_rejects_reusing_a_cursor_with_different_filters() {
        let ctx = make_test_context();
        let cursor = serde_json::to_string(&SessionListCursor {
            version: 1,
            snapshot_as_of: "2026-07-01T12:00:01Z".into(),
            before_created_at: "2026-07-01T12:00:00Z".into(),
            before_session_id: "sess_cursor".into(),
            include_archived: true,
            working_directory: None,
        })
        .unwrap();

        let error = session_list_value(
            Some(&json!({
                "cursor": cursor,
                "includeArchived": false,
                "limit": 20
            })),
            &Deps::from_test_context(&ctx),
        )
        .await
        .unwrap_err();
        assert!(matches!(error, ToolError::InvalidParams { .. }));
    }
}
