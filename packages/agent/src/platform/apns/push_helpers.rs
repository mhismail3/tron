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
//!   next `NotifyApp` call.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::sync::Arc;

use tracing::{debug, info, warn};

use crate::domains::session::event_store::sqlite::repositories::device_token::{
    DeactivatedTokenInfo, DeviceTokenRepo,
};
use crate::domains::session::event_store::types::payloads::device::DeviceTokenInvalidatedPayload;
use crate::domains::session::event_store::{AppendOptions, ConnectionPool, EventStore, EventType};
use crate::domains::tools::implementations::errors::ToolError;
use crate::domains::tools::implementations::traits::{Notification, NotifyResult};

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
pub(crate) fn active_tokens(pool: &ConnectionPool) -> Result<Vec<DeviceToken>, ToolError> {
    let conn = pool
        .get()
        .map_err(|e| ToolError::internal(format!("Failed to get DB connection: {e}")))?;
    let tokens = DeviceTokenRepo::get_all_active(&conn)
        .map_err(|e| ToolError::internal(format!("Failed to query device tokens: {e}")))?;
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

/// Convert a tool-level [`Notification`] to a platform-level [`ApnsNotification`].
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
mod tests {
    use super::*;
    use crate::domains::tools::implementations::traits::Notification;

    #[test]
    fn to_apns_notification_maps_all_fields() {
        let notification = Notification {
            title: "Task Done".into(),
            body: "Your build completed".into(),
            priority: "high".into(),
            badge: Some(3),
            data: Some(serde_json::json!({"sessionId": "sess_1"})),
            sheet_content: None,
        };

        let apns = to_apns_notification(&notification);
        assert_eq!(apns.title, "Task Done");
        assert_eq!(apns.body, "Your build completed");
        assert_eq!(apns.priority, "high");
        assert_eq!(apns.badge, Some(3));
        assert_eq!(apns.sound, Some("default".to_string()));
        assert_eq!(apns.data.get("sessionId").unwrap(), "sess_1");
    }

    #[test]
    fn to_apns_notification_handles_missing_data() {
        let notification = Notification {
            title: "T".into(),
            body: "B".into(),
            priority: "normal".into(),
            badge: None,
            data: None,
            sheet_content: None,
        };

        let apns = to_apns_notification(&notification);
        assert_eq!(apns.title, "T");
        assert_eq!(apns.body, "B");
        assert!(apns.data.is_empty());
        assert_eq!(apns.badge, None);
    }

    #[test]
    fn to_apns_notification_converts_non_string_data_values() {
        let notification = Notification {
            title: "T".into(),
            body: "B".into(),
            priority: "normal".into(),
            badge: None,
            data: Some(serde_json::json!({"count": 42, "flag": true})),
            sheet_content: None,
        };

        let apns = to_apns_notification(&notification);
        assert_eq!(apns.data.get("count").unwrap(), "42");
        assert_eq!(apns.data.get("flag").unwrap(), "true");
    }

    #[test]
    fn process_results_all_success() {
        // Use a pool we can't actually connect to — process_send_results only
        // touches the pool for 410 cleanup, so all-success skips it.
        let manager = r2d2_sqlite::SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();

        let results = vec![
            ApnsSendResult {
                success: true,
                device_token: "aabb".into(),
                apns_id: Some("id1".into()),
                status_code: Some(200),
                reason: None,
                error: None,
            },
            ApnsSendResult {
                success: true,
                device_token: "ccdd".into(),
                apns_id: Some("id2".into()),
                status_code: Some(200),
                reason: None,
                error: None,
            },
        ];

        let result = process_send_results(&results, &pool, None);
        assert!(result.success);
        assert!(result.message.as_ref().unwrap().contains("2 of 2"));
        assert_eq!(result.success_count, 2);
        assert_eq!(result.total_count, 2);
    }

    #[test]
    fn process_results_all_failure() {
        let manager = r2d2_sqlite::SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();

        let results = vec![ApnsSendResult {
            success: false,
            device_token: "aabb".into(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("BadDeviceToken".into()),
            error: Some("bad token".into()),
        }];

        let result = process_send_results(&results, &pool, None);
        assert!(!result.success);
        assert!(result.message.as_ref().unwrap().contains("0 of 1"));
        assert!(result.message.as_ref().unwrap().contains("bad token"));
        assert_eq!(result.success_count, 0);
        assert_eq!(result.total_count, 1);
    }

    #[test]
    fn process_results_mixed() {
        let manager = r2d2_sqlite::SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();

        let results = vec![
            ApnsSendResult {
                success: true,
                device_token: "aabb".into(),
                apns_id: Some("id1".into()),
                status_code: Some(200),
                reason: None,
                error: None,
            },
            ApnsSendResult {
                success: false,
                device_token: "ccdd".into(),
                apns_id: None,
                status_code: Some(500),
                reason: None,
                error: Some("server error".into()),
            },
        ];

        let result = process_send_results(&results, &pool, None);
        assert!(result.success); // at least one succeeded
        assert!(result.message.as_ref().unwrap().contains("1 of 2"));
        assert_eq!(result.success_count, 1);
        assert_eq!(result.total_count, 2);
    }

    // ── group_tokens ─────────────────────────────────────────────────

    fn dt(token: &str, env: &str, bundle: &str) -> DeviceToken {
        DeviceToken {
            token: token.to_string(),
            environment: env.to_string(),
            bundle_id: bundle.to_string(),
        }
    }

    #[test]
    fn group_tokens_same_env_same_bundle_together() {
        let tokens = vec![
            dt("aa", "production", "com.tron.mobile"),
            dt("bb", "production", "com.tron.mobile"),
        ];
        let groups = group_tokens(&tokens);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].environment, "production");
        assert_eq!(groups[0].bundle_id, "com.tron.mobile");
        assert_eq!(groups[0].tokens, vec!["aa", "bb"]);
    }

    #[test]
    fn group_tokens_same_env_different_bundle_split() {
        // *** Regression test for the 2026-04-16 incident. ***
        // If this fails, the Beta-scheme bug is back: two sandbox tokens
        // from different bundles got sent with the same apns-topic.
        let tokens = vec![
            dt("aa", "sandbox", "com.tron.mobile"),
            dt("bb", "sandbox", "com.tron.mobile.beta"),
        ];
        let groups = group_tokens(&tokens);
        assert_eq!(
            groups.len(),
            2,
            "distinct bundles must form distinct groups"
        );
        let beta = groups
            .iter()
            .find(|g| g.bundle_id == "com.tron.mobile.beta")
            .unwrap();
        let prod = groups
            .iter()
            .find(|g| g.bundle_id == "com.tron.mobile")
            .unwrap();
        assert_eq!(beta.tokens, vec!["bb"]);
        assert_eq!(prod.tokens, vec!["aa"]);
    }

    #[test]
    fn group_tokens_full_matrix_four_groups() {
        let tokens = vec![
            dt("a1", "production", "com.tron.mobile"),
            dt("a2", "production", "com.tron.mobile.beta"),
            dt("a3", "sandbox", "com.tron.mobile"),
            dt("a4", "sandbox", "com.tron.mobile.beta"),
        ];
        let groups = group_tokens(&tokens);
        assert_eq!(groups.len(), 4);
    }

    #[test]
    fn group_tokens_empty_input_empty_output() {
        let groups = group_tokens(&[]);
        assert!(groups.is_empty());
    }

    // ── is_terminal_token_error ──────────────────────────────────────

    fn failed(status: u16, reason: Option<&str>) -> ApnsSendResult {
        ApnsSendResult {
            success: false,
            device_token: "tok".into(),
            apns_id: None,
            status_code: Some(status),
            reason: reason.map(String::from),
            error: Some("err".into()),
        }
    }

    #[test]
    fn terminal_410_is_terminal() {
        assert!(is_terminal_token_error(&failed(410, Some("Unregistered"))));
    }

    #[test]
    fn terminal_bad_device_token_is_terminal() {
        assert!(is_terminal_token_error(&failed(
            400,
            Some("BadDeviceToken")
        )));
    }

    #[test]
    fn terminal_device_token_not_for_topic_is_terminal() {
        // *** Regression test for the original bug. ***
        // Without this deactivation, a broken Beta token stays in the DB
        // and keeps failing every NotifyApp call.
        assert!(is_terminal_token_error(&failed(
            400,
            Some("DeviceTokenNotForTopic")
        )));
    }

    #[test]
    fn terminal_topic_disallowed_is_not_terminal() {
        // Cert/team config issue — not a per-token failure. Don't punish
        // the user's tokens for a server-side provisioning mistake.
        assert!(!is_terminal_token_error(&failed(
            400,
            Some("TopicDisallowed")
        )));
    }

    #[test]
    fn terminal_other_400_reasons_are_not_terminal() {
        assert!(!is_terminal_token_error(&failed(
            400,
            Some("PayloadTooLarge")
        )));
        assert!(!is_terminal_token_error(&failed(400, Some("IdleTimeout"))));
        assert!(!is_terminal_token_error(&failed(400, Some("BadMessageId"))));
    }

    #[test]
    fn terminal_403_is_not_terminal() {
        // JWT / provider-token issue. Never a per-token failure.
        assert!(!is_terminal_token_error(&failed(
            403,
            Some("ExpiredProviderToken")
        )));
        assert!(!is_terminal_token_error(&failed(
            403,
            Some("InvalidProviderToken")
        )));
    }

    #[test]
    fn terminal_404_is_not_terminal() {
        assert!(!is_terminal_token_error(&failed(404, None)));
    }

    #[test]
    fn terminal_429_is_not_terminal() {
        assert!(!is_terminal_token_error(&failed(429, None)));
    }

    #[test]
    fn terminal_500_is_not_terminal() {
        assert!(!is_terminal_token_error(&failed(500, None)));
    }

    #[test]
    fn terminal_success_is_not_terminal() {
        let ok = ApnsSendResult {
            success: true,
            device_token: "tok".into(),
            apns_id: Some("id".into()),
            status_code: Some(200),
            reason: None,
            error: None,
        };
        assert!(!is_terminal_token_error(&ok));
    }

    // ── process_send_results deactivation (with real DB) ─────────────

    /// Build an in-memory pool with the full schema applied.
    fn pool_with_schema() -> crate::domains::session::event_store::ConnectionPool {
        use r2d2_sqlite::SqliteConnectionManager;
        let manager = SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();
        let conn = pool.get().unwrap();
        crate::domains::session::event_store::sqlite::migrations::run_migrations(&conn).unwrap();
        drop(conn);
        pool
    }

    fn register(pool: &crate::domains::session::event_store::ConnectionPool, token: &str) {
        let conn = pool.get().unwrap();
        DeviceTokenRepo::register(&conn, token, None, None, "sandbox", "com.tron.mobile").unwrap();
    }

    fn is_active(pool: &crate::domains::session::event_store::ConnectionPool, token: &str) -> bool {
        let conn = pool.get().unwrap();
        let row = DeviceTokenRepo::get_all_active(&conn)
            .unwrap()
            .into_iter()
            .find(|r| r.device_token == token);
        row.is_some()
    }

    #[test]
    fn process_results_deactivates_on_http_410() {
        let pool = pool_with_schema();
        let token = "a".repeat(64);
        register(&pool, &token);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".into()),
            error: Some("gone".into()),
        }];
        process_send_results(&results, &pool, None);

        assert!(!is_active(&pool, &token), "410 should deactivate");
    }

    #[test]
    fn process_results_deactivates_on_bad_device_token() {
        let pool = pool_with_schema();
        let token = "b".repeat(64);
        register(&pool, &token);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("BadDeviceToken".into()),
            error: Some("bad".into()),
        }];
        process_send_results(&results, &pool, None);

        assert!(
            !is_active(&pool, &token),
            "BadDeviceToken should deactivate"
        );
    }

    #[test]
    fn process_results_deactivates_on_device_token_not_for_topic() {
        // *** Full-stack regression test for the original bug. ***
        let pool = pool_with_schema();
        let token = "c".repeat(64);
        register(&pool, &token);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("DeviceTokenNotForTopic".into()),
            error: Some("wrong bundle".into()),
        }];
        process_send_results(&results, &pool, None);

        assert!(
            !is_active(&pool, &token),
            "DeviceTokenNotForTopic should deactivate (was the 2026-04-16 bug)"
        );
    }

    #[test]
    fn process_results_does_not_deactivate_on_non_terminal_400() {
        let pool = pool_with_schema();
        let token = "d".repeat(64);
        register(&pool, &token);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("PayloadTooLarge".into()),
            error: Some("too big".into()),
        }];
        process_send_results(&results, &pool, None);

        assert!(
            is_active(&pool, &token),
            "transient 400 must not deactivate"
        );
    }

    #[test]
    fn process_results_does_not_deactivate_on_topic_disallowed() {
        // Cert misconfig — never punish the token.
        let pool = pool_with_schema();
        let token = "e".repeat(64);
        register(&pool, &token);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("TopicDisallowed".into()),
            error: Some("cert wrong".into()),
        }];
        process_send_results(&results, &pool, None);

        assert!(
            is_active(&pool, &token),
            "TopicDisallowed must NOT deactivate"
        );
    }

    #[test]
    fn process_results_does_not_deactivate_on_5xx() {
        let pool = pool_with_schema();
        let token = "f".repeat(64);
        register(&pool, &token);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(503),
            reason: None,
            error: Some("apns down".into()),
        }];
        process_send_results(&results, &pool, None);

        assert!(is_active(&pool, &token), "server error must not deactivate");
    }

    #[test]
    fn process_results_does_not_deactivate_on_success() {
        let pool = pool_with_schema();
        let token = "0".repeat(64);
        register(&pool, &token);

        let results = vec![ApnsSendResult {
            success: true,
            device_token: token.clone(),
            apns_id: Some("id".into()),
            status_code: Some(200),
            reason: None,
            error: None,
        }];
        process_send_results(&results, &pool, None);

        assert!(is_active(&pool, &token), "success must never deactivate");
    }

    // ── device.token_invalidated event emission ─────────────────────

    /// Fixture: a schema-migrated event store plus a workspace+session
    /// row so a device token bound to them doesn't fail the FK.
    fn event_store_with_session() -> (Arc<EventStore>, String) {
        use r2d2_sqlite::SqliteConnectionManager;
        let manager = SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();
        let conn = pool.get().unwrap();
        crate::domains::session::event_store::sqlite::migrations::run_migrations(&conn).unwrap();
        let session_id = "sess-h22".to_string();
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws-h22', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at)
             VALUES (?1, 'ws-h22', 't', 'claude-opus', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            rusqlite::params![session_id],
        )
        .unwrap();
        drop(conn);
        (Arc::new(EventStore::new(pool)), session_id)
    }

    fn register_with_session(store: &EventStore, token: &str, session_id: &str) {
        let conn = store.pool().get().unwrap();
        DeviceTokenRepo::register(
            &conn,
            token,
            Some(session_id),
            Some("ws-h22"),
            "production",
            "com.tron.mobile",
        )
        .unwrap();
    }

    fn count_invalidated_events(store: &EventStore, session_id: &str) -> i64 {
        let conn = store.pool().get().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM events WHERE session_id = ?1 AND type = ?2",
            rusqlite::params![session_id, EventType::DeviceTokenInvalidated.as_str()],
            |row| row.get(0),
        )
        .unwrap()
    }

    #[test]
    fn emits_invalidated_event_on_410() {
        let (store, session_id) = event_store_with_session();
        let token = "a".repeat(64);
        register_with_session(&store, &token, &session_id);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".into()),
            error: Some("gone".into()),
        }];
        process_send_results(&results, &store.pool().clone(), Some(&store));

        assert_eq!(
            count_invalidated_events(&store, &session_id),
            1,
            "exactly one device.token_invalidated event must be persisted on terminal error"
        );
    }

    #[test]
    fn does_not_emit_for_non_terminal_errors() {
        let (store, session_id) = event_store_with_session();
        let token = "b".repeat(64);
        register_with_session(&store, &token, &session_id);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(503),
            reason: None,
            error: Some("upstream down".into()),
        }];
        process_send_results(&results, &store.pool().clone(), Some(&store));

        assert_eq!(
            count_invalidated_events(&store, &session_id),
            0,
            "transient errors must NOT emit an invalidation event"
        );
    }

    #[test]
    fn dedups_repeat_terminal_errors_on_same_token() {
        // If APNS responds 410 twice for the same token, we should only
        // emit ONE invalidated event. The second 410 hits an already-
        // inactive row and deactivate() returns None, skipping emission.
        let (store, session_id) = event_store_with_session();
        let token = "c".repeat(64);
        register_with_session(&store, &token, &session_id);

        let terminal = ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".into()),
            error: Some("gone".into()),
        };
        process_send_results(
            std::slice::from_ref(&terminal),
            &store.pool().clone(),
            Some(&store),
        );
        process_send_results(
            std::slice::from_ref(&terminal),
            &store.pool().clone(),
            Some(&store),
        );

        assert_eq!(
            count_invalidated_events(&store, &session_id),
            1,
            "repeat 410s on the same token must not produce duplicate events"
        );
    }

    #[test]
    fn no_emission_when_event_store_is_absent() {
        // The delegate is shipped with `None` event_store from tests that
        // exercise deactivation in isolation (the scope tests above). The
        // deactivation side effect still runs; emission is skipped silently.
        let (store, _session_id) = event_store_with_session();
        let token = "d".repeat(64);
        // Register with no session binding so deactivate returns info with
        // session_id = None — which ALSO skips emission even if a store were
        // passed. This asserts the None-store path.
        let conn = store.pool().get().unwrap();
        DeviceTokenRepo::register(&conn, &token, None, None, "production", "com.tron.mobile")
            .unwrap();
        drop(conn);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".into()),
            error: Some("gone".into()),
        }];
        // Pass None explicitly for event_store.
        process_send_results(&results, &store.pool().clone(), None);

        // Token is still deactivated (side effect preserved).
        assert!(!is_active(&store.pool().clone(), &token));
    }

    #[test]
    fn skips_emission_when_token_has_no_session_binding() {
        // Token registered without a session_id → no sensible attribution
        // for the event. Deactivation still runs.
        let (store, _session_id) = event_store_with_session();
        let token = "e".repeat(64);
        let conn = store.pool().get().unwrap();
        DeviceTokenRepo::register(&conn, &token, None, None, "production", "com.tron.mobile")
            .unwrap();
        drop(conn);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".into()),
            error: Some("gone".into()),
        }];
        process_send_results(&results, &store.pool().clone(), Some(&store));

        // No event produced for a session-less token.
        let conn = store.pool().get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM events WHERE type = ?1",
                rusqlite::params![EventType::DeviceTokenInvalidated.as_str()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "no session_id → no event");
        // Deactivation still applied.
        assert!(!is_active(&store.pool().clone(), &token));
    }

    #[test]
    fn event_payload_carries_prefix_and_status_and_reason() {
        let (store, session_id) = event_store_with_session();
        let token = "f".repeat(64);
        register_with_session(&store, &token, &session_id);

        let results = vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("BadDeviceToken".into()),
            error: Some("bad".into()),
        }];
        process_send_results(&results, &store.pool().clone(), Some(&store));

        let conn = store.pool().get().unwrap();
        let payload: String = conn
            .query_row(
                "SELECT payload FROM events WHERE type = ?1 AND session_id = ?2 LIMIT 1",
                rusqlite::params![EventType::DeviceTokenInvalidated.as_str(), session_id],
                |row| row.get(0),
            )
            .unwrap();
        let payload: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(payload["tokenPrefix"], "ffffffff");
        assert_eq!(payload["statusCode"], 400);
        assert_eq!(payload["reason"], "BadDeviceToken");
        assert_eq!(payload["bundleId"], "com.tron.mobile");
        assert_eq!(payload["sessionId"], session_id);
        assert!(payload["timestamp"].is_string());
    }
}
