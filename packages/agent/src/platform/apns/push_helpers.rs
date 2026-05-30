//! Shared helpers for push notification delegates.
//!
//! Shared by the relay delegate and cron push notifier so they use identical
//! token-query, notification-conversion, and result-processing logic.
//!
//! Key functions:
//! - [`group_tokens`] — split the active-tokens list by `(environment, bundle_id)`.
//!   Each group becomes one transport call so the `apns-topic` header is
//!   correct for every token in the batch. The 2026-04-16 `DeviceTokenNotForTopic`
//!   regression would have been caught by the `group_tokens_same_env_different_bundle_split`
//!   unit test.
//! - [`is_terminal_token_error`] — classifies an APNs failure as terminal
//!   (deactivate the token) vs transient. Terminal: HTTP 410, HTTP 400
//!   `BadDeviceToken`, HTTP 400 `DeviceTokenNotForTopic`. Everything else
//!   (JWT errors, rate limits, 5xx, `TopicDisallowed`) retries on the
//!   next `notifications::send` invocation.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::sync::Arc;

use tracing::{debug, info, warn};

use crate::domains::capability_support::implementations::errors::CapabilityExecutionError;
use crate::domains::capability_support::implementations::traits::{Notification, NotifyResult};
use crate::domains::session::event_store::sqlite::repositories::device_token::{
    DeactivatedTokenInfo, DeviceTokenRepo,
};
use crate::domains::session::event_store::types::payloads::device::DeviceTokenInvalidatedPayload;
use crate::domains::session::event_store::{AppendOptions, ConnectionPool, EventStore, EventType};

use super::types::{ApnsNotification, ApnsSendResult};

/// Return the first 8 bytes of a token for logging (UTF-8–safe).
pub(crate) fn token_prefix(token: &str) -> &str {
    crate::shared::text::truncate_str(token, 8)
}

/// A device token with its APNs environment and bundle ID.
pub(crate) struct DeviceToken {
    pub token: String,
    pub environment: String,
    /// APNs bundle ID (`apns-topic`). NOT NULL on the row — every active
    /// registration carries its bundle identifier so the send path can
    /// attach the correct `apns-topic` without an alternate topic.
    pub bundle_id: String,
}

/// A group of tokens that share the same (environment, bundle_id) tuple —
/// the natural unit of an APNs request.
pub(crate) struct TokenGroup<'a> {
    pub environment: &'a str,
    pub bundle_id: &'a str,
    pub tokens: Vec<&'a str>,
}

/// Query all active device tokens from the database.
pub(crate) fn active_tokens(
    pool: &ConnectionPool,
) -> Result<Vec<DeviceToken>, CapabilityExecutionError> {
    let conn = pool.get().map_err(|e| {
        CapabilityExecutionError::internal(format!("Failed to get DB connection: {e}"))
    })?;
    let tokens = DeviceTokenRepo::get_all_active(&conn).map_err(|e| {
        CapabilityExecutionError::internal(format!("Failed to query device tokens: {e}"))
    })?;
    Ok(tokens
        .into_iter()
        .map(|t| DeviceToken {
            token: t.device_token,
            environment: t.environment,
            bundle_id: t.bundle_id,
        })
        .collect())
}

/// Group device tokens by `(environment, bundle_id)`.
///
/// Two tokens in the same environment but against different bundles
/// (e.g., Beta sandbox + a hypothetical other sandbox bundle) MUST end up
/// in distinct groups — the relay sends one `apns-topic` per request.
/// Merging them would reproduce the pre-fix bug where the Beta token was
/// rejected with `DeviceTokenNotForTopic`.
///
/// `BTreeMap` gives deterministic ordering so tests don't flake.
pub(crate) fn group_tokens(tokens: &[DeviceToken]) -> Vec<TokenGroup<'_>> {
    let mut grouped: BTreeMap<(&str, &str), Vec<&str>> = BTreeMap::new();
    for dt in tokens {
        grouped
            .entry((&dt.environment, &dt.bundle_id))
            .or_default()
            .push(&dt.token);
    }
    grouped
        .into_iter()
        .map(|((environment, bundle_id), tokens)| TokenGroup {
            environment,
            bundle_id,
            tokens,
        })
        .collect()
}

