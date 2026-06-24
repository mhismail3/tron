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
    match error {
        EngineError::PolicyViolation(message) => invalid_params(message),
        EngineError::SchemaViolation { message, .. } => invalid_params(message),
        EngineError::InvalidSchema { message, .. } => invalid_params(message),
        EngineError::InvalidId { kind, value } => {
            invalid_params(format!("invalid {kind}: {value}"))
        }
        EngineError::NotFound { kind, id } => invalid_params(format!("{kind} not found: {id}")),
        other => internal(other.to_string()),
    }
}
