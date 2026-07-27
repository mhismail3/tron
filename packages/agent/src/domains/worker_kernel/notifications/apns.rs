//! Direct APNs HTTP/2 provider transport.
//!
//! A successful response records only APNs acceptance. Provider credentials
//! are reloaded from the strict auth owner; the signed ES256 token is cached
//! for at most fifty minutes and never persisted.

use std::sync::Arc;
use std::time::Duration as StdDuration;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration, Utc};
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use p256::pkcs8::DecodePrivateKey;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use crate::domains::auth::credentials::{ApplePushCredentials, load_apple_push_credentials};
use crate::domains::worker_kernel::notifications::{
    MAX_APNS_PAYLOAD_BYTES, NotificationEnvironment,
};
use crate::domains::worker_kernel::persistence::{
    NotificationDispatchOutcome, NotificationRefreshDispatch, NotificationTargetDispatch,
};

const PROVIDER_TOKEN_CACHE_MINUTES: i64 = 50;
const RETRY_BASE_SECONDS: i64 = 30;
const RETRY_MAX_SECONDS: i64 = 900;

#[derive(Clone)]
struct CachedProviderToken {
    fingerprint: String,
    token: String,
    expires_at: DateTime<Utc>,
}

#[derive(Clone)]
pub(in crate::domains::worker_kernel) struct ApnsClient {
    http: reqwest::Client,
    auth_path: std::path::PathBuf,
    provider_token: Arc<Mutex<Option<CachedProviderToken>>>,
}

impl ApnsClient {
    pub(in crate::domains::worker_kernel) fn new(home: &std::path::Path) -> Result<Self, String> {
        let http = reqwest::Client::builder()
            .http2_adaptive_window(true)
            .pool_idle_timeout(StdDuration::from_secs(300))
            .timeout(StdDuration::from_secs(30))
            .build()
            .map_err(|error| format!("build APNs HTTP/2 client: {error}"))?;
        Ok(Self {
            http,
            auth_path: home.join("auth.json"),
            provider_token: Arc::new(Mutex::new(None)),
        })
    }

    pub(in crate::domains::worker_kernel) async fn send_alert(
        &self,
        target: &NotificationTargetDispatch,
    ) -> NotificationDispatchOutcome {
        let category = if target.actions.is_empty() {
            "TRON_NOTIFICATION"
        } else {
            "TRON_REMINDER"
        };
        let mut aps = json!({
            "alert":{"title":target.title,"body":target.body},
            "sound":"default",
            "category":category,
            "badge":target.unread_count,
        });
        if let Some(thread_key) = target.thread_key.as_deref() {
            aps["thread-id"] = Value::String(thread_key.to_owned());
        }
        let payload = json!({
            "aps":aps,
            "tron":{
                "kind":"notification",
                "serverId":target.client_server_id,
                "deliveryId":target.delivery_id,
            }
        });
        self.send(
            &target.token,
            &target.topic,
            target.environment,
            &target.target_id,
            &target.delivery_id,
            &target.expires_at,
            "alert",
            "10",
            payload,
            target.attempt_number,
        )
        .await
    }

