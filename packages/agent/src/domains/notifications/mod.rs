//! Notifications domain worker.
//!
//! This module owns canonical function execution for the `notifications::*`
//! namespace. Notification delivery/read truth is resource-backed:
//! `notifications::send` creates a `notification` resource plus delivery
//! `evidence`, and read/mark-all-read state is stored as `decision` resources.
//! Session events and APNs delivery remain audit/projection channels, not inbox
//! source truth.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::capability_support::implementations::errors::CapabilityExecutionError;
use crate::domains::capability_support::implementations::traits::Notification;
use crate::domains::notifications::inbox::{DeliveryObservation, NotificationInboxService};
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::errors::to_json_value;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::opt_u64;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

const MAX_TITLE_LENGTH: usize = 50;
const MAX_BODY_LENGTH: usize = 200;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "notifications",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod inbox;

async fn notifications_send_value(
    params: Option<&Value>,
    deps: &Deps,
    invocation: &Invocation,
) -> Result<Value, CapabilityError> {
    let raw_title = require_string_param(params, "title")?;
    let raw_body = require_string_param(params, "body")?;
    if raw_title.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "title must not be empty".to_owned(),
        });
    }
    if raw_body.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "body must not be empty".to_owned(),
        });
    }
    reject_raw_secret_text(&raw_title, "title")?;
    reject_raw_secret_text(&raw_body, "body")?;
    let title = crate::shared::text::truncate_with_suffix(&raw_title, MAX_TITLE_LENGTH, "...");
    let body = crate::shared::text::truncate_with_suffix(&raw_body, MAX_BODY_LENGTH, "...");
    let priority = opt_string(params, "priority").unwrap_or_else(|| "normal".to_owned());
    if !matches!(priority.as_str(), "low" | "normal" | "high") {
        return Err(CapabilityError::InvalidParams {
            message: "priority must be low, normal, or high".to_owned(),
        });
    }
    let badge = params
        .and_then(|value| value.get("badge"))
        .and_then(Value::as_u64)
        .map(u32::try_from)
        .transpose()
        .map_err(|_| CapabilityError::InvalidParams {
            message: "badge must fit in u32".to_owned(),
        })?;
    let session_id = resolve_notification_scope(
        "sessionId",
        invocation.causal_context.session_id.as_deref(),
        opt_string(params, "sessionId").as_deref(),
    )?;
    let workspace_id = resolve_notification_scope(
        "workspaceId",
        invocation.causal_context.workspace_id.as_deref(),
        opt_string(params, "workspaceId").as_deref(),
    )?;
    let mut data_object = params
        .and_then(|value| value.get("data"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    data_object.insert(
        "invocationId".to_owned(),
        Value::String(invocation.id.as_str().to_owned()),
    );
    data_object.insert("sessionId".to_owned(), Value::String(session_id.clone()));
    data_object.insert(
        "workspaceId".to_owned(),
        Value::String(workspace_id.clone()),
    );
    let data = if data_object.is_empty() {
        None
    } else {
        Some(Value::Object(data_object))
    };
    if let Some(data) = &data {
        reject_raw_secret_value(data, "data")?;
    }
    let sheet_content = params
        .and_then(|value| value.get("sheetContent"))
        .cloned()
        .or_else(|| params.and_then(|value| value.get("sheet_content")).cloned());
    if let Some(sheet_content) = &sheet_content {
        reject_raw_secret_value(sheet_content, "sheetContent")?;
    }
    let now = chrono::Utc::now().to_rfc3339();
    let prepared = NotificationInboxService::prepare(
        invocation,
        json!({
            "notificationId": invocation.id.as_str(),
            "title": title,
            "body": body,
            "priority": priority,
            "badge": badge,
            "data": data,
            "sheetContent": sheet_content,
            "sessionId": session_id,
            "workspaceId": workspace_id,
            "invocationId": invocation.id.as_str(),
            "createdAt": now,
            "updatedAt": now,
            "isUserSession": invocation.causal_context.actor_kind == crate::engine::ActorKind::Agent,
            "delivery": {
                "status": "pending",
                "success": false,
                "message": Value::Null,
                "successCount": 0,
                "totalCount": 0,
                "warning": Value::Null,
                "errorCode": Value::Null
            },
            "metadata": {
                "domain": "notifications",
                "recordKind": "inbox",
                "sourceFunctionId": "notifications::send"
            }
        }),
    );
    let notification = Notification {
        title: prepared.pending_payload["title"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        body: prepared.pending_payload["body"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        priority: prepared.pending_payload["priority"]
            .as_str()
            .unwrap_or("normal")
            .to_owned(),
        badge,
        data: data.clone(),
        sheet_content: sheet_content.clone(),
    };
    let delivery = match deps.notify_delegate.send_notification(&notification).await {
        Ok(delivery) => DeliveryObservation {
            success: delivery.success,
            message: delivery.message,
            success_count: u64::from(delivery.success_count),
            total_count: u64::from(delivery.total_count),
            warning: delivery.warning,
            error_code: None,
        },
        Err(error) => delivery_from_error(error),
    };
    let (resource_refs, evidence_refs) =
        NotificationInboxService::persist_delivery(deps, invocation, prepared, delivery.clone())
            .await?;
    Ok(json!({
        "title": notification.title,
        "body": notification.body,
        "priority": notification.priority,
        "success": delivery.success,
        "message": delivery.message,
        "successCount": delivery.success_count,
        "totalCount": delivery.total_count,
        "warning": delivery.warning,
        "data": data,
        "sheetContent": sheet_content,
        "resourceRefs": resource_refs,
        "evidenceRefs": evidence_refs,
    }))
}

fn delivery_from_error(error: CapabilityExecutionError) -> DeliveryObservation {
    let (code, message) = match error {
        CapabilityExecutionError::Validation { message } => ("VALIDATION", message),
        CapabilityExecutionError::NotFound { message } => ("NOT_FOUND", message),
        other => ("NOTIFICATION_SEND_FAILED", other.to_string()),
    };
    DeliveryObservation {
        success: false,
        message: Some(message),
        success_count: 0,
        total_count: 0,
        warning: Some(format!("Notification delivery failed: {code}")),
        error_code: Some(code.to_owned()),
    }
}

fn resolve_notification_scope(
    field: &str,
    causal_value: Option<&str>,
    requested_value: Option<&str>,
) -> Result<String, CapabilityError> {
    match (causal_value, requested_value) {
        (Some(causal), Some(requested)) if causal != requested => {
            Err(CapabilityError::InvalidParams {
                message: format!("{field} must match the invocation causal context"),
            })
        }
        (Some(causal), _) => Ok(causal.to_owned()),
        (None, Some(requested)) => Ok(requested.to_owned()),
        (None, None) => Ok("notifications".to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::capability_support::implementations::traits::{
        NotifyDelegate, NotifyResult,
    };
    use crate::engine::{ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, TraceId};
    use crate::shared::server::test_support::make_test_context;
    use async_trait::async_trait;
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct RecordingNotify {
        last: Mutex<Option<Notification>>,
    }

    #[async_trait]
    impl NotifyDelegate for RecordingNotify {
        async fn send_notification(
            &self,
            notification: &Notification,
        ) -> Result<NotifyResult, CapabilityExecutionError> {
            *self.last.lock().unwrap() = Some(notification.clone());
            Ok(NotifyResult {
                success: true,
                message: None,
                success_count: 1,
                total_count: 1,
                warning: None,
            })
        }
    }

    fn test_invocation() -> Invocation {
        let causal_context = CausalContext::new(
            ActorId::new("agent:test").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("test-grant").expect("grant id"),
            TraceId::generate(),
        )
        .with_session_id("sess_1")
        .with_workspace_id("ws_1");
        Invocation::new_sync(
            FunctionId::new("notifications::send").expect("function id"),
            json!({}),
            causal_context,
        )
    }

    #[tokio::test]
    async fn send_truncates_and_injects_causal_context() {
        let ctx = make_test_context();
        let notify = Arc::new(RecordingNotify::default());
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
            notify_delegate: notify.clone(),
        };
        let invocation = test_invocation();
        let result = notifications_send_value(
            Some(&json!({
                "title": "t".repeat(80),
                "body": "b".repeat(260),
                "priority": "high",
                "data": {
                    "custom": "value",
                    "invocationId": "forged-invocation",
                    "sessionId": "forged-session",
                    "workspaceId": "forged-workspace"
                }
            })),
            &deps,
            &invocation,
        )
        .await
        .expect("send");

        assert_eq!(result["success"], json!(true));
        let sent = notify.last.lock().unwrap().clone().expect("notification");
        assert!(sent.title.len() <= MAX_TITLE_LENGTH);
        assert!(sent.body.len() <= MAX_BODY_LENGTH);
        assert_eq!(sent.priority, "high");
        assert_eq!(sent.data.as_ref().unwrap()["custom"], json!("value"));
        assert_eq!(sent.data.as_ref().unwrap()["sessionId"], json!("sess_1"));
        assert_eq!(sent.data.as_ref().unwrap()["workspaceId"], json!("ws_1"));
        assert_eq!(
            sent.data.as_ref().unwrap()["invocationId"],
            json!(invocation.id.as_str())
        );
    }

    #[tokio::test]
    async fn send_rejects_scope_overrides_from_causal_invocations() {
        let ctx = make_test_context();
        let notify = Arc::new(RecordingNotify::default());
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
            notify_delegate: notify.clone(),
        };
        let invocation = test_invocation();
        let error = notifications_send_value(
            Some(&json!({
                "title": "Scoped",
                "body": "Scope must come from causal context.",
                "priority": "normal",
                "sessionId": "other-session"
            })),
            &deps,
            &invocation,
        )
        .await
        .expect_err("causal context session must not be overridden");

        assert!(
            error.to_string().contains("causal context"),
            "unexpected error: {error}"
        );
        assert!(
            notify.last.lock().unwrap().is_none(),
            "invalid notification must not reach delivery delegate"
        );
    }

    #[tokio::test]
    async fn send_rejects_secret_like_values_before_truncation() {
        let ctx = make_test_context();
        let notify = Arc::new(RecordingNotify::default());
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
            notify_delegate: notify.clone(),
        };
        let invocation = test_invocation();
        let error = notifications_send_value(
            Some(&json!({
                "title": format!("{} token=hidden", "safe prefix ".repeat(8)),
                "body": "body",
                "priority": "normal"
            })),
            &deps,
            &invocation,
        )
        .await
        .expect_err("raw secret-like title should fail before truncation");

        assert!(
            error.to_string().contains("secret-like value"),
            "unexpected error: {error}"
        );
        assert!(
            notify.last.lock().unwrap().is_none(),
            "invalid notification must not reach delivery delegate"
        );
    }
}

async fn notifications_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let limit = opt_u64(params, "limit", 50).min(100);
    let session_id = opt_string(params, "sessionId");
    let result = NotificationInboxService::list(deps, limit, session_id.as_deref()).await?;
    to_json_value(&result)
}

async fn notifications_mark_read_value(
    params: Option<&Value>,
    deps: &Deps,
    invocation: &Invocation,
) -> Result<Value, CapabilityError> {
    let event_id = require_string_param(params, "eventId")?;
    let result = NotificationInboxService::mark_read(deps, invocation, &event_id).await?;
    to_json_value(&result)
}

async fn notifications_mark_all_read_value(
    params: Option<&Value>,
    deps: &Deps,
    invocation: &Invocation,
) -> Result<Value, CapabilityError> {
    let session_id = opt_string(params, "sessionId");
    let result =
        NotificationInboxService::mark_all_read(deps, invocation, session_id.as_deref()).await?;
    to_json_value(&result)
}

fn reject_raw_secret_text(text: &str, field: &str) -> Result<(), CapabilityError> {
    let trimmed = text.trim();
    if trimmed.starts_with("secret_ref:") || trimmed.starts_with("vault:") {
        return Ok(());
    }
    let lower = trimmed.to_ascii_lowercase();
    if trimmed.starts_with("sk-")
        || lower.contains("secret=")
        || lower.contains("token=")
        || lower.contains("password=")
        || lower.contains("api_key=")
        || lower.contains("apikey=")
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{field} contains secret-like value; store only secret_ref or vault handles"
            ),
        });
    }
    Ok(())
}

fn reject_raw_secret_value(value: &Value, field: &str) -> Result<(), CapabilityError> {
    match value {
        Value::String(text) => reject_raw_secret_text(text, field),
        Value::Array(items) => {
            for (idx, item) in items.iter().enumerate() {
                reject_raw_secret_value(item, &format!("{field}[{idx}]"))?;
            }
            Ok(())
        }
        Value::Object(map) => {
            for (key, item) in map {
                reject_raw_secret_value(item, &format!("{field}.{key}"))?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}
