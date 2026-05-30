//! Capability recipe authoring for resolve/prepare guidance.

use serde_json::{Value, json};
use std::collections::BTreeSet;

use super::{
    CapabilityRegistryEntry, compact_description, conditional_approval_contract,
    direct_execution_allowed, display_name, examples, requires_fresh_revision,
};
use crate::domains::capability::types::AgentCapabilityRecipe;
use crate::engine::FunctionDefinition;

pub(super) fn agent_recipe_for_entry(entry: &CapabilityRegistryEntry) -> AgentCapabilityRecipe {
    let function = &entry.function;
    let required_payload = recipe_payload_fields(function.request_schema.as_ref(), true);
    let optional_payload = recipe_payload_fields(function.request_schema.as_ref(), false);
    let examples = recipe_examples(entry);
    let execute_template = examples
        .first()
        .cloned()
        .unwrap_or_else(|| recipe_execute_template(entry, recipe_payload_example(function)));
    let inspect_required = recipe_inspect_required(function);
    AgentCapabilityRecipe {
        contract_id: entry.contract_id.clone(),
        display_name: display_name(function),
        use_when: recipe_use_when(function),
        execute_template,
        required_payload,
        optional_payload,
        examples,
        direct_execution: recipe_direct_execution(function).to_owned(),
        inspect_required,
        approval_behavior: recipe_approval_behavior(function).to_owned(),
        lifecycle_kind: recipe_lifecycle_kind(function),
        result_summary: recipe_result_summary(function.response_schema.as_ref()),
        aliases: recipe_aliases(function),
    }
}

#[derive(Clone, Debug)]
pub(crate) struct AgentCapabilityRecipeDisplay {
    pub(crate) execute_template_json: Option<String>,
    pub(crate) required_arguments: String,
    pub(crate) optional_arguments: String,
    optional_payload: Vec<String>,
    pub(crate) search_execution_guidance: String,
    pub(crate) approval_guidance: Option<String>,
    pub(crate) primer_execution_guidance: Option<String>,
    pub(crate) risky_direct_example_json: Option<String>,
}

impl AgentCapabilityRecipeDisplay {
    pub(crate) fn new(recipe: &AgentCapabilityRecipe) -> Self {
        Self {
            execute_template_json: serde_json::to_string(&recipe.execute_template).ok(),
            required_arguments: display_field_list(&recipe.required_payload),
            optional_arguments: display_field_list(&recipe.optional_payload),
            optional_payload: recipe.optional_payload.clone(),
            search_execution_guidance: if recipe.inspect_required {
                "Freshness is required for elevated-risk work; model-facing execute prepares it before approval.".to_owned()
            } else {
                format!("Direct execution: {}.", recipe.direct_execution)
            },
            approval_guidance: (recipe.approval_behavior != "none")
                .then(|| format!("Approval: {}.", recipe.approval_behavior)),
            primer_execution_guidance: primer_execution_guidance(recipe),
            risky_direct_example_json: risky_direct_recipe_example_json(recipe),
        }
    }

    pub(crate) fn optional_arguments_limited(&self, limit: usize) -> Option<String> {
        if self.optional_payload.is_empty() {
            return None;
        }
        Some(
            self.optional_payload
                .iter()
                .take(limit)
                .cloned()
                .collect::<Vec<_>>()
                .join("; "),
        )
    }
}

fn display_field_list(fields: &[String]) -> String {
    if fields.is_empty() {
        "none".to_owned()
    } else {
        fields.join("; ")
    }
}

fn primer_execution_guidance(recipe: &AgentCapabilityRecipe) -> Option<String> {
    if recipe.inspect_required {
        return Some(" Execute prepares freshness before elevated-risk work.".to_owned());
    }
    if recipe.approval_behavior != "none" {
        return Some(format!(" Approval: {}.", recipe.approval_behavior));
    }
    if recipe.direct_execution == "conditional_safe_direct" {
        return Some(
            " Safe payloads run directly; risky payloads may pause for approval.".to_owned(),
        );
    }
    None
}

fn risky_direct_recipe_example_json(recipe: &AgentCapabilityRecipe) -> Option<String> {
    if recipe.direct_execution != "conditional_safe_direct" {
        return None;
    }
    recipe
        .examples
        .iter()
        .find(|example| {
            example["arguments"]["executionMode"] == "sandbox_materialized"
                && example["arguments"]["expectedOutputs"].is_array()
        })
        .and_then(|example| serde_json::to_string(example).ok())
}

