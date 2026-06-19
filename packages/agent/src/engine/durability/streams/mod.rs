//! Engine stream primitive.
//!
//! Streams are resumable cursor views over engine-visible change records. They
//! are not a transport: engine clients, agent capabilities, and external workers can
//! all poll the same stream cursor model. Package-owned lifecycle topics such
//! as `catalog.discovery` and `approval.lifecycle` publish durable evidence
//! transitions through this substrate without becoming typed session events.
//!
//! INVARIANT: live subscriptions that omit an explicit cursor start at the
//! topic tail. Historical replay is explicit (`afterCursor` / `cursor`) and
//! belongs to callers that are intentionally catching up.
//!
//! INVARIANT: stream polling applies engine visibility before pagination. A
//! session subscriber must never wait behind older rows owned by other
//! sessions.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::kernel::errors::EngineError;
use crate::engine::kernel::ids::{InvocationId, TraceId};
use crate::engine::kernel::types::VisibilityScope;

mod memory;
mod sqlite_store;

pub use memory::InMemoryEngineStreamStore;
pub use sqlite_store::SqliteEngineStreamStore;

/// Monotonic stream cursor.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct StreamCursor(pub u64);

impl StreamCursor {
    /// Return the next cursor value.
    #[must_use]
    pub fn next(self) -> Self {
        Self(self.0 + 1)
    }
}

/// Durable stream event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineStreamEvent {
    /// Monotonic cursor assigned by the store.
    pub cursor: StreamCursor,
    /// Topic name, e.g. `catalog.changes` or `events.session`.
    pub topic: String,
    /// JSON payload.
    pub payload: Value,
    /// Visibility for stream delivery.
    pub visibility: VisibilityScope,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
    /// Producer worker/capability label.
    pub producer: String,
    /// Trace propagated from the producer.
    pub trace_id: Option<TraceId>,
    /// Parent invocation that caused the event, if known.
    pub parent_invocation_id: Option<InvocationId>,
    /// Event timestamp.
    pub created_at: DateTime<Utc>,
}

/// Stream subscription record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineStreamSubscription {
    /// Stable subscription id.
    pub subscription_id: String,
    /// Topic being watched.
    pub topic: String,
    /// Cursor after which the next poll starts by default.
    pub cursor: StreamCursor,
    /// Visibility of the subscription itself.
    pub visibility: VisibilityScope,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
    /// Whether the subscription is active.
    pub active: bool,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
}

/// Actor scope used by stream filtering.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamActorScope {
    /// Session visible to the actor.
    pub session_id: Option<String>,
    /// Workspace visible to the actor.
    pub workspace_id: Option<String>,
    /// Whether the actor may see all streams.
    pub admin: bool,
}

impl StreamActorScope {
    /// Build a non-admin actor scope.
    #[must_use]
    pub fn scoped(session_id: Option<String>, workspace_id: Option<String>) -> Self {
        Self {
            session_id,
            workspace_id,
            admin: false,
        }
    }

    /// Build an admin actor scope.
    #[must_use]
    pub fn admin() -> Self {
        Self {
            session_id: None,
            workspace_id: None,
            admin: true,
        }
    }
}

/// Page of stream events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineStreamPage {
    /// Events in ascending cursor order.
    pub events: Vec<EngineStreamEvent>,
    /// Cursor to pass to the next poll.
    pub next_cursor: StreamCursor,
    /// Whether more matching events remain after this page.
    pub has_more: bool,
}

/// Request for publishing a stream event.
#[derive(Clone, Debug, PartialEq)]
pub struct PublishStreamEvent {
    /// Topic name.
    pub topic: String,
    /// Payload.
    pub payload: Value,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
    /// Producer label.
    pub producer: String,
    /// Trace id.
    pub trace_id: Option<TraceId>,
    /// Parent invocation id.
    pub parent_invocation_id: Option<InvocationId>,
}

fn row_to_stream_event(
    conn: &rusqlite::Connection,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<EngineStreamEvent> {
    let payload_json: String = row.get(2)?;
    let payload = crate::shared::storage::resolve_stored_json_value(conn, &payload_json)
        .map_err(storage_to_sql_err)?;
    let trace_id: Option<String> = row.get(7)?;
    let parent_invocation_id: Option<String> = row.get(8)?;
    Ok(EngineStreamEvent {
        cursor: StreamCursor(row.get::<_, i64>(0)? as u64),
        topic: row.get(1)?,
        payload,
        visibility: visibility_from_str(&row.get::<_, String>(3)?),
        session_id: row.get(4)?,
        workspace_id: row.get(5)?,
        producer: row.get(6)?,
        trace_id: trace_id.and_then(|id| TraceId::new(id).ok()),
        parent_invocation_id: parent_invocation_id.and_then(|id| InvocationId::new(id).ok()),
        created_at: parse_time(row.get::<_, String>(9)?),
    })
}

fn stream_scope_visible(
    visibility: &VisibilityScope,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor: &StreamActorScope,
) -> bool {
    if actor.admin {
        return true;
    }
    match visibility {
        VisibilityScope::System | VisibilityScope::Agent | VisibilityScope::Client => true,
        VisibilityScope::Session => {
            matches!((actor.session_id.as_deref(), session_id), (Some(a), Some(s)) if a == s)
        }
        VisibilityScope::Workspace => {
            matches!((actor.workspace_id.as_deref(), workspace_id), (Some(a), Some(w)) if a == w)
        }
        VisibilityScope::Internal | VisibilityScope::Worker | VisibilityScope::Admin => false,
    }
}

fn visibility_from_str(value: &str) -> VisibilityScope {
    match value {
        "session" => VisibilityScope::Session,
        "workspace" => VisibilityScope::Workspace,
        "system" => VisibilityScope::System,
        "client" => VisibilityScope::Client,
        "worker" => VisibilityScope::Worker,
        "agent" => VisibilityScope::Agent,
        "admin" => VisibilityScope::Admin,
        _ => VisibilityScope::Internal,
    }
}

fn parse_time(value: String) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(&value)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now())
}

fn storage_to_sql_err(error: anyhow::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error.to_string())))
}

fn sqlite_err(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}
