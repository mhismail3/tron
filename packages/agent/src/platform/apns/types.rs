use std::collections::HashMap;
use std::fmt::Debug;
#[cfg(test)]
use std::sync::Mutex;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// One relay request whose tokens all share a concrete APNs route.
#[derive(Clone, Debug)]
pub(crate) struct ApnsBatch {
    pub(crate) device_tokens: Vec<String>,
    pub(crate) environment: String,
    pub(crate) bundle_id: String,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ApnsNotification {
    pub(crate) title: String,
    pub(crate) body: String,
    pub(crate) data: HashMap<String, String>,
    pub(crate) priority: String,
    pub(crate) sound: Option<String>,
    pub(crate) badge: Option<u32>,
    pub(crate) thread_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct ApnsSendResult {
    pub(crate) success: bool,
    pub(crate) device_token: String,
    pub(crate) apns_id: Option<String>,
    pub(crate) status_code: Option<u16>,
    pub(crate) reason: Option<String>,
    pub(crate) error: Option<String>,
}

impl ApnsSendResult {
    pub(crate) fn is_terminal_token_failure(&self) -> bool {
        self.status_code == Some(410)
            || matches!(
                self.reason.as_deref(),
                Some("BadDeviceToken" | "DeviceTokenNotForTopic" | "Unregistered")
            )
    }
}

#[async_trait]
pub(crate) trait PushSender: Send + Sync + Debug {
    async fn send_to_many(
        &self,
        batch: &ApnsBatch,
        notification: &ApnsNotification,
    ) -> Vec<ApnsSendResult>;
}

#[cfg(test)]
#[derive(Debug)]
pub(crate) struct MockPushSender {
    results: Mutex<Vec<Vec<ApnsSendResult>>>,
    calls: Mutex<Vec<(ApnsBatch, ApnsNotification)>>,
}

#[cfg(test)]
impl MockPushSender {
    pub(crate) fn succeeding() -> Self {
        Self {
            results: Mutex::new(Vec::new()),
            calls: Mutex::new(Vec::new()),
        }
    }

    pub(crate) fn with_results(results: Vec<Vec<ApnsSendResult>>) -> Self {
        Self {
            results: Mutex::new(results),
            calls: Mutex::new(Vec::new()),
        }
    }

    pub(crate) fn calls(&self) -> Vec<(ApnsBatch, ApnsNotification)> {
        self.calls.lock().expect("mock calls lock").clone()
    }
}

#[cfg(test)]
#[async_trait]
impl PushSender for MockPushSender {
    async fn send_to_many(
        &self,
        batch: &ApnsBatch,
        notification: &ApnsNotification,
    ) -> Vec<ApnsSendResult> {
        self.calls
            .lock()
            .expect("mock calls lock")
            .push((batch.clone(), notification.clone()));
        let mut results = self.results.lock().expect("mock results lock");
        if results.is_empty() {
            return batch
                .device_tokens
                .iter()
                .map(|token| ApnsSendResult {
                    success: true,
                    device_token: token.clone(),
                    apns_id: Some("mock-apns-id".to_owned()),
                    status_code: Some(200),
                    reason: None,
                    error: None,
                })
                .collect();
        }
        results.remove(0)
    }
}
