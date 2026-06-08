//! Engine stream primitive.
//!
//! Streams are resumable cursor views over engine-visible change records. They
//! are not a transport: engine clients, agent capabilities, and external workers can
//! all poll the same stream cursor model.
//!
//! INVARIANT: live subscriptions that omit an explicit cursor start at the
//! topic tail. Historical replay is explicit (`afterCursor` / `cursor`) and
//! belongs to callers that are intentionally catching up.
//!
//! INVARIANT: stream polling applies engine visibility before pagination. A
//! session subscriber must never wait behind older rows owned by other
//! sessions.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{InvocationId, TraceId};
use crate::engine::kernel::types::VisibilityScope;

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

/// In-memory stream store.
#[derive(Default)]
pub struct InMemoryEngineStreamStore {
    next_cursor: u64,
    events: Vec<EngineStreamEvent>,
    subscriptions: BTreeMap<String, EngineStreamSubscription>,
}

impl InMemoryEngineStreamStore {
    /// Create an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Publish one event and return its cursor.
    pub fn publish(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        if event.topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        self.next_cursor += 1;
        let cursor = StreamCursor(self.next_cursor);
        self.events.push(EngineStreamEvent {
            cursor,
            topic: event.topic,
            payload: event.payload,
            visibility: event.visibility,
            session_id: event.session_id,
            workspace_id: event.workspace_id,
            producer: event.producer,
            trace_id: event.trace_id,
            parent_invocation_id: event.parent_invocation_id,
            created_at: Utc::now(),
        });
        Ok(cursor)
    }

    /// Create or update a subscription.
    pub fn subscribe(
        &mut self,
        subscription_id: String,
        topic: String,
        cursor: StreamCursor,
        visibility: VisibilityScope,
        session_id: Option<String>,
        workspace_id: Option<String>,
    ) -> Result<EngineStreamSubscription> {
        if subscription_id.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream subscription id must not be empty".to_owned(),
            ));
        }
        if topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        let subscription = EngineStreamSubscription {
            subscription_id: subscription_id.clone(),
            topic,
            cursor,
            visibility,
            session_id,
            workspace_id,
            active: true,
            created_at: Utc::now(),
        };
        self.subscriptions
            .insert(subscription_id, subscription.clone());
        Ok(subscription)
    }

    /// Return the latest cursor assigned for a topic.
    #[must_use]
    pub fn latest_cursor(&self, topic: &str) -> StreamCursor {
        self.events
            .iter()
            .rev()
            .find(|event| event.topic == topic)
            .map(|event| event.cursor)
            .unwrap_or_default()
    }

    /// Mark a subscription inactive.
    pub fn unsubscribe(&mut self, subscription_id: &str) -> Result<bool> {
        let Some(subscription) = self.subscriptions.get_mut(subscription_id) else {
            return Ok(false);
        };
        let was_active = subscription.active;
        subscription.active = false;
        Ok(was_active)
    }

    /// Advance a subscription cursor after client delivery.
    pub fn acknowledge(
        &mut self,
        subscription_id: &str,
        cursor: StreamCursor,
    ) -> Result<EngineStreamSubscription> {
        let Some(subscription) = self.subscriptions.get_mut(subscription_id) else {
            return Err(EngineError::NotFound {
                kind: "stream_subscription",
                id: subscription_id.to_owned(),
            });
        };
        if !subscription.active {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is inactive"
            )));
        }
        if subscription.cursor < cursor {
            subscription.cursor = cursor;
        }
        Ok(subscription.clone())
    }

    /// Poll a subscription after a cursor.
    pub fn poll(
        &self,
        subscription_id: &str,
        after: Option<StreamCursor>,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "stream poll limit must be greater than zero".to_owned(),
            ));
        }
        let subscription =
            self.subscriptions
                .get(subscription_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "stream_subscription",
                    id: subscription_id.to_owned(),
                })?;
        if !subscription.active {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is inactive"
            )));
        }
        if !stream_scope_visible(
            &subscription.visibility,
            subscription.session_id.as_deref(),
            subscription.workspace_id.as_deref(),
            actor,
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is not visible"
            )));
        }
        let after = after.unwrap_or(subscription.cursor);
        let limit = limit.min(500);
        let mut visible = self
            .events
            .iter()
            .filter(|event| event.topic == subscription.topic)
            .filter(|event| event.cursor > after)
            .filter(|event| {
                stream_scope_visible(
                    &event.visibility,
                    event.session_id.as_deref(),
                    event.workspace_id.as_deref(),
                    actor,
                )
            })
            .cloned()
            .collect::<Vec<_>>();
        visible.sort_by_key(|event| event.cursor);
        let has_more = visible.len() > limit;
        let mut next_cursor = after;
        let events = visible
            .into_iter()
            .take(limit)
            .map(|event| {
                next_cursor = event.cursor;
                event
            })
            .collect::<Vec<_>>();
        Ok(EngineStreamPage {
            events,
            next_cursor,
            has_more,
        })
    }

    /// List stream records carrying one trace id.
    pub fn list_by_trace(&self, trace_id: &str, limit: usize) -> Result<Vec<EngineStreamEvent>> {
        let mut events = self
            .events
            .iter()
            .filter(|event| {
                event
                    .trace_id
                    .as_ref()
                    .map(|id| id.as_str() == trace_id)
                    .unwrap_or(false)
            })
            .cloned()
            .collect::<Vec<_>>();
        events.sort_by_key(|event| event.cursor);
        events.truncate(limit.min(500));
        Ok(events)
    }
}

