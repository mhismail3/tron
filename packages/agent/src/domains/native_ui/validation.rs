//! Fail-closed A2UI v0.9.1 and Tron catalog validation.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use super::catalog::{
    A2UI_VERSION, CATALOG_ID, CATALOG_REVISION, DEFINITION_SCHEMA_VERSION, MAX_ACTIONS,
    MAX_COMPONENTS, MAX_DEPTH, MAX_PAYLOAD_BYTES, MAX_TEXT_BYTES, allowed_component_properties,
    client_function_contract, is_component, is_modifier, modifier_supports_component,
    supports_client_function,
};
use super::model::{NativeUIDefinition, ValidationDiagnostic, ValidationReport};
use crate::engine::{ActorContext, EngineHostHandle, FunctionId};

pub(crate) fn parse_definition(value: &Value) -> Result<NativeUIDefinition, ValidationDiagnostic> {
    serde_json::from_value(value.clone()).map_err(|error| {
        ValidationDiagnostic::new(
            "definition.invalid_envelope",
            "/",
            format!("definition envelope is invalid: {error}"),
        )
    })
}

pub(crate) fn content_hash(definition: &NativeUIDefinition) -> String {
    let encoded = serde_json::to_vec(definition).expect("serializable native UI definition");
    hex::encode(Sha256::digest(encoded))
}

pub(crate) fn validate_structure(definition: &NativeUIDefinition) -> ValidationReport {
    let mut diagnostics = Vec::new();
    let encoded = serde_json::to_vec(definition).unwrap_or_default();
    if encoded.len() > MAX_PAYLOAD_BYTES {
        push(
            &mut diagnostics,
            "definition.payload_too_large",
            "/",
            format!(
                "definition is {} bytes; maximum is {MAX_PAYLOAD_BYTES}",
                encoded.len()
            ),
        );
    }
    if definition.schema_version != DEFINITION_SCHEMA_VERSION {
        push(
            &mut diagnostics,
            "definition.unsupported_schema",
            "/schemaVersion",
            format!(
                "schemaVersion must be {DEFINITION_SCHEMA_VERSION}, got {}",
                definition.schema_version
            ),
        );
    }
    if definition.definition_id.trim().is_empty() || definition.definition_id.len() > 128 {
        push(
            &mut diagnostics,
            "definition.invalid_id",
            "/definitionId",
            "definitionId must contain 1-128 characters",
        );
    }
    if definition.catalog_id != CATALOG_ID || definition.catalog_revision != CATALOG_REVISION {
        push(
            &mut diagnostics,
            "catalog.unsupported",
            "/catalogId",
            format!("only catalog {CATALOG_ID} revision {CATALOG_REVISION} is supported"),
        );
    }
    validate_presentation(definition, &mut diagnostics);
    validate_messages(definition, &mut diagnostics);
    let total_text = definition.messages.iter().map(text_bytes).sum::<usize>()
        + definition.presentation.title.len();
    if total_text > MAX_TEXT_BYTES {
        push(
            &mut diagnostics,
            "definition.text_too_large",
            "/messages",
            format!("definition text is {total_text} bytes; maximum is {MAX_TEXT_BYTES}"),
        );
    }
    ValidationReport {
        valid: diagnostics.is_empty(),
        content_hash: content_hash(definition),
        diagnostics,
    }
}

pub(crate) async fn validate_capability_bindings(
    definition: &NativeUIDefinition,
    engine_host: &EngineHostHandle,
    actor: &ActorContext,
) -> Vec<ValidationDiagnostic> {
    let mut bindings = Vec::new();
    for (message_index, message) in definition.messages.iter().enumerate() {
        let Some(components) = message
            .get("updateComponents")
            .and_then(|value| value.get("components"))
            .and_then(Value::as_array)
        else {
            continue;
        };
        for (component_index, component) in components.iter().enumerate() {
            if let Some(action) = component.get("action") {
                collect_capability_bindings(
                    action,
                    &format!(
                        "/messages/{message_index}/updateComponents/components/{component_index}/action"
                    ),
                    &mut bindings,
                );
            }
        }
    }

    let mut diagnostics = Vec::new();
    for (path, function_id, argument_template) in bindings {
        if function_id.starts_with("native_ui::") {
            push(
                &mut diagnostics,
                "action.recursive_native_ui",
                path,
                "surface actions cannot invoke native_ui publication or dispatch capabilities",
            );
            continue;
        }
        let parsed = match FunctionId::new(function_id.clone()) {
            Ok(parsed) => parsed,
            Err(error) => {
                push(
                    &mut diagnostics,
                    "action.invalid_function_id",
                    path,
                    error.to_string(),
                );
                continue;
            }
        };
        let function = match engine_host.inspect_function(&parsed, Some(actor)).await {
            Ok(function) => function,
            Err(error) => {
                push(
                    &mut diagnostics,
                    "action.unknown_capability",
                    path,
                    format!("capability {function_id} is unavailable: {error}"),
                );
                continue;
            }
        };
        if !function
            .allowed_delivery_modes
            .contains(&crate::engine::DeliveryMode::Sync)
        {
            push(
                &mut diagnostics,
                "action.unsupported_delivery_mode",
                path.clone(),
                format!("capability {function_id} does not allow synchronous invocation"),
            );
        }
        if !matches!(function.effect_class, crate::engine::EffectClass::PureRead)
            && function.idempotency.is_none()
        {
            push(
                &mut diagnostics,
                "action.missing_idempotency_contract",
                path.clone(),
                format!("mutating capability {function_id} has no idempotency contract"),
            );
        }
        match function.request_schema.as_ref() {
            Some(schema) => validate_template_against_schema(
                &argument_template,
                schema,
                &format!("{}/argumentTemplate", path.trim_end_matches("/functionId")),
                &mut diagnostics,
            ),
            None => push(
                &mut diagnostics,
                "action.missing_request_schema",
                path,
                format!("capability {function_id} has no request schema"),
            ),
        }
    }
    diagnostics
}

/// Returns every native client function referenced by a validated message set,
/// including result-action chains.
pub(crate) fn required_client_functions(messages: &[Value]) -> BTreeSet<(String, u64)> {
    let mut functions = BTreeSet::new();
    for message in messages {
        let Some(components) = message
            .get("updateComponents")
            .and_then(|value| value.get("components"))
            .and_then(Value::as_array)
        else {
            continue;
        };
        for component in components {
            if let Some(action) = component.get("action") {
                collect_client_functions(action, &mut functions);
            }
        }
    }
    functions
}

fn validate_presentation(
    definition: &NativeUIDefinition,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    if definition.presentation.title.trim().is_empty() || definition.presentation.title.len() > 160
    {
        push(
            diagnostics,
            "presentation.invalid_title",
            "/presentation/title",
            "title must contain 1-160 characters",
        );
    }
    if definition.presentation.detents.is_empty() || definition.presentation.detents.len() > 3 {
        push(
            diagnostics,
            "presentation.invalid_detents",
            "/presentation/detents",
            "detents must contain 1-3 values",
        );
    }
    for (index, detent) in definition.presentation.detents.iter().enumerate() {
        if !matches!(detent.as_str(), "small" | "medium" | "large") {
            push(
                diagnostics,
                "presentation.unsupported_detent",
                format!("/presentation/detents/{index}"),
                format!("unsupported detent {detent}"),
            );
        }
    }
}

