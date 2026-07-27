//! Closed HMAC-authenticated Cloudflare relay client.
//!
//! The relay is a provider transport, not a worker. This client serializes one
//! fixed alert or background-refresh request per durable engine target. It
//! never accepts a worker-authored APNs dictionary and never includes relay
//! credentials in errors or evidence.

use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{Duration, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::domains::auth::credentials::NotificationRelayCredentials;
use crate::domains::worker_kernel::persistence::{
    NotificationDispatchOutcome, NotificationRefreshDispatch, NotificationTargetDispatch,
};

const RELAY_PATH: &str = "/v2/notification";
const RETRY_BASE_SECONDS: i64 = 30;
const RETRY_MAX_SECONDS: i64 = 900;

type HmacSha256 = Hmac<Sha256>;

#[derive(Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
enum RelayRequest<'a> {
    #[serde(rename = "alert")]
    Alert {
        request_id: &'a str,
        device_token: &'a str,
        topic: &'a str,
        environment: &'a str,
        expires_at: &'a str,
        collapse_id: &'a str,
        title: &'a str,
        body: &'a str,
        thread_key: Option<&'a str>,
        category: &'static str,
        badge: u32,
        server_id: &'a str,
        delivery_id: &'a str,
    },
    #[serde(rename = "background")]
    Background {
        request_id: &'a str,
        device_token: &'a str,
        topic: &'a str,
        environment: &'a str,
        expires_at: String,
        collapse_id: String,
        badge: u32,
        server_id: &'a str,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RelayResponse {
    status: RelayStatus,
    #[serde(default)]
    apns_id: Option<String>,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    retry_after_seconds: Option<u64>,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RelayStatus {
    AcceptedByApns,
    Retryable,
    PermanentFailure,
    InvalidToken,
    Ambiguous,
}

#[derive(Clone)]
pub(super) struct RelayClient {
    http: reqwest::Client,
}

impl RelayClient {
    pub(super) fn new() -> Result<Self, String> {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|error| format!("build notification relay client: {error}"))?;
        Ok(Self { http })
    }

    pub(super) async fn send_alert(
        &self,
        credentials: &NotificationRelayCredentials,
        target: &NotificationTargetDispatch,
    ) -> NotificationDispatchOutcome {
        let category = if target.actions.is_empty() {
            "TRON_NOTIFICATION"
        } else {
            "TRON_REMINDER"
        };
        self.send(
            credentials,
            &target.target_id,
            RelayRequest::Alert {
                request_id: &target.target_id,
                device_token: &target.token,
                topic: &target.topic,
                environment: target.environment.as_str(),
                expires_at: &target.expires_at,
                collapse_id: &target.delivery_id,
                title: &target.title,
                body: &target.body,
                thread_key: target.thread_key.as_deref(),
                category,
                badge: target.unread_count,
                server_id: &target.client_server_id,
                delivery_id: &target.delivery_id,
            },
            target.attempt_number,
        )
        .await
    }

    pub(super) async fn send_refresh(
        &self,
        credentials: &NotificationRelayCredentials,
        refresh: &NotificationRefreshDispatch,
    ) -> NotificationDispatchOutcome {
        self.send(
            credentials,
            &refresh.refresh_id,
            RelayRequest::Background {
                request_id: &refresh.refresh_id,
                device_token: &refresh.token,
                topic: &refresh.topic,
                environment: refresh.environment.as_str(),
                expires_at: (Utc::now() + Duration::hours(1)).to_rfc3339(),
                collapse_id: format!("state-{}", refresh.installation_id),
                badge: refresh.unread_count,
                server_id: &refresh.client_server_id,
            },
            refresh.attempt_number,
        )
        .await
    }

    async fn send(
        &self,
        credentials: &NotificationRelayCredentials,
        request_id: &str,
        request: RelayRequest<'_>,
        attempt_number: u32,
    ) -> NotificationDispatchOutcome {
        if credentials.validate().is_err() {
            return blocked("notification_relay_credentials_invalid");
        }
        let body = match serde_json::to_vec(&request) {
            Ok(body) => body,
            Err(_) => {
                return NotificationDispatchOutcome::Permanent {
                    code: "relay_payload_encoding_failed".to_owned(),
                    invalidate_token: false,
                };
            }
        };
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |duration| duration.as_secs());
        let signature = relay_signature(&credentials.secret, timestamp, request_id, &body);
        let endpoint = format!("{}{RELAY_PATH}", credentials.url.trim_end_matches('/'));
        let response = self
            .http
            .post(endpoint)
            .header("content-type", "application/json")
            .header("x-tron-timestamp", timestamp.to_string())
            .header("x-tron-request-id", request_id)
            .header("x-tron-signature", signature)
            .body(body)
            .send()
            .await;
        let response = match response {
            Ok(response) => response,
            Err(_) => {
                return NotificationDispatchOutcome::Retryable {
                    code: "relay_transport_error".to_owned(),
                    retry_at: retry_at(attempt_number, None),
                };
            }
        };
        let status = response.status();
        if matches!(status.as_u16(), 401 | 403) {
            return blocked("notification_relay_auth_failed");
        }
        if status.as_u16() == 404 {
            return blocked("notification_relay_contract_unavailable");
        }
        if status.as_u16() == 429 || status.is_server_error() {
            return NotificationDispatchOutcome::Retryable {
                code: format!("relay_http_{}", status.as_u16()),
                retry_at: retry_at(attempt_number, None),
            };
        }
        if !status.is_success() {
            return NotificationDispatchOutcome::Permanent {
                code: format!("relay_http_{}", status.as_u16()),
                invalidate_token: false,
            };
        }
        let response = match response.json::<RelayResponse>().await {
            Ok(response) => response,
            Err(_) => {
                return NotificationDispatchOutcome::Retryable {
                    code: "relay_response_invalid".to_owned(),
                    retry_at: retry_at(attempt_number, None),
                };
            }
        };
        let reason = response
            .reason
            .as_deref()
            .map(sanitize_reason)
            .filter(|reason| !reason.is_empty());
        match response.status {
            RelayStatus::AcceptedByApns => NotificationDispatchOutcome::Accepted {
                apns_id: response
                    .apns_id
                    .unwrap_or_else(|| stable_provider_id(request_id)),
            },
            RelayStatus::Retryable => NotificationDispatchOutcome::Retryable {
                code: reason.unwrap_or_else(|| "relay_retryable".to_owned()),
                retry_at: retry_at(attempt_number, response.retry_after_seconds),
            },
            RelayStatus::PermanentFailure => NotificationDispatchOutcome::Permanent {
                code: reason.unwrap_or_else(|| "relay_permanent_failure".to_owned()),
                invalidate_token: false,
            },
            RelayStatus::InvalidToken => NotificationDispatchOutcome::Permanent {
                code: reason.unwrap_or_else(|| "relay_invalid_device_token".to_owned()),
                invalidate_token: true,
            },
            RelayStatus::Ambiguous => NotificationDispatchOutcome::Blocked {
                code: "relay_delivery_ambiguous".to_owned(),
                retry_at: (Utc::now() + Duration::hours(1)).to_rfc3339(),
            },
        }
    }
}

