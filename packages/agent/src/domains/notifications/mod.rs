//! notifications domain worker.
//!
//! This module owns canonical function execution for the notifications namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::capability_support::implementations::errors::CapabilityExecutionError;
use crate::domains::capability_support::implementations::traits::Notification;
use crate::domains::notifications::inbox::NotificationInboxService;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
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
    let mut data_object = params
        .and_then(|value| value.get("data"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    data_object
        .entry("invocationId")
        .or_insert_with(|| Value::String(invocation.id.as_str().to_owned()));
    if let Some(session_id) = invocation.causal_context.session_id.as_deref() {
        data_object
            .entry("sessionId")
            .or_insert_with(|| Value::String(session_id.to_owned()));
    }
    if let Some(workspace_id) = invocation.causal_context.workspace_id.as_deref() {
        data_object
            .entry("workspaceId")
            .or_insert_with(|| Value::String(workspace_id.to_owned()));
    }
    let data = if data_object.is_empty() {
        None
    } else {
        Some(Value::Object(data_object))
    };
    let sheet_content = params
        .and_then(|value| value.get("sheetContent"))
        .cloned()
        .or_else(|| params.and_then(|value| value.get("sheet_content")).cloned());
    let notification = Notification {
        title: title.clone(),
        body: body.clone(),
        priority: priority.clone(),
        badge,
        data: data.clone(),
        sheet_content: sheet_content.clone(),
    };
    let delivery = deps
        .notify_delegate
        .send_notification(&notification)
        .await
        .map_err(notify_error)?;
    Ok(json!({
        "title": title,
        "body": body,
        "priority": priority,
        "success": delivery.success,
        "message": delivery.message,
        "successCount": delivery.success_count,
        "totalCount": delivery.total_count,
        "warning": delivery.warning,
        "data": data,
        "sheetContent": sheet_content,
    }))
}

fn notify_error(error: CapabilityExecutionError) -> CapabilityError {
    match error {
        CapabilityExecutionError::Validation { message } => {
            CapabilityError::InvalidParams { message }
        }
        CapabilityExecutionError::NotFound { message } => CapabilityError::NotFound {
            code: "NOTIFICATION_TARGET_NOT_FOUND".to_owned(),
            message,
        },
        other => CapabilityError::Custom {
            code: "NOTIFICATION_SEND_FAILED".to_owned(),
            message: other.to_string(),
            details: None,
        },
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
            event_store: ctx.event_store.clone(),
            notify_delegate: notify.clone(),
        };
        let invocation = test_invocation();
        let result = notifications_send_value(
            Some(&json!({
                "title": "t".repeat(80),
                "body": "b".repeat(260),
                "priority": "high",
                "data": {"custom": "value"}
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
}

async fn notifications_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let limit = opt_u64(params, "limit", 50).min(100);
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications::list", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::list(&conn, limit)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_read_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let event_id = require_string_param(params, "eventId")?;
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_read", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_read(&conn, &event_id)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_all_read_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = opt_string(params, "sessionId");
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_all_read", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_all_read(&conn, session_id.as_deref())
    })
    .await?;
    to_json_value(&result)
}