fn validate_messages(definition: &NativeUIDefinition, diagnostics: &mut Vec<ValidationDiagnostic>) {
    if definition.messages.is_empty() {
        push(
            diagnostics,
            "a2ui.missing_messages",
            "/messages",
            "at least one A2UI message is required",
        );
        return;
    }
    let mut logical_surface_id: Option<String> = None;
    let mut create_count = 0;
    let mut components = BTreeMap::<String, Value>::new();
    let mut action_count = 0;

    for (message_index, message) in definition.messages.iter().enumerate() {
        let path = format!("/messages/{message_index}");
        let Some(object) = message.as_object() else {
            push(
                diagnostics,
                "a2ui.message_not_object",
                path,
                "A2UI message must be an object",
            );
            continue;
        };
        if object.get("version").and_then(Value::as_str) != Some(A2UI_VERSION) {
            push(
                diagnostics,
                "a2ui.unsupported_version",
                format!("{path}/version"),
                format!("version must be {A2UI_VERSION}"),
            );
        }
        let operations = [
            "createSurface",
            "updateComponents",
            "updateDataModel",
            "deleteSurface",
        ]
        .into_iter()
        .filter(|key| object.contains_key(*key))
        .collect::<Vec<_>>();
        if object.len() != 2 || operations.len() != 1 {
            push(
                diagnostics,
                "a2ui.invalid_message_shape",
                path.clone(),
                "message must contain version and exactly one canonical A2UI operation",
            );
            continue;
        }
        match operations[0] {
            "createSurface" => {
                create_count += 1;
                if message_index != 0 || create_count > 1 {
                    push(
                        diagnostics,
                        "a2ui.invalid_create_order",
                        path.clone(),
                        "createSurface must appear exactly once as the first message",
                    );
                }
                let Some(create) = object.get("createSurface").and_then(Value::as_object) else {
                    push(
                        diagnostics,
                        "a2ui.invalid_create",
                        format!("{path}/createSurface"),
                        "createSurface must be an object",
                    );
                    continue;
                };
                validate_exact_keys(
                    create,
                    &["surfaceId", "catalogId"],
                    &["theme", "sendDataModel"],
                    &format!("{path}/createSurface"),
                    diagnostics,
                );
                let surface_id = required_string(
                    create,
                    "surfaceId",
                    &format!("{path}/createSurface"),
                    diagnostics,
                );
                if let Some(surface_id) = surface_id {
                    logical_surface_id = Some(surface_id.to_owned());
                }
                if create.get("catalogId").and_then(Value::as_str)
                    != Some(definition.catalog_id.as_str())
                {
                    push(
                        diagnostics,
                        "a2ui.catalog_mismatch",
                        format!("{path}/createSurface/catalogId"),
                        "createSurface catalogId must match the definition catalogId",
                    );
                }
            }
            "updateComponents" => validate_component_update(
                object.get("updateComponents"),
                &path,
                logical_surface_id.as_deref(),
                &mut components,
                &mut action_count,
                diagnostics,
            ),
            "updateDataModel" => validate_data_update(
                object.get("updateDataModel"),
                &path,
                logical_surface_id.as_deref(),
                diagnostics,
            ),
            "deleteSurface" => push(
                diagnostics,
                "a2ui.deleted_definition",
                path,
                "stored definitions cannot finish by deleting their own surface",
            ),
            _ => unreachable!(),
        }
    }

    if create_count != 1 {
        push(
            diagnostics,
            "a2ui.missing_create",
            "/messages",
            "definition requires exactly one createSurface message",
        );
    }
    if components.len() > MAX_COMPONENTS {
        push(
            diagnostics,
            "catalog.too_many_components",
            "/messages",
            format!(
                "surface contains {} components; maximum is {MAX_COMPONENTS}",
                components.len()
            ),
        );
    }
    if action_count > MAX_ACTIONS {
        push(
            diagnostics,
            "catalog.too_many_actions",
            "/messages",
            format!("surface contains {action_count} actions; maximum is {MAX_ACTIONS}"),
        );
    }
    validate_component_graph(&components, diagnostics);
}

fn validate_component_update(
    value: Option<&Value>,
    message_path: &str,
    logical_surface_id: Option<&str>,
    components: &mut BTreeMap<String, Value>,
    action_count: &mut usize,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let path = format!("{message_path}/updateComponents");
    let Some(update) = value.and_then(Value::as_object) else {
        push(
            diagnostics,
            "a2ui.invalid_component_update",
            path,
            "updateComponents must be an object",
        );
        return;
    };
    validate_exact_keys(
        update,
        &["surfaceId", "components"],
        &[],
        &path,
        diagnostics,
    );
    validate_surface_id(update, logical_surface_id, &path, diagnostics);
    let Some(batch) = update.get("components").and_then(Value::as_array) else {
        push(
            diagnostics,
            "a2ui.invalid_components",
            format!("{path}/components"),
            "components must be a non-empty array",
        );
        return;
    };
    if batch.is_empty() {
        push(
            diagnostics,
            "a2ui.empty_components",
            format!("{path}/components"),
            "components must be a non-empty array",
        );
    }
    let mut batch_ids = BTreeSet::new();
    for (index, component) in batch.iter().enumerate() {
        let component_path = format!("{path}/components/{index}");
        let Some(object) = component.as_object() else {
            push(
                diagnostics,
                "catalog.component_not_object",
                component_path,
                "component must be an object",
            );
            continue;
        };
        let Some(id) = required_string(object, "id", &component_path, diagnostics) else {
            continue;
        };
        if id.len() > 128 || !batch_ids.insert(id.to_owned()) {
            push(
                diagnostics,
                "catalog.invalid_component_id",
                format!("{component_path}/id"),
                "component id must be unique within a batch and no longer than 128 characters",
            );
            continue;
        }
        let Some(kind) = required_string(object, "component", &component_path, diagnostics) else {
            continue;
        };
        if !is_component(kind) {
            push(
                diagnostics,
                "catalog.unknown_component",
                format!("{component_path}/component"),
                format!("unsupported component {kind}"),
            );
            continue;
        }
        let allowed = allowed_component_properties(kind);
        for key in object.keys() {
            if !allowed.contains(key.as_str()) {
                push(
                    diagnostics,
                    "catalog.unknown_property",
                    format!("{component_path}/{key}"),
                    format!("property {key} is not valid for {kind}"),
                );
            }
        }
        validate_component_required_fields(kind, object, &component_path, diagnostics);
        validate_component_values(kind, object, &component_path, diagnostics);
        validate_modifiers(kind, object.get("modifiers"), &component_path, diagnostics);
        if let Some(action) = object.get("action") {
            *action_count +=
                validate_action(action, &format!("{component_path}/action"), diagnostics);
        }
        let _ = components.insert(id.to_owned(), component.clone());
    }
}

