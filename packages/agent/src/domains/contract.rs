//! Generic capability-contract builders.
//!
//! Domain contracts are the first-party plugin manifest for in-process workers:
//! they declare the canonical function id, schema, authority, risk/effect, and
//! capability metadata that the registry projects into contracts,
//! implementations, search documents, and the generated capability primer.
//!
//! Domain `contract.rs` files own their function inventory, schemas, risk,
//! authority, idempotency, lease, compensation, and stream metadata. This
//! module contains only method-agnostic construction helpers used to turn those
//! local records into engine definitions.

use serde_json::{Map, Value, json};

use super::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::engine::{
    AuthorityRequirement, CompensationContract, DurableOutputContract, EffectClass,
    FunctionDefinition, FunctionId, IdempotencyContract, Provenance, ResourceLeaseRequirement,
    Result as EngineResult, RiskLevel, VisibilityScope, WorkerId,
};

/// Fully-owned contract record supplied by one domain worker.
pub(crate) struct CapabilityContract {
    /// Stable operation key used by the owning domain handler.
    pub(crate) operation_key: String,
    /// Stable canonical function id.
    pub(crate) function_id: &'static str,
    /// Worker that owns the registered function.
    pub(crate) owner_worker: &'static str,
    /// Domain worker namespace that owns behavior.
    pub(crate) domain_worker: &'static str,
    /// Effect class enforced by the engine.
    pub(crate) effect_class: EffectClass,
    /// Risk classification.
    pub(crate) risk_level: RiskLevel,
    /// Catalog visibility.
    pub(crate) visibility: VisibilityScope,
    /// Required domain authority scope.
    pub(crate) authority_scope: Option<&'static str>,
    /// Whether the required authority needs approval.
    pub(crate) approval_required: bool,
    /// Transport-level idempotency mode for engine client protocol bindings.
    pub(crate) idempotency_mode: TransportIdempotencyMode,
    /// Domain module provenance.
    pub(crate) domain_module: &'static str,
    /// Strict request schema.
    pub(crate) request_schema: Option<Value>,
    /// Strict response schema.
    pub(crate) response_schema: Option<Value>,
    /// Mutating idempotency contract.
    pub(crate) idempotency: Option<IdempotencyContract>,
    /// Engine resource lease requirement.
    pub(crate) resource_lease: Option<ResourceLeaseRequirement>,
    /// Durable compensation contract.
    pub(crate) compensation: Option<CompensationContract>,
    /// Durable output contract enforced after handler execution.
    pub(crate) output_contract: DurableOutputContract,
    /// Discovery-visible high-risk contract metadata.
    pub(crate) high_risk_contract: Option<Value>,
    /// Stream topics emitted by the function.
    pub(crate) stream_topics: Vec<&'static str>,
    /// Human-readable discovery description.
    pub(crate) description: Option<&'static str>,
    /// Search/discovery tags.
    pub(crate) tags: Vec<&'static str>,
    /// Compact usage examples rendered by inspect/search/primer surfaces.
    pub(crate) examples: Vec<Value>,
    /// Capability lifecycle metadata consumed by the runner, registry, and
    /// generated clients. This is the contract-native replacement for any
    /// hardcoded interactive-tool lists.
    pub(crate) lifecycle: Option<Value>,
    /// Optional presentation metadata for chip/sheet summaries. Renderers may
    /// use hints such as `themeColor`, but capability identity always comes
    /// from the contract.
    pub(crate) presentation_hints: Option<Value>,
}

