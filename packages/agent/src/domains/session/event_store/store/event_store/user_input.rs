//! Durable Ask User state derived from canonical session events.
//!
//! A successful `request_user_input` tool completion opens a request. The
//! corresponding structured `message.user` row resolves it. No parallel pause
//! table or in-memory continuation exists, so reconnect and process restart use
//! the same indexed event truth as the provider transcript.

use rusqlite::{OptionalExtension, params};

use super::EventStore;
use crate::domains::session::event_store::errors::Result;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum UserInputRequestState {
    Missing,
    Pending,
    Answered,
}

impl EventStore {
    pub(crate) fn user_input_request_state(
        &self,
        session_id: &str,
        invocation_id: &str,
    ) -> Result<UserInputRequestState> {
        let conn = self.conn()?;
        let answered = conn
            .query_row(
                "SELECT 1 FROM events
             WHERE session_id=?1 AND type='message.user'
               AND tool_name='request_user_input_answer' AND invocation_id=?2
             LIMIT 1",
                params![session_id, invocation_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if answered {
            return Ok(UserInputRequestState::Answered);
        }

        let completion_payload = conn
            .query_row(
                "SELECT payload FROM events
             WHERE session_id=?1 AND type='tool.invocation.completed'
               AND tool_name='request_user_input' AND invocation_id=?2
             ORDER BY sequence DESC LIMIT 1",
                params![session_id, invocation_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(payload) = completion_payload else {
            return Ok(UserInputRequestState::Missing);
        };
        let payload = serde_json::from_str::<serde_json::Value>(&payload).unwrap_or_default();
        Ok(
            if payload.get("isError").and_then(serde_json::Value::as_bool) == Some(false) {
                UserInputRequestState::Pending
            } else {
                UserInputRequestState::Missing
            },
        )
    }

    /// Return the schema-validated arguments persisted for a request.
    /// The caller can validate a client answer against the exact choices the
    /// model presented instead of trusting client-supplied question metadata.
    pub(crate) fn user_input_request_arguments(
        &self,
        session_id: &str,
        invocation_id: &str,
    ) -> Result<Option<serde_json::Value>> {
        let conn = self.conn()?;
        let payload = conn
            .query_row(
                "SELECT payload FROM events
             WHERE session_id=?1 AND type='tool.invocation.started'
               AND tool_name='request_user_input' AND invocation_id=?2
             ORDER BY sequence DESC LIMIT 1",
                params![session_id, invocation_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        Ok(payload
            .and_then(|payload| serde_json::from_str::<serde_json::Value>(&payload).ok())
            .and_then(|payload| payload.get("arguments").cloned()))
    }
}
