//! Relay client — HMAC-signed HTTPS transport to Cloudflare Worker relay.
//!
//! The relay holds the `.p8` signing key and forwards notifications to APNs.
//! This client only needs the relay URL and a shared HMAC secret.

use std::time::{SystemTime, UNIX_EPOCH};

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use tracing::{debug, warn};

use super::config::RelayConfig;
use super::sender::{ApnsBatch, PushSender};
use super::types::{ApnsNotification, ApnsSendResult};

type HmacSha256 = Hmac<Sha256>;

/// Relay client for sending push notifications via a Cloudflare Worker.
///
/// Environment and bundle ID are passed per request (derived from each
/// device token's registered values) so this struct carries neither.
#[derive(Debug)]
pub struct RelayClient {
    client: reqwest::Client,
    relay_url: String,
    relay_secret: String,
}

/// Request body sent to the relay.
#[derive(Debug, Serialize)]
struct RelayRequest<'a> {
    device_tokens: &'a [String],
    notification: &'a ApnsNotification,
    environment: &'a str,
    /// APNs `apns-topic` for every token in this request. Always present
    /// — the `device_tokens.bundle_id` column is NOT NULL (v001 schema),
    /// and upstream callers compose `(environment, bundle_id)` groups so
    /// all tokens in one request share one topic.
    bundle_id: &'a str,
}

/// Response body from the relay.
#[derive(Debug, Deserialize)]
struct RelayResponse {
    results: Vec<RelayResult>,
}

/// Per-device result from the relay.
#[derive(Debug, Deserialize)]
struct RelayResult {
    device_token: String,
    success: bool,
    apns_id: Option<String>,
    status_code: Option<u16>,
    reason: Option<String>,
    error: Option<String>,
}

impl From<RelayResult> for ApnsSendResult {
    fn from(r: RelayResult) -> Self {
        Self {
            success: r.success,
            device_token: r.device_token,
            apns_id: r.apns_id,
            status_code: r.status_code,
            reason: r.reason,
            error: r.error,
        }
    }
}

impl RelayClient {
    /// Create a new relay client from config.
    pub fn new(config: RelayConfig) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("failed to build HTTP client for relay");

        Self {
            client,
            relay_url: config.relay_url,
            relay_secret: config.relay_secret,
        }
    }

    /// Compute HMAC-SHA256 signature: `hex(HMAC(secret, "{timestamp}.{body}"))`.
    fn sign(&self, timestamp: u64, body: &str) -> String {
        let message = format!("{timestamp}.{body}");
        let mut mac =
            HmacSha256::new_from_slice(self.relay_secret.as_bytes()).expect("HMAC accepts any key size");
        mac.update(message.as_bytes());
        hex::encode(mac.finalize().into_bytes())
    }

    /// Build error results for every token (used when relay is unreachable).
    fn error_results(device_tokens: &[String], error: &str) -> Vec<ApnsSendResult> {
        device_tokens
            .iter()
            .map(|t| ApnsSendResult {
                success: false,
                device_token: t.clone(),
                apns_id: None,
                status_code: None,
                reason: None,
                error: Some(error.to_string()),
            })
            .collect()
    }
}

