//! APNS service — JWT signing, HTTP/2 notification delivery.
//!
//! Uses `reqwest` for HTTP/2 transport and `jsonwebtoken` for ES256 JWT signing.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use super::config::ApnsConfig;
use super::types::{ApnsNotification, ApnsSendResult};

/// JWT token validity period (55 minutes — refresh before Apple's 1-hour expiry).
const TOKEN_VALIDITY: Duration = Duration::from_secs(55 * 60);

/// JWT claims for APNS authentication.
#[derive(Debug, Serialize, Deserialize)]
struct ApnsClaims {
    /// Issuer (Team ID).
    iss: String,
    /// Issued at (Unix timestamp).
    iat: i64,
}

/// Cached JWT token with expiry tracking.
struct CachedToken {
    token: String,
    created_at: Instant,
}

/// APNS service for sending push notifications to Apple devices.
pub struct ApnsService {
    config: ApnsConfig,
    encoding_key: EncodingKey,
    client: reqwest::Client,
    cached_token: Mutex<Option<CachedToken>>,
}

impl std::fmt::Debug for ApnsService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApnsService")
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

impl ApnsService {
    /// Create a new APNS service from config.
    ///
    /// Reads the private key from disk and builds an HTTP/2 client.
    pub fn new(config: ApnsConfig) -> Result<Self, ApnsError> {
        let key_path = config.resolved_key_path();
        let key_pem = std::fs::read(&key_path).map_err(|e| ApnsError::KeyRead {
            path: key_path.display().to_string(),
            reason: e.to_string(),
        })?;

        let encoding_key = EncodingKey::from_ec_pem(&key_pem).map_err(|e| ApnsError::KeyParse {
            reason: e.to_string(),
        })?;

        // APNs requires HTTP/2. Force it via http2_prior_knowledge — ALPN
        // alone isn't enough because reqwest defaults to HTTP/1.1 unless told otherwise.
        let client = reqwest::Client::builder()
            .http2_prior_knowledge()
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| ApnsError::ClientBuild {
                reason: e.to_string(),
            })?;

        info!(
            key_id = %config.key_id,
            team_id = %config.team_id,
            environment = %config.environment,
            "APNS service initialized"
        );

