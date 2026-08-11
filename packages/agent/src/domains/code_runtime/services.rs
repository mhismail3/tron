//! Fixed native-service registry exposed only through the code broker.
//!
//! The registry is deliberately closed: exactly four engine-owned services
//! exist, and implementations are injected by their source owners. Missing
//! platform integrations remain discoverable with an authoritative disabled
//! reason; they never fall back to a Worker, shell command, or arbitrary
//! function name.

use std::sync::Arc;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use tokio_util::sync::CancellationToken;

/// Stable fixed-service identity.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FixedServiceId {
    /// Durable local and paired-device notifications.
    Notifications,
    /// Audio-to-text transcription.
    Transcription,
    /// Browser observation and control through the explicit browser bridge.
    BrowserControl,
    /// Mac UI observation and control through the explicit accessibility bridge.
    MacControl,
}
impl FixedServiceId {
    /// Stable broker-facing identifier.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Notifications => "notifications",
            Self::Transcription => "transcription",
            Self::BrowserControl => "browser_control",
            Self::MacControl => "mac_control",
        }
    }

    const fn display_name(self) -> &'static str {
        match self {
            Self::Notifications => "Notifications",
            Self::Transcription => "Transcription",
            Self::BrowserControl => "Browser Control",
            Self::MacControl => "Mac Control",
        }
    }

    const fn summary(self) -> &'static str {
        match self {
            Self::Notifications => "Deliver and inspect Tron notifications.",
            Self::Transcription => "Transcribe audio and inspect model readiness.",
            Self::BrowserControl => "Observe and operate an explicitly connected browser.",
            Self::MacControl => "Observe and operate Mac applications with explicit OS permission.",
        }
    }

    const fn operations(self) -> &'static [&'static str] {
        match self {
            Self::Notifications => &["send", "status"],
            Self::Transcription => &["transcribe", "status", "preload"],
            Self::BrowserControl | Self::MacControl => &["perform"],
        }
    }
}

const SERVICE_IDS: [FixedServiceId; 4] = [
    FixedServiceId::Notifications,
    FixedServiceId::Transcription,
    FixedServiceId::BrowserControl,
    FixedServiceId::MacControl,
];

/// Authoritative discovery row.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FixedServiceDescriptor {
    /// Stable service id.
    pub service_id: FixedServiceId,
    /// User-facing title.
    pub name: String,
    /// Concise purpose.
    pub summary: String,
    /// Closed operations accepted by this service.
    pub operations: Vec<String>,
    /// Whether its platform owner is currently callable.
    pub available: bool,
    /// Server-authored reason when unavailable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable_reason: Option<String>,
}

/// Exact invocation passed to one native owner.
#[derive(Clone, Debug, PartialEq)]
pub struct FixedServiceInvocation {
    /// Stable idempotency key inherited from the durable outer broker call.
    pub call_id: String,
    /// Closed operation selected from the service descriptor.
    pub operation: String,
    /// JSON-safe input.
    pub input: Value,
}

/// Source-owned implementation for one fixed service.
#[async_trait]
pub trait FixedService: Send + Sync {
    /// Current availability. This must be cheap and content-free.
    fn availability(&self) -> Result<(), String>;

    /// Invoke one already-validated operation.
    async fn invoke(
        &self,
        invocation: FixedServiceInvocation,
        cancellation: &CancellationToken,
    ) -> Result<Value, String>;
}

/// Fixed registry failure.
#[derive(Debug, Error)]
pub enum FixedServiceError {
    /// Input named no supported fixed service or operation.
    #[error("invalid fixed-service request: {0}")]
    Invalid(String),
    /// The platform owner is not currently callable.
    #[error("fixed service unavailable: {0}")]
    Unavailable(String),
    /// The source owner rejected or failed the operation.
    #[error("fixed service failed: {0}")]
    Failed(String),
}