impl CapabilityContract {
    /// Create a domain-owned capability contract with common defaults.
    pub(crate) fn new(
        method: &'static str,
        owner_worker: &'static str,
        effect_class: EffectClass,
        risk_level: RiskLevel,
        authority_scope: Option<&'static str>,
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
            domain_worker: owner_worker,
            effect_class,
            risk_level,
            visibility: VisibilityScope::System,
            authority_scope,
            approval_required: false,
            idempotency_mode: TransportIdempotencyMode::NotRequired,
            domain_module: owner_worker,
            request_schema: None,
            response_schema: None,
            idempotency: None,
            resource_lease: None,
            compensation: None,
            output_contract: DurableOutputContract::None,
            high_risk_contract: None,
            stream_topics: Vec::new(),
            description: None,
            tags: Vec::new(),
            examples: Vec::new(),
            lifecycle: None,
            presentation_hints: None,
        }
    }

    /// Override the canonical function id.
    pub(crate) fn function_id(mut self, function_id: &'static str) -> Self {
        self.function_id = function_id;
        self
    }

    /// Override the behavior-owning domain worker.
    pub(crate) fn domain_worker(mut self, domain_worker: &'static str) -> Self {
        self.domain_worker = domain_worker;
        self
    }

    /// Mark the authority requirement as approval-gated.
    pub(crate) fn approval_required(mut self, approval_required: bool) -> Self {
        self.approval_required = approval_required;
        self
    }

    /// Set transport idempotency mode.
    pub(crate) fn idempotency_mode(mut self, mode: TransportIdempotencyMode) -> Self {
        self.idempotency_mode = mode;
        self
    }

    /// Set engine visibility.
    pub(crate) fn visibility(mut self, visibility: VisibilityScope) -> Self {
        self.visibility = visibility;
        self
    }

    /// Set domain module provenance.
    pub(crate) fn domain_module(mut self, module: &'static str) -> Self {
        self.domain_module = module;
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

    /// Attach mutating idempotency metadata.
    pub(crate) fn idempotency(mut self, contract: IdempotencyContract) -> Self {
        self.idempotency = Some(contract);
        self
    }

    /// Attach resource lease metadata.
    pub(crate) fn resource_lease(mut self, requirement: ResourceLeaseRequirement) -> Self {
        self.resource_lease = Some(requirement);
        self
    }

    /// Attach compensation metadata.
    pub(crate) fn compensation(mut self, contract: CompensationContract) -> Self {
        self.compensation = Some(contract);
        self
    }

    /// Attach durable output contract metadata.
    pub(crate) fn output_contract(mut self, contract: DurableOutputContract) -> Self {
        self.output_contract = contract;
        self
    }

    /// Attach high-risk discovery metadata.
    pub(crate) fn high_risk_contract(mut self, contract: Value) -> Self {
        self.high_risk_contract = Some(contract);
        self
    }

    /// Attach stream topics.
    pub(crate) fn stream_topics(mut self, topics: Vec<&'static str>) -> Self {
        self.stream_topics = topics;
        self
    }

    /// Override the discovery description.
    pub(crate) fn description(mut self, description: &'static str) -> Self {
        self.description = Some(description);
        self
    }

    /// Attach search/discovery tags.
    pub(crate) fn tags(mut self, tags: Vec<&'static str>) -> Self {
        self.tags = tags;
        self
    }

    /// Attach compact examples consumed by generated docs and primers.
    pub(crate) fn examples(mut self, examples: Vec<Value>) -> Self {
        self.examples = examples;
        self
    }

    /// Attach lifecycle metadata.
    pub(crate) fn lifecycle(mut self, lifecycle: Value) -> Self {
        self.lifecycle = Some(lifecycle);
        self
    }

    /// Attach presentation hints for generated UI.
    pub(crate) fn presentation_hints(mut self, hints: Value) -> Self {
        self.presentation_hints = Some(hints);
        self
    }

    /// Convert the local domain record to the aggregate catalog shape.
    pub(crate) fn build(self) -> EngineResult<CapabilitySpec> {
        Ok(CapabilitySpec {
            operation_key: self.operation_key,
            function_id: FunctionId::new(self.function_id)?,
            owner_worker: WorkerId::new(self.owner_worker)?,
            domain_worker: WorkerId::new(self.domain_worker)?,
            effect_class: self.effect_class,
            risk_level: self.risk_level,
            visibility: self.visibility,
            authority_scope: self.authority_scope,
            idempotency_mode: self.idempotency_mode,
            domain_module: self.domain_module,
            request_schema: self.request_schema,
            response_schema: self.response_schema,
            idempotency: self.idempotency,
            resource_lease: self.resource_lease,
            compensation: self.compensation,
            output_contract: self.output_contract,
            approval_required: self.approval_required,
            high_risk_contract: self.high_risk_contract,
            stream_topics: self.stream_topics,
            description: self.description,
            tags: self.tags,
            examples: self.examples,
            lifecycle: self.lifecycle,
            presentation_hints: self.presentation_hints,
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
    .with_risk(spec.risk_level)
    .with_tags(spec.tags.iter().map(|tag| (*tag).to_owned()).collect())
    .with_provenance(Provenance::system());
    if let Some(scope) = spec.authority_scope {
        let mut requirement = AuthorityRequirement::scope(scope);
        if spec.approval_required {
            requirement = requirement.with_approval_required();
        }
        definition = definition.with_required_authority(requirement);
    }
    if let Some(contract) = &spec.idempotency {
        definition = definition.with_idempotency(contract.clone());
    }
    if let Some(requirement) = &spec.resource_lease {
        definition = definition.with_resource_lease(requirement.clone());
    }
    if let Some(contract) = &spec.compensation {
        definition = definition.with_compensation(contract.clone());
    }
    definition = definition.with_output_contract(spec.output_contract.clone());
    if let Some(schema) = &spec.request_schema {
        definition = definition.with_request_schema(schema.clone());
    }
    if let Some(schema) = &spec.response_schema {
        definition = definition.with_response_schema(schema.clone());
    }
    let plugin_id = format!("first_party.{}", spec.domain_module);
    let implementation_id = format!(
        "{plugin_id}.v{}.{}",
        definition.revision.0,
        spec.operation_key.as_str()
    );
    let context_primer_level = if matches!(
        spec.function_id.as_str(),
        "capability::search"
            | "capability::inspect"
            | "capability::execute"
            | "filesystem::list_dir"
            | "filesystem::read_file"
            | "filesystem::write_file"
            | "filesystem::edit_file"
            | "filesystem::find"
            | "filesystem::glob"
            | "filesystem::search_text"
            | "filesystem::diff"
            | "filesystem::apply_patch"
            | "process::run"
            | "web::search"
            | "web::fetch"
            | "notifications::send"
            | "agent::ask_user"
            | "agent::status"
            | "agent::submit_answers"
            | "agent::spawn_subagent"
            | "agent::subagent_status"
            | "agent::subagent_result"
            | "agent::cancel_subagent"
            | "job::wait"
            | "job::stream_output"
            | "sandbox::spawn_worker"
            | "sandbox::list_spawned_workers"
            | "sandbox::stop_spawned_worker"
            | "worker::protocol_guide"
    ) {
        "core"
    } else {
        "catalog"
    };
    let stops_turn = spec
        .lifecycle
        .as_ref()
        .and_then(|value| value.get("stopsTurn"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let is_interactive = spec.lifecycle.as_ref().is_some_and(|value| {
        matches!(
            value.get("kind").and_then(Value::as_str),
            Some("approval" | "user_input" | "async_run" | "stream" | "external_interaction")
        )
    });
    let presentation_hints = presentation_hints_for_capability(spec);
    definition.metadata = json!({
        "operationKey": spec.operation_key.as_str(),
        "domainWorker": spec.domain_worker.as_str(),
        "canonicalCapability": spec.function_id.as_str(),
        "contractId": spec.function_id.as_str(),
        "implementationId": implementation_id,
        "pluginId": plugin_id,
        "trustTier": "first_party_signed",
        "contextPrimerLevel": context_primer_level,
        "runtimeRequirements": {
            "workerKind": "in_process",
            "deliveryModes": definition.allowed_delivery_modes.iter().map(|mode| mode.as_str()).collect::<Vec<_>>()
        },
        "examples": spec.examples,
        "domainAuthorityScope": spec.authority_scope,
        "idempotencyMode": spec.idempotency_mode.as_str(),
        "domainModule": spec.domain_module,
        "highRiskContract": spec.high_risk_contract,
        "outputContract": spec.output_contract,
        "streamTopics": spec.stream_topics,
        "lifecycle": spec.lifecycle,
        "stopsTurn": stops_turn,
        "isInteractive": is_interactive,
        "presentationHints": presentation_hints,
    });
    definition
}

fn presentation_hints_for_capability(spec: &CapabilitySpec) -> Value {
    let mut hints = spec
        .presentation_hints
        .as_ref()
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(Map::new);
    if !hints.contains_key("themeColor") {
        if let Some(color) = default_theme_color(spec.function_id.as_str()) {
            hints.insert("themeColor".to_owned(), Value::String(color.to_owned()));
        }
    }
    Value::Object(hints)
}

fn default_theme_color(function_id: &str) -> Option<&'static str> {
    let namespace = function_id
        .split_once("::")
        .map(|(namespace, _)| namespace)?;
    match namespace {
        "capability" => Some("#10B981"),
        "filesystem" => Some("#10B981"),
        "process" => Some("#38BDF8"),
        "web" => Some("#3B82F6"),
        "notifications" => Some("#EC4899"),
        "agent" => Some("#8B5CF6"),
        "job" => Some("#F59E0B"),
        "sandbox" => Some("#A97BFF"),
        "display" => Some("#818CF8"),
        "browser" => Some("#06B6D4"),
        "mcp" => Some("#2DD4BF"),
        _ => None,
    }
}
