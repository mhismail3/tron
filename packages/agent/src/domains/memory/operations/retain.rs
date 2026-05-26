//! Memory operation implementations.
//!
//! Memory retain commands live here behind canonical `memory::*` functions while
//! the retain runtime keeps summarization, persistence, and event emission in a
//! narrow domain service.

use crate::domains::memory::Deps;
use crate::domains::memory::retain as memory_retain;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;

pub(crate) async fn retain(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<serde_json::Value, CapabilityError> {
    memory_retain::trigger_manual_retain(Some(&invocation.payload), deps, Some(invocation.clone()))
        .await
}
