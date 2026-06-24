use crate::engine::EngineError;
use crate::shared::server::errors::CapabilityError;

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

pub(super) fn engine_error(error: EngineError) -> CapabilityError {
    crate::shared::server::error_mapping::engine_error_to_capability_error(error)
}
