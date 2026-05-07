use super::*;

pub(super) async fn handle(method: &str) -> Result<Value, RpcError> {
    match method {
        "browser::start_stream" => Err(RpcError::NotAvailable {
            message: "Browser streaming has been removed".into(),
        }),
        "browser::stop_stream" => Ok(json!({ "success": true })),
        _ => Err(RpcError::Internal {
            message: format!("browser method {method} is not engine-owned"),
        }),
    }
}