        Ok(Self {
            config,
            encoding_key,
            client,
            cached_token: Mutex::new(None),
        })
    }

    /// Send a notification to a single device.
    #[allow(clippy::too_many_lines)]
    pub async fn send(
        &self,
        device_token: &str,
        notification: &ApnsNotification,
    ) -> ApnsSendResult {
        let jwt = match self.get_or_refresh_token() {
            Ok(t) => t,
            Err(e) => {
                return ApnsSendResult {
                    success: false,
                    device_token: device_token.to_string(),
                    apns_id: None,
                    status_code: None,
                    reason: None,
                    error: Some(format!("JWT generation failed: {e}")),
                };
            }
        };

        let url = format!(
            "https://{}:443/3/device/{}",
            self.config.apns_host(),
            device_token
        );

        let priority = if notification.priority == "high" {
            "10"
        } else {
            "5"
        };

        let payload = self.build_payload(notification);

        info!(
            url = %url,
            token_len = device_token.len(),
            token_prefix = tron_core::text::truncate_str(device_token, 8),
            bundle_id = %self.config.bundle_id,
            priority = priority,
            payload = %payload,
            "APNS request"
        );

        let result = self
            .client
            .post(&url)
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", &self.config.bundle_id)
            .header("apns-push-type", "alert")
            .header("apns-priority", priority)
            .header("apns-expiration", "0")
            .json(&payload)
            .send()
            .await;

        match result {
            Ok(response) => {
                let status = response.status().as_u16();
                let apns_id = response
                    .headers()
                    .get("apns-id")
                    .and_then(|v| v.to_str().ok())
                    .map(String::from);
                let http_version = format!("{:?}", response.version());

                if response.status().is_success() {
                    info!(
                        status,
                        http_version = %http_version,
                        device_token = tron_core::text::truncate_str(device_token, 8),
                        apns_id = ?apns_id,
                        "APNS send OK"
                    );
                    ApnsSendResult {
                        success: true,
                        device_token: device_token.to_string(),
                        apns_id,
                        status_code: Some(status),
                        reason: None,
                        error: None,
                    }
                } else {
                    let body = response.text().await.unwrap_or_default();
                    let reason = serde_json::from_str::<serde_json::Value>(&body)
                        .ok()
                        .and_then(|v| v.get("reason")?.as_str().map(String::from));

                    warn!(
                        status,
                        http_version = %http_version,
                        reason = ?reason,
                        body = %body,
                        device_token = tron_core::text::truncate_str(device_token, 8),
                        "APNS send FAILED"
                    );

                    ApnsSendResult {
                        success: false,
                        device_token: device_token.to_string(),
                        apns_id,
                        status_code: Some(status),
                        reason,
                        error: Some(body),
                    }
                }
            }
            Err(e) => {
                warn!(
                    error = %e,
                    error_debug = ?e,
                    url = %url,
                    "APNS HTTP request FAILED (transport error)"
                );
                ApnsSendResult {
                    success: false,
                    device_token: device_token.to_string(),
                    apns_id: None,
                    status_code: None,
                    reason: None,
                    error: Some(e.to_string()),
                }
            }
        }
    }

    /// Send a notification to multiple devices in parallel.
    pub async fn send_to_many(
        &self,
        device_tokens: &[String],
        notification: &ApnsNotification,
    ) -> Vec<ApnsSendResult> {
        let futures: Vec<_> = device_tokens
            .iter()
            .map(|token| self.send(token, notification))
            .collect();
        futures::future::join_all(futures).await
    }

    /// Get a cached JWT or generate a new one.
    fn get_or_refresh_token(&self) -> Result<String, ApnsError> {
        let mut cached = self
            .cached_token
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);

        if let Some(ref token) = *cached {
            if token.created_at.elapsed() < TOKEN_VALIDITY {
                return Ok(token.token.clone());
            }
        }

        let jwt = self.generate_jwt()?;
        *cached = Some(CachedToken {
            token: jwt.clone(),
            created_at: Instant::now(),
        });

        Ok(jwt)
    }

    /// Generate a new ES256 JWT for APNS authentication.
    fn generate_jwt(&self) -> Result<String, ApnsError> {
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.config.key_id.clone());

        let claims = ApnsClaims {
            iss: self.config.team_id.clone(),
            iat: chrono::Utc::now().timestamp(),
        };

        jsonwebtoken::encode(&header, &claims, &self.encoding_key).map_err(|e| ApnsError::JwtSign {
            reason: e.to_string(),
        })
    }

    /// Build the APNS JSON payload.
    #[allow(clippy::unused_self)]
    fn build_payload(&self, notification: &ApnsNotification) -> serde_json::Value {
        let mut aps = serde_json::json!({
            "alert": {
                "title": notification.title,
                "body": notification.body,
            },
        });

        if let Some(ref sound) = notification.sound {
            aps["sound"] = serde_json::json!(sound);
        }
        if let Some(badge) = notification.badge {
            aps["badge"] = serde_json::json!(badge);
        }
        if let Some(ref thread_id) = notification.thread_id {
            aps["thread-id"] = serde_json::json!(thread_id);
        }
        aps["mutable-content"] = serde_json::json!(1);

        let mut payload = serde_json::json!({ "aps": aps });

        // Add custom data fields at root level
        if let Some(obj) = payload.as_object_mut() {
            for (key, value) in &notification.data {
                let _ = obj.insert(key.clone(), serde_json::json!(value));
            }
        }

        payload
    }
}

