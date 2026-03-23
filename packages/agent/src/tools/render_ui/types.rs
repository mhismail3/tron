//! Types for the `RenderUI` tool and `RenderUIProvider` trait.
//!
//! Wire format matches the iOS `RenderUIStartedPlugin.DataPayload` exactly.

use serde::{Deserialize, Serialize};

/// Result of pushing a UI spec to the render backend.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderResult {
    /// Canvas identifier.
    pub canvas_id: String,
    /// URL where the rendered UI is visible.
    pub url: String,
    /// Number of elements in the spec.
    pub element_count: usize,
}

/// Info about a running render backend.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderBackendInfo {
    /// Base URL of the backend (e.g., `http://localhost:9250`).
    pub base_url: String,
    /// Backend identifier (e.g., `"tron-json-render"`).
    pub backend_id: String,
}

/// Status of the render backend.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum RenderBackendStatus {
    /// Backend is running and reachable.
    Running {
        /// Base URL.
        #[serde(rename = "baseUrl")]
        base_url: String,
    },
    /// Backend is starting up.
    Starting,
    /// Backend is not running.
    Stopped,
    /// Backend encountered an error.
    Error {
        /// Error message.
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_result_serializes_camel_case() {
        let r = RenderResult {
            canvas_id: "my-canvas".into(),
            url: "http://localhost:9250/canvas/my-canvas".into(),
            element_count: 5,
        };
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["canvasId"], "my-canvas");
        assert_eq!(json["url"], "http://localhost:9250/canvas/my-canvas");
        assert_eq!(json["elementCount"], 5);
    }

    #[test]
    fn render_result_roundtrip() {
        let r = RenderResult {
            canvas_id: "c1".into(),
            url: "http://localhost:9250/canvas/c1".into(),
            element_count: 3,
        };
        let json = serde_json::to_string(&r).unwrap();
        let back: RenderResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.canvas_id, "c1");
        assert_eq!(back.element_count, 3);
    }

    #[test]
    fn render_backend_info_serializes_camel_case() {
        let info = RenderBackendInfo {
            base_url: "http://localhost:9250".into(),
            backend_id: "tron-json-render".into(),
        };
        let json = serde_json::to_value(&info).unwrap();
        assert_eq!(json["baseUrl"], "http://localhost:9250");
        assert_eq!(json["backendId"], "tron-json-render");
    }

    #[test]
    fn render_backend_status_running() {
        let s = RenderBackendStatus::Running {
            base_url: "http://localhost:9250".into(),
        };
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["status"], "running");
        assert_eq!(json["baseUrl"], "http://localhost:9250");
    }

    #[test]
    fn render_backend_status_stopped() {
        let s = RenderBackendStatus::Stopped;
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["status"], "stopped");
    }

    #[test]
    fn render_backend_status_starting() {
        let s = RenderBackendStatus::Starting;
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["status"], "starting");
    }

    #[test]
    fn render_backend_status_error() {
        let s = RenderBackendStatus::Error {
            message: "backend crashed".into(),
        };
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["status"], "error");
        assert_eq!(json["message"], "backend crashed");
    }
}