fn validate_component_values(
    kind: &str,
    object: &Map<String, Value>,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    validate_typed_property(
        object,
        "visible",
        path,
        "boolean",
        true,
        Value::is_boolean,
        diagnostics,
    );
    validate_typed_property(
        object,
        "accessibilityLabel",
        path,
        "string",
        true,
        Value::is_string,
        diagnostics,
    );

    let (strings, numbers, booleans): (&[&str], &[&str], &[&str]) = match kind {
        "Surface" => (&["child"], &[], &[]),
        "Navigation" => (&["child", "title"], &[], &[]),
        "Scroll" => (&["child", "axis"], &[], &["showsIndicators"]),
        "Row" | "Column" | "Overlay" => (&["alignment"], &["spacing"], &[]),
        "Grid" => (&[], &["columns", "spacing"], &[]),
        "AdaptiveColumns" => (&[], &["minimumColumnWidth", "spacing"], &[]),
        "List" => (&[], &["spacing"], &[]),
        "Section" => (&["title", "icon", "footer"], &[], &[]),
        "GlassCard" => (&["accent"], &[], &["interactive"]),
        "Divider" => (&["orientation"], &[], &[]),
        "Spacer" => (&[], &["minimumLength"], &[]),
        "Text" => (
            &["text", "label", "icon", "style", "format"],
            &[],
            &["selectable"],
        ),
        "Image" => (&["name", "url", "contentMode"], &[], &[]),
        "Icon" => (&["systemName", "tone"], &["size"], &[]),
        "Badge" => (&["text", "tone"], &[], &[]),
        "Progress" => (&["label"], &["value", "total"], &[]),
        "EmptyState" => (&["title", "message", "systemImage"], &[], &[]),
        "Button" => (&["label", "value", "icon", "role"], &[], &[]),
        "Toggle" => (&["label", "icon"], &[], &[]),
        "Slider" | "Stepper" => (
            &["label", "icon", "format", "commit"],
            &["value", "minimum", "maximum", "step"],
            &[],
        ),
        "TextField" | "SecureField" => (&["label", "value", "placeholder"], &[], &[]),
        "ChoicePicker" => (&["label", "value"], &[], &[]),
        "Menu" => (&["label", "icon"], &[], &[]),
        "ResourcePicker" => (&["label", "kind", "selected"], &[], &[]),
        "NativeSlot" => (&["name"], &[], &[]),
        _ => (&[], &[], &[]),
    };
    for key in strings {
        validate_typed_property(
            object,
            key,
            path,
            "string",
            true,
            Value::is_string,
            diagnostics,
        );
    }
    for key in numbers {
        validate_typed_property(
            object,
            key,
            path,
            "finite number",
            *key == "value",
            |value| value.as_f64().is_some_and(f64::is_finite),
            diagnostics,
        );
    }
    for key in booleans {
        validate_typed_property(
            object,
            key,
            path,
            "boolean",
            false,
            Value::is_boolean,
            diagnostics,
        );
    }

    if matches!(
        kind,
        "Row"
            | "Column"
            | "Overlay"
            | "Grid"
            | "AdaptiveColumns"
            | "List"
            | "Section"
            | "GlassCard"
            | "Menu"
    ) && let Some(children) = object.get("children")
        && !children.as_array().is_some_and(|values| {
            !values.is_empty()
                && values
                    .iter()
                    .all(|value| value.as_str().is_some_and(|id| !id.is_empty()))
        })
    {
        push(
            diagnostics,
            "catalog.invalid_children",
            format!("{path}/children"),
            "children must be a non-empty array of component ids",
        );
    }
    if kind == "Toggle" {
        validate_typed_property(
            object,
            "value",
            path,
            "boolean",
            true,
            Value::is_boolean,
            diagnostics,
        );
    }
    validate_component_enum(
        object,
        "axis",
        &["vertical", "horizontal"],
        path,
        diagnostics,
    );
    validate_component_enum(
        object,
        "orientation",
        &["horizontal", "vertical"],
        path,
        diagnostics,
    );
    validate_component_enum(object, "contentMode", &["fit", "fill"], path, diagnostics);
    validate_component_enum(
        object,
        "role",
        &["normal", "secondary", "cancel", "destructive"],
        path,
        diagnostics,
    );
    validate_component_enum(object, "format", &["number", "percent"], path, diagnostics);
    validate_component_enum(
        object,
        "commit",
        &["change", "interactionEnd", "submit"],
        path,
        diagnostics,
    );
    validate_component_enum(object, "kind", &["workspace", "model"], path, diagnostics);

    if let Some(columns) = object.get("columns").and_then(Value::as_f64)
        && (columns.fract() != 0.0 || !(1.0..=8.0).contains(&columns))
    {
        push(
            diagnostics,
            "catalog.invalid_columns",
            format!("{path}/columns"),
            "Grid columns must be an integer from 1 through 8",
        );
    }
    for key in ["spacing", "minimumLength", "size", "minimumColumnWidth"] {
        if let Some(number) = object.get(key).and_then(Value::as_f64)
            && (!(0.0..=10_000.0).contains(&number) || !number.is_finite())
        {
            push(
                diagnostics,
                "catalog.numeric_out_of_bounds",
                format!("{path}/{key}"),
                "numeric property is outside its bounded range",
            );
        }
    }
    if let Some(step) = object.get("step").and_then(Value::as_f64)
        && step <= 0.0
    {
        push(
            diagnostics,
            "catalog.invalid_step",
            format!("{path}/step"),
            "step must be positive",
        );
    }
    if kind == "ChoicePicker"
        && let Some(options) = object.get("options")
        && !options.as_array().is_some_and(|values| {
            !values.is_empty()
                && values.len() <= 100
                && values.iter().all(|value| {
                    value.as_object().is_some_and(|option| {
                        option.len() == 2
                            && option
                                .get("label")
                                .and_then(Value::as_str)
                                .is_some_and(|v| !v.is_empty())
                            && option
                                .get("value")
                                .and_then(Value::as_str)
                                .is_some_and(|v| !v.is_empty())
                    })
                })
        })
    {
        push(
            diagnostics,
            "catalog.invalid_options",
            format!("{path}/options"),
            "ChoicePicker options require 1-100 exact label/value objects",
        );
    }
    if kind == "NativeSlot" {
        if object.get("name").and_then(Value::as_str) != Some("surfaceDiagnostics") {
            push(
                diagnostics,
                "catalog.unsupported_native_slot",
                format!("{path}/name"),
                "NativeSlot is limited to surfaceDiagnostics",
            );
        }
        if !object.get("arguments").is_some_and(Value::is_object) {
            push(
                diagnostics,
                "catalog.invalid_native_slot_arguments",
                format!("{path}/arguments"),
                "NativeSlot arguments must be an object",
            );
        }
    }
    validate_json_depth(&Value::Object(object.clone()), 0, path, diagnostics);
}

