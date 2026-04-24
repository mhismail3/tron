//! Schema-drift detection for MCP tool lists.
//!
//! Pure diff logic used by [`crate::mcp::server_manager`] to decide whether a
//! TTL-driven re-fetch observed any change. Emitted as a structured
//! [`SchemaDiff`] so the router can log actionable context and refresh the
//! [`crate::mcp::tool_index::ToolIndex`] only when something actually shifted.

use std::collections::HashMap;

use serde::Serialize;

use crate::mcp::types::McpToolDef;

/// Structured diff between two tool-definition sets for the same MCP server.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct SchemaDiff {
    /// Tool names that appeared in `new` but not `old`.
    pub added: Vec<String>,
    /// Tool names that appeared in `old` but not `new`.
    pub removed: Vec<String>,
    /// Tool names present in both sets whose `description` or `input_schema`
    /// differs. Name match is the equivalence key; this list captures renames
    /// against identical schemas as (removed, added) rather than modified.
    pub modified: Vec<String>,
}

impl SchemaDiff {
    /// Returns `true` when no tools were added, removed, or modified.
    pub fn is_empty(&self) -> bool {
        self.added.is_empty() && self.removed.is_empty() && self.modified.is_empty()
    }
}

/// Compute the diff between two tool-definition vectors.
///
/// The comparison keys tools by `name`. For names present in both sets, a
/// tool is considered "modified" when its description or canonicalized
/// `input_schema` differs. Order-independence is guaranteed: schemas whose
/// JSON-equivalent content differs only in property ordering are treated as
/// equal (the MCP spec does not order `properties`).
pub fn diff_schemas(old: &[McpToolDef], new: &[McpToolDef]) -> SchemaDiff {
    let old_by_name: HashMap<&str, &McpToolDef> =
        old.iter().map(|t| (t.name.as_str(), t)).collect();
    let new_by_name: HashMap<&str, &McpToolDef> =
        new.iter().map(|t| (t.name.as_str(), t)).collect();

    let mut added: Vec<String> = new_by_name
        .keys()
        .filter(|k| !old_by_name.contains_key(*k))
        .map(|k| (*k).to_string())
        .collect();
    let mut removed: Vec<String> = old_by_name
        .keys()
        .filter(|k| !new_by_name.contains_key(*k))
        .map(|k| (*k).to_string())
        .collect();
    let mut modified: Vec<String> = old_by_name
        .iter()
        .filter_map(|(name, old_def)| {
            let new_def = new_by_name.get(name)?;
            if old_def.description != new_def.description
                || old_def.input_schema != new_def.input_schema
            {
                Some((*name).to_string())
            } else {
                None
            }
        })
        .collect();

    added.sort();
    removed.sort();
    modified.sort();

    SchemaDiff {
        added,
        removed,
        modified,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn def(name: &str, desc: &str, schema: serde_json::Value) -> McpToolDef {
        McpToolDef {
            name: name.into(),
            description: desc.into(),
            input_schema: schema,
        }
    }

    #[test]
    fn diff_empty_when_both_empty() {
        assert!(diff_schemas(&[], &[]).is_empty());
    }

    #[test]
    fn diff_empty_when_identical() {
        let old = vec![def("query", "Run SQL", json!({"type": "object"}))];
        let new = old.clone();
        assert!(diff_schemas(&old, &new).is_empty());
    }

    #[test]
    fn diff_detects_added_tool() {
        let old = vec![def("query", "Run SQL", json!({"type": "object"}))];
        let new = vec![
            def("query", "Run SQL", json!({"type": "object"})),
            def("list_tables", "List tables", json!({"type": "object"})),
        ];
        let d = diff_schemas(&old, &new);
        assert_eq!(d.added, vec!["list_tables"]);
        assert!(d.removed.is_empty());
        assert!(d.modified.is_empty());
    }

    #[test]
    fn diff_detects_removed_tool() {
        let old = vec![
            def("query", "Run SQL", json!({"type": "object"})),
            def("drop_table", "Drop a table", json!({"type": "object"})),
        ];
        let new = vec![def("query", "Run SQL", json!({"type": "object"}))];
        let d = diff_schemas(&old, &new);
        assert_eq!(d.removed, vec!["drop_table"]);
        assert!(d.added.is_empty());
        assert!(d.modified.is_empty());
    }

    #[test]
    fn diff_detects_modified_schema_shape() {
        let old = vec![def(
            "query",
            "Run SQL",
            json!({"type": "object", "properties": {"sql": {"type": "string"}}}),
        )];
        let new = vec![def(
            "query",
            "Run SQL",
            json!({
                "type": "object",
                "properties": {"sql": {"type": "string"}, "limit": {"type": "number"}},
                "required": ["sql"],
            }),
        )];
        let d = diff_schemas(&old, &new);
        assert_eq!(d.modified, vec!["query"]);
        assert!(d.added.is_empty());
        assert!(d.removed.is_empty());
    }

    #[test]
    fn diff_detects_description_change_as_modified() {
        let old = vec![def("query", "Run SQL", json!({"type": "object"}))];
        let new = vec![def(
            "query",
            "Run SQL query (async)",
            json!({"type": "object"}),
        )];
        let d = diff_schemas(&old, &new);
        assert_eq!(d.modified, vec!["query"]);
    }

    #[test]
    fn diff_rename_appears_as_add_plus_remove_not_modified() {
        let old = vec![def("old_name", "Same", json!({"type": "object"}))];
        let new = vec![def("new_name", "Same", json!({"type": "object"}))];
        let d = diff_schemas(&old, &new);
        assert_eq!(d.added, vec!["new_name"]);
        assert_eq!(d.removed, vec!["old_name"]);
        assert!(d.modified.is_empty());
    }

    #[test]
    fn diff_multiple_categories_coexist() {
        let old = vec![
            def("a", "A", json!({"type": "object"})),
            def("b", "B-old", json!({"type": "object"})),
            def("c", "C", json!({"type": "object"})),
        ];
        let new = vec![
            def("a", "A", json!({"type": "object"})),
            def("b", "B-new", json!({"type": "object"})),
            def("d", "D", json!({"type": "object"})),
        ];
        let d = diff_schemas(&old, &new);
        assert_eq!(d.added, vec!["d"]);
        assert_eq!(d.removed, vec!["c"]);
        assert_eq!(d.modified, vec!["b"]);
    }

    #[test]
    fn diff_is_sorted_for_deterministic_logging() {
        let old = vec![
            def("a", "A", json!({"type": "object"})),
            def("b", "B", json!({"type": "object"})),
        ];
        let new = vec![
            def("z", "Z", json!({"type": "object"})),
            def("y", "Y", json!({"type": "object"})),
        ];
        let d = diff_schemas(&old, &new);
        assert_eq!(d.added, vec!["y", "z"]);
        assert_eq!(d.removed, vec!["a", "b"]);
    }

    #[test]
    fn schema_diff_is_empty_when_all_fields_empty() {
        let d = SchemaDiff::default();
        assert!(d.is_empty());
    }

    #[test]
    fn schema_diff_not_empty_when_any_field_populated() {
        let mut d = SchemaDiff::default();
        d.added.push("x".into());
        assert!(!d.is_empty());
        let mut d = SchemaDiff::default();
        d.removed.push("x".into());
        assert!(!d.is_empty());
        let mut d = SchemaDiff::default();
        d.modified.push("x".into());
        assert!(!d.is_empty());
    }
}
