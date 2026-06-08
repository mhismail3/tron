//! Trigger catalog type contracts.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{DeliveryMode, IdempotencyKeySource, Provenance, TriggerRevision, VisibilityScope};
use crate::engine::kernel::ids::{
    AuthorityGrantId, FunctionId, TriggerId, TriggerTypeId, WorkerId,
};

/// Trigger type catalog definition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TriggerTypeDefinition {
    /// Trigger type id.
    pub id: TriggerTypeId,
    /// Owner worker.
    pub owner_worker: WorkerId,
    /// Description.
    pub description: String,
    /// Config schema.
    pub config_schema: Option<Value>,
    /// Allowed delivery modes.
    pub allowed_delivery_modes: Vec<DeliveryMode>,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Provenance.
    pub provenance: Provenance,
}

impl TriggerTypeDefinition {
    /// Create a trigger type definition.
    #[must_use]
    pub fn new(id: TriggerTypeId, owner_worker: WorkerId, description: impl Into<String>) -> Self {
        Self {
            id,
            owner_worker,
            description: description.into(),
            config_schema: None,
            allowed_delivery_modes: vec![DeliveryMode::Sync],
            visibility: VisibilityScope::Internal,
            provenance: Provenance::system(),
        }
    }
}

/// Trigger catalog definition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TriggerDefinition {
    /// Trigger id.
    pub id: TriggerId,
    /// Trigger revision.
    pub revision: TriggerRevision,
    /// Owner worker.
    pub owner_worker: WorkerId,
    /// Trigger type.
    pub trigger_type: TriggerTypeId,
    /// Target function.
    pub target_function: FunctionId,
    /// Trigger config.
    pub config: Value,
    /// Delivery mode.
    pub delivery_mode: DeliveryMode,
    /// Authority grant used when fired.
    pub authority_grant: AuthorityGrantId,
    /// Idempotency key strategy.
    pub idempotency_key_strategy: Option<IdempotencyKeySource>,
    /// Max causal depth.
    pub max_depth: Option<u32>,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Provenance.
    pub provenance: Provenance,
}

impl TriggerDefinition {
    /// Create a trigger definition.
    #[must_use]
    pub fn new(
        id: TriggerId,
        owner_worker: WorkerId,
        trigger_type: TriggerTypeId,
        target_function: FunctionId,
        authority_grant: AuthorityGrantId,
    ) -> Self {
        Self {
            id,
            revision: TriggerRevision(1),
            owner_worker,
            trigger_type,
            target_function,
            config: Value::Null,
            delivery_mode: DeliveryMode::Sync,
            authority_grant,
            idempotency_key_strategy: None,
            max_depth: None,
            visibility: VisibilityScope::Internal,
            provenance: Provenance::system(),
        }
    }

    /// Set delivery mode.
    #[must_use]
    pub fn with_delivery_mode(mut self, mode: DeliveryMode) -> Self {
        self.delivery_mode = mode;
        self
    }
}
