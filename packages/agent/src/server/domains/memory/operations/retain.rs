//! Memory operation implementations.
//!
//! Memory retain commands live here behind canonical `memory::*` functions while
//! the retain runtime keeps summarization, persistence, and event emission in a
//! narrow domain service.

use super::*;
use crate::server::domains::memory::retain as memory_retain;
use crate::server::shared::errors::CapabilityError;
use serde_json::Value;

pub(crate) async fn retain(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    memory_retain::trigger_manual_retain(Some(payload), deps).await
}