/// Closed set of native service owners.
#[derive(Clone, Default)]
pub struct FixedServiceRegistry {
    notifications: Option<Arc<dyn FixedService>>,
    transcription: Option<Arc<dyn FixedService>>,
    browser_control: Option<Arc<dyn FixedService>>,
    mac_control: Option<Arc<dyn FixedService>>,
}

impl std::fmt::Debug for FixedServiceRegistry {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FixedServiceRegistry")
            .field("services", &self.discover())
            .finish()
    }
}

impl FixedServiceRegistry {
    /// Build the exact registry. `None` is an explicit unavailable owner, not a
    /// signal to discover or synthesize an alternative implementation.
    #[must_use]
    pub fn new(
        notifications: Option<Arc<dyn FixedService>>,
        transcription: Option<Arc<dyn FixedService>>,
        browser_control: Option<Arc<dyn FixedService>>,
        mac_control: Option<Arc<dyn FixedService>>,
    ) -> Self {
        Self {
            notifications,
            transcription,
            browser_control,
            mac_control,
        }
    }

    /// Discover all four fixed identities in stable order.
    #[must_use]
    pub fn discover(&self) -> Vec<FixedServiceDescriptor> {
        SERVICE_IDS
            .into_iter()
            .map(|service_id| {
                let implementation = self.implementation(service_id);
                let unavailable_reason = match implementation {
                    Some(implementation) => implementation.availability().err(),
                    None => Some("No platform owner is connected.".to_owned()),
                };
                FixedServiceDescriptor {
                    service_id,
                    name: service_id.display_name().to_owned(),
                    summary: service_id.summary().to_owned(),
                    operations: service_id
                        .operations()
                        .iter()
                        .map(|operation| (*operation).to_owned())
                        .collect(),
                    available: unavailable_reason.is_none(),
                    unavailable_reason,
                }
            })
            .collect()
    }

    /// Invoke one closed operation through its exact source owner.
    pub async fn invoke(
        &self,
        service_id: FixedServiceId,
        invocation: FixedServiceInvocation,
        cancellation: &CancellationToken,
    ) -> Result<Value, FixedServiceError> {
        if !service_id
            .operations()
            .contains(&invocation.operation.as_str())
        {
            return Err(FixedServiceError::Invalid(format!(
                "service '{}' does not define operation '{}'",
                service_id.as_str(),
                invocation.operation
            )));
        }
        let implementation = self.implementation(service_id).ok_or_else(|| {
            FixedServiceError::Unavailable(format!(
                "{} has no connected platform owner",
                service_id.display_name()
            ))
        })?;
        implementation
            .availability()
            .map_err(FixedServiceError::Unavailable)?;
        implementation
            .invoke(invocation, cancellation)
            .await
            .map_err(FixedServiceError::Failed)
    }

    fn implementation(&self, service_id: FixedServiceId) -> Option<&Arc<dyn FixedService>> {
        match service_id {
            FixedServiceId::Notifications => self.notifications.as_ref(),
            FixedServiceId::Transcription => self.transcription.as_ref(),
            FixedServiceId::BrowserControl => self.browser_control.as_ref(),
            FixedServiceId::MacControl => self.mac_control.as_ref(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_is_exact_stable_and_user_friendly() {
        let rows = FixedServiceRegistry::default().discover();
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].name, "Notifications");
        assert_eq!(rows[1].name, "Transcription");
        assert_eq!(rows[2].name, "Browser Control");
        assert_eq!(rows[3].name, "Mac Control");
        assert!(rows.iter().all(|row| !row.available));
    }

    #[tokio::test]
    async fn unknown_operation_is_rejected_before_availability() {
        let error = FixedServiceRegistry::default()
            .invoke(
                FixedServiceId::Notifications,
                FixedServiceInvocation {
                    call_id: "call".to_owned(),
                    operation: "arbitrary".to_owned(),
                    input: Value::Null,
                },
                &CancellationToken::new(),
            )
            .await
            .unwrap_err();
        assert!(matches!(error, FixedServiceError::Invalid(_)));
    }
}
