use super::*;
use crate::server::domains::memory::retain::{RetainSource, trigger_retain};

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
pub async fn maybe_fire(deps: &RetainDeps, session_id: &str) {
    let interval = crate::settings::get_settings().memory.auto_retain_interval;
    maybe_fire_with_interval(deps, session_id, interval).await;
}

/// Core of [`maybe_fire`] with the threshold passed in explicitly. Exists so
/// tests can exercise the full `gather_state` → `should_auto_retain` →
/// `trigger_retain` composition without mutating the global settings singleton.
pub(super) async fn maybe_fire_with_interval(deps: &RetainDeps, session_id: &str, interval: u32) {
    // Cheap short-circuit: avoid hitting SQLite when auto-retain is disabled.
    if interval == 0 {
        return;
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
            return;
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
            if let Err(err) = trigger_retain(
                deps,
                session_id_owned.clone(),
                RetainSource::Auto { interval_fired },
            )
            .await
            {
                warn!(
                    session_id = %session_id_owned,
                    error = %err,
                    "auto-retain: trigger_retain failed"
                );
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
        }
    }
}