fn validate_typed_property(
    object: &Map<String, Value>,
    key: &str,
    path: &str,
    expected: &str,
    allows_binding: bool,
    predicate: impl Fn(&Value) -> bool,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let Some(value) = object.get(key) else { return };
    if value
        .as_object()
        .is_some_and(|binding| binding.contains_key("path"))
    {
        if !allows_binding || !is_valid_path_binding(value) {
            push(
                diagnostics,
                "binding.invalid",
                format!("{path}/{key}"),
                "binding must be an exact non-empty JSON Pointer object",
            );
        }
        return;
    }
    if !predicate(value) {
        push(
            diagnostics,
            "catalog.invalid_property_type",
            format!("{path}/{key}"),
            format!("property {key} must be {expected}"),
        );
    }
}

fn is_valid_path_binding(value: &Value) -> bool {
    value.as_object().is_some_and(|binding| {
        binding.len() == 1
            && binding
                .get("path")
                .and_then(Value::as_str)
                .is_some_and(|pointer| pointer.starts_with('/') && pointer.len() > 1)
    })
}

fn validate_component_enum(
    object: &Map<String, Value>,
    key: &str,
    allowed: &[&str],
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let Some(value) = object.get(key) else { return };
    if value.is_object() {
        return;
    }
    if !value.as_str().is_some_and(|value| allowed.contains(&value)) {
        push(
            diagnostics,
            "catalog.invalid_enum",
            format!("{path}/{key}"),
            format!("property {key} has an unsupported value"),
        );
    }
}

fn validate_data_update(
    value: Option<&Value>,
    message_path: &str,
    logical_surface_id: Option<&str>,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let path = format!("{message_path}/updateDataModel");
    let Some(update) = value.and_then(Value::as_object) else {
        push(
            diagnostics,
            "a2ui.invalid_data_update",
            path,
            "updateDataModel must be an object",
        );
        return;
    };
    validate_exact_keys(
        update,
        &["surfaceId"],
        &["path", "value"],
        &path,
        diagnostics,
    );
    validate_surface_id(update, logical_surface_id, &path, diagnostics);
    if let Some(pointer) = update.get("path").and_then(Value::as_str)
        && !pointer.is_empty()
        && !pointer.starts_with('/')
    {
        push(
            diagnostics,
            "a2ui.invalid_data_path",
            format!("{path}/path"),
            "data model path must be empty or a JSON Pointer beginning with /",
        );
    }
    if let Some(value) = update.get("value") {
        validate_json_depth(value, 0, &format!("{path}/value"), diagnostics);
    }
}

fn validate_component_required_fields(
    kind: &str,
    object: &Map<String, Value>,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let required: &[&str] = match kind {
        "Surface" | "Navigation" | "Scroll" => &["child"],
        "Row" | "Column" | "Overlay" | "Grid" | "AdaptiveColumns" | "List" | "Section"
        | "GlassCard" | "Menu" => &["children"],
        "Text" => &["text"],
        "Image" => &["name"],
        "Icon" => &["systemName"],
        "Badge" => &["text"],
        "EmptyState" => &["title"],
        "Button" => &["label", "action"],
        "Toggle" | "Slider" | "Stepper" | "TextField" | "SecureField" => {
            &["label", "value", "action"]
        }
        "ChoicePicker" => &["label", "value", "options", "action"],
        "ResourcePicker" => &["label", "kind", "action"],
        "NativeSlot" => &["name", "arguments"],
        _ => &[],
    };
    for key in required {
        if !object.contains_key(*key) {
            push(
                diagnostics,
                "catalog.missing_property",
                path,
                format!("{kind} requires property {key}"),
            );
        }
    }
    if let (Some(minimum), Some(maximum)) = (
        object.get("minimum").and_then(Value::as_f64),
        object.get("maximum").and_then(Value::as_f64),
    ) && minimum > maximum
    {
        push(
            diagnostics,
            "catalog.invalid_range",
            path,
            "minimum cannot exceed maximum",
        );
    }
}

fn validate_modifiers(
    component: &str,
    value: Option<&Value>,
    component_path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let Some(value) = value else { return };
    let Some(modifiers) = value.as_array() else {
        push(
            diagnostics,
            "modifier.not_array",
            format!("{component_path}/modifiers"),
            "modifiers must be an ordered array",
        );
        return;
    };
    if modifiers.len() > 32 {
        push(
            diagnostics,
            "modifier.too_many",
            format!("{component_path}/modifiers"),
            "a component may contain at most 32 modifiers",
        );
    }
    for (index, modifier) in modifiers.iter().enumerate() {
        let path = format!("{component_path}/modifiers/{index}");
        let Some(object) = modifier.as_object() else {
            push(
                diagnostics,
                "modifier.not_object",
                path,
                "modifier must be an object",
            );
            continue;
        };
        let Some(name) = required_string(object, "name", &path, diagnostics) else {
            continue;
        };
        if !is_modifier(name) {
            push(
                diagnostics,
                "modifier.unknown",
                format!("{path}/name"),
                format!("unsupported modifier {name}"),
            );
            continue;
        }
        if !modifier_supports_component(name, component) {
            push(
                diagnostics,
                "modifier.inapplicable",
                path.clone(),
                format!("modifier {name} cannot be applied to {component}"),
            );
        }
        validate_modifier_keys(name, object, &path, diagnostics);
        validate_modifier_value_types(name, object, &path, diagnostics);
        for &key in modifier_color_keys(name) {
            if let Some(value) = object.get(key) {
                validate_color_value(value, &format!("{path}/{key}"), diagnostics);
            }
        }
        if name == "sizeClass" {
            for key in ["compact", "regular"] {
                if let Some(value) = object.get(key) {
                    validate_size_class_override(value, &format!("{path}/{key}"), diagnostics);
                }
            }
        }
        for (key, number) in object
            .iter()
            .filter_map(|(key, value)| value.as_f64().map(|number| (key.as_str(), number)))
        {
            let valid = match (name, key) {
                ("opacity", "value") => (0.0..=1.0).contains(&number),
                ("cornerRadius", "value") => (0.0..=128.0).contains(&number),
                ("animation", "duration") => (0.0..=10.0).contains(&number),
                _ => (-10_000.0..=10_000.0).contains(&number),
            };
            if !valid {
                push(
                    diagnostics,
                    "modifier.value_out_of_bounds",
                    format!("{path}/{key}"),
                    format!("modifier value {number} is outside its allowed bounds"),
                );
            }
        }
    }
}

