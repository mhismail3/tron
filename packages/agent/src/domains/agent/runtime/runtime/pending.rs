use super::HashSet;
use serde_json::Value;
use std::fmt::Write;

/// Parse a pending-results event row's payload into an `(id, value)` pair.
///
/// Used by the `get_pending_*` helpers that surface unconsumed notification
/// events into the next prompt's context. A corrupt payload means the event
/// cannot be displayed to the model, so we drop it — but we log first so the
/// stale/corrupt payload is findable in operator logs.
fn parse_pending_event_payload(
    event: crate::domains::session::event_store::sqlite::row_types::EventRow,
) -> Option<(String, Value)> {
    match serde_json::from_str::<Value>(&event.payload) {
        Ok(payload) => Some((event.id, payload)),
        Err(e) => {
            tracing::warn!(
                event_id = %event.id,
                event_type = %event.event_type,
                error = %e,
                "pending-results: corrupt event payload JSON; dropping from prompt context"
            );
            None
        }
    }
}

/// Query unconsumed subagent results from the event store.
///
/// Returns `(event_id, payload_json)` pairs for `notification.subagent_result`
/// events that have no matching `subagent.results_consumed` event referencing
/// their ID. Works identically for live sessions and session resume.
pub fn get_pending_subagent_results(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
) -> Vec<(String, Value)> {
    let notifications = event_store
        .get_events_by_type(session_id, &["notification.subagent_result"], None)
        .unwrap_or_default();

    if notifications.is_empty() {
        return vec![];
    }

    let consumed_events = event_store
        .get_events_by_type(session_id, &["subagent.results_consumed"], None)
        .unwrap_or_default();

    let mut consumed_ids: HashSet<String> = HashSet::new();
    for event in &consumed_events {
        if let Ok(payload) = serde_json::from_str::<Value>(&event.payload)
            && let Some(ids) = payload.get("consumedEventIds").and_then(|v| v.as_array())
        {
            for id in ids {
                if let Some(s) = id.as_str() {
                    let _ = consumed_ids.insert(s.to_owned());
                }
            }
        }
    }

    notifications
        .into_iter()
        .filter(|event| !consumed_ids.contains(&event.id))
        .filter_map(|event| parse_pending_event_payload(event))
        .collect()
}

