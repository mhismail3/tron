//! Builder for tool JSON Schema definitions.
//!
//! Replaces the repetitive `Map::new()` + `insert()` boilerplate in every
//! tool's `definition()` method with a concise builder API.

use serde_json::Value;
use tron_core::tools::{Tool, ToolParameterSchema};

/// Fluent builder for [`Tool`] schemas.
///
/// ```ignore
/// ToolSchemaBuilder::new("Read", "Read file contents")
///     .required_property("file_path", json!({"type": "string", "description": "Path"}))
///     .property("offset", json!({"type": "number", "description": "Start line"}))
///     .build()
/// ```
pub struct ToolSchemaBuilder {
    name: String,
    description: String,
    properties: serde_json::Map<String, Value>,
    required: Vec<String>,
}

impl ToolSchemaBuilder {
    /// Create a new builder with the given tool name and description.
    pub fn new(name: impl Into<String>, description: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            properties: serde_json::Map::new(),
            required: Vec::new(),
        }
    }

    /// Add an optional property.
    pub fn property(mut self, name: &str, schema: Value) -> Self {
        let _ = self.properties.insert(name.into(), schema);
        self
    }

    /// Add a required property.
    pub fn required_property(mut self, name: &str, schema: Value) -> Self {
        let _ = self.properties.insert(name.into(), schema);
        self.required.push(name.into());
        self
    }

    /// Build the final [`Tool`] definition.
    pub fn build(self) -> Tool {
        Tool {
            name: self.name,
            description: self.description,
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: if self.properties.is_empty() {
                    None
                } else {
                    Some(self.properties)
                },
                required: if self.required.is_empty() {
                    None
                } else {
                    Some(self.required)
                },
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn empty_schema() {
        let tool = ToolSchemaBuilder::new("Empty", "No params").build();
        assert_eq!(tool.name, "Empty");
        assert_eq!(tool.description, "No params");
        assert_eq!(tool.parameters.schema_type, "object");
        assert!(tool.parameters.properties.is_none());
        assert!(tool.parameters.required.is_none());
        assert!(tool.parameters.description.is_none());
        assert!(tool.parameters.extra.is_empty());
    }

    #[test]
    fn required_property_in_both_properties_and_required() {
        let tool = ToolSchemaBuilder::new("T", "D")
            .required_property("name", json!({"type": "string"}))
            .build();
        let props = tool.parameters.properties.unwrap();
        assert!(props.contains_key("name"));
        let req = tool.parameters.required.unwrap();
        assert_eq!(req, vec!["name"]);
    }

    #[test]
    fn optional_property_not_in_required() {
        let tool = ToolSchemaBuilder::new("T", "D")
            .property("limit", json!({"type": "number"}))
            .build();
        let props = tool.parameters.properties.unwrap();
        assert!(props.contains_key("limit"));
        assert!(tool.parameters.required.is_none());
    }

    #[test]
    fn mixed_properties_correct_separation() {
        let tool = ToolSchemaBuilder::new("T", "D")
            .required_property("file_path", json!({"type": "string"}))
            .required_property("content", json!({"type": "string"}))
            .property("encoding", json!({"type": "string"}))
            .build();
        let props = tool.parameters.properties.unwrap();
        assert_eq!(props.len(), 3);
        let req = tool.parameters.required.unwrap();
        assert_eq!(req, vec!["file_path", "content"]);
    }

    #[test]
    fn all_properties_present() {
        let tool = ToolSchemaBuilder::new("T", "D")
            .required_property("b", json!({"type": "string"}))
            .property("a", json!({"type": "number"}))
            .required_property("c", json!({"type": "boolean"}))
            .build();
        let props = tool.parameters.properties.unwrap();
        assert_eq!(props.len(), 3);
        assert!(props.contains_key("a"));
        assert!(props.contains_key("b"));
        assert!(props.contains_key("c"));
        let req = tool.parameters.required.unwrap();
        assert_eq!(req, vec!["b", "c"]);
    }

    #[test]
    fn matches_hand_rolled_tool() {
        // Build a tool the old way
        let old = Tool {
            name: "Read".into(),
            description: "Read file".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert(
                        "file_path".into(),
                        json!({"type": "string", "description": "Path"}),
                    );
                    let _ = m.insert(
                        "offset".into(),
                        json!({"type": "number", "description": "Start"}),
                    );
                    m
                }),
                required: Some(vec!["file_path".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        };

        // Build the same tool with the builder
        let new = ToolSchemaBuilder::new("Read", "Read file")
            .required_property("file_path", json!({"type": "string", "description": "Path"}))
            .property("offset", json!({"type": "number", "description": "Start"}))
            .build();

        // Serialize and compare
        let old_json = serde_json::to_value(&old).unwrap();
        let new_json = serde_json::to_value(&new).unwrap();
        assert_eq!(old_json, new_json);
    }
}