fn validate_modifier_value_types(
    name: &str,
    object: &Map<String, Value>,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let numeric: &[&str] = match name {
        "frame" => &[
            "width",
            "height",
            "minWidth",
            "maxWidth",
            "minHeight",
            "maxHeight",
        ],
        "padding" => &["value"],
        "offset" => &["x", "y"],
        "aspectRatio" => &["value"],
        "font" => &["size"],
        "opacity" | "cornerRadius" | "lineSpacing" => &["value"],
        "shadow" => &["radius", "x", "y"],
        "overlay" | "stroke" => &["width"],
        "lineLimit" => &["value"],
        "animation" => &["duration"],
        _ => &[],
    };
    for key in numeric {
        let Some(value) = object.get(*key) else {
            continue;
        };
        if name == "frame"
            && matches!(*key, "maxWidth" | "maxHeight")
            && value.as_str() == Some("infinity")
        {
            continue;
        }
        let Some(number) = value.as_f64().filter(|number| number.is_finite()) else {
            push(
                diagnostics,
                "modifier.invalid_number",
                format!("{path}/{key}"),
                format!("modifier property {key} must be a finite number"),
            );
            continue;
        };
        let permits_negative = name == "offset"
            || name == "lineSpacing"
            || (name == "shadow" && matches!(*key, "x" | "y"));
        if !permits_negative && number < 0.0 {
            push(
                diagnostics,
                "modifier.negative_value",
                format!("{path}/{key}"),
                format!("modifier property {key} cannot be negative"),
            );
        }
        if name == "lineLimit" && (number.fract() != 0.0 || !(1.0..=100.0).contains(&number)) {
            push(
                diagnostics,
                "modifier.invalid_line_limit",
                format!("{path}/{key}"),
                "lineLimit must be an integer from 1 through 100",
            );
        }
    }
    let booleans: &[&str] = match name {
        "fixedSize" => &["horizontal", "vertical"],
        "glassEffect" => &["interactive"],
        "lineLimit" => &["reservesSpace"],
        "textSelection" | "monospacedDigit" | "hidden" => &["enabled"],
        "disabled" => &["value"],
        _ => &[],
    };
    for key in booleans {
        if let Some(value) = object.get(*key)
            && !value.is_boolean()
        {
            push(
                diagnostics,
                "modifier.invalid_boolean",
                format!("{path}/{key}"),
                format!("modifier property {key} must be a boolean"),
            );
        }
    }
    let enums: &[(&str, &[&str])] = match name {
        "padding" => &[(
            "edges",
            &[
                "all",
                "horizontal",
                "vertical",
                "top",
                "bottom",
                "leading",
                "trailing",
            ],
        )],
        "aspectRatio" => &[("contentMode", &["fit", "fill"])],
        "fontWeight" => &[("value", &["regular", "medium", "semibold", "bold", "light"])],
        "fontDesign" => &[("value", &["default", "rounded", "monospaced", "serif"])],
        "multilineTextAlignment" => &[("value", &["leading", "center", "trailing"])],
        "buttonStyle" => &[("value", &["plain", "bordered", "prominent"])],
        "transition" => &[("value", &["opacity", "scale", "opacityScale"])],
        "animation" => &[("preset", &["easeIn", "easeOut", "easeInOut", "spring"])],
        _ => &[],
    };
    for (key, allowed) in enums {
        if let Some(value) = object.get(*key)
            && !value.as_str().is_some_and(|value| allowed.contains(&value))
        {
            push(
                diagnostics,
                "modifier.invalid_enum",
                format!("{path}/{key}"),
                format!("modifier property {key} has an unsupported value"),
            );
        }
    }
    if let Some(value_path) = object.get("valuePath")
        && !value_path
            .as_str()
            .is_some_and(|pointer| pointer.starts_with('/') && pointer.len() > 1)
    {
        push(
            diagnostics,
            "modifier.invalid_value_path",
            format!("{path}/valuePath"),
            "animation valuePath must be a non-empty JSON Pointer",
        );
    }
}

fn modifier_color_keys(name: &str) -> &'static [&'static str] {
    match name {
        "foregroundStyle" | "tint" | "background" => &["value"],
        "glassEffect" => &["tint"],
        "shadow" | "overlay" | "stroke" => &["color"],
        _ => &[],
    }
}

fn validate_color_value(value: &Value, path: &str, diagnostics: &mut Vec<ValidationDiagnostic>) {
    if value.as_str().is_some_and(is_color_token) {
        return;
    }
    if value.is_string() {
        push(
            diagnostics,
            "modifier.unknown_color_token",
            path,
            "color token is not part of catalog revision 1",
        );
        return;
    }
    let Some(object) = value.as_object() else {
        push(
            diagnostics,
            "modifier.invalid_color",
            path,
            "color must be a token or bounded RGBA object",
        );
        return;
    };
    validate_exact_keys(
        object,
        &["red", "green", "blue"],
        &["alpha"],
        path,
        diagnostics,
    );
    for channel in ["red", "green", "blue", "alpha"] {
        if let Some(raw) = object.get(channel)
            && !raw
                .as_f64()
                .is_some_and(|value| (0.0..=1.0).contains(&value))
        {
            push(
                diagnostics,
                "modifier.invalid_color_channel",
                format!("{path}/{channel}"),
                "RGBA channels must be finite numbers from 0 through 1",
            );
        }
    }
}

fn is_color_token(value: &str) -> bool {
    matches!(
        value,
        "accent"
            | "emerald"
            | "purple"
            | "cyan"
            | "mint"
            | "red"
            | "destructive"
            | "secondary"
            | "muted"
            | "surface"
            | "surfaceElevated"
            | "border"
            | "primary"
            | "success"
            | "warning"
    )
}

fn validate_size_class_override(
    value: &Value,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let Some(object) = value.as_object() else {
        push(
            diagnostics,
            "modifier.invalid_size_class",
            path,
            "size-class override must be an object",
        );
        return;
    };
    validate_exact_keys(
        object,
        &[],
        &["padding", "maxWidth", "hidden"],
        path,
        diagnostics,
    );
    for key in ["padding", "maxWidth"] {
        if let Some(value) = object.get(key)
            && !value
                .as_f64()
                .is_some_and(|number| (0.0..=10_000.0).contains(&number))
        {
            push(
                diagnostics,
                "modifier.invalid_size_class_value",
                format!("{path}/{key}"),
                "size-class dimensions must be finite numbers from 0 through 10000",
            );
        }
    }
    if object
        .get("hidden")
        .is_some_and(|value| !value.is_boolean())
    {
        push(
            diagnostics,
            "modifier.invalid_size_class_value",
            format!("{path}/hidden"),
            "size-class hidden must be boolean",
        );
    }
}

fn validate_modifier_keys(
    name: &str,
    object: &Map<String, Value>,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let allowed: &[&str] = match name {
        "frame" => &[
            "name",
            "width",
            "height",
            "minWidth",
            "maxWidth",
            "minHeight",
            "maxHeight",
            "alignment",
        ],
        "padding" => &["name", "edges", "value"],
        "offset" => &["name", "x", "y"],
        "fixedSize" => &["name", "horizontal", "vertical"],
        "aspectRatio" => &["name", "value", "contentMode"],
        "font" => &["name", "style", "size"],
        "fontWeight" | "fontDesign" | "foregroundStyle" | "tint" | "background" | "clipShape"
        | "contentShape" | "buttonStyle" | "transition" => &["name", "value"],
        "opacity" | "cornerRadius" | "lineSpacing" => &["name", "value"],
        "glassEffect" => &["name", "style", "tint", "interactive"],
        "shadow" => &["name", "color", "radius", "x", "y"],
        "overlay" | "stroke" => &["name", "color", "width"],
        "lineLimit" => &["name", "value", "reservesSpace"],
        "multilineTextAlignment" => &["name", "value"],
        "textSelection" | "monospacedDigit" | "hidden" => &["name", "enabled"],
        "disabled" => &["name", "value"],
        "accessibility" => &["name", "label", "hint", "value", "identifier"],
        "animation" => &["name", "preset", "duration", "valuePath"],
        "sizeClass" => &["name", "compact", "regular"],
        _ => &["name"],
    };
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            push(
                diagnostics,
                "modifier.unknown_property",
                format!("{path}/{key}"),
                format!("property {key} is not valid for modifier {name}"),
            );
        }
    }
}