    pub(in crate::domains::worker_kernel) async fn send_refresh(
        &self,
        refresh: &NotificationRefreshDispatch,
    ) -> NotificationDispatchOutcome {
        let collapse_id = format!("state-{}", refresh.installation_id);
        let payload = json!({
            "aps":{"content-available":1,"badge":refresh.unread_count},
            "tron":{
                "kind":"notification_state_refresh",
                "serverId":refresh.client_server_id,
            }
        });
        self.send(
            &refresh.token,
            &refresh.topic,
            refresh.environment,
            &refresh.refresh_id,
            &collapse_id,
            &(Utc::now() + Duration::hours(1)).to_rfc3339(),
            "background",
            "5",
            payload,
            refresh.attempt_number,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn send(
        &self,
        device_token: &str,
        topic: &str,
        environment: NotificationEnvironment,
        provider_request_id: &str,
        collapse_id: &str,
        expires_at: &str,
        push_type: &str,
        priority: &str,
        payload: Value,
        attempt_number: u32,
    ) -> NotificationDispatchOutcome {
        let body = match serde_json::to_vec(&payload) {
            Ok(body) if body.len() < MAX_APNS_PAYLOAD_BYTES => body,
            Ok(_) => {
                return NotificationDispatchOutcome::Permanent {
                    code: "payload_too_large".to_owned(),
                    invalidate_token: false,
                };
            }
            Err(_) => {
                return NotificationDispatchOutcome::Permanent {
                    code: "payload_encoding_failed".to_owned(),
                    invalidate_token: false,
                };
            }
        };
        let provider_token = match self.provider_token().await {
            Ok(token) => token,
            Err(code) => {
                return NotificationDispatchOutcome::Blocked {
                    code,
                    retry_at: (Utc::now() + Duration::minutes(5)).to_rfc3339(),
                };
            }
        };
        let endpoint = apns_endpoint(environment);
        let apns_id = stable_provider_id(provider_request_id);
        let expiration = DateTime::parse_from_rfc3339(expires_at)
            .map(|value| value.timestamp().max(0))
            .unwrap_or_default();
        let response = self
            .http
            .post(format!("{endpoint}/3/device/{device_token}"))
            .bearer_auth(provider_token)
            .header("apns-id", &apns_id)
            .header("apns-topic", topic)
            .header("apns-push-type", push_type)
            .header("apns-priority", priority)
            .header("apns-expiration", expiration.to_string())
            .header("apns-collapse-id", truncate_collapse_id(collapse_id))
            .body(body)
            .send()
            .await;
        let response = match response {
            Ok(response) => response,
            Err(_) => {
                return NotificationDispatchOutcome::Retryable {
                    code: "transport_error".to_owned(),
                    retry_at: retry_at(attempt_number),
                };
            }
        };
        let status = response.status();
        if status.is_success() {
            let response_apns_id = response
                .headers()
                .get("apns-id")
                .and_then(|value| value.to_str().ok())
                .map_or(apns_id, ToOwned::to_owned);
            return NotificationDispatchOutcome::Accepted {
                apns_id: response_apns_id,
            };
        }
        let reason = response
            .json::<Value>()
            .await
            .ok()
            .and_then(|value| {
                value
                    .get("reason")
                    .and_then(Value::as_str)
                    .map(sanitize_reason)
            })
            .unwrap_or_else(|| format!("http_{}", status.as_u16()));
        match classify_failure(status.as_u16(), &reason) {
            ApnsFailureDisposition::Retryable => NotificationDispatchOutcome::Retryable {
                code: reason,
                retry_at: retry_at(attempt_number),
            },
            ApnsFailureDisposition::Permanent { invalidate_token } => {
                NotificationDispatchOutcome::Permanent {
                    code: reason,
                    invalidate_token,
                }
            }
        }
    }

    async fn provider_token(&self) -> Result<String, String> {
        let credentials = load_apple_push_credentials(&self.auth_path)
            .map_err(|_| "apns_credentials_invalid".to_owned())?
            .ok_or_else(|| "apns_credentials_missing".to_owned())?;
        credentials
            .validate()
            .map_err(|_| "apns_credentials_invalid".to_owned())?;
        let fingerprint = credential_fingerprint(&credentials);
        let now = Utc::now();
        let mut cache = self.provider_token.lock().await;
        if let Some(cached) = cache.as_ref() {
            if cached.fingerprint == fingerprint && cached.expires_at > now {
                return Ok(cached.token.clone());
            }
        }
        let token = sign_provider_token(&credentials, now)
            .map_err(|_| "apns_credentials_invalid".to_owned())?;
        *cache = Some(CachedProviderToken {
            fingerprint,
            token: token.clone(),
            expires_at: now + Duration::minutes(PROVIDER_TOKEN_CACHE_MINUTES),
        });
        Ok(token)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ApnsFailureDisposition {
    Retryable,
    Permanent { invalidate_token: bool },
}

fn apns_endpoint(environment: NotificationEnvironment) -> &'static str {
    match environment {
        NotificationEnvironment::Sandbox => "https://api.sandbox.push.apple.com",
        NotificationEnvironment::Production => "https://api.push.apple.com",
    }
}

fn classify_failure(status: u16, reason: &str) -> ApnsFailureDisposition {
    if status == 429 || status >= 500 {
        return ApnsFailureDisposition::Retryable;
    }
    ApnsFailureDisposition::Permanent {
        invalidate_token: matches!(
            reason,
            "BadDeviceToken" | "DeviceTokenNotForTopic" | "Unregistered"
        ),
    }
}

pub(crate) fn validate_private_key(private_key: &str) -> Result<(), String> {
    SigningKey::from_pkcs8_pem(private_key.trim())
        .map(|_| ())
        .map_err(|error| format!("APNs private key is not a valid ES256 PKCS#8 key: {error}"))
}

fn sign_provider_token(
    credentials: &ApplePushCredentials,
    issued_at: DateTime<Utc>,
) -> Result<String, String> {
    let header = URL_SAFE_NO_PAD.encode(
        serde_json::to_vec(&json!({"alg":"ES256","kid":credentials.key_id}))
            .map_err(|error| format!("encode APNs JWT header: {error}"))?,
    );
    let claims = URL_SAFE_NO_PAD.encode(
        serde_json::to_vec(&json!({"iss":credentials.team_id,"iat":issued_at.timestamp()}))
            .map_err(|error| format!("encode APNs JWT claims: {error}"))?,
    );
    let signing_input = format!("{header}.{claims}");
    let signing_key = SigningKey::from_pkcs8_pem(credentials.private_key.trim())
        .map_err(|error| format!("decode APNs private key: {error}"))?;
    let signature: Signature = signing_key.sign(signing_input.as_bytes());
    Ok(format!(
        "{signing_input}.{}",
        URL_SAFE_NO_PAD.encode(signature.to_bytes())
    ))
}

fn credential_fingerprint(credentials: &ApplePushCredentials) -> String {
    hex::encode(Sha256::digest(
        format!(
            "{}\0{}\0{}",
            credentials.team_id, credentials.key_id, credentials.private_key
        )
        .as_bytes(),
    ))
}

fn truncate_collapse_id(value: &str) -> String {
    if value.len() <= 64 {
        value.to_owned()
    } else {
        hex::encode(Sha256::digest(value.as_bytes()))
    }
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

fn retry_at(attempt_number: u32) -> String {
    let exponent = attempt_number.saturating_sub(1).min(10);
    let seconds = RETRY_BASE_SECONDS
        .saturating_mul(1_i64 << exponent)
        .min(RETRY_MAX_SECONDS);
    let jitter = i64::from(rand::random::<u8>() % 16);
    (Utc::now() + Duration::seconds(seconds + jitter)).to_rfc3339()
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
    use p256::elliptic_curve::rand_core::OsRng;
    use p256::pkcs8::{EncodePrivateKey, LineEnding};

    use super::*;

    #[test]
    fn provider_jwt_is_es256_and_contains_no_private_key() {
        let key = SigningKey::random(&mut OsRng);
        let private_key = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
        let credentials = ApplePushCredentials {
            team_id: "TEAM123456".to_owned(),
            key_id: "KEY1234567".to_owned(),
            private_key: private_key.clone(),
        };
        let token = sign_provider_token(
            &credentials,
            DateTime::parse_from_rfc3339("2026-07-25T12:00:00Z")
                .unwrap()
                .with_timezone(&Utc),
        )
        .unwrap();
        assert_eq!(token.split('.').count(), 3);
        assert!(!token.contains("PRIVATE"));
        assert!(!token.contains(&private_key));
    }

    #[test]
    fn long_collapse_identity_becomes_a_stable_64_byte_digest() {
        let value = "x".repeat(100);
        assert_eq!(truncate_collapse_id(&value).len(), 64);
        assert_eq!(truncate_collapse_id(&value), truncate_collapse_id(&value));
    }

    #[test]
    fn provider_request_identity_is_stable_and_does_not_echo_target_ids() {
        let first = stable_provider_id("notification_target_private");
        assert_eq!(first, stable_provider_id("notification_target_private"));
        assert_eq!(first.len(), 36);
        assert!(!first.contains("private"));
    }

    #[test]
    fn environments_and_retry_classification_follow_apns_contract() {
        assert_eq!(
            apns_endpoint(NotificationEnvironment::Sandbox),
            "https://api.sandbox.push.apple.com"
        );
        assert_eq!(
            apns_endpoint(NotificationEnvironment::Production),
            "https://api.push.apple.com"
        );
        assert_eq!(
            classify_failure(429, "TooManyRequests"),
            ApnsFailureDisposition::Retryable
        );
        assert_eq!(
            classify_failure(503, "ServiceUnavailable"),
            ApnsFailureDisposition::Retryable
        );
        assert_eq!(
            classify_failure(410, "Unregistered"),
            ApnsFailureDisposition::Permanent {
                invalidate_token: true
            }
        );
        assert_eq!(
            classify_failure(400, "BadPayload"),
            ApnsFailureDisposition::Permanent {
                invalidate_token: false
            }
        );
    }

    #[tokio::test]
    async fn missing_credentials_block_durable_work_before_network_dispatch() {
        let directory = tempfile::tempdir().unwrap();
        let client = ApnsClient::new(directory.path()).unwrap();
        let target = NotificationTargetDispatch {
            target_id: "target_1".to_owned(),
            delivery_id: "delivery_1".to_owned(),
            worker_id: "automation-reminders".to_owned(),
            source_record_id: Some("occurrence_1".to_owned()),
            trace_id: "trace_1".to_owned(),
            installation_id: "installation_1".to_owned(),
            client_server_id: "server_1".to_owned(),
            token: "ab".repeat(32),
            topic: "com.tron.mobile.beta".to_owned(),
            environment: NotificationEnvironment::Sandbox,
            title: "Reminder".to_owned(),
            body: "Credential setup is missing.".to_owned(),
            thread_key: None,
            actions: vec!["complete".to_owned()],
            expires_at: (Utc::now() + Duration::minutes(5)).to_rfc3339(),
            unread_count: 1,
            attempt_number: 1,
        };

        match client.send_alert(&target).await {
            NotificationDispatchOutcome::Blocked { code, .. } => {
                assert_eq!(code, "apns_credentials_missing");
            }
            outcome => panic!("expected blocked APNs dispatch, got {outcome:?}"),
        }
    }
}
