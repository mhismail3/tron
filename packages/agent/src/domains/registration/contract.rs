//! Domain-owned function contract construction.
//!
//! Source domains declare one function contract. Building it produces the exact
//! [`FunctionDefinition`] registered with the engine; handler binding derives
//! the local operation key from the canonical function id. Startup retains no
//! second tool catalog or transport-policy mirror.

use serde_json::Value;

use crate::engine::{
    EffectClass, FunctionDefinition, FunctionId, FunctionVisibility, IdempotencyContract,
    ModelToolAudience, ModelToolContract, Result as EngineResult, RiskLevel, WorkerId,
};

/// Fluent source-domain builder for one executable engine function.
pub(crate) struct FunctionContract {
    function_id: &'static str,
    owner_worker: &'static str,
    effect_class: EffectClass,
    risk_level: RiskLevel,
    visibility: FunctionVisibility,
    request_schema: Option<Value>,
    response_schema: Option<Value>,
    idempotency: Option<IdempotencyContract>,
    description: Option<&'static str>,
    model_tool: Option<ModelToolContract>,
}

impl FunctionContract {
    /// Create a domain-owned function contract with common defaults.
    pub(crate) fn new(
        function_id: &'static str,
        owner_worker: &'static str,
        effect_class: EffectClass,
        risk_level: RiskLevel,
    ) -> Self {
        Self {
            function_id,
            owner_worker,
            effect_class,
            risk_level,
            visibility: FunctionVisibility::Public,
            request_schema: None,
            response_schema: None,
            idempotency: None,
            description: None,
            model_tool: None,
        }
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

    /// Attach the executable idempotency contract for a mutating function.
    pub(crate) fn idempotency(mut self, contract: IdempotencyContract) -> Self {
        self.idempotency = Some(contract);
        self
    }

    /// Attach the canonical model-facing identity and audience.
    pub(crate) fn model_tool(
        mut self,
        name: &'static str,
        audience: ModelToolAudience,
        order: u16,
        group: &'static str,
    ) -> Self {
        self.model_tool = Some(ModelToolContract {
            name: name.to_owned(),
            audience,
            order: Some(order),
            group: Some(group.to_owned()),
            worker: None,
        });
        self
    }

    /// Validate identities and build the exact engine definition.
    pub(crate) fn build(self) -> EngineResult<FunctionDefinition> {
        let function_id = FunctionId::new(self.function_id)?;
        let description = self
            .description
            .map(str::to_owned)
            .unwrap_or_else(|| function_id.as_str().to_owned());
        let mut definition = FunctionDefinition::new(
            function_id,
            WorkerId::new(self.owner_worker)?,
            description,
            self.visibility,
            self.effect_class,
        )
        .with_risk(self.risk_level);
        if let Some(contract) = self.idempotency {
            definition = definition.with_idempotency(contract);
        }
        if let Some(schema) = self.request_schema {
            definition = definition.with_request_schema(schema);
        }
        if let Some(schema) = self.response_schema {
            definition = definition.with_response_schema(schema);
        }
        if let Some(model_tool) = self.model_tool {
            definition = definition.with_model_tool(model_tool);
        }
        Ok(definition)
    }
}
