use super::RetainDeps;
use super::{AutoRetainDecision, gather_state, should_auto_retain};
use crate::domains::memory::retain::{RetainSource, trigger_retain};
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use serde_json::{Value, json};
use tracing::debug;
use tracing::warn;

// ─────────────────────────────────────────────────────────────────────────────
// Async entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Evaluate auto-retain policy and fire `trigger_retain` if the threshold is
/// crossed. Fire-and-forget from the caller's perspective — errors are logged
/// but never surfaced upward.
///
/// Reads the current `memory.auto_retain_interval` from the settings singleton.
/// The setting is hot-reloadable via `settings::update` capability, so user changes
/// take effect on the next agent run without a server restart.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoRetainFireOutcome {
    pub fired: bool,
    pub status: String,
    pub reason: Option<String>,
    pub interval: u32,
    pub user_messages_since_retain: Option<i64>,
}

impl AutoRetainFireOutcome {
    fn skipped(reason: &str, interval: u32, user_messages_since_retain: Option<i64>) -> Self {
        Self {
            fired: false,
            status: "skipped".to_owned(),
            reason: Some(reason.to_owned()),
            interval,
            user_messages_since_retain,
        }
    }

    fn failed(reason: &str, interval: u32, user_messages_since_retain: Option<i64>) -> Self {
        Self {
            fired: false,
            status: "failed".to_owned(),
            reason: Some(reason.to_owned()),
            interval,
            user_messages_since_retain,
        }
    }

    fn from_retain_response(value: &Value, interval: u32, user_messages_since_retain: i64) -> Self {
        let fired = value
            .get("retained")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let status = value
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or(if fired { "retaining" } else { "skipped" })
            .to_owned();
        let reason = value
            .get("reason")
            .and_then(Value::as_str)
            .map(str::to_owned);
        Self {
            fired,
            status,
            reason,
            interval,
            user_messages_since_retain: Some(user_messages_since_retain),
        }
    }

    pub(crate) fn into_value(self) -> Value {
        json!({
            "fired": self.fired,
            "status": self.status,
            "reason": self.reason,
            "interval": self.interval,
            "userMessagesSinceRetain": self.user_messages_since_retain,
        })
    }
}

pub async fn maybe_fire(
    deps: &RetainDeps,
    session_id: &str,
    parent_invocation: Option<Invocation>,
) -> AutoRetainFireOutcome {
    let interval = crate::domains::settings::get_settings()
        .memory
        .auto_retain_interval;
    maybe_fire_with_interval(deps, session_id, interval, parent_invocation).await
}

/// Core of [`maybe_fire`] with the threshold passed in explicitly. Exists so
/// tests can exercise the full `gather_state` → `should_auto_retain` →
/// `trigger_retain` composition without mutating the global settings singleton.
pub(super) async fn maybe_fire_with_interval(
    deps: &RetainDeps,
    session_id: &str,
    interval: u32,
    parent_invocation: Option<Invocation>,
) -> AutoRetainFireOutcome {
    // Cheap short-circuit: avoid hitting SQLite when auto-retain is disabled.
    if interval == 0 {
        return AutoRetainFireOutcome::skipped("disabled", interval, None);
    }

    let event_store = deps.event_store.clone();
    let session_id_owned = session_id.to_owned();
    let session_id_for_task = session_id_owned.clone();
    let gather_result = run_blocking_task("memory.auto_retain.gather_state", move || {
        gather_state(&event_store, &session_id_for_task, interval)
    })
    .await;

    let input = match gather_result {
        Ok(input) => input,
        Err(err) => {
            warn!(
                session_id = %session_id_owned,
                error = %err,
                "auto-retain: failed to gather state; skipping"
            );
            return AutoRetainFireOutcome::failed("state_unavailable", interval, None);
        }
    };

    match should_auto_retain(input) {
        AutoRetainDecision::Fire { interval_fired } => {
            debug!(
                session_id = %session_id_owned,
                interval_fired,
                user_messages_since_retain = input.user_messages_since_retain,
                "auto-retain: firing"
            );
            match trigger_retain(
                deps,
                session_id_owned.clone(),
                RetainSource::Auto { interval_fired },
                parent_invocation,
            )
            .await
            {
                Ok(value) => AutoRetainFireOutcome::from_retain_response(
                    &value,
                    interval,
                    input.user_messages_since_retain,
                ),
                Err(err) => {
                    warn!(
                        session_id = %session_id_owned,
                        error = %err,
                        "auto-retain: trigger_retain failed"
                    );
                    AutoRetainFireOutcome::failed(
                        "retain_failed",
                        interval,
                        Some(input.user_messages_since_retain),
                    )
                }
            }
        }
        AutoRetainDecision::Skip(reason) => {
            debug!(
                session_id = %session_id_owned,
                ?reason,
                user_messages_since_retain = input.user_messages_since_retain,
                interval,
                "auto-retain: skipped"
            );
            AutoRetainFireOutcome::skipped(
                reason.as_str(),
                interval,
                Some(input.user_messages_since_retain),
            )
        }
    }
}
