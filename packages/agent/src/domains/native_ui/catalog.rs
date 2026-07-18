//! Tron native component, modifier, and client-function catalog.

use std::collections::BTreeSet;

use serde_json::{Value, json};

pub(crate) const DEFINITION_SCHEMA_VERSION: &str = "tron.native-ui.definition.v1";
pub(crate) const A2UI_VERSION: &str = "v0.9.1";
pub(crate) const CATALOG_ID: &str = "https://tron.local/native-ui/catalogs/sheet/v1";
pub(crate) const CATALOG_REVISION: u64 = 1;

pub(crate) const MAX_PAYLOAD_BYTES: usize = 64 * 1024;
pub(crate) const MAX_COMPONENTS: usize = 200;
pub(crate) const MAX_ACTIONS: usize = 50;
pub(crate) const MAX_TEXT_BYTES: usize = 16 * 1024;
pub(crate) const MAX_DEPTH: usize = 8;
pub(crate) const MAX_CLIENT_FUNCTIONS: usize = 128;

pub(crate) const COMPONENTS: &[&str] = &[
    "Surface",
    "Navigation",
    "Scroll",
    "Row",
    "Column",
    "Overlay",
    "Grid",
    "AdaptiveColumns",
    "List",
    "Section",
    "GlassCard",
    "Divider",
    "Spacer",
    "Text",
    "Image",
    "Icon",
    "Badge",
    "Progress",
    "EmptyState",
    "Button",
    "Toggle",
    "Slider",
    "Stepper",
    "TextField",
    "SecureField",
    "ChoicePicker",
    "Menu",
    "ResourcePicker",
    "NativeSlot",
];

pub(crate) const MODIFIERS: &[&str] = &[
    "frame",
    "padding",
    "offset",
    "fixedSize",
    "aspectRatio",
    "font",
    "fontWeight",
    "fontDesign",
    "foregroundStyle",
    "tint",
    "opacity",
    "background",
    "glassEffect",
    "clipShape",
    "cornerRadius",
    "shadow",
    "overlay",
    "stroke",
    "lineLimit",
    "multilineTextAlignment",
    "lineSpacing",
    "textSelection",
    "monospacedDigit",
    "disabled",
    "hidden",
    "contentShape",
    "buttonStyle",
    "accessibility",
    "transition",
    "animation",
    "sizeClass",
];

pub(crate) const CLIENT_FUNCTIONS: &[(&str, u64)] = &[
    ("dismiss", 1),
    ("navigate", 1),
    ("copy", 1),
    ("openUrl", 1),
    ("resourcePicker", 1),
    ("filePicker", 1),
    ("camera", 1),
];

pub(crate) fn is_component(value: &str) -> bool {
    COMPONENTS.contains(&value)
}

pub(crate) fn is_modifier(value: &str) -> bool {
    MODIFIERS.contains(&value)
}

pub(crate) fn supports_client_function(name: &str, revision: u64) -> bool {
    CLIENT_FUNCTIONS
        .iter()
        .any(|(known_name, known_revision)| *known_name == name && *known_revision == revision)
}

/// Exact client-side contract the server accepts for a precompiled native function.
///
/// Keeping this schema beside the catalog revision makes catalog negotiation fail
/// closed when either side changes a function without revising the contract.
pub(crate) fn client_function_contract(name: &str, revision: u64) -> Option<(Value, &'static str)> {
    if revision != 1 {
        return None;
    }
    let contract = match name {
        "dismiss" => (
            json!({
                "type":"object",
                "additionalProperties":false
            }),
            "null",
        ),
        "navigate" => (
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["destination"],
                "properties":{"destination":{"type":"string","minLength":1}}
            }),
            "object",
        ),
        "copy" => (
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["text"],
                "properties":{"text":{"type":"string","maxLength":16384}}
            }),
            "null",
        ),
        "openUrl" => (
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["url"],
                "properties":{"url":{"type":"string","minLength":1,"maxLength":2048}}
            }),
            "null",
        ),
        "resourcePicker" => (
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["kind"],
                "properties":{
                    "kind":{"type":"string","enum":["workspace","model"]},
                    "selected":{"type":["string","null"]}
                }
            }),
            "object",
        ),
        "filePicker" => (
            json!({
                "type":"object",
                "additionalProperties":false,
                "properties":{
                    "contentTypes":{"type":"array","maxItems":32,"items":{"type":"string"}},
                    "allowsMultiple":{"type":"boolean"}
                }
            }),
            "object",
        ),
        "camera" => (
            json!({
                "type":"object",
                "additionalProperties":false,
                "properties":{"mediaType":{"type":"string","enum":["photo","video"]}}
            }),
            "object",
        ),
        _ => return None,
    };
    Some(contract)
}

pub(crate) fn allowed_component_properties(component: &str) -> BTreeSet<&'static str> {
    let mut values = BTreeSet::from([
        "id",
        "component",
        "modifiers",
        "visible",
        "accessibilityLabel",
    ]);
    let specific: &[&str] = match component {
        "Surface" => &["child"],
        "Navigation" => &["child", "title"],
        "Scroll" => &["child", "axis", "showsIndicators"],
        "Row" | "Column" | "Overlay" => &["children", "spacing", "alignment"],
        "Grid" => &["children", "columns", "spacing"],
        "AdaptiveColumns" => &["children", "minimumColumnWidth", "spacing"],
        "List" => &["children", "spacing"],
        "Section" => &["children", "title", "icon", "footer"],
        "GlassCard" => &["children", "accent", "interactive"],
        "Divider" => &["orientation"],
        "Spacer" => &["minimumLength"],
        "Text" => &["text", "label", "icon", "style", "selectable", "format"],
        "Image" => &["name", "url", "contentMode"],
        "Icon" => &["systemName", "size", "tone"],
        "Badge" => &["text", "tone"],
        "Progress" => &["value", "total", "label"],
        "EmptyState" => &["title", "message", "systemImage"],
        "Button" => &["label", "value", "icon", "role", "action"],
        "Toggle" => &["label", "value", "icon", "action"],
        "Slider" => &[
            "label", "value", "icon", "minimum", "maximum", "step", "format", "commit", "action",
        ],
        "Stepper" => &[
            "label", "value", "icon", "minimum", "maximum", "step", "action",
        ],
        "TextField" | "SecureField" => &["label", "value", "placeholder", "action"],
        "ChoicePicker" => &["label", "value", "options", "action"],
        "Menu" => &["label", "icon", "children"],
        "ResourcePicker" => &["label", "kind", "selected", "action"],
        "NativeSlot" => &["name", "arguments"],
        _ => &[],
    };
    values.extend(specific.iter().copied());
    values
}

pub(crate) fn modifier_supports_component(modifier: &str, component: &str) -> bool {
    match modifier {
        "lineLimit"
        | "multilineTextAlignment"
        | "lineSpacing"
        | "textSelection"
        | "monospacedDigit" => component == "Text",
        "buttonStyle" => matches!(component, "Button" | "Menu"),
        "font" | "fontWeight" | "fontDesign" => {
            matches!(
                component,
                "Text" | "Button" | "Badge" | "TextField" | "SecureField"
            )
        }
        _ => true,
    }
}
