//! `DeviceDelegate` implementation backed by `DeviceRequestBroker`.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;
use crate::server::device::DeviceRequestBroker;
use crate::tools::errors::ToolError;
use crate::tools::traits::DeviceDelegate;

/// Default timeout for device requests (30 seconds).
const DEVICE_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Routes tool device requests through the `DeviceRequestBroker`.
pub struct BrokerDeviceDelegate {
    broker: Arc<DeviceRequestBroker>,
}

impl BrokerDeviceDelegate {
    /// Create a new delegate.
    pub fn new(broker: Arc<DeviceRequestBroker>) -> Self {
        Self { broker }
    }
}

#[async_trait]
impl DeviceDelegate for BrokerDeviceDelegate {
    async fn device_request(
        &self,
        session_id: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, ToolError> {
        self.broker
            .request(session_id, method, params, DEVICE_REQUEST_TIMEOUT)
            .await
            .map_err(|e| ToolError::Internal {
                message: e.to_string(),
            })
    }
}
