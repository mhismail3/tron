use crate::engine::EngineError;
use crate::shared::server::errors::CapabilityError;

pub(super) fn invalid_params(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

pub(super) fn policy_error(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Custom {
        code: "WORKER_LIFECYCLE_POLICY".to_owned(),
        message: message.into(),
        details: None,
    }
}

pub(super) fn engine_error(error: EngineError) -> CapabilityError {
    CapabilityError::Custom {
        code: "WORKER_LIFECYCLE_ENGINE".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

pub(super) fn internal_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
