//! Relay-backed [`NotifyDelegate`] — sends push notifications via the Cloudflare
//! Worker relay.

use std::sync::Arc;

use async_trait::async_trait;
use tracing::debug;

use crate::events::{ConnectionPool, EventStore};
use crate::tools::errors::ToolError;
use crate::tools::traits::{NotifyDelegate, NotifyResult};

use super::push_helpers;
use super::sender::{ApnsBatch, PushSender};

/// Relay-backed notification delegate.
pub struct RelayNotifyDelegate {
    sender: Arc<dyn PushSender>,
    pool: ConnectionPool,
    /// Event store used to emit `device.token_invalidated` when the
    /// relay returns a response mapping to a terminal APNs token error.
    /// Same store the rest of the server uses so token invalidation events
    /// are emitted through the canonical event pipeline.
    event_store: Arc<EventStore>,
}

impl RelayNotifyDelegate {
    /// Create a new delegate with the given push sender and event store.
    pub fn new(sender: Arc<dyn PushSender>, event_store: Arc<EventStore>) -> Self {
        let pool = event_store.pool().clone();
        Self {
            sender,
            pool,
            event_store,
        }
    }
}

#[async_trait]
impl NotifyDelegate for RelayNotifyDelegate {
    async fn send_notification(
        &self,
        notification: &crate::tools::traits::Notification,
    ) -> Result<NotifyResult, ToolError> {
        let device_tokens = push_helpers::active_tokens(&self.pool)?;

        if device_tokens.is_empty() {
            debug!("No active device tokens — skipping relay send");
            return Ok(NotifyResult {
                success: true,
                message: None,
                success_count: 0,
                total_count: 0,
                warning: None,
            });
        }

        let apns_notif = push_helpers::to_apns_notification(notification);
        let total = device_tokens.len();
        let groups = push_helpers::group_tokens(&device_tokens);

        debug!(
            device_count = total,
            group_count = groups.len(),
            title = %notification.title,
            "Sending notification via relay"
        );

        let mut all_results = Vec::with_capacity(total);
        for group in &groups {
            let owned: Vec<String> = group.tokens.iter().map(|t| t.to_string()).collect();
            // INVARIANT: `device_tokens.bundle_id` is NOT NULL (v001 schema),
            // so every group carries a concrete APNs topic. The relay worker
            // no longer has an `env.APNS_BUNDLE_ID` alternate-topic path
            // for this request — the per-token value is the one source of truth.
            debug!(
                environment = group.environment,
                bundle_id = group.bundle_id,
                count = group.tokens.len(),
                "relay group"
            );
            let batch = ApnsBatch {
                device_tokens: &owned,
                environment: group.environment,
                bundle_id: group.bundle_id,
            };
            let results = self.sender.send_to_many(&batch, &apns_notif).await;
            all_results.extend(results);
        }
        Ok(push_helpers::process_send_results(
            &all_results,
            &self.pool,
            Some(&self.event_store),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::sqlite::migrations::run_migrations;
    use crate::events::sqlite::repositories::device_token::DeviceTokenRepo;
    use crate::server::platform::apns::sender::tests::MockPushSender;
    use crate::server::platform::apns::types::ApnsSendResult;
    use crate::tools::traits::Notification;

    /// Test fixture: an in-memory event store already wired through its
    /// own pool. Returns both so tests that want to inspect the DB can
    /// still `pool.get()` without constructing a parallel connection.
    fn event_store_with_schema() -> Arc<EventStore> {
        use r2d2_sqlite::SqliteConnectionManager;
        let manager = SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
        drop(conn);
        Arc::new(EventStore::new(pool))
    }

    fn register(store: &EventStore, token: &str, env: &str, bundle: &str) {
        let conn = store.pool().get().unwrap();
        DeviceTokenRepo::register(&conn, token, None, None, env, bundle).unwrap();
    }

    fn notif() -> Notification {
        Notification {
            title: "hi".into(),
            body: "there".into(),
            priority: "high".into(),
            badge: None,
            data: None,
            sheet_content: None,
        }
    }

    /// Helper to pull sorted, filtered calls from the mock so test
    /// assertions are order-independent (groups are sorted by (env, bundle)
    /// via BTreeMap, but explicit sort is safer).
    fn sorted_calls(mock: &MockPushSender) -> Vec<(Vec<String>, String, String, String)> {
        let mut calls = mock.calls.lock().unwrap().clone();
        calls.sort_by(|a, b| (a.2.clone(), a.3.clone()).cmp(&(b.2.clone(), b.3.clone())));
        calls
    }

    #[tokio::test]
    async fn sends_per_bundle_group_with_correct_bundle_id() {
        // *** Regression test for the 2026-04-16 incident. ***
        //
        // A Beta sandbox token and a Prod sandbox token must go out as
        // two separate relay calls, each with its own apns-topic. If the
        // delegate collapses them, the Beta token hits production topic
        // and Apple rejects with DeviceTokenNotForTopic.
        let store = event_store_with_schema();
        register(&store, &"1".repeat(64), "sandbox", "com.tron.mobile");
        register(&store, &"2".repeat(64), "sandbox", "com.tron.mobile.beta");

        let mock = Arc::new(MockPushSender::succeeding());
        let delegate = RelayNotifyDelegate::new(mock.clone(), store);

        let result = delegate.send_notification(&notif()).await.unwrap();
        assert!(result.success);
        assert_eq!(result.total_count, 2);

        let calls = sorted_calls(&mock);
        assert_eq!(calls.len(), 2, "two distinct (env, bundle) groups");
        // (env, bundle_id) for each call
        assert_eq!(calls[0].2, "sandbox");
        assert_eq!(calls[0].3, "com.tron.mobile");
        assert_eq!(calls[1].2, "sandbox");
        assert_eq!(calls[1].3, "com.tron.mobile.beta");
    }

    #[tokio::test]
    async fn every_sender_call_carries_a_non_empty_bundle_id() {
        // INVARIANT: the transport never sees an empty `bundle_id`. The
        // v001 schema enforces NOT NULL, and the relay worker no longer
        // has an APNS_BUNDLE_ID alternate-topic path — a missing topic would
        // produce a server-side error, so we guard against regressions
        // that might bypass the NOT NULL constraint through future
        // direct SQL inserts.
        let store = event_store_with_schema();
        register(&store, &"1".repeat(64), "production", "com.tron.mobile");
        register(&store, &"2".repeat(64), "sandbox", "com.tron.mobile.beta");

        let mock = Arc::new(MockPushSender::succeeding());
        let delegate = RelayNotifyDelegate::new(mock.clone(), store);

        delegate.send_notification(&notif()).await.unwrap();

        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        for call in calls.iter() {
            assert!(
                !call.3.is_empty(),
                "every relay call must carry a concrete bundle_id"
            );
        }
    }

    #[tokio::test]
    async fn deactivates_token_on_device_token_not_for_topic() {
        // *** Full-stack regression test for the 2026-04-16 incident. ***
        //
        // Even after the NOT NULL bundle_id change, APNs can still return
        // `DeviceTokenNotForTopic` if (for example) a Prod-signed app was
        // reinstalled as Beta and kept the old token row. The server must
        // self-heal by deactivating the offending row so the iOS client
        // re-registers with the correct bundle on next launch.
        let store = event_store_with_schema();
        let token = "b".repeat(64);
        register(&store, &token, "sandbox", "com.tron.mobile.beta");

        let mock = Arc::new(MockPushSender::with_results(vec![vec![ApnsSendResult {
            success: false,
            device_token: token.clone(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("DeviceTokenNotForTopic".into()),
            error: Some("wrong bundle".into()),
        }]]));
        let delegate = RelayNotifyDelegate::new(mock, store.clone());

        delegate.send_notification(&notif()).await.unwrap();

        // Token should be deactivated — next send skips it.
        let conn = store.pool().get().unwrap();
        let active = DeviceTokenRepo::get_all_active(&conn).unwrap();
        assert!(
            active.is_empty(),
            "token with DeviceTokenNotForTopic must be deactivated"
        );
    }

    #[tokio::test]
    async fn empty_tokens_returns_success_with_zero_count() {
        let store = event_store_with_schema();
        let mock = Arc::new(MockPushSender::succeeding());
        let delegate = RelayNotifyDelegate::new(mock.clone(), store);

        let result = delegate.send_notification(&notif()).await.unwrap();
        assert!(result.success);
        assert_eq!(result.total_count, 0);
        assert_eq!(result.success_count, 0);
        assert_eq!(mock.calls.lock().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn fans_out_to_all_registered_devices_by_bundle_group() {
        // Notifications fan out to every active token. Grouping by
        // (environment, bundle_id) ensures the relay uses the right
        // apns-topic per bundle — but every registered device gets a
        // push, not just the ones "viewing" the session. This matches
        // the iPhone + iPad use case (two Prod devices → both pinged).
        let store = event_store_with_schema();
        register(&store, &"1".repeat(64), "production", "com.tron.mobile");
        register(&store, &"2".repeat(64), "production", "com.tron.mobile");
        register(&store, &"3".repeat(64), "sandbox", "com.tron.mobile.beta");

        let mock = Arc::new(MockPushSender::succeeding());
        let delegate = RelayNotifyDelegate::new(mock.clone(), store);

        let result = delegate.send_notification(&notif()).await.unwrap();
        assert_eq!(result.total_count, 3, "every registered device gets a push");
        // Two bundle groups → two sender calls (Prod-bundle batch of 2, Beta batch of 1).
        let calls = sorted_calls(&mock);
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].3, "com.tron.mobile");
        assert_eq!(calls[0].0.len(), 2, "both Prod tokens in one batch");
        assert_eq!(calls[1].3, "com.tron.mobile.beta");
        assert_eq!(calls[1].0.len(), 1);
    }
}