/// SQLite-backed stream store.
pub struct SqliteEngineStreamStore {
    conn: Connection,
}

impl SqliteEngineStreamStore {
    /// Open a stream store in the engine ledger database.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("stream.open", err.to_string()))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_stream_events (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  visibility TEXT NOT NULL,
  session_id TEXT,
  workspace_id TEXT,
  producer TEXT NOT NULL,
  trace_id TEXT,
  parent_invocation_id TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS engine_stream_subscriptions (
  subscription_id TEXT PRIMARY KEY,
  topic TEXT NOT NULL,
  cursor INTEGER NOT NULL,
  visibility TEXT NOT NULL,
  session_id TEXT,
  workspace_id TEXT,
  active INTEGER NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_engine_stream_events_trace
  ON engine_stream_events(trace_id, cursor);
"#,
            )
            .map_err(|err| sqlite_err("stream.init", err.to_string()))
    }

    /// Borrow the underlying connection for focused tests.
    #[cfg(test)]
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    /// Publish one event and return its cursor.
    pub fn publish(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        if event.topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        let owner_id = format!("stream_event_{}", uuid::Uuid::now_v7());
        let payload = crate::shared::storage::store_json_value(
            &self.conn,
            &event.payload,
            &crate::shared::storage::StorePayloadOptions::new(
                "engine_stream_event",
                owner_id,
                "payload",
                "runtime",
            )
            .with_scope(
                event.trace_id.as_ref().map(ToString::to_string),
                event.session_id.clone(),
                event.workspace_id.clone(),
            ),
        )
        .map_err(|err| sqlite_err("stream.event.payload", err.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO engine_stream_events
                 (topic, payload_json, visibility, session_id, workspace_id, producer, trace_id, parent_invocation_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    event.topic,
                    payload,
                    event.visibility.as_str(),
                    event.session_id,
                    event.workspace_id,
                    event.producer,
                    event.trace_id.map(|id| id.to_string()),
                    event.parent_invocation_id.map(|id| id.to_string()),
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("stream.publish", err.to_string()))?;
        Ok(StreamCursor(self.conn.last_insert_rowid() as u64))
    }

    /// Create or update a subscription.
    pub fn subscribe(
        &mut self,
        subscription_id: String,
        topic: String,
        cursor: StreamCursor,
        visibility: VisibilityScope,
        session_id: Option<String>,
        workspace_id: Option<String>,
    ) -> Result<EngineStreamSubscription> {
        if subscription_id.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream subscription id must not be empty".to_owned(),
            ));
        }
        if topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        let created_at = Utc::now();
        self.conn
            .execute(
                "INSERT INTO engine_stream_subscriptions
                 (subscription_id, topic, cursor, visibility, session_id, workspace_id, active, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7)
                 ON CONFLICT(subscription_id) DO UPDATE SET
                   topic = excluded.topic,
                   cursor = excluded.cursor,
                   visibility = excluded.visibility,
                   session_id = excluded.session_id,
                   workspace_id = excluded.workspace_id,
                   active = 1",
                params![
                    subscription_id,
                    topic,
                    cursor.0 as i64,
                    visibility.as_str(),
                    session_id,
                    workspace_id,
                    created_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("stream.subscribe", err.to_string()))?;
        Ok(EngineStreamSubscription {
            subscription_id,
            topic,
            cursor,
            visibility,
            session_id,
            workspace_id,
            active: true,
            created_at,
        })
    }

    /// Return the latest cursor assigned for a topic.
    pub fn latest_cursor(&self, topic: &str) -> Result<StreamCursor> {
        let cursor = self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(cursor), 0)
                 FROM engine_stream_events
                 WHERE topic = ?1",
                params![topic],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|err| sqlite_err("stream.latest_cursor", err.to_string()))?;
        Ok(StreamCursor(cursor as u64))
    }

    /// Mark a subscription inactive.
    pub fn unsubscribe(&mut self, subscription_id: &str) -> Result<bool> {
        let changed = self
            .conn
            .execute(
                "UPDATE engine_stream_subscriptions SET active = 0
                 WHERE subscription_id = ?1 AND active = 1",
                params![subscription_id],
            )
            .map_err(|err| sqlite_err("stream.unsubscribe", err.to_string()))?;
        Ok(changed > 0)
    }

    /// Advance a subscription cursor after client delivery.
    pub fn acknowledge(
        &mut self,
        subscription_id: &str,
        cursor: StreamCursor,
    ) -> Result<EngineStreamSubscription> {
        let subscription = self.subscription(subscription_id)?;
        if !subscription.active {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is inactive"
            )));
        }
        self.conn
            .execute(
                "UPDATE engine_stream_subscriptions
                 SET cursor = CASE WHEN cursor < ?2 THEN ?2 ELSE cursor END
                 WHERE subscription_id = ?1 AND active = 1",
                params![subscription_id, cursor.0 as i64],
            )
            .map_err(|err| sqlite_err("stream.acknowledge", err.to_string()))?;
        self.subscription(subscription_id)
    }

    /// Poll a subscription after a cursor.
    pub fn poll(
        &self,
        subscription_id: &str,
        after: Option<StreamCursor>,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "stream poll limit must be greater than zero".to_owned(),
            ));
        }
        let subscription = self.subscription(subscription_id)?;
        if !subscription.active {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is inactive"
            )));
        }
        if !stream_scope_visible(
            &subscription.visibility,
            subscription.session_id.as_deref(),
            subscription.workspace_id.as_deref(),
            actor,
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is not visible"
            )));
        }
        let after = after.unwrap_or(subscription.cursor);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT cursor, topic, payload_json, visibility, session_id, workspace_id,
                        producer, trace_id, parent_invocation_id, created_at
                 FROM engine_stream_events
                 WHERE topic = ?1
                   AND cursor > ?2
                   AND (
                     ?5 = 1
                     OR visibility IN ('system', 'agent', 'client')
                     OR (visibility = 'session' AND session_id = ?3)
                     OR (visibility = 'workspace' AND workspace_id = ?4)
                   )
                 ORDER BY cursor ASC
                 LIMIT ?6",
            )
            .map_err(|err| sqlite_err("stream.poll.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(
                params![
                    subscription.topic,
                    after.0 as i64,
                    actor.session_id.as_deref(),
                    actor.workspace_id.as_deref(),
                    if actor.admin { 1_i64 } else { 0_i64 },
                    limit.min(500) as i64 + 1
                ],
                |row| row_to_stream_event(&self.conn, row),
            )
            .map_err(|err| sqlite_err("stream.poll.query", err.to_string()))?;
        let limit = limit.min(500);
        let mut events = Vec::new();
        let mut next_cursor = after;
        let mut has_more = false;
        for (index, row) in rows.enumerate() {
            let event = row.map_err(|err| sqlite_err("stream.poll.row", err.to_string()))?;
            if index >= limit {
                has_more = true;
                break;
            }
            next_cursor = event.cursor;
            if stream_scope_visible(
                &event.visibility,
                event.session_id.as_deref(),
                event.workspace_id.as_deref(),
                actor,
            ) {
                events.push(event);
            }
        }
        Ok(EngineStreamPage {
            events,
            next_cursor,
            has_more,
        })
    }

    /// List stream records carrying one trace id.
    pub fn list_by_trace(&self, trace_id: &str, limit: usize) -> Result<Vec<EngineStreamEvent>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT cursor, topic, payload_json, visibility, session_id, workspace_id,
                        producer, trace_id, parent_invocation_id, created_at
                 FROM engine_stream_events
                 WHERE trace_id = ?1
                 ORDER BY cursor ASC
                 LIMIT ?2",
            )
            .map_err(|err| sqlite_err("stream.list_by_trace.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![trace_id, limit.min(500) as i64], |row| {
                row_to_stream_event(&self.conn, row)
            })
            .map_err(|err| sqlite_err("stream.list_by_trace.query", err.to_string()))?;
        let mut events = Vec::new();
        for row in rows {
            events
                .push(row.map_err(|err| sqlite_err("stream.list_by_trace.row", err.to_string()))?);
        }
        Ok(events)
    }

    fn subscription(&self, subscription_id: &str) -> Result<EngineStreamSubscription> {
        self.conn
            .query_row(
                "SELECT subscription_id, topic, cursor, visibility, session_id, workspace_id, active, created_at
                 FROM engine_stream_subscriptions WHERE subscription_id = ?1",
                params![subscription_id],
                |row| {
                    Ok(EngineStreamSubscription {
                        subscription_id: row.get(0)?,
                        topic: row.get(1)?,
                        cursor: StreamCursor(row.get::<_, i64>(2)? as u64),
                        visibility: visibility_from_str(&row.get::<_, String>(3)?),
                        session_id: row.get(4)?,
                        workspace_id: row.get(5)?,
                        active: row.get::<_, i64>(6)? != 0,
                        created_at: parse_time(row.get::<_, String>(7)?),
                    })
                },
            )
            .optional()
            .map_err(|err| sqlite_err("stream.subscription", err.to_string()))?
            .ok_or_else(|| EngineError::NotFound {
                kind: "stream_subscription",
                id: subscription_id.to_owned(),
            })
    }
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