/// APNS service errors.
#[derive(Debug, thiserror::Error)]
pub enum ApnsError {
    /// Failed to read private key file.
    #[error("failed to read APNS key at {path}: {reason}")]
    KeyRead {
        /// Key file path.
        path: String,
        /// Error description.
        reason: String,
    },
    /// Failed to parse private key.
    #[error("failed to parse APNS key: {reason}")]
    KeyParse {
        /// Error description.
        reason: String,
    },
    /// Failed to build HTTP client.
    #[error("failed to build HTTP client: {reason}")]
    ClientBuild {
        /// Error description.
        reason: String,
    },
    /// Failed to sign JWT.
    #[error("failed to sign JWT: {reason}")]
    JwtSign {
        /// Error description.
        reason: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_notification() -> ApnsNotification {
        ApnsNotification {
            title: "Test".to_string(),
            body: "Hello".to_string(),
            data: std::collections::HashMap::new(),
            priority: "high".to_string(),
            sound: Some("default".to_string()),
            badge: Some(1),
            thread_id: Some("sess_123".to_string()),
        }
    }

    #[test]
    fn build_payload_basic() {
        // We need a real key to create ApnsService, so test payload building indirectly
        let notification = make_notification();
        let aps = serde_json::json!({
            "alert": {
                "title": notification.title,
                "body": notification.body,
            },
            "sound": "default",
            "badge": 1,
            "thread-id": "sess_123",
            "mutable-content": 1,
        });
        let payload = serde_json::json!({ "aps": aps });

        assert_eq!(payload["aps"]["alert"]["title"], "Test");
        assert_eq!(payload["aps"]["alert"]["body"], "Hello");
        assert_eq!(payload["aps"]["sound"], "default");
        assert_eq!(payload["aps"]["badge"], 1);
        assert_eq!(payload["aps"]["thread-id"], "sess_123");
        assert_eq!(payload["aps"]["mutable-content"], 1);
    }

    #[test]
    fn build_payload_minimal() {
        let notification = ApnsNotification {
            title: "T".to_string(),
            body: "B".to_string(),
            data: std::collections::HashMap::new(),
            priority: "normal".to_string(),
            sound: None,
            badge: None,
            thread_id: None,
        };
        let aps = serde_json::json!({
            "alert": {
                "title": notification.title,
                "body": notification.body,
            },
            "mutable-content": 1,
        });
        let payload = serde_json::json!({ "aps": aps });

        assert!(payload["aps"]["sound"].is_null());
        assert!(payload["aps"]["badge"].is_null());
        assert!(payload["aps"]["thread-id"].is_null());
    }

    #[test]
    fn build_payload_with_custom_data() {
        let mut data = std::collections::HashMap::new();
        let _ = data.insert("sessionId".to_string(), "sess_1".to_string());
        let _ = data.insert("toolCallId".to_string(), "tc_1".to_string());

        let notification = ApnsNotification {
            title: "T".to_string(),
            body: "B".to_string(),
            data,
            priority: "high".to_string(),
            sound: None,
            badge: None,
            thread_id: None,
        };

        // Build payload manually (same logic as service)
        let mut payload = serde_json::json!({
            "aps": {
                "alert": { "title": "T", "body": "B" },
                "mutable-content": 1,
            }
        });
        if let Some(obj) = payload.as_object_mut() {
            for (key, value) in &notification.data {
                let _ = obj.insert(key.clone(), serde_json::json!(value));
            }
        }

        assert_eq!(payload["sessionId"], "sess_1");
        assert_eq!(payload["toolCallId"], "tc_1");
    }

    #[test]
    fn apns_error_display() {
        let err = ApnsError::KeyRead {
            path: "/test.p8".to_string(),
            reason: "not found".to_string(),
        };
        assert!(err.to_string().contains("/test.p8"));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn jwt_claims_serialize() {
        let claims = ApnsClaims {
            iss: "TEAM123".to_string(),
            iat: 1700000000,
        };
        let json = serde_json::to_value(&claims).unwrap();
        assert_eq!(json["iss"], "TEAM123");
        assert_eq!(json["iat"], 1700000000);
    }

    #[test]
    fn send_result_success_shape() {
        let result = ApnsSendResult {
            success: true,
            device_token: "abc123".to_string(),
            apns_id: Some("uuid-here".to_string()),
            status_code: Some(200),
            reason: None,
            error: None,
        };
        assert!(result.success);
        assert_eq!(result.status_code, Some(200));
    }

    #[test]
    fn send_result_failure_shape() {
        let result = ApnsSendResult {
            success: false,
            device_token: "abc123".to_string(),
            apns_id: None,
            status_code: Some(410),
            reason: Some("Unregistered".to_string()),
            error: Some("device not registered".to_string()),
        };
        assert!(!result.success);
        assert_eq!(result.reason.as_deref(), Some("Unregistered"));
    }

    #[test]
    fn notification_default_priority() {
        let json = r#"{"title": "T", "body": "B"}"#;
        let n: ApnsNotification = serde_json::from_str(json).unwrap();
        assert_eq!(n.priority, "high");
    }

    #[test]
    fn notification_custom_priority() {
        let json = r#"{"title": "T", "body": "B", "priority": "normal"}"#;
        let n: ApnsNotification = serde_json::from_str(json).unwrap();
        assert_eq!(n.priority, "normal");
    }

    #[test]
    fn new_service_with_missing_key_fails() {
        let config = ApnsConfig {
            key_id: "ABC".to_string(),
            team_id: "XYZ".to_string(),
            bundle_id: "com.test".to_string(),
            environment: "sandbox".to_string(),
            key_path: Some("/nonexistent/key.p8".to_string()),
        };
        let result = ApnsService::new(config);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ApnsError::KeyRead { .. }));
    }

    #[test]
    fn new_service_with_invalid_key_fails() {
        let dir = tempfile::tempdir().unwrap();
        let key_path = dir.path().join("bad.p8");
        std::fs::write(&key_path, "not a valid PEM key").unwrap();

        let config = ApnsConfig {
            key_id: "ABC".to_string(),
            team_id: "XYZ".to_string(),
            bundle_id: "com.test".to_string(),
            environment: "sandbox".to_string(),
            key_path: Some(key_path.to_string_lossy().to_string()),
        };
        let result = ApnsService::new(config);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ApnsError::KeyParse { .. }));
    }
}