fn validate_action(
    action: &Value,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) -> usize {
    let Some(object) = action.as_object() else {
        push(
            diagnostics,
            "action.not_object",
            path,
            "action must be an object",
        );
        return 1;
    };
    let variants = ["serverCapability", "clientFunction", "event"]
        .into_iter()
        .filter(|key| object.contains_key(*key))
        .collect::<Vec<_>>();
    let allowed = BTreeSet::from([
        "serverCapability",
        "clientFunction",
        "event",
        "resultAction",
    ]);
    for key in object.keys() {
        if !allowed.contains(key.as_str()) {
            push(
                diagnostics,
                "action.unknown_property",
                format!("{path}/{key}"),
                format!("unknown action property {key}"),
            );
        }
    }
    if variants.len() != 1 {
        push(
            diagnostics,
            "action.invalid_variant",
            path,
            "action requires exactly one of serverCapability, clientFunction, or event",
        );
    }
    if let Some(binding) = object.get("serverCapability") {
        let Some(binding) = binding.as_object() else {
            push(
                diagnostics,
                "action.invalid_capability",
                format!("{path}/serverCapability"),
                "serverCapability must be an object",
            );
            return 1;
        };
        validate_exact_keys(
            binding,
            &["functionId", "argumentTemplate"],
            &[],
            &format!("{path}/serverCapability"),
            diagnostics,
        );
        let _ = required_string(
            binding,
            "functionId",
            &format!("{path}/serverCapability"),
            diagnostics,
        );
        if let Some(template) = binding
            .get("argumentTemplate")
            .filter(|value| value.is_object())
        {
            validate_binding_template(
                template,
                &format!("{path}/serverCapability/argumentTemplate"),
                0,
                diagnostics,
            );
        } else {
            push(
                diagnostics,
                "action.invalid_argument_template",
                format!("{path}/serverCapability/argumentTemplate"),
                "argumentTemplate must be an object",
            );
        }
    }
    if let Some(function) = object.get("clientFunction") {
        let Some(function) = function.as_object() else {
            push(
                diagnostics,
                "action.invalid_client_function",
                format!("{path}/clientFunction"),
                "clientFunction must be an object",
            );
            return 1;
        };
        validate_exact_keys(
            function,
            &["name", "revision", "arguments"],
            &[],
            &format!("{path}/clientFunction"),
            diagnostics,
        );
        let name = required_string(function, "name", path, diagnostics);
        let revision = function.get("revision").and_then(Value::as_u64);
        if let (Some(name), Some(revision)) = (name, revision) {
            if !supports_client_function(name, revision) {
                push(
                    diagnostics,
                    "action.unsupported_client_function",
                    format!("{path}/clientFunction"),
                    format!("unsupported native function {name} revision {revision}"),
                );
            }
        } else if revision.is_none() {
            push(
                diagnostics,
                "action.invalid_client_function_revision",
                format!("{path}/clientFunction/revision"),
                "client function revision must be an unsigned integer",
            );
        }
        if let Some(arguments) = function.get("arguments").filter(|value| value.is_object()) {
            validate_binding_template(
                arguments,
                &format!("{path}/clientFunction/arguments"),
                0,
                diagnostics,
            );
            if let (Some(name), Some(revision), Some((schema, _))) = (
                name,
                revision,
                name.and_then(|name| client_function_contract(name, revision.unwrap_or_default())),
            ) {
                let _ = (name, revision);
                validate_template_against_schema(
                    arguments,
                    &schema,
                    &format!("{path}/clientFunction/arguments"),
                    diagnostics,
                );
            }
        } else {
            push(
                diagnostics,
                "action.invalid_client_arguments",
                format!("{path}/clientFunction/arguments"),
                "client function arguments must be an object",
            );
        }
    }
    if let Some(event) = object.get("event") {
        let Some(event) = event.as_object() else {
            push(
                diagnostics,
                "action.invalid_event",
                format!("{path}/event"),
                "event must be an object",
            );
            return 1;
        };
        validate_exact_keys(
            event,
            &["name"],
            &["context"],
            &format!("{path}/event"),
            diagnostics,
        );
        let _ = required_string(event, "name", &format!("{path}/event"), diagnostics);
        if let Some(context) = event.get("context") {
            validate_binding_template(context, &format!("{path}/event/context"), 0, diagnostics);
        }
    }
    if let Some(result_action) = object.get("resultAction") {
        return 1 + validate_action(result_action, &format!("{path}/resultAction"), diagnostics);
    }
    1
}

fn validate_binding_template(
    value: &Value,
    path: &str,
    depth: usize,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    if depth > MAX_DEPTH {
        push(
            diagnostics,
            "binding.depth_exceeded",
            path,
            format!("binding template exceeds maximum depth {MAX_DEPTH}"),
        );
        return;
    }
    match value {
        Value::Array(values) => {
            for (index, child) in values.iter().enumerate() {
                validate_binding_template(
                    child,
                    &format!("{path}/{index}"),
                    depth + 1,
                    diagnostics,
                );
            }
        }
        Value::Object(object) => {
            let reserved = ["path", "$event", "$result"]
                .into_iter()
                .filter(|key| object.contains_key(*key))
                .collect::<Vec<_>>();
            if !reserved.is_empty() {
                let valid = object.len() == 1
                    && reserved.len() == 1
                    && object
                        .get(reserved[0])
                        .and_then(Value::as_str)
                        .is_some_and(|token| {
                            !token.is_empty()
                                && (reserved[0] != "path"
                                    || (token.starts_with('/') && token.len() > 1))
                        });
                if !valid {
                    push(
                        diagnostics,
                        "binding.invalid_expression",
                        path,
                        "binding expressions must contain exactly one valid path, $event, or $result token",
                    );
                }
                return;
            }
            for (key, child) in object {
                validate_binding_template(child, &format!("{path}/{key}"), depth + 1, diagnostics);
            }
        }
        _ => {}
    }
}