fn recipe_use_when(function: &FunctionDefinition) -> String {
    let description = compact_description(&function.description);
    if description.starts_with("Canonical domain capability ") {
        format!(
            "Use for {} work through the `{}` capability.",
            function.id.namespace(),
            function.id.as_str()
        )
    } else {
        description
    }
}

fn recipe_payload_fields(schema: Option<&Value>, required_only: bool) -> Vec<String> {
    let Some(schema) = schema else {
        return Vec::new();
    };
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return Vec::new();
    };
    properties
        .iter()
        .filter(|(name, _)| required.contains(name.as_str()) == required_only)
        .take(if required_only { 12 } else { 16 })
        .map(|(name, field)| recipe_field_summary(name, field))
        .collect()
}

fn recipe_field_summary(name: &str, field: &Value) -> String {
    let ty = recipe_schema_type(field);
    let mut summary = format!("{name}: {ty}");
    if let Some(values) = field.get("enum").and_then(Value::as_array) {
        let values = values
            .iter()
            .filter_map(Value::as_str)
            .take(8)
            .collect::<Vec<_>>();
        if !values.is_empty() {
            summary.push_str(&format!(" [{}]", values.join("|")));
        }
    }
    if let Some(description) = field.get("description").and_then(Value::as_str)
        && !description.trim().is_empty()
    {
        summary.push_str(&format!(" - {}", compact_description(description)));
    }
    summary
}

fn recipe_schema_type(field: &Value) -> String {
    if let Some(ty) = field.get("type") {
        if let Some(ty) = ty.as_str() {
            if ty == "array" {
                let item_ty = field
                    .get("items")
                    .map(recipe_schema_type)
                    .unwrap_or_else(|| "value".to_owned());
                return format!("array<{item_ty}>");
            }
            return ty.to_owned();
        }
        if let Some(types) = ty.as_array() {
            let types = types.iter().filter_map(Value::as_str).collect::<Vec<_>>();
            if !types.is_empty() {
                return types.join("|");
            }
        }
    }
    if field.get("oneOf").is_some() {
        return "oneOf".to_owned();
    }
    if field.get("anyOf").is_some() {
        return "anyOf".to_owned();
    }
    "value".to_owned()
}

fn recipe_examples(entry: &CapabilityRegistryEntry) -> Vec<Value> {
    let existing = examples(&entry.function)
        .into_iter()
        .filter_map(|example| normalize_recipe_example(entry, example))
        .take(4)
        .collect::<Vec<_>>();
    if existing.is_empty() {
        vec![recipe_execute_template(
            entry,
            recipe_payload_example(&entry.function),
        )]
    } else {
        existing
    }
}

fn normalize_recipe_example(entry: &CapabilityRegistryEntry, example: Value) -> Option<Value> {
    if example.get("mode").is_some() || example.get("payload").is_some() {
        let mut object = example.as_object()?.clone();
        let payload = object.remove("payload").unwrap_or_else(|| json!({}));
        let mut template = recipe_execute_template(entry, payload);
        if let Some(reason) = object.remove("reason") {
            template["reason"] = reason;
        }
        if let Some(idempotency_key) = object.remove("idempotencyKey") {
            template["idempotencyKey"] = idempotency_key;
        }
        return Some(template);
    }
    Some(recipe_execute_template(entry, example))
}

fn recipe_execute_template(entry: &CapabilityRegistryEntry, payload: Value) -> Value {
    json!({
        "intent": default_recipe_reason(entry),
        "target": entry.contract_id.clone(),
        "arguments": payload,
        "reason": default_recipe_reason(entry)
    })
}

fn default_recipe_reason(entry: &CapabilityRegistryEntry) -> String {
    format!("Use {} for the requested work.", entry.contract_id)
}

fn recipe_payload_example(function: &FunctionDefinition) -> Value {
    let Some(schema) = function.request_schema.as_ref() else {
        return json!({});
    };
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return json!({});
    };
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let mut payload = serde_json::Map::new();
    for name in &required {
        if let Some(field) = properties.get(*name) {
            payload.insert(
                (*name).to_owned(),
                recipe_example_value(name, field, function),
            );
        }
    }
    if should_show_expected_current_version_guard(properties, &required)
        && let Some(field) = properties.get("expectedCurrentVersionId")
    {
        payload.insert(
            "expectedCurrentVersionId".to_owned(),
            recipe_example_value("expectedCurrentVersionId", field, function),
        );
    }
    Value::Object(payload)
}

