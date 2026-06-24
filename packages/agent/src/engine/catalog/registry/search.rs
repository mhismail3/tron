//! Function discovery and catalog search helpers.

use crate::engine::catalog::discovery::FunctionQuery;
use crate::engine::kernel::policy;
use crate::engine::kernel::types::FunctionDefinition;

use super::LiveCatalog;

impl LiveCatalog {
    /// Discover functions.
    #[must_use]
    pub fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition> {
        self.functions
            .values()
            .filter(|entry| {
                let function = &entry.definition;
                let can_include_internal = query
                    .actor
                    .as_ref()
                    .map(|actor| actor.actor_kind.is_admin_like())
                    .unwrap_or(false);
                if !(query.include_internal && can_include_internal)
                    && !policy::is_visible_to_actor(function, query.actor.as_ref())
                {
                    return false;
                }
                if let Some(visibility) = &query.visibility {
                    if &function.visibility != visibility {
                        return false;
                    }
                }
                if let Some(prefix) = &query.namespace_prefix {
                    if !function.id.as_str().starts_with(prefix) {
                        return false;
                    }
                }
                if let Some(effect) = query.effect_class {
                    if function.effect_class != effect {
                        return false;
                    }
                }
                if let Some(max_risk) = query.max_risk {
                    if function.risk_level > max_risk {
                        return false;
                    }
                }
                if let Some(health) = &query.health {
                    if &function.health != health {
                        return false;
                    }
                }
                if let Some(text) = &query.text {
                    let tokens = search_tokens(text);
                    if !tokens.is_empty() {
                        let haystack = function_search_haystack(function);
                        if !tokens.iter().all(|token| haystack.contains(token)) {
                            return false;
                        }
                    }
                }
                true
            })
            .map(|entry| entry.definition.clone())
            .collect()
    }
}

fn search_tokens(text: &str) -> Vec<String> {
    normalize_search_text(text)
        .split_whitespace()
        .map(ToOwned::to_owned)
        .collect()
}

fn function_search_haystack(function: &FunctionDefinition) -> String {
    let mut parts = vec![
        function.id.as_str().to_owned(),
        normalize_search_text(function.id.as_str()),
        function.description.clone(),
    ];
    parts.extend(function.tags.iter().cloned());
    if !function.metadata.is_null()
        && let Ok(metadata) = serde_json::to_string(&function.metadata)
    {
        parts.push(metadata);
    }
    normalize_search_text(&parts.join(" "))
}

fn normalize_search_text(text: &str) -> String {
    text.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                ' '
            }
        })
        .collect()
}
