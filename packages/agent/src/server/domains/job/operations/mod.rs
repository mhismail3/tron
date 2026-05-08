//! Job operation implementations.
//!
//! Queue-backed job commands, hidden apply functions, and job subscription
//! helpers live here behind canonical `job::*` functions.

use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::queue::publish_queue_lifecycle_event;
use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, EngineQueueDrainer,
    EnqueueInvocation, FunctionDefinition, FunctionId, IdempotencyContract, Invocation, Provenance,
    RiskLevel,
};
use tokio_util::sync::CancellationToken;

static ACTIVE_SUBSCRIPTIONS: std::sync::LazyLock<dashmap::DashMap<String, CancellationToken>> =
    std::sync::LazyLock::new(dashmap::DashMap::new);

// Operation modules grouped by workflow.

mod apply;
pub(crate) use apply::*;
mod commands;
pub(crate) use commands::*;
mod status;
pub(crate) use status::*;
mod subscriptions;
pub(crate) use subscriptions::*;
