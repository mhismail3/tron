//! Resource version and payload hash helpers.

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::engine::errors::{EngineError, Result};

pub(crate) fn payload_hash(payload: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(payload).map_err(|error| EngineError::LedgerFailure {
        operation: "resource.payload_hash",
        message: error.to_string(),
    })?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(format!("{:x}", hasher.finalize()))
}