fn should_show_expected_current_version_guard(
    properties: &serde_json::Map<String, Value>,
    required: &BTreeSet<&str>,
) -> bool {
    properties.contains_key("expectedCurrentVersionId")
        && required.contains("resourceId")
        && required.len() == 1
}

fn recipe_example_value(name: &str, field: &Value, function: &FunctionDefinition) -> Value {
    if let Some(values) = field.get("enum").and_then(Value::as_array)
        && let Some(value) = values.first()
    {
        return value.clone();
    }
    match name {
        "command" => Value::String("date".to_owned()),
        "path" | "filePath" | "file_path" => Value::String("README.md".to_owned()),
        "pattern" => Value::String("TODO".to_owned()),
        "query" => Value::String("project documentation".to_owned()),
        "url" => Value::String("https://example.com".to_owned()),
        "title" => Value::String("Tron update".to_owned()),
        "body" => Value::String("Task finished.".to_owned()),
        "content" | "newContent" => Value::String("example content".to_owned()),
        "expectedCurrentVersionId" => Value::String("<currentVersionId>".to_owned()),
        "oldString" => Value::String("old text".to_owned()),
        "newString" => Value::String("new text".to_owned()),
        "task" => Value::String("Investigate the requested topic and report findings.".to_owned()),
        "ids" => json!(["job-<id>"]),
        "questions" => json!([{
            "header": "Choice",
            "id": "choice",
            "question": "Which option should I use?",
            "options": [{"label": "Option A (Recommended)", "description": "Use this path."}]
        }]),
        "code" if function.id.as_str() == "program::run_javascript" => {
            Value::String("return args;".to_owned())
        }
        other => {
            let ty = field
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("string");
            match ty {
                "integer" | "number" => json!(1),
                "boolean" => json!(true),
                "array" => json!([]),
                "object" => json!({}),
                _ => Value::String(format!("<{other}>")),
            }
        }
    }
}

fn recipe_inspect_required(function: &FunctionDefinition) -> bool {
    if matches!(function.id.as_str(), "process::run" | "notifications::send") {
        return false;
    }
    requires_fresh_revision(function)
}

fn recipe_direct_execution(function: &FunctionDefinition) -> &'static str {
    if function.id.as_str() == "process::run" {
        "conditional_safe_direct"
    } else if function.id.as_str() == "notifications::send" || !requires_fresh_revision(function) {
        "direct"
    } else if direct_execution_allowed(function) {
        "direct_with_idempotency"
    } else {
        "inspect_first"
    }
}

fn recipe_approval_behavior(function: &FunctionDefinition) -> &'static str {
    if function.required_authority.approval_required {
        "always_pauses_for_user_approval"
    } else if !conditional_approval_contract(function).is_null() {
        "conditional; payloads classified as risky pause for user approval"
    } else {
        "none"
    }
}

fn recipe_lifecycle_kind(function: &FunctionDefinition) -> String {
    function
        .metadata
        .pointer("/lifecycle/kind")
        .and_then(Value::as_str)
        .or_else(|| {
            if function
                .metadata
                .get("streamTopics")
                .and_then(Value::as_array)
                .is_some_and(|topics| !topics.is_empty())
            {
                Some("stream")
            } else {
                None
            }
        })
        .unwrap_or("immediate")
        .to_owned()
}

fn recipe_result_summary(schema: Option<&Value>) -> String {
    let Some(schema) = schema else {
        return "Returns a structured capability result.".to_owned();
    };
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return "Returns a structured capability result.".to_owned();
    };
    let fields = properties.keys().take(8).cloned().collect::<Vec<_>>();
    if fields.is_empty() {
        "Returns a structured capability result.".to_owned()
    } else {
        format!("Returns fields: {}.", fields.join(", "))
    }
}

fn recipe_aliases(function: &FunctionDefinition) -> Vec<String> {
    let mut aliases = BTreeSet::new();
    aliases.insert(function.id.as_str().to_owned());
    aliases.insert(function.id.namespace().to_owned());
    if let Some((_, name)) = function.id.as_str().rsplit_once("::") {
        aliases.insert(name.replace('_', " "));
    }
    for tag in &function.tags {
        aliases.insert(tag.to_owned());
    }
    aliases.into_iter().take(24).collect()
}
