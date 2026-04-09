//! Transport-agnostic push notification sender trait.
//!
//! Implemented by [`ApnsService`](super::ApnsService) (direct .p8 signing + HTTP/2 to APNs)
//! and [`RelayClient`](super::relay::RelayClient) (HMAC-signed HTTPS to Cloudflare Worker relay).

use async_trait::async_trait;

use super::types::{ApnsNotification, ApnsSendResult};

/// Transport-agnostic push notification sender.
///
/// Returns one [`ApnsSendResult`] per token, in the same order as the input.
#[async_trait]
pub trait PushSender: Send + Sync + std::fmt::Debug {
    /// Send a notification to multiple device tokens in a given APNs environment.
    async fn send_to_many(
        &self,
        device_tokens: &[String],
        notification: &ApnsNotification,
        environment: &str,
    ) -> Vec<ApnsSendResult>;
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Records each call for assertion and returns pre-configured results.
    #[derive(Debug)]
    pub struct MockPushSender {
        /// Pre-configured results returned by `send_to_many`.
        /// If empty, generates a success result per token.
        results: Mutex<Vec<Vec<ApnsSendResult>>>,
        /// Recorded calls: (device_tokens, notification title).
        pub calls: Mutex<Vec<(Vec<String>, String)>>,
    }

    impl MockPushSender {
        /// Create a mock that returns success for every token.
        pub fn succeeding() -> Self {
            Self {
                results: Mutex::new(Vec::new()),
                calls: Mutex::new(Vec::new()),
            }
        }

        /// Create a mock that returns the given results in order.
        pub fn with_results(results: Vec<Vec<ApnsSendResult>>) -> Self {
            Self {
                results: Mutex::new(results),
                calls: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait]
    impl PushSender for MockPushSender {
        async fn send_to_many(
            &self,
            device_tokens: &[String],
            notification: &ApnsNotification,
            _environment: &str,
        ) -> Vec<ApnsSendResult> {
            self.calls
                .lock()
                .unwrap()
                .push((device_tokens.to_vec(), notification.title.clone()));

            let mut results = self.results.lock().unwrap();
            if results.is_empty() {
                // Default: success for every token
                device_tokens
                    .iter()
                    .map(|t| ApnsSendResult {
                        success: true,
                        device_token: t.clone(),
                        apns_id: Some("mock-id".to_string()),
                        status_code: Some(200),
                        reason: None,
                        error: None,
                    })
                    .collect()
            } else {
                results.remove(0)
            }
        }
    }

    #[tokio::test]
    async fn mock_returns_default_success() {
        let mock = MockPushSender::succeeding();
        let notif = ApnsNotification {
            title: "T".into(),
            body: "B".into(),
            data: Default::default(),
            priority: "high".into(),
            sound: None,
            badge: None,
            thread_id: None,
        };

        let results = mock.send_to_many(&["aabb".into(), "ccdd".into()], &notif, "sandbox").await;
        assert_eq!(results.len(), 2);
        assert!(results[0].success);
        assert!(results[1].success);
        assert_eq!(results[0].device_token, "aabb");
        assert_eq!(results[1].device_token, "ccdd");
    }

    #[tokio::test]
    async fn mock_returns_configured_results() {
        let configured = vec![vec![ApnsSendResult {
            success: false,
            device_token: "tok1".into(),
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".into()),
            error: None,
        }]];
        let mock = MockPushSender::with_results(configured);
        let notif = ApnsNotification {
            title: "T".into(),
            body: "B".into(),
            data: Default::default(),
            priority: "high".into(),
            sound: None,
            badge: None,
            thread_id: None,
        };

        let results = mock.send_to_many(&["tok1".into()], &notif, "sandbox").await;
        assert_eq!(results.len(), 1);
        assert!(!results[0].success);
        assert_eq!(results[0].status_code, Some(410));
    }

    #[tokio::test]
    async fn mock_records_calls() {
        let mock = MockPushSender::succeeding();
        let notif = ApnsNotification {
            title: "Test Title".into(),
            body: "B".into(),
            data: Default::default(),
            priority: "high".into(),
            sound: None,
            badge: None,
            thread_id: None,
        };

        mock.send_to_many(&["tok1".into()], &notif, "sandbox").await;
        mock.send_to_many(&["tok2".into(), "tok3".into()], &notif, "sandbox").await;

        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].0, vec!["tok1".to_string()]);
        assert_eq!(calls[0].1, "Test Title");
        assert_eq!(calls[1].0, vec!["tok2".to_string(), "tok3".to_string()]);
    }
}