#[async_trait::async_trait]
impl PushSender for RelayClient {
    async fn send_to_many(
        &self,
        batch: &ApnsBatch<'_>,
        notification: &ApnsNotification,
    ) -> Vec<ApnsSendResult> {
        let device_tokens = batch.device_tokens;
        if device_tokens.is_empty() {
            return Vec::new();
        }

        let request = RelayRequest {
            device_tokens,
            notification,
            environment: batch.environment,
            bundle_id: batch.bundle_id,
        };

        let body = match serde_json::to_string(&request) {
            Ok(b) => b,
            Err(e) => {
                warn!(error = %e, "failed to serialize relay request");
                return Self::error_results(device_tokens, &format!("serialization error: {e}"));
            }
        };

        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let signature = self.sign(timestamp, &body);
        let url = format!("{}/v1/push", self.relay_url.trim_end_matches('/'));

        debug!(
            url = %url,
            device_count = device_tokens.len(),
            environment = %batch.environment,
            bundle_id = %batch.bundle_id,
            "sending via relay"
        );

        let response = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .header("X-Tron-Timestamp", timestamp.to_string())
            .header("X-Tron-Signature", &signature)
            .body(body)
            .send()
            .await;

        let response = match response {
            Ok(r) => r,
            Err(e) => {
                if e.is_timeout() {
                    warn!("relay request timed out");
                    return Self::error_results(device_tokens, "relay timeout");
                }
                warn!(error = %e, "relay request failed");
                return Self::error_results(device_tokens, &format!("relay error: {e}"));
            }
        };

        let status = response.status();
        if status == reqwest::StatusCode::UNAUTHORIZED {
            warn!("relay returned 401 — check TRON_RELAY_SECRET matches the Worker secret");
            return Self::error_results(device_tokens, "relay: invalid signature (check TRON_RELAY_SECRET)");
        }
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            warn!("relay returned 429 — rate limited");
            return Self::error_results(device_tokens, "relay: rate limited");
        }
        if status.is_server_error() {
            let body_text = response.text().await.unwrap_or_default();
            warn!(status = %status, body = %body_text, "relay returned server error");
            return Self::error_results(device_tokens, &format!("relay: {status}"));
        }
        if !status.is_success() {
            let body_text = response.text().await.unwrap_or_default();
            warn!(status = %status, body = %body_text, "relay returned unexpected status");
            return Self::error_results(device_tokens, &format!("relay: {status} — {body_text}"));
        }

        // Parse successful response
        let body_text = match response.text().await {
            Ok(t) => t,
            Err(e) => {
                warn!(error = %e, "failed to read relay response body");
                return Self::error_results(device_tokens, &format!("relay response read error: {e}"));
            }
        };

        let relay_response: RelayResponse = match serde_json::from_str(&body_text) {
            Ok(r) => r,
            Err(e) => {
                warn!(error = %e, body = %body_text, "relay returned malformed JSON");
                return Self::error_results(device_tokens, &format!("relay: malformed response: {e}"));
            }
        };

        let mut results: Vec<ApnsSendResult> =
            relay_response.results.into_iter().map(Into::into).collect();

        // Handle result count mismatch
        if results.len() != device_tokens.len() {
            warn!(
                expected = device_tokens.len(),
                got = results.len(),
                "relay returned different number of results than tokens sent"
            );
            // Pad with errors if too few, truncate if too many
            results.resize_with(device_tokens.len(), || ApnsSendResult {
                success: false,
                device_token: String::new(),
                apns_id: None,
                status_code: None,
                reason: None,
                error: Some("relay: missing result for this token".into()),
            });
        }

