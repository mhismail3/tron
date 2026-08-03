//! Runtime selection between relay and direct APNs transports.
//!
//! Selection is explicit and engine-owned. One target uses one configured mode
//! for each attempt; ambiguous relay outcomes never fall through to direct
//! APNs. A missing `notification-push` entry preserves the prior direct mode
//! for existing installations.

use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::domains::auth::credentials::{
    NotificationTransportMode, load_apple_push_credentials, load_notification_push_config,
};
use crate::domains::worker_kernel::persistence::{
    NotificationDispatchOutcome, NotificationRefreshDispatch, NotificationTargetDispatch,
};

use super::{apns::ApnsClient, relay::RelayClient};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(in crate::domains::worker_kernel) enum NotificationTransportKind {
    Relay,
    Direct,
}

impl NotificationTransportKind {
    pub(in crate::domains::worker_kernel) const fn as_str(self) -> &'static str {
        match self {
            Self::Relay => "relay",
            Self::Direct => "direct",
        }
    }
}

pub(in crate::domains::worker_kernel) struct NotificationTransportResult {
    pub(in crate::domains::worker_kernel) kind: NotificationTransportKind,
    pub(in crate::domains::worker_kernel) outcome: NotificationDispatchOutcome,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::domains::worker_kernel) struct NotificationTransportReadiness {
    pub(in crate::domains::worker_kernel) mode: NotificationTransportKind,
    pub(in crate::domains::worker_kernel) configured: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(in crate::domains::worker_kernel) problem_code: Option<&'static str>,
}

#[derive(Clone)]
pub(in crate::domains::worker_kernel) struct NotificationTransport {
    auth_path: std::path::PathBuf,
    direct: ApnsClient,
    relay: RelayClient,
}

impl NotificationTransport {
    pub(in crate::domains::worker_kernel) fn new(home: &std::path::Path) -> Result<Self, String> {
        Ok(Self {
            auth_path: home.join("auth.json"),
            direct: ApnsClient::new(home)?,
            relay: RelayClient::new()?,
        })
    }

    pub(in crate::domains::worker_kernel) fn readiness(&self) -> NotificationTransportReadiness {
        match load_notification_push_config(&self.auth_path) {
            Err(_) => NotificationTransportReadiness {
                mode: NotificationTransportKind::Direct,
                configured: false,
                problem_code: Some("notification_transport_config_invalid"),
            },
            Ok(Some(config)) if config.mode == NotificationTransportMode::Relay => {
                NotificationTransportReadiness {
                    mode: NotificationTransportKind::Relay,
                    configured: config.relay.is_some(),
                    problem_code: config
                        .relay
                        .is_none()
                        .then_some("notification_relay_credentials_missing"),
                }
            }
            Ok(_) => match load_apple_push_credentials(&self.auth_path) {
                Ok(Some(credentials)) if credentials.validate().is_ok() => {
                    NotificationTransportReadiness {
                        mode: NotificationTransportKind::Direct,
                        configured: true,
                        problem_code: None,
                    }
                }
                Ok(None) => NotificationTransportReadiness {
                    mode: NotificationTransportKind::Direct,
                    configured: false,
                    problem_code: Some("apns_credentials_missing"),
                },
                _ => NotificationTransportReadiness {
                    mode: NotificationTransportKind::Direct,
                    configured: false,
                    problem_code: Some("apns_credentials_invalid"),
                },
            },
        }
    }

    pub(in crate::domains::worker_kernel) fn configuration_revision(&self) -> String {
        std::fs::read(&self.auth_path).map_or_else(
            |_| "missing".to_owned(),
            |contents| hex::encode(Sha256::digest(contents)),
        )
    }

    pub(in crate::domains::worker_kernel) async fn send_alert(
        &self,
        target: &NotificationTargetDispatch,
    ) -> NotificationTransportResult {
        match load_notification_push_config(&self.auth_path) {
            Ok(Some(config)) if config.mode == NotificationTransportMode::Relay => {
                let outcome = match config.relay {
                    Some(credentials) => self.relay.send_alert(&credentials, target).await,
                    None => blocked("notification_relay_credentials_missing"),
                };
                NotificationTransportResult {
                    kind: NotificationTransportKind::Relay,
                    outcome,
                }
            }
            Err(_) => NotificationTransportResult {
                kind: NotificationTransportKind::Direct,
                outcome: blocked("notification_transport_config_invalid"),
            },
            _ => NotificationTransportResult {
                kind: NotificationTransportKind::Direct,
                outcome: self.direct.send_alert(target).await,
            },
        }
    }

    pub(in crate::domains::worker_kernel) async fn send_refresh(
        &self,
        refresh: &NotificationRefreshDispatch,
    ) -> NotificationTransportResult {
        match load_notification_push_config(&self.auth_path) {
            Ok(Some(config)) if config.mode == NotificationTransportMode::Relay => {
                let outcome = match config.relay {
                    Some(credentials) => self.relay.send_refresh(&credentials, refresh).await,
                    None => blocked("notification_relay_credentials_missing"),
                };
                NotificationTransportResult {
                    kind: NotificationTransportKind::Relay,
                    outcome,
                }
            }
            Err(_) => NotificationTransportResult {
                kind: NotificationTransportKind::Direct,
                outcome: blocked("notification_transport_config_invalid"),
            },
            _ => NotificationTransportResult {
                kind: NotificationTransportKind::Direct,
                outcome: self.direct.send_refresh(refresh).await,
            },
        }
    }
}

fn blocked(code: &str) -> NotificationDispatchOutcome {
    NotificationDispatchOutcome::Blocked {
        code: code.to_owned(),
        retry_at: (chrono::Utc::now() + chrono::Duration::minutes(5)).to_rfc3339(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_transport_config_preserves_direct_compatibility() {
        let directory = tempfile::tempdir().unwrap();
        let transport = NotificationTransport::new(directory.path()).unwrap();
        let readiness = transport.readiness();
        assert_eq!(readiness.mode, NotificationTransportKind::Direct);
        assert_eq!(readiness.problem_code, Some("apns_credentials_missing"));
    }
}
