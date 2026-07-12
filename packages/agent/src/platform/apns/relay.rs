use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use super::{ApnsBatch, ApnsNotification, ApnsSendResult, PushSender};

type HmacSha256 = Hmac<Sha256>;

pub(super) struct RelaySender {
    client: reqwest::Client,
    relay_url: String,
    relay_secret: String,
}

impl fmt::Debug for RelaySender {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelaySender")
            .field("relay_url", &self.relay_url)
            .field("relay_secret", &"[redacted]")
            .finish_non_exhaustive()
    }
}

#[derive(Serialize)]
struct RelayRequest<'a> {
    device_tokens: &'a [String],
    notification: &'a ApnsNotification,
    environment: &'a str,
    bundle_id: &'a str,
}

#[derive(Deserialize)]
struct RelayResponse {
    results: Vec<ApnsSendResult>,
}

impl RelaySender {
    pub(super) fn from_runtime_env() -> Option<Self> {
        let relay_url = nonempty_env("TRON_RELAY_URL")?;
        let relay_secret = nonempty_env("TRON_RELAY_SECRET")?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .expect("APNs relay HTTP client configuration is valid");
        Some(Self {
            client,
            relay_url,
            relay_secret,
        })
    }

    fn sign(&self, timestamp: u64, body: &str) -> String {
        let mut mac = HmacSha256::new_from_slice(self.relay_secret.as_bytes())
            .expect("HMAC accepts any key length");
        mac.update(format!("{timestamp}.{body}").as_bytes());
        hex::encode(mac.finalize().into_bytes())
    }

    fn error_results(batch: &ApnsBatch, message: &str) -> Vec<ApnsSendResult> {
        batch
            .device_tokens
            .iter()
            .map(|token| ApnsSendResult {
                success: false,
                device_token: token.clone(),
                apns_id: None,
                status_code: None,
                reason: None,
                error: Some(message.to_owned()),
            })
            .collect()
    }
}

#[async_trait::async_trait]
impl PushSender for RelaySender {
    async fn send_to_many(
        &self,
        batch: &ApnsBatch,
        notification: &ApnsNotification,
    ) -> Vec<ApnsSendResult> {
        if batch.device_tokens.is_empty() {
            return Vec::new();
        }
        let body = match serde_json::to_string(&RelayRequest {
            device_tokens: &batch.device_tokens,
            notification,
            environment: &batch.environment,
            bundle_id: &batch.bundle_id,
        }) {
            Ok(body) => body,
            Err(error) => {
                tracing::warn!(error = %error, "APNs relay request serialization failed");
                return Self::error_results(batch, "relay_request_serialization_failed");
            }
        };
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let response = self
            .client
            .post(format!("{}/v1/push", self.relay_url.trim_end_matches('/')))
            .header("Content-Type", "application/json")
            .header("X-Tron-Timestamp", timestamp.to_string())
            .header("X-Tron-Signature", self.sign(timestamp, &body))
            .body(body)
            .send()
            .await;
        let response = match response {
            Ok(response) => response,
            Err(error) => {
                tracing::warn!(error = %error, "APNs relay request failed");
                return Self::error_results(batch, "relay_request_failed");
            }
        };
        let status = response.status();
        if !status.is_success() {
            tracing::warn!(status = %status, "APNs relay rejected request");
            return Self::error_results(batch, &format!("relay_http_{}", status.as_u16()));
        }
        let relay = match response.json::<RelayResponse>().await {
            Ok(relay) => relay,
            Err(error) => {
                tracing::warn!(error = %error, "APNs relay response was invalid");
                return Self::error_results(batch, "relay_response_invalid");
            }
        };
        if relay.results.len() != batch.device_tokens.len() {
            tracing::warn!(
                expected = batch.device_tokens.len(),
                actual = relay.results.len(),
                "APNs relay result count mismatch"
            );
            return Self::error_results(batch, "relay_result_count_mismatch");
        }
        relay.results
    }
}

fn nonempty_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sender() -> RelaySender {
        RelaySender {
            client: reqwest::Client::new(),
            relay_url: "https://relay.invalid".to_owned(),
            relay_secret: "test-secret".to_owned(),
        }
    }

    #[test]
    fn signatures_are_deterministic_and_secret_sensitive() {
        let first = sender();
        let mut second = sender();
        assert_eq!(first.sign(123, "body"), first.sign(123, "body"));
        second.relay_secret = "different-secret".to_owned();
        assert_ne!(first.sign(123, "body"), second.sign(123, "body"));
        assert_eq!(first.sign(123, "body").len(), 64);
    }

    #[test]
    fn debug_output_redacts_secret() {
        let output = format!("{:?}", sender());
        assert!(!output.contains("test-secret"));
        assert!(output.contains("[redacted]"));
    }

    #[test]
    fn relay_wire_contract_uses_deployed_snake_case_shape() {
        let request = RelayRequest {
            device_tokens: &["aabb".to_owned()],
            notification: &ApnsNotification {
                title: "Title".to_owned(),
                body: "Body".to_owned(),
                data: std::collections::HashMap::new(),
                priority: "high".to_owned(),
                sound: Some("default".to_owned()),
                badge: Some(1),
                thread_id: Some("session".to_owned()),
            },
            environment: "sandbox",
            bundle_id: "com.example.beta",
        };
        let encoded = serde_json::to_value(request).expect("serialize request");
        assert!(encoded.get("device_tokens").is_some());
        assert!(encoded.get("bundle_id").is_some());
        assert!(encoded["notification"].get("thread_id").is_some());
        assert!(encoded.get("deviceTokens").is_none());

        let result: ApnsSendResult = serde_json::from_value(serde_json::json!({
            "success": true,
            "device_token": "aabb",
            "apns_id": "delivery-id",
            "status_code": 200,
            "reason": null,
            "error": null
        }))
        .expect("decode deployed relay response");
        assert!(result.success);
        assert_eq!(result.status_code, Some(200));
    }
}