/// Convert a capability-level [`Notification`] to a platform-level [`ApnsNotification`].
pub(crate) fn to_apns_notification(notification: &Notification) -> ApnsNotification {
    let mut data = HashMap::new();

    if let Some(ref extra) = notification.data
        && let Some(obj) = extra.as_object()
    {
        for (k, v) in obj {
            let s = if let Some(s) = v.as_str() {
                s.to_string()
            } else {
                v.to_string()
            };
            let _ = data.insert(k.clone(), s);
        }
    }

    ApnsNotification {
        title: notification.title.clone(),
        body: notification.body.clone(),
        data,
        priority: notification.priority.clone(),
        sound: Some("default".to_string()),
        badge: notification.badge,
        thread_id: None,
    }
}

/// Return true when an APNs failure is terminal for this specific token —
/// i.e., the token is permanently invalid and should be deactivated in
/// the DB. Transient failures (JWT / rate / 5xx / non-terminal 400 reasons)
/// must NOT deactivate.
///
/// Apple doc:
/// - HTTP 410 (`Unregistered`): the device is no longer registered for the topic.
/// - HTTP 400 `BadDeviceToken`: the token is malformed or not for this environment.
/// - HTTP 400 `DeviceTokenNotForTopic`: the token was issued for a different
///   bundle and will never work against the current `apns-topic`. We already
///   pass the correct topic per token since v006, so if this still surfaces
///   the token is genuinely wrong for the app — deactivate it.
///
/// Deliberately NOT terminal: `TopicDisallowed` (cert/team issue, not token),
/// `ExpiredProviderToken` / `InvalidProviderToken` (JWT), `MissingProviderToken`
/// (config), any 429 / 5xx.
pub(crate) fn is_terminal_token_error(result: &ApnsSendResult) -> bool {
    if result.success {
        return false;
    }
    if result.status_code == Some(410) {
        return true;
    }
    matches!(
        result.reason.as_deref(),
        Some("BadDeviceToken" | "DeviceTokenNotForTopic")
    )
}