fn blocked(code: &str) -> NotificationDispatchOutcome {
    NotificationDispatchOutcome::Blocked {
        code: code.to_owned(),
        retry_at: (Utc::now() + Duration::minutes(5)).to_rfc3339(),
    }
}

fn retry_at(attempt_number: u32, retry_after_seconds: Option<u64>) -> String {
    let requested = retry_after_seconds
        .and_then(|seconds| i64::try_from(seconds).ok())
        .map(|seconds| seconds.clamp(RETRY_BASE_SECONDS, RETRY_MAX_SECONDS));
    let exponent = attempt_number.saturating_sub(1).min(10);
    let exponential = RETRY_BASE_SECONDS
        .saturating_mul(1_i64 << exponent)
        .min(RETRY_MAX_SECONDS);
    let jitter = i64::from(rand::random::<u8>() % 16);
    (Utc::now() + Duration::seconds(requested.unwrap_or(exponential) + jitter)).to_rfc3339()
}

fn relay_signature(secret: &str, timestamp: u64, request_id: &str, body: &[u8]) -> String {
    let body_hash = hex::encode(Sha256::digest(body));
    let canonical = format!("POST\n{RELAY_PATH}\n{timestamp}\n{request_id}\n{body_hash}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key size");
    mac.update(canonical.as_bytes());
    hex::encode(mac.finalize().into_bytes())
}

fn stable_provider_id(value: &str) -> String {
    let digest = hex::encode(Sha256::digest(value.as_bytes()));
    format!(
        "{}-{}-{}-{}-{}",
        &digest[0..8],
        &digest[8..12],
        &digest[12..16],
        &digest[16..20],
        &digest[20..32]
    )
}

fn sanitize_reason(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || "_-".contains(*character))
        .take(96)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_signature_covers_path_timestamp_request_and_body() {
        let first = relay_signature("0123456789abcdef", 10, "request-1", br#"{"a":1}"#);
        assert_eq!(first.len(), 64);
        assert_ne!(
            first,
            relay_signature("0123456789abcdef", 10, "request-2", br#"{"a":1}"#)
        );
        assert_ne!(
            first,
            relay_signature("0123456789abcdef", 11, "request-1", br#"{"a":1}"#)
        );
    }

    #[test]
    fn relay_request_is_closed_and_contains_no_arbitrary_payload_dictionary() {
        let request = RelayRequest::Alert {
            request_id: "target-1",
            device_token: "device-token",
            topic: "com.tron.mobile",
            environment: "production",
            expires_at: "2026-07-27T12:00:00Z",
            collapse_id: "delivery-1",
            title: "Title",
            body: "Body",
            thread_key: Some("thread"),
            category: "TRON_REMINDER",
            badge: 1,
            server_id: "server-1",
            delivery_id: "delivery-1",
        };
        let value = serde_json::to_value(request).unwrap();
        assert!(value.get("payload").is_none());
        assert!(value.get("data").is_none());
        assert!(value.get("sound").is_none());
        assert_eq!(value["kind"], "alert");
        assert_eq!(value["requestId"], "target-1");
        assert_eq!(value["deviceToken"], "device-token");
        assert_eq!(value["expiresAt"], "2026-07-27T12:00:00Z");
        assert_eq!(value["collapseId"], "delivery-1");
        assert_eq!(value["threadKey"], "thread");
        assert_eq!(value["serverId"], "server-1");
        assert_eq!(value["deliveryId"], "delivery-1");
        for forbidden_snake_case_key in [
            "request_id",
            "device_token",
            "expires_at",
            "collapse_id",
            "thread_key",
            "server_id",
            "delivery_id",
        ] {
            assert!(value.get(forbidden_snake_case_key).is_none());
        }
    }

    #[test]
    fn provider_ids_are_stable_uuid_shaped_and_do_not_echo_target_ids() {
        let first = stable_provider_id("notification_target_private");
        assert_eq!(first, stable_provider_id("notification_target_private"));
        assert_eq!(first.len(), 36);
        assert!(!first.contains("private"));
    }
}
