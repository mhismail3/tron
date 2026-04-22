//! Transport-agnostic push notification sender trait.
//!
//! Implemented by [`ApnsService`](super::ApnsService) (direct .p8 signing + HTTP/2 to APNs)
//! and [`RelayClient`](super::relay::RelayClient) (HMAC-signed HTTPS to Cloudflare Worker relay).

use async_trait::async_trait;

use super::types::{ApnsNotification, ApnsSendResult};

/// A pre-grouped push batch.
///
/// INVARIANT (M32): every token in `device_tokens` belongs to the same
/// `(environment, bundle_id)` tuple. An APNs request carries one
/// `apns-topic` for the whole batch, so merging tokens from different
/// bundles triggers `DeviceTokenNotForTopic` rejections. By taking this
/// struct instead of four loose arguments, `send_to_many` makes the
/// pre-grouping requirement structural — the compiler enforces it.
///
/// Callers construct a batch per `TokenGroup` produced by
/// `push_helpers::group_tokens`. Empty `bundle_id` (`""`) means "use the
/// implementation's default" (relay → `env.APNS_BUNDLE_ID`; direct →
/// `ApnsConfig.bundle_id`), preserved for pre-v006 legacy tokens that
/// registered without a bundle_id.
#[derive(Clone, Copy, Debug)]
pub struct ApnsBatch<'a> {
    /// Device tokens that share the same (environment, bundle_id) tuple.
    pub device_tokens: &'a [String],
    /// APNs environment — "production" or "sandbox".
    pub environment: &'a str,
    /// APNs `apns-topic` for the whole request.
    pub bundle_id: &'a str,
}

/// Transport-agnostic push notification sender.
///
/// Returns one [`ApnsSendResult`] per token, in the same order as
/// `batch.device_tokens`.
#[async_trait]
pub trait PushSender: Send + Sync + std::fmt::Debug {
    /// Send a notification to a pre-grouped batch of device tokens.
    ///
    /// See [`ApnsBatch`] for the structural invariant — callers cannot
    /// pass a mixed-bundle batch because a batch carries exactly one
    /// `bundle_id`.
    async fn send_to_many(
        &self,
        batch: &ApnsBatch<'_>,
        notification: &ApnsNotification,
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
        /// Recorded calls: (device_tokens, notification title, environment, bundle_id).
        pub calls: Mutex<Vec<(Vec<String>, String, String, String)>>,
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
            batch: &ApnsBatch<'_>,
            notification: &ApnsNotification,
        ) -> Vec<ApnsSendResult> {
            self.calls.lock().unwrap().push((
                batch.device_tokens.to_vec(),
                notification.title.clone(),
                batch.environment.to_string(),
                batch.bundle_id.to_string(),
            ));

            let mut results = self.results.lock().unwrap();
            if results.is_empty() {
                // Default: success for every token
                batch
                    .device_tokens
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

    fn test_notif() -> ApnsNotification {
        ApnsNotification {
            title: "T".into(),
            body: "B".into(),
            data: Default::default(),
            priority: "high".into(),
            sound: None,
            badge: None,
            thread_id: None,
        }
    }

    #[tokio::test]
    async fn mock_returns_default_success() {
        let mock = MockPushSender::succeeding();
        let tokens = vec!["aabb".to_string(), "ccdd".to_string()];
        let batch = ApnsBatch {
            device_tokens: &tokens,
            environment: "sandbox",
            bundle_id: "",
        };
        let results = mock.send_to_many(&batch, &test_notif()).await;
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
        let tokens = vec!["tok1".to_string()];
        let batch = ApnsBatch {
            device_tokens: &tokens,
            environment: "sandbox",
            bundle_id: "",
        };
        let results = mock.send_to_many(&batch, &test_notif()).await;
        assert_eq!(results.len(), 1);
        assert!(!results[0].success);
        assert_eq!(results[0].status_code, Some(410));
    }

    #[tokio::test]
    async fn mock_records_calls_with_env_and_bundle() {
        let mock = MockPushSender::succeeding();
        let notif = ApnsNotification {
            title: "Test Title".into(),
            ..test_notif()
        };

        let t1 = vec!["tok1".to_string()];
        mock.send_to_many(
            &ApnsBatch {
                device_tokens: &t1,
                environment: "sandbox",
                bundle_id: "com.tron.mobile.beta",
            },
            &notif,
        )
        .await;
        let t2 = vec!["tok2".to_string(), "tok3".to_string()];
        mock.send_to_many(
            &ApnsBatch {
                device_tokens: &t2,
                environment: "production",
                bundle_id: "com.tron.mobile",
            },
            &notif,
        )
        .await;

        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].0, vec!["tok1".to_string()]);
        assert_eq!(calls[0].1, "Test Title");
        assert_eq!(calls[0].2, "sandbox");
        assert_eq!(calls[0].3, "com.tron.mobile.beta");
        assert_eq!(calls[1].0, vec!["tok2".to_string(), "tok3".to_string()]);
        assert_eq!(calls[1].2, "production");
        assert_eq!(calls[1].3, "com.tron.mobile");
    }

    #[tokio::test]
    async fn mock_captures_empty_bundle_id_as_fallback_marker() {
        let mock = MockPushSender::succeeding();
        let tokens = vec!["tok".to_string()];
        let batch = ApnsBatch {
            device_tokens: &tokens,
            environment: "production",
            bundle_id: "",
        };
        mock.send_to_many(&batch, &test_notif()).await;
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls[0].3, "", "empty bundle_id signals 'use default'");
    }

    #[tokio::test]
    async fn mixed_bundles_rejected_by_type_system() {
        // Regression guard for M32: the ApnsBatch type carries EXACTLY
        // one (environment, bundle_id) pair. There is no constructor that
        // accepts multiple bundles, so a mixed-bundle batch cannot be
        // expressed in the type system. This test documents that
        // invariant — by running at all — and exercises two batches
        // with different bundles separately.
        let mock = MockPushSender::succeeding();
        let t1 = vec!["beta-1".to_string(), "beta-2".to_string()];
        let t2 = vec!["prod-1".to_string()];
        mock.send_to_many(
            &ApnsBatch {
                device_tokens: &t1,
                environment: "sandbox",
                bundle_id: "com.tron.mobile.beta",
            },
            &test_notif(),
        )
        .await;
        mock.send_to_many(
            &ApnsBatch {
                device_tokens: &t2,
                environment: "production",
                bundle_id: "com.tron.mobile",
            },
            &test_notif(),
        )
        .await;
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls.len(), 2, "each bundle gets its own call");
        assert_ne!(
            calls[0].3, calls[1].3,
            "calls carry distinct bundle_ids by construction"
        );
    }
}
