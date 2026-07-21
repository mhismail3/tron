//! Engine stream primitive.
//!
//! Streams are resumable cursor views over engine-visible change records. They
//! are not a transport: authenticated engine clients and retained internal
//! services poll the same stream cursor model. Package-owned lifecycle topics
//! publish durable evidence transitions through this substrate without
//! becoming typed session events. Callers own their cursor; authenticated
//! transports keep live-subscription lifecycle in connection state.
//!
//! INVARIANT: historical replay is explicit (`afterCursor` / `cursor`) and
//! belongs to callers that are intentionally catching up.
//!
//! INVARIANT: stream delivery has exactly two scopes: system broadcasts and a
//! named session. Internal consumers may intentionally read every session.
//! Workspace remains event metadata and an explicit protocol filter; it is not
//! a delivery or permission scope.
//!
//! INVARIANT: stream polling applies delivery scope before pagination. A
//! session subscriber must never wait behind older rows owned by other
//! sessions. Unknown persisted scope values fail closed.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::kernel::errors::EngineError;
use crate::engine::kernel::ids::{InvocationId, TraceId};
use crate::engine::kernel::types::StreamVisibility;

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
    pub visibility: StreamVisibility,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
    /// Producer worker/function label.
    pub producer: String,
    /// Trace propagated from the producer.
    pub trace_id: Option<TraceId>,
    /// Parent invocation that caused the event, if known.
    pub parent_invocation_id: Option<InvocationId>,
    /// Event timestamp.
    pub created_at: DateTime<Utc>,
}

/// Actor scope used by stream filtering.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamActorScope {
    /// Session visible to the actor.
    pub session_id: Option<String>,
    /// Whether the internal caller may read every session.
    pub all_sessions: bool,
}

impl StreamActorScope {
    /// Build a session-scoped client view.
    #[must_use]
    pub fn scoped(session_id: Option<String>) -> Self {
        Self {
            session_id,
            all_sessions: false,
        }
    }

    /// Build an internal view across every session.
    #[must_use]
    pub fn all() -> Self {
        Self {
            session_id: None,
            all_sessions: true,
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
    pub visibility: StreamVisibility,
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
        visibility: visibility_from_str(&row.get::<_, String>(3)?)?,
        session_id: row.get(4)?,
        workspace_id: row.get(5)?,
        producer: row.get(6)?,
        trace_id: trace_id.and_then(|id| TraceId::new(id).ok()),
        parent_invocation_id: parent_invocation_id.and_then(|id| InvocationId::new(id).ok()),
        created_at: parse_time(row.get::<_, String>(9)?),
    })
}

fn stream_scope_visible(
    visibility: &StreamVisibility,
    session_id: Option<&str>,
    actor: &StreamActorScope,
) -> bool {
    if actor.all_sessions {
        return true;
    }
    match visibility {
        StreamVisibility::System => true,
        StreamVisibility::Session => {
            matches!((actor.session_id.as_deref(), session_id), (Some(a), Some(s)) if a == s)
        }
    }
}

fn visibility_from_str(value: &str) -> rusqlite::Result<StreamVisibility> {
    match value {
        "session" => Ok(StreamVisibility::Session),
        "system" => Ok(StreamVisibility::System),
        invalid => Err(rusqlite::Error::FromSqlConversionFailure(
            3,
            rusqlite::types::Type::Text,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("unknown engine stream visibility '{invalid}'"),
            )),
        )),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persisted_visibility_decoder_accepts_only_runtime_scopes() {
        assert_eq!(
            visibility_from_str("session").expect("session visibility"),
            StreamVisibility::Session
        );
        assert_eq!(
            visibility_from_str("system").expect("system visibility"),
            StreamVisibility::System
        );
        assert!(visibility_from_str("workspace").is_err());
        assert!(visibility_from_str("internal").is_err());
    }
}
