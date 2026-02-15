use serde::{Deserialize, Serialize};

/// JSON-RPC 2.0 request.
#[derive(Debug, Deserialize)]
pub struct RpcRequest {
    pub method: String,
    pub params: Option<serde_json::Value>,
    pub id: Option<serde_json::Value>,
}

/// JSON-RPC 2.0 response.
#[derive(Debug, Serialize)]
pub struct RpcResponse {
    pub id: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

/// JSON-RPC 2.0 error object.
#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

// Standard JSON-RPC error codes
pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

impl RpcResponse {
    pub fn success(id: Option<serde_json::Value>, result: serde_json::Value) -> Self {
        Self {
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: Option<serde_json::Value>, code: i32, message: impl Into<String>) -> Self {
        Self {
            id,
            result: None,
            error: Some(RpcError {
                code,
                message: message.into(),
                data: None,
            }),
        }
    }

    pub fn method_not_found(id: Option<serde_json::Value>, method: &str) -> Self {
        Self::error(id, METHOD_NOT_FOUND, format!("Method not found: {method}"))
    }

    pub fn invalid_params(id: Option<serde_json::Value>, msg: impl Into<String>) -> Self {
        Self::error(id, INVALID_PARAMS, msg)
    }

    pub fn internal_error(id: Option<serde_json::Value>, msg: impl Into<String>) -> Self {
        Self::error(id, INTERNAL_ERROR, msg)
    }

    pub fn parse_error() -> Self {
        Self::error(None, PARSE_ERROR, "Parse error")
    }
}

/// Extract a required string param from the RPC params object.
pub fn require_str<'a>(params: &'a serde_json::Value, key: &str) -> Result<&'a str, String> {
    params
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("Missing required parameter: {key}"))
}

/// Extract an optional string param.
pub fn optional_str<'a>(params: &'a serde_json::Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(|v| v.as_str())
}

/// Extract an optional i64 param.
pub fn optional_i64(params: &serde_json::Value, key: &str) -> Option<i64> {
    params.get(key).and_then(|v| v.as_i64())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_rpc_request() {
        let json = r#"{"method":"agent.message","params":{"session_id":"sess_123","content":"hello"},"id":1}"#;
        let req: RpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.method, "agent.message");
        assert!(req.params.is_some());
        assert_eq!(req.id, Some(serde_json::json!(1)));
    }

    #[test]
    fn success_response_serializes() {
        let resp = RpcResponse::success(Some(serde_json::json!(1)), serde_json::json!({"ok": true}));
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"result\""));
        assert!(!json.contains("\"error\""));
    }

    #[test]
    fn error_response_serializes() {
        let resp = RpcResponse::method_not_found(Some(serde_json::json!(1)), "foo.bar");
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"error\""));
        assert!(json.contains("-32601"));
        assert!(json.contains("foo.bar"));
        assert!(!json.contains("\"result\""));
    }

    #[test]
    fn require_str_extracts() {
        let params = serde_json::json!({"name": "test", "count": 5});
        assert_eq!(require_str(&params, "name").unwrap(), "test");
        assert!(require_str(&params, "missing").is_err());
        assert!(require_str(&params, "count").is_err()); // not a string
    }

    #[test]
    fn optional_helpers() {
        let params = serde_json::json!({"name": "test", "count": 5});
        assert_eq!(optional_str(&params, "name"), Some("test"));
        assert_eq!(optional_str(&params, "missing"), None);
        assert_eq!(optional_i64(&params, "count"), Some(5));
        assert_eq!(optional_i64(&params, "missing"), None);
    }

    #[test]
    fn parse_error_has_no_id() {
        let resp = RpcResponse::parse_error();
        assert!(resp.id.is_none());
        assert_eq!(resp.error.as_ref().unwrap().code, PARSE_ERROR);
    }
}
