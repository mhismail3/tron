use crate::engine::EngineError;
use crate::shared::server::errors::CapabilityError;

pub(super) fn engine_error(error: EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

pub(super) fn invalid_params(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

pub(super) fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}
