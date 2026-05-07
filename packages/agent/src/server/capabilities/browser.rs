use super::*;

pub(super) async fn handle(method: &str) -> Result<Value, CapabilityError> {
    match method {
        "browser::start_stream" => Err(CapabilityError::NotAvailable {
            message: "Browser streaming has been removed".into(),
        }),
        "browser::stop_stream" => Ok(json!({ "success": true })),
        _ => Err(CapabilityError::Internal {
            message: format!("browser method {method} is not engine-owned"),
        }),
    }
}