fn validate_template_against_schema(
    value: &Value,
    schema: &Value,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    if is_dynamic_binding(value) {
        return;
    }
    if let Some(allowed) = schema.get("enum").and_then(Value::as_array)
        && !allowed.contains(value)
    {
        push(
            diagnostics,
            "binding.schema_enum_mismatch",
            path,
            "static action argument is outside the capability schema enum",
        );
        return;
    }
    let expected_types = match schema.get("type") {
        Some(Value::String(value)) => vec![value.as_str()],
        Some(Value::Array(values)) => values.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    };
    if !expected_types.is_empty()
        && !expected_types
            .iter()
            .any(|kind| json_type_matches(value, kind))
    {
        push(
            diagnostics,
            "binding.schema_type_mismatch",
            path,
            format!("static action argument does not match schema type {expected_types:?}"),
        );
        return;
    }
    match value {
        Value::Object(object) => {
            let properties = schema.get("properties").and_then(Value::as_object);
            if let Some(required) = schema.get("required").and_then(Value::as_array) {
                for key in required.iter().filter_map(Value::as_str) {
                    if !object.contains_key(key) {
                        push(
                            diagnostics,
                            "binding.schema_missing_property",
                            path,
                            format!("action argument is missing required property {key}"),
                        );
                    }
                }
            }
            for (key, child) in object {
                if let Some(child_schema) = properties.and_then(|values| values.get(key)) {
                    validate_template_against_schema(
                        child,
                        child_schema,
                        &format!("{path}/{key}"),
                        diagnostics,
                    );
                } else if schema.get("additionalProperties") == Some(&Value::Bool(false)) {
                    push(
                        diagnostics,
                        "binding.schema_unknown_property",
                        format!("{path}/{key}"),
                        format!("action argument property {key} is not accepted by the capability"),
                    );
                }
            }
        }
        Value::Array(values) => {
            if let Some(max_items) = schema.get("maxItems").and_then(Value::as_u64)
                && values.len() as u64 > max_items
            {
                push(
                    diagnostics,
                    "binding.schema_array_too_large",
                    path,
                    format!("action argument exceeds maxItems {max_items}"),
                );
            }
            if let Some(item_schema) = schema.get("items") {
                for (index, child) in values.iter().enumerate() {
                    validate_template_against_schema(
                        child,
                        item_schema,
                        &format!("{path}/{index}"),
                        diagnostics,
                    );
                }
            }
        }
        Value::String(text) => {
            if let Some(minimum) = schema.get("minLength").and_then(Value::as_u64)
                && (text.chars().count() as u64) < minimum
            {
                push(
                    diagnostics,
                    "binding.schema_string_too_short",
                    path,
                    format!("action argument is shorter than minLength {minimum}"),
                );
            }
            if let Some(maximum) = schema.get("maxLength").and_then(Value::as_u64)
                && (text.chars().count() as u64) > maximum
            {
                push(
                    diagnostics,
                    "binding.schema_string_too_long",
                    path,
                    format!("action argument exceeds maxLength {maximum}"),
                );
            }
        }
        Value::Number(number) => {
            if let (Some(actual), Some(minimum)) = (
                number.as_f64(),
                schema.get("minimum").and_then(Value::as_f64),
            ) && actual < minimum
            {
                push(
                    diagnostics,
                    "binding.schema_number_too_small",
                    path,
                    format!("action argument is below minimum {minimum}"),
                );
            }
        }
        _ => {}
    }
}

fn is_dynamic_binding(value: &Value) -> bool {
    value.as_object().is_some_and(|object| {
        object.len() == 1
            && ["path", "$event", "$result"].into_iter().any(|key| {
                object
                    .get(key)
                    .and_then(Value::as_str)
                    .is_some_and(|token| !token.is_empty())
            })
    })
}

fn json_type_matches(value: &Value, kind: &str) -> bool {
    match kind {
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "boolean" => value.is_boolean(),
        "number" => value.is_number(),
        "integer" => value.as_i64().is_some() || value.as_u64().is_some(),
        "null" => value.is_null(),
        _ => false,
    }
}

fn collect_capability_bindings(
    action: &Value,
    path: &str,
    bindings: &mut Vec<(String, String, Value)>,
) {
    if let Some(binding) = action.get("serverCapability")
        && let (Some(function_id), Some(argument_template)) = (
            binding.get("functionId").and_then(Value::as_str),
            binding.get("argumentTemplate"),
        )
    {
        bindings.push((
            format!("{path}/serverCapability/functionId"),
            function_id.to_owned(),
            argument_template.clone(),
        ));
    }
    if let Some(result_action) = action.get("resultAction") {
        collect_capability_bindings(result_action, &format!("{path}/resultAction"), bindings);
    }
}

fn collect_client_functions(action: &Value, functions: &mut BTreeSet<(String, u64)>) {
    if let (Some(name), Some(revision)) = (
        action
            .get("clientFunction")
            .and_then(|value| value.get("name"))
            .and_then(Value::as_str),
        action
            .get("clientFunction")
            .and_then(|value| value.get("revision"))
            .and_then(Value::as_u64),
    ) {
        functions.insert((name.to_owned(), revision));
    }
    if let Some(result_action) = action.get("resultAction") {
        collect_client_functions(result_action, functions);
    }
}

fn validate_component_graph(
    components: &BTreeMap<String, Value>,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    if !components.contains_key("root") {
        push(
            diagnostics,
            "catalog.missing_root",
            "/messages",
            "final component graph requires component id root",
        );
        return;
    }
    for (id, component) in components {
        for reference in child_references(component) {
            if !components.contains_key(reference) {
                push(
                    diagnostics,
                    "catalog.missing_child",
                    format!("/components/{id}"),
                    format!("component {id} references unknown child {reference}"),
                );
            }
        }
    }
    let mut visiting = BTreeSet::new();
    let mut visited = BTreeSet::new();
    visit_component(
        "root",
        1,
        components,
        &mut visiting,
        &mut visited,
        diagnostics,
    );
}

fn visit_component<'a>(
    id: &'a str,
    depth: usize,
    components: &'a BTreeMap<String, Value>,
    visiting: &mut BTreeSet<&'a str>,
    visited: &mut BTreeSet<&'a str>,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    if depth > MAX_DEPTH {
        push(
            diagnostics,
            "catalog.depth_exceeded",
            format!("/components/{id}"),
            format!("component graph exceeds maximum depth {MAX_DEPTH}"),
        );
        return;
    }
    if visited.contains(id) {
        return;
    }
    if !visiting.insert(id) {
        push(
            diagnostics,
            "catalog.cycle",
            format!("/components/{id}"),
            format!("component graph contains a cycle at {id}"),
        );
        return;
    }
    if let Some(component) = components.get(id) {
        for child in child_references(component) {
            visit_component(child, depth + 1, components, visiting, visited, diagnostics);
        }
    }
    let _ = visiting.remove(id);
    let _ = visited.insert(id);
}

fn child_references(component: &Value) -> Vec<&str> {
    let mut refs = Vec::new();
    if let Some(child) = component.get("child").and_then(Value::as_str) {
        refs.push(child);
    }
    if let Some(children) = component.get("children") {
        match children {
            Value::Array(values) => {
                refs.extend(values.iter().filter_map(Value::as_str));
            }
            Value::Object(template) => {
                if let Some(component_id) = template.get("componentId").and_then(Value::as_str) {
                    refs.push(component_id);
                }
            }
            _ => {}
        }
    }
    refs
}

fn validate_surface_id(
    object: &Map<String, Value>,
    expected: Option<&str>,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    let actual = required_string(object, "surfaceId", path, diagnostics);
    if let (Some(actual), Some(expected)) = (actual, expected)
        && actual != expected
    {
        push(
            diagnostics,
            "a2ui.surface_id_mismatch",
            format!("{path}/surfaceId"),
            format!("surfaceId {actual} does not match createSurface id {expected}"),
        );
    }
}