/// Format pending subagent results into markdown context string.
pub fn format_subagent_results(results: &[(String, Value)]) -> Option<String> {
    if results.is_empty() {
        return None;
    }

    let mut ctx = String::from("# Completed Sub-Agent Results\n\n");
    ctx.push_str(
        "The following sub-agent(s) have completed since your last turn. \
         Review their results and incorporate them into your response.\n\n",
    );

    for (_event_id, payload) in results {
        let success = payload
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let icon = if success { "+" } else { "x" };
        let subagent_id = payload
            .get("subagentSessionId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let task = payload
            .get("task")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let total_turns = payload
            .get("totalTurns")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let duration = payload.get("duration").and_then(Value::as_i64).unwrap_or(0);

        let _ = writeln!(ctx, "## [{icon}] Sub-Agent: `{subagent_id}`\n");
        let _ = writeln!(ctx, "**Task**: {task}");
        let _ = writeln!(
            ctx,
            "**Status**: {}",
            if success { "Completed" } else { "Failed" }
        );
        let _ = writeln!(ctx, "**Turns**: {total_turns}");
        #[allow(clippy::cast_precision_loss)]
        let duration_secs = duration as f64 / 1000.0;
        let _ = writeln!(ctx, "**Duration**: {duration_secs:.1}s");

        if let Some(output) = payload.get("output").and_then(Value::as_str)
            && !output.is_empty()
        {
            let truncated = if output.len() > 2000 {
                format!("{}\n\n... [Output truncated]", &output[..2000])
            } else {
                output.to_string()
            };
            let _ = write!(ctx, "\n**Output**:\n```\n{truncated}\n```\n");
        }

        if let Some(error) = payload.get("error").and_then(Value::as_str) {
            let _ = writeln!(ctx, "\n**Error**:\n{error}\n");
        }

        ctx.push_str("\n---\n\n");
    }

    Some(ctx)
}

/// Query pending (unconsumed) background process results for a session.
pub fn get_pending_process_results(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
) -> Vec<(String, Value)> {
    let notifications = event_store
        .get_events_by_type(session_id, &["notification.process_result"], None)
        .unwrap_or_default();

    if notifications.is_empty() {
        return vec![];
    }

    let consumed_events = event_store
        .get_events_by_type(session_id, &["process.results_consumed"], None)
        .unwrap_or_default();

    let mut consumed_ids: HashSet<String> = HashSet::new();
    for event in &consumed_events {
        if let Ok(payload) = serde_json::from_str::<Value>(&event.payload)
            && let Some(ids) = payload.get("consumedEventIds").and_then(|v| v.as_array())
        {
            for id in ids {
                if let Some(s) = id.as_str() {
                    let _ = consumed_ids.insert(s.to_owned());
                }
            }
        }
    }

    notifications
        .into_iter()
        .filter(|event| !consumed_ids.contains(&event.id))
        .filter_map(|event| parse_pending_event_payload(event))
        .collect()
}

/// Format pending process results into markdown context string.
pub fn format_process_results(results: &[(String, Value)]) -> Option<String> {
    if results.is_empty() {
        return None;
    }

    let mut ctx = String::from("# Completed Background Processes\n\n");
    ctx.push_str("The following background process(es) have completed since your last turn.\n\n");

    for (_event_id, payload) in results {
        let success = payload
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let icon = if success { "+" } else { "x" };
        let process_id = payload
            .get("processId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let label = payload
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let exit_code = payload.get("exitCode").and_then(Value::as_i64);
        let duration = payload.get("duration").and_then(Value::as_i64).unwrap_or(0);

        let _ = writeln!(ctx, "## [{icon}] Process: `{label}` ({process_id})\n");
        let status_str = if success {
            match exit_code {
                Some(code) => format!("Completed (exit code {code})"),
                None => "Completed".into(),
            }
        } else {
            match exit_code {
                Some(code) => format!("Failed (exit code {code})"),
                None => "Failed".into(),
            }
        };
        let _ = writeln!(ctx, "**Status**: {status_str}");
        #[allow(clippy::cast_precision_loss)]
        let duration_secs = duration as f64 / 1000.0;
        let _ = writeln!(ctx, "**Duration**: {duration_secs:.1}s");

        if let Some(output) = payload.get("output").and_then(Value::as_str)
            && !output.is_empty()
        {
            let truncated = if output.len() > 2000 {
                format!("{}\n\n... [Output truncated]", &output[..2000])
            } else {
                output.to_string()
            };
            let _ = write!(ctx, "\n**Output**:\n```\n{truncated}\n```\n");
        }

        if let Some(blob_id) = payload.get("blobId").and_then(Value::as_str) {
            let _ = writeln!(ctx, "\nFull output available: `{blob_id}`");
        }

        ctx.push_str("\n---\n\n");
    }

    Some(ctx)
}

/// Get pending user job action notifications (backgrounded/cancelled from iOS).
/// Filters out already-consumed actions using `user_job_actions.consumed` events.
pub fn get_pending_user_job_actions(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
) -> Vec<(String, Value)> {
    let notifications = event_store
        .get_events_by_type(session_id, &["notification.user_job_action"], None)
        .unwrap_or_default();

    if notifications.is_empty() {
        return vec![];
    }

    let consumed_events = event_store
        .get_events_by_type(session_id, &["user_job_actions.consumed"], None)
        .unwrap_or_default();

    let mut consumed_ids: HashSet<String> = HashSet::new();
    for event in &consumed_events {
        if let Ok(payload) = serde_json::from_str::<Value>(&event.payload)
            && let Some(ids) = payload.get("consumedEventIds").and_then(|v| v.as_array())
        {
            for id in ids {
                if let Some(s) = id.as_str() {
                    let _ = consumed_ids.insert(s.to_owned());
                }
            }
        }
    }

    notifications
        .into_iter()
        .filter(|event| !consumed_ids.contains(&event.id))
        .filter_map(|event| parse_pending_event_payload(event))
        .collect()
}

/// Format user job actions into a system message for context injection.
pub fn format_user_job_actions(actions: &[(String, Value)]) -> String {
    let mut ctx = String::from("# User Job Actions\n\n");
    for (_event_id, action) in actions {
        let job_id = action
            .get("jobId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let action_type = action
            .get("action")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let label = action
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let _ = writeln!(ctx, "- User **{action_type}** job `{label}` ({job_id})");
    }
    ctx
}
