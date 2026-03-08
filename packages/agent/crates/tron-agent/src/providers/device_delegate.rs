//! `DeviceDelegate` implementation backed by `DeviceRequestBroker`.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;
use tron_server::device::DeviceRequestBroker;
use tron_tools::errors::ToolError;
use tron_tools::traits::DeviceDelegate;

/// Default timeout for device requests (30 seconds).
const DEVICE_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Routes tool device requests through the `DeviceRequestBroker`.
pub struct BrokerDeviceDelegate {
    broker: Arc<DeviceRequestBroker>,
}

impl BrokerDeviceDelegate {
    pub fn new(broker: Arc<DeviceRequestBroker>) -> Self {
        Self { broker }
    }
}

#[async_trait]
impl DeviceDelegate for BrokerDeviceDelegate {
    async fn device_request(&self, method: &str, params: Value) -> Result<Value, ToolError> {
        self.broker
            .request(method, params, DEVICE_REQUEST_TIMEOUT)
            .await
            .map_err(|e| ToolError::Internal {
                message: e.to_string(),
            })
    }
}