fn validate_exact_keys(
    object: &Map<String, Value>,
    required: &[&str],
    optional: &[&str],
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    for key in required {
        if !object.contains_key(*key) {
            push(
                diagnostics,
                "schema.missing_property",
                path,
                format!("missing required property {key}"),
            );
        }
    }
    for key in object.keys() {
        if !required.contains(&key.as_str()) && !optional.contains(&key.as_str()) {
            push(
                diagnostics,
                "schema.unknown_property",
                format!("{path}/{key}"),
                format!("unknown property {key}"),
            );
        }
    }
}

fn required_string<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) -> Option<&'a str> {
    match object.get(key).and_then(Value::as_str) {
        Some(value) if !value.trim().is_empty() => Some(value),
        _ => {
            push(
                diagnostics,
                "schema.invalid_string",
                format!("{path}/{key}"),
                format!("{key} must be a non-empty string"),
            );
            None
        }
    }
}

fn validate_json_depth(
    value: &Value,
    depth: usize,
    path: &str,
    diagnostics: &mut Vec<ValidationDiagnostic>,
) {
    if depth > MAX_DEPTH {
        push(
            diagnostics,
            "data.depth_exceeded",
            path,
            format!("data model exceeds maximum depth {MAX_DEPTH}"),
        );
        return;
    }
    match value {
        Value::Array(values) => {
            for (index, child) in values.iter().enumerate() {
                validate_json_depth(child, depth + 1, &format!("{path}/{index}"), diagnostics);
            }
        }
        Value::Object(values) => {
            for (key, child) in values {
                validate_json_depth(child, depth + 1, &format!("{path}/{key}"), diagnostics);
            }
        }
        _ => {}
    }
}

fn text_bytes(value: &Value) -> usize {
    match value {
        Value::String(value) => value.len(),
        Value::Array(values) => values.iter().map(text_bytes).sum(),
        Value::Object(values) => values.values().map(text_bytes).sum(),
        _ => 0,
    }
}

fn push(
    diagnostics: &mut Vec<ValidationDiagnostic>,
    code: impl Into<String>,
    path: impl Into<String>,
    message: impl Into<String>,
) {
    diagnostics.push(ValidationDiagnostic::new(code, path, message));
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::domains::native_ui::builtins;
    use crate::domains::registration::contract::function_definition_for_capability;
    use crate::engine::{
        ActorId, ActorKind, AuthorityGrantId, EngineHostHandle, WorkerDefinition, WorkerId,
        WorkerKind,
    };

    #[test]
    fn bundled_definitions_validate_structurally() {
        for id in [
            "settings.engine",
            "session.compaction_detail",
            "lab.catalog",
        ] {
            let definition = builtins::definition(id).unwrap();
            let report = validate_structure(&definition);
            assert!(report.valid, "{id}: {:#?}", report.diagnostics);
        }
    }

    #[tokio::test]
    async fn live_capability_validation_uses_the_requesting_actor_visibility() {
        let host = EngineHostHandle::new_in_memory().expect("engine host");
        host.register_worker_for_setup(
            WorkerDefinition::new(
                WorkerId::new("settings").unwrap(),
                WorkerKind::InProcess,
                ActorId::new("system:native-ui-test").unwrap(),
                AuthorityGrantId::new("engine-system").unwrap(),
            )
            .with_namespace_claim("settings"),
            false,
        )
        .expect("settings worker registration");
        let settings_update = crate::domains::settings::contract::capabilities()
            .expect("settings contracts")
            .into_iter()
            .find(|capability| capability.function_id.as_str() == "settings::update")
            .expect("settings update contract");
        host.register_function_for_setup(
            function_definition_for_capability(&settings_update),
            None,
            false,
        )
        .expect("settings update registration");
        let function_id = FunctionId::new("settings::update").unwrap();
        assert!(host.inspect_function(&function_id, None).await.is_err());

        let actor = ActorContext::new(
            ActorId::new("client:native-ui-test").unwrap(),
            ActorKind::Client,
            AuthorityGrantId::new("client-native-ui-test").unwrap(),
        );
        let definition = builtins::definition("settings.engine").unwrap();
        let diagnostics = validate_capability_bindings(&definition, &host, &actor).await;
        assert!(diagnostics.is_empty(), "{diagnostics:#?}");
    }

    #[test]
    fn duplicate_ids_and_cycles_fail_closed() {
        let mut definition = builtins::definition("lab.catalog").unwrap();
        definition.messages = vec![
            json!({"version":"v0.9.1","createSurface":{"surfaceId":"x","catalogId":CATALOG_ID}}),
            json!({"version":"v0.9.1","updateComponents":{"surfaceId":"x","components":[
                {"id":"root","component":"Column","children":["root"]},
                {"id":"root","component":"Text","text":"duplicate"}
            ]}}),
        ];
        let report = validate_structure(&definition);
        assert!(!report.valid);
        assert!(
            report
                .diagnostics
                .iter()
                .any(|item| item.code == "catalog.invalid_component_id")
        );
    }

    #[test]
    fn modifier_order_changes_content_hash() {
        let mut first = builtins::definition("session.compaction_detail").unwrap();
        let mut second = first.clone();
        let modifiers = first.messages[1]["updateComponents"]["components"][2]["modifiers"]
            .as_array_mut()
            .unwrap();
        modifiers.push(json!({"name":"opacity","value":0.5}));
        let modifiers = second.messages[1]["updateComponents"]["components"][2]["modifiers"]
            .as_array_mut()
            .unwrap();
        modifiers.insert(0, json!({"name":"opacity","value":0.5}));
        assert_ne!(content_hash(&first), content_hash(&second));
    }

    #[test]
    fn malformed_property_binding_and_client_arguments_fail_closed() {
        let mut property = builtins::definition("lab.catalog").unwrap();
        component_mut(&mut property, "lab-slider").insert("step".to_owned(), json!("fast"));
        let report = validate_structure(&property);
        assert!(
            report
                .diagnostics
                .iter()
                .any(|item| item.code == "catalog.invalid_property_type")
        );

        let mut binding = builtins::definition("settings.engine").unwrap();
        let selected = &mut component_mut(&mut binding, "workspace-button")["action"]["clientFunction"]
            ["arguments"]["selected"];
        *selected = json!({"path":"/defaultWorkspace","extra":true});
        let report = validate_structure(&binding);
        assert!(
            report
                .diagnostics
                .iter()
                .any(|item| item.code == "binding.invalid_expression")
        );

        let mut arguments = builtins::definition("lab.catalog").unwrap();
        arguments.messages[1]["updateComponents"]["components"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|component| component["id"] == "lab-button")
            .unwrap()["action"]["clientFunction"]["arguments"]["unexpected"] = json!(true);
        let report = validate_structure(&arguments);
        assert!(
            report
                .diagnostics
                .iter()
                .any(|item| item.code == "binding.schema_unknown_property")
        );
    }

    fn component_mut<'a>(
        definition: &'a mut NativeUIDefinition,
        id: &str,
    ) -> &'a mut Map<String, Value> {
        definition.messages[1]["updateComponents"]["components"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|component| component["id"] == id)
            .unwrap()
            .as_object_mut()
            .unwrap()
    }
}
