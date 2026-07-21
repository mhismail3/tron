//! Generic capability-contract builders.
//!
//! Domain contracts are the primitive manifest for retained in-process workers:
//! they declare the canonical function id, schema, risk/effect, and emitted
//! stream topics.
//!
//! Domain `contract.rs` files own their function inventory, schemas, risk,
//! idempotency, and stream declarations. This
//! module contains only method-agnostic construction helpers used to turn those
//! local records into engine definitions.

use serde_json::Value;

use super::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionId, FunctionVisibility, IdempotencyContract,
    Result as EngineResult, RiskLevel, WorkerId,
};

/// Fully-owned contract record supplied by one source domain.
pub(crate) struct CapabilityContract {
    /// Stable operation key used by the owning domain handler.
    pub(crate) operation_key: String,
    /// Stable canonical function id.
    pub(crate) function_id: &'static str,
    /// Worker that owns the registered function.
    pub(crate) owner_worker: &'static str,
    /// Effect class enforced by the engine.
    pub(crate) effect_class: EffectClass,
    /// Risk classification.
    pub(crate) risk_level: RiskLevel,
    /// Catalog visibility.
    pub(crate) visibility: FunctionVisibility,
    /// Transport-level idempotency mode for engine client protocol bindings.
    pub(crate) idempotency_mode: TransportIdempotencyMode,
    /// Strict request schema.
    pub(crate) request_schema: Option<Value>,
    /// Strict response schema.
    pub(crate) response_schema: Option<Value>,
    /// Mutating idempotency contract.
    pub(crate) idempotency: Option<IdempotencyContract>,
    /// Stream topics emitted by the function.
    pub(crate) stream_topics: Vec<&'static str>,
    /// Human-readable discovery description.
    pub(crate) description: Option<&'static str>,
}

impl CapabilityContract {
    /// Create a domain-owned capability contract with common defaults.
    pub(crate) fn new(
        method: &'static str,
        owner_worker: &'static str,
        effect_class: EffectClass,
        risk_level: RiskLevel,
    ) -> Self {
        let operation_key = method
            .rsplit_once("::")
            .map(|(_, key)| key)
            .unwrap_or(method)
            .to_string();
        Self {
            operation_key,
            function_id: method,
            owner_worker,
            effect_class,
            risk_level,
            visibility: FunctionVisibility::Public,
            idempotency_mode: TransportIdempotencyMode::NotRequired,
            request_schema: None,
            response_schema: None,
            idempotency: None,
            stream_topics: Vec::new(),
            description: None,
        }
    }

    /// Set transport idempotency mode.
    pub(crate) fn idempotency_mode(mut self, mode: TransportIdempotencyMode) -> Self {
        self.idempotency_mode = mode;
        self
    }

    /// Set engine visibility.
    pub(crate) fn visibility(mut self, visibility: FunctionVisibility) -> Self {
        self.visibility = visibility;
        self
    }

    /// Attach a request schema.
    pub(crate) fn request_schema(mut self, schema: Value) -> Self {
        self.request_schema = Some(schema);
        self
    }

    /// Attach a response schema.
    pub(crate) fn response_schema(mut self, schema: Value) -> Self {
        self.response_schema = Some(schema);
        self
    }

    /// Attach a human-readable discovery description.
    pub(crate) fn description(mut self, description: &'static str) -> Self {
        self.description = Some(description);
        self
    }

    /// Attach mutating idempotency metadata.
    pub(crate) fn idempotency(mut self, contract: IdempotencyContract) -> Self {
        self.idempotency = Some(contract);
        self
    }

    /// Attach stream topics.
    pub(crate) fn stream_topics(mut self, topics: Vec<&'static str>) -> Self {
        self.stream_topics = topics;
        self
    }

    /// Convert the local domain record to the aggregate catalog shape.
    pub(crate) fn build(self) -> EngineResult<CapabilitySpec> {
        Ok(CapabilitySpec {
            operation_key: self.operation_key,
            function_id: FunctionId::new(self.function_id)?,
            owner_worker: WorkerId::new(self.owner_worker)?,
            effect_class: self.effect_class,
            risk_level: self.risk_level,
            visibility: self.visibility,
            idempotency_mode: self.idempotency_mode,
            request_schema: self.request_schema,
            response_schema: self.response_schema,
            idempotency: self.idempotency,
            stream_topics: self.stream_topics,
            description: self.description,
        })
    }
}

/// Build an engine function definition from one domain-owned contract.
pub(crate) fn function_definition_for_capability(spec: &CapabilitySpec) -> FunctionDefinition {
    let mut definition = FunctionDefinition::new(
        spec.function_id.clone(),
        spec.owner_worker.clone(),
        spec.description.map(str::to_owned).unwrap_or_else(|| {
            format!("Canonical domain capability {}", spec.function_id.as_str())
        }),
        spec.visibility.clone(),
        spec.effect_class,
    )
    .with_risk(spec.risk_level);
    if let Some(contract) = &spec.idempotency {
        definition = definition.with_idempotency(contract.clone());
    }
    if let Some(schema) = &spec.request_schema {
        definition = definition.with_request_schema(schema.clone());
    }
    if let Some(schema) = &spec.response_schema {
        definition = definition.with_response_schema(schema.clone());
    }
    definition
}
