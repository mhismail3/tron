use crate::engine::EngineError;
use crate::shared::server::errors::CapabilityError;

pub(super) fn invalid_params(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

pub(super) fn engine_error(error: EngineError) -> CapabilityError {
    CapabilityError::Custom {
        code: "MEMORY_ENGINE".to_owned(),
        message: error.to_string(),
        details: None,
    }
}