        results
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_signature_deterministic() {
        let client = RelayClient {
            client: reqwest::Client::new(),
            relay_url: "https://example.com".into(),
            relay_secret: "test-secret".into(),
        };

        let sig1 = client.sign(1000000, r#"{"test":"data"}"#);
        let sig2 = client.sign(1000000, r#"{"test":"data"}"#);
        assert_eq!(sig1, sig2);
        // HMAC output is 64 hex chars (32 bytes)
        assert_eq!(sig1.len(), 64);
    }

    #[test]
    fn hmac_changes_with_timestamp() {
        let client = RelayClient {
            client: reqwest::Client::new(),
            relay_url: "https://example.com".into(),
            relay_secret: "test-secret".into(),
        };

        let sig1 = client.sign(1000000, "body");
        let sig2 = client.sign(1000001, "body");
        assert_ne!(sig1, sig2);
    }

    #[test]
    fn hmac_changes_with_body() {
        let client = RelayClient {
            client: reqwest::Client::new(),
            relay_url: "https://example.com".into(),
            relay_secret: "test-secret".into(),
        };

        let sig1 = client.sign(1000000, "body1");
        let sig2 = client.sign(1000000, "body2");
        assert_ne!(sig1, sig2);
    }

    #[test]
    fn hmac_changes_with_secret() {
        let c1 = RelayClient {
            client: reqwest::Client::new(),
            relay_url: "https://example.com".into(),
            relay_secret: "secret-a".into(),
        };
        let c2 = RelayClient {
            client: reqwest::Client::new(),
            relay_url: "https://example.com".into(),
            relay_secret: "secret-b".into(),
        };

        assert_ne!(c1.sign(1000000, "body"), c2.sign(1000000, "body"));
    }

    #[test]
    fn error_results_per_token() {
        let results = RelayClient::error_results(
            &["tok1".into(), "tok2".into()],
            "relay timeout",
        );
        assert_eq!(results.len(), 2);
        assert!(!results[0].success);
        assert!(!results[1].success);
        assert_eq!(results[0].device_token, "tok1");
        assert_eq!(results[1].device_token, "tok2");
        assert_eq!(results[0].error.as_deref(), Some("relay timeout"));
    }

    #[tokio::test]
    async fn empty_tokens_returns_empty_vec() {
        let client = RelayClient {
            client: reqwest::Client::new(),
            relay_url: "https://example.com".into(),
            relay_secret: "test".into(),
        };
        let notif = ApnsNotification {
            title: "T".into(),
            body: "B".into(),
            data: Default::default(),
            priority: "high".into(),
            sound: None,
            badge: None,
            thread_id: None,
        };

        let tokens: Vec<String> = Vec::new();
        let batch = ApnsBatch {
            device_tokens: &tokens,
            environment: "sandbox",
            bundle_id: "com.tron.mobile",
        };
        let results = client.send_to_many(&batch, &notif).await;
        assert!(results.is_empty());
    }

    #[test]
    fn request_serialization_matches_api_contract() {
        let tokens = vec!["aabbccdd".to_string()];
        let notification = ApnsNotification {
            title: "Test".into(),
            body: "Hello".into(),
            data: Default::default(),
            priority: "high".into(),
            sound: Some("default".into()),
            badge: Some(1),
            thread_id: None,
        };
        let request = RelayRequest {
            device_tokens: &tokens,
            notification: &notification,
            environment: "production",
            bundle_id: "com.tron.mobile",
        };

        let json: serde_json::Value = serde_json::to_value(&request).unwrap();
        assert!(json["device_tokens"].is_array());
        assert_eq!(json["device_tokens"][0], "aabbccdd");
        assert_eq!(json["notification"]["title"], "Test");
        assert_eq!(json["notification"]["body"], "Hello");
        assert_eq!(json["environment"], "production");
        assert_eq!(json["bundle_id"], "com.tron.mobile");
    }

    #[test]
    fn request_serialization_always_includes_bundle_id() {
        // Post-R5 invariant: `device_tokens.bundle_id` is NOT NULL, so the
        // wire ALWAYS carries a concrete `bundle_id`. The relay worker
        // uses it verbatim as `apns-topic` and no longer has a fallback
        // path for a missing value.
        let tokens = vec!["aa".to_string()];
        let notification = ApnsNotification {
            title: "T".into(),
            body: "B".into(),
            data: Default::default(),
            priority: "high".into(),
            sound: None,
            badge: None,
            thread_id: None,
        };
        let request = RelayRequest {
            device_tokens: &tokens,
            notification: &notification,
            environment: "sandbox",
            bundle_id: "com.tron.mobile.beta",
        };

        let json = serde_json::to_string(&request).unwrap();
        assert!(
            json.contains("\"bundle_id\":\"com.tron.mobile.beta\""),
            "bundle_id must always serialize: {json}"
        );
    }

    #[test]
    fn relay_result_converts_to_apns_result() {
        let relay_result = RelayResult {
            device_token: "aabb".into(),
            success: true,
            apns_id: Some("uuid".into()),
            status_code: Some(200),
            reason: None,
            error: None,
        };
        let apns: ApnsSendResult = relay_result.into();
        assert!(apns.success);
        assert_eq!(apns.device_token, "aabb");
        assert_eq!(apns.apns_id.as_deref(), Some("uuid"));
    }

    #[test]
    fn relay_result_410_converts_correctly() {
        let relay_result = RelayResult {
            device_token: "ccdd".into(),
            success: false,
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".into()),
            error: None,
        };
        let apns: ApnsSendResult = relay_result.into();
        assert!(!apns.success);
        assert_eq!(apns.status_code, Some(410));
        assert_eq!(apns.reason.as_deref(), Some("Unregistered"));
    }
}
