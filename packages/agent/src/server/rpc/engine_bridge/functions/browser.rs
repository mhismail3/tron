use super::*;

pub(super) async fn handle(method: &str) -> Result<Value, RpcError> {
    match method {
        "browser.startStream" => Err(RpcError::NotAvailable {
            message: "Browser streaming has been removed".into(),
        }),
        "browser.stopStream" => Ok(json!({ "success": true })),
        _ => Err(RpcError::Internal {
            message: format!("browser method {method} is not engine-owned"),
        }),
    }
}