/// Process send results: auto-deactivate terminally-failed tokens,
/// collect errors, build the summary shown to the user, and emit a
/// `device.token_invalidated` event for each deactivation so iOS has
/// a push-driven signal of the server discarding its token.
///
/// Event emission is best-effort: if the token row has no session_id
/// (registered without a session binding) or the attributed session no
/// longer exists, the info is still logged at `info` level so operator
/// visibility doesn't depend on the broadcast path.
pub(crate) fn process_send_results(
    results: &[ApnsSendResult],
    pool: &ConnectionPool,
    event_store: Option<&Arc<EventStore>>,
) -> NotifyResult {
    let total = results.len();
    let mut success_count = 0;
    let mut errors = Vec::new();

    for result in results {
        debug!(
            token_prefix = token_prefix(&result.device_token),
            token_len = result.device_token.len(),
            success = result.success,
            status = ?result.status_code,
            reason = ?result.reason,
            error = ?result.error,
            apns_id = ?result.apns_id,
            "push per-device result"
        );

        if result.success {
            success_count += 1;
        } else {
            if is_terminal_token_error(result) {
                if let Ok(conn) = pool.get() {
                    match DeviceTokenRepo::deactivate(&conn, &result.device_token) {
                        Ok(infos) if infos.is_empty() => {
                            debug!(
                                token_prefix = token_prefix(&result.device_token),
                                "token already inactive — skipping duplicate deactivation"
                            );
                        }
                        Ok(infos) => {
                            // Under the v007 workspace+bundle-scoped identity,
                            // a single token may have multiple active rows
                            // (one per workspace/bundle). Every affected
                            // registration must log + emit its own event.
                            info!(
                                token_prefix = token_prefix(&result.device_token),
                                rows_deactivated = infos.len(),
                                status = ?result.status_code,
                                reason = ?result.reason,
                                "deactivated device token after terminal APNs error"
                            );
                            for info in &infos {
                                info!(
                                    token_prefix = token_prefix(&result.device_token),
                                    session_id = info.session_id.as_deref().unwrap_or("<none>"),
                                    workspace_id = info.workspace_id.as_deref().unwrap_or("<none>"),
                                    bundle_id = info.bundle_id.as_str(),
                                    "  ↳ row attributed"
                                );
                            }
                            drop(conn);
                            for info in infos {
                                maybe_emit_invalidated_event(event_store, result, &info);
                            }
                        }
                        Err(e) => {
                            warn!(
                                token_prefix = token_prefix(&result.device_token),
                                error = %e,
                                "failed to deactivate device token after terminal APNs error"
                            );
                        }
                    }
                }
            }
            if let Some(ref err) = result.error {
                errors.push(format!(
                    "{}...(len={}): {}",
                    token_prefix(&result.device_token),
                    result.device_token.len(),
                    err
                ));
            }
        }
    }

    let message = if errors.is_empty() {
        format!("Sent to {success_count} of {total} devices.")
    } else {
        format!(
            "Sent to {success_count} of {total} devices. Errors: {}",
            errors.join("; ")
        )
    };

    debug!(
        success_count,
        error_count = errors.len(),
        total,
        message = %message,
        "push delivery summary"
    );

    #[allow(clippy::cast_possible_truncation)]
    NotifyResult {
        success: success_count > 0,
        message: Some(message),
        success_count: u32::try_from(success_count).unwrap_or(u32::MAX),
        total_count: u32::try_from(total).unwrap_or(u32::MAX),
        // Real relay delivery doesn't stub — no warning.
        warning: None,
    }
}

/// Emit a `device.token_invalidated` event if we have an event store and
/// the token's session is still valid. Returns quietly on any failure —
/// the deactivation itself is what protects the user from repeated
/// 410s; the event is diagnostic-quality only.
fn maybe_emit_invalidated_event(
    event_store: Option<&Arc<EventStore>>,
    result: &ApnsSendResult,
    info: &DeactivatedTokenInfo,
) {
    let Some(store) = event_store else { return };
    let Some(session_id) = info.session_id.as_deref() else {
        debug!(
            token_prefix = token_prefix(&result.device_token),
            "skipping device.token_invalidated emission: token had no session binding"
        );
        return;
    };

    let payload = DeviceTokenInvalidatedPayload {
        session_id: session_id.to_owned(),
        token_prefix: token_prefix(&result.device_token).to_owned(),
        bundle_id: info.bundle_id.clone(),
        status_code: result.status_code,
        reason: result.reason.clone(),
        timestamp: chrono::Utc::now().to_rfc3339(),
    };
    // bundle_id is now a plain String — NOT NULL on the row, always present.

    let Ok(value) = serde_json::to_value(&payload) else {
        warn!("failed to serialize DeviceTokenInvalidatedPayload");
        return;
    };

    let append_result = store.append(&AppendOptions {
        session_id,
        event_type: EventType::DeviceTokenInvalidated,
        payload: value,
        parent_id: None,
        sequence: None,
    });

    if let Err(e) = append_result {
        // Session may no longer exist (user deleted it) — that's expected
        // for long-abandoned sessions whose tokens finally rot. Log at
        // debug so normal operation isn't noisy.
        debug!(
            session_id,
            token_prefix = token_prefix(&result.device_token),
            error = %e,
            "device.token_invalidated event not persisted (session may be gone)"
        );
    }
}

#[cfg(test)]
#[path = "push_helpers_tests.rs"]
mod tests;
