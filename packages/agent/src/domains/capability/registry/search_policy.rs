use serde::{Deserialize, Serialize};

use super::index::{risk_rank, trust_rank};
use super::{CapabilityIndexDocument, effect_name, risk_name};
use crate::engine::{ActorContext, EffectClass, FunctionHealth, FunctionQuery, RiskLevel};

/// Profile-controlled search policy.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct CapabilitySearchPolicy {
    pub(crate) lexical: bool,
    pub(crate) local_vector: bool,
    pub(crate) cloud_embeddings: bool,
    pub(crate) max_results: usize,
    pub(crate) require_local_vector: bool,
    pub(crate) allow_lexical_only_when_degraded: bool,
}

impl Default for CapabilitySearchPolicy {
    fn default() -> Self {
        Self {
            lexical: true,
            local_vector: true,
            cloud_embeddings: false,
            max_results: 50,
            require_local_vector: false,
            allow_lexical_only_when_degraded: true,
        }
    }
}

/// Filters accepted by `capability::search`.
#[derive(Clone, Debug, Default)]
pub(crate) struct CapabilitySearchFilters {
    pub(crate) kind: Option<String>,
    pub(crate) contract_id: Option<String>,
    pub(crate) namespace: Option<String>,
    pub(crate) plugin_id: Option<String>,
    pub(crate) effect: Option<EffectClass>,
    pub(crate) risk_max: Option<RiskLevel>,
    pub(crate) trust_tier_min: Option<String>,
    pub(crate) include_unavailable: bool,
    pub(crate) scope: Option<String>,
}

impl CapabilitySearchFilters {
    pub(crate) fn function_query(&self, actor: ActorContext) -> FunctionQuery {
        FunctionQuery {
            actor: Some(actor),
            namespace_prefix: self.namespace.clone(),
            effect_class: self.effect,
            // Discovery must keep enough candidates available for the index to
            // explain when model-supplied risk filters are too narrow. Execution
            // remains policy-enforced at invoke time.
            max_risk: None,
            health: if self.include_unavailable {
                None
            } else {
                Some(FunctionHealth::Healthy)
            },
            ..FunctionQuery::default()
        }
    }

    pub(super) fn allows_document(&self, document: &CapabilityIndexDocument) -> bool {
        if let Some(kind) = &self.kind
            && !document_kind_matches(kind, &document.kind)
        {
            return false;
        }
        if let Some(contract_id) = &self.contract_id
            && document.contract_id != *contract_id
        {
            return false;
        }
        if let Some(namespace) = &self.namespace
            && !document.function_id.starts_with(&format!("{namespace}::"))
            && document.worker_id != *namespace
            && !document.plugin_id.contains(namespace)
        {
            return false;
        }
        if let Some(plugin_id) = &self.plugin_id
            && document.plugin_id != *plugin_id
        {
            return false;
        }
        if let Some(scope) = &self.scope
            && document.visibility != *scope
        {
            return false;
        }
        if let Some(effect) = self.effect
            && document.effect_class != effect_name(effect)
        {
            return false;
        }
        if let Some(risk_max) = self.risk_max
            && risk_rank(&document.risk_level) > risk_rank(risk_name(risk_max))
        {
            return false;
        }
        if let Some(min) = &self.trust_tier_min
            && trust_rank(&document.trust_tier) > trust_rank(min)
        {
            return false;
        }
        if !self.include_unavailable && document.health != "Healthy" && document.health != "ready" {
            return false;
        }
        true
    }

    pub(super) fn without_risk_max(&self) -> Self {
        let mut relaxed = self.clone();
        relaxed.risk_max = None;
        relaxed
    }
}

fn document_kind_matches(filter: &str, document_kind: &str) -> bool {
    match filter.trim().to_ascii_lowercase().as_str() {
        "function" | "functions" => document_kind == "implementation",
        "capability" | "capabilities" => matches!(document_kind, "contract" | "implementation"),
        "contract" | "contracts" => document_kind == "contract",
        "implementation" | "implementations" => document_kind == "implementation",
        "plugin" | "plugins" => document_kind == "plugin",
        "worker" | "workers" => document_kind == "worker",
        other => document_kind == other,
    }
}
