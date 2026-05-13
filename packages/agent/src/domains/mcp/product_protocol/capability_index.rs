//! Searchable in-memory tool index for MCP meta-tool routing.
//!
//! Pure data structure with zero external dependencies. Indexes tools
//! discovered from MCP servers and supports keyword search with scoring.

use std::fmt::Write;

use serde::Serialize;

use crate::domains::mcp::types::McpToolDef;
use serde_json::Value;

/// Summary of a single tool parameter (extracted from JSON Schema).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ParamSummary {
    /// Parameter name.
    pub name: String,
    /// JSON Schema type (e.g., "string", "integer").
    pub param_type: String,
    /// Whether this parameter is required.
    pub required: bool,
    /// Human-readable parameter description.
    pub description: String,
}

/// A tool stored in the index with pre-tokenized fields for fast search.
struct IndexedCapability {
    server_name: String,
    tool_name: String,
    description: String,
    params: Vec<ParamSummary>,
    name_tokens: Vec<String>,
    desc_tokens: Vec<String>,
}

/// A search result with relevance score.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpCapabilityMatch {
    /// MCP server name.
    pub server: String,
    /// Capability name.
    pub tool: String,
    /// ModelCapability description.
    pub description: String,
    /// Parameter summaries for this tool.
    pub params: Vec<ParamSummary>,
    /// Relevance score (higher is better).
    pub score: u32,
}

/// In-memory index of all MCP capabilities across all servers.
pub struct McpCapabilityIndex {
    capabilities: Vec<IndexedCapability>,
}

impl Default for McpCapabilityIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl McpCapabilityIndex {
    /// Create an empty tool index.
    pub fn new() -> Self {
        Self {
            capabilities: Vec::new(),
        }
    }

    /// Add capabilities from a server. Parses schemas and tokenizes for search.
    pub fn add_server_tools(&mut self, server: &str, defs: &[McpToolDef]) {
        for def in defs {
            let params = extract_params(&def.input_schema);
            let name_tokens = tokenize(&def.name);
            let desc_tokens = tokenize(&def.description);
            self.capabilities.push(IndexedCapability {
                server_name: server.to_string(),
                tool_name: def.name.clone(),
                description: def.description.clone(),
                params,
                name_tokens,
                desc_tokens,
            });
        }
    }

    /// Remove all capabilities belonging to a server.
    pub fn remove_server(&mut self, server: &str) {
        self.capabilities.retain(|t| t.server_name != server);
    }

    /// Search for capabilities matching the query keywords, optionally filtered by server.
    /// Returns up to 40 results sorted by descending score.
    pub fn search(&self, query: &str, server_filter: Option<&str>) -> Vec<McpCapabilityMatch> {
        let keywords: Vec<String> = tokenize(query.trim());
        let server_filter = server_filter.and_then(|server| {
            let trimmed = server.trim();
            (!trimmed.is_empty()).then_some(trimmed)
        });

        let mut results: Vec<McpCapabilityMatch> = self
            .capabilities
            .iter()
            .filter(|t| server_filter.is_none_or(|s| t.server_name == s))
            .filter_map(|t| {
                let score = score_tool(t, &keywords);
                if !keywords.is_empty() && score == 0 {
                    return None;
                }
                Some(McpCapabilityMatch {
                    server: t.server_name.clone(),
                    tool: t.tool_name.clone(),
                    description: t.description.clone(),
                    params: t.params.clone(),
                    score,
                })
            })
            .collect();

        results.sort_by(|a, b| b.score.cmp(&a.score));
        // Cap keyword searches at 40, but allow full listing when browsing
        if !keywords.is_empty() {
            results.truncate(40);
        }
        results
    }

    /// Total number of indexed capabilities.
    pub fn capability_count(&self) -> usize {
        self.capabilities.len()
    }

    /// Number of capabilities from a specific server.
    pub fn server_capability_count(&self, server: &str) -> usize {
        self.capabilities
            .iter()
            .filter(|t| t.server_name == server)
            .count()
    }

    /// Format search results as compact text for LLM consumption.
    pub fn format_results(matches: &[McpCapabilityMatch]) -> String {
        if matches.is_empty() {
            return "No capabilities found. Try different keywords or omit the server filter."
                .to_string();
        }

        let mut out = format!("Found {} tool(s):\n", matches.len());
        for m in matches {
            let _ = write!(out, "\n[{}] {} — {}\n", m.server, m.tool, m.description);
            if m.params.is_empty() {
                out.push_str("  params: (none)\n");
            } else {
                let param_strs: Vec<String> = m
                    .params
                    .iter()
                    .map(|p| {
                        if p.required {
                            format!("{} ({}, required)", p.name, p.param_type)
                        } else {
                            format!("{} ({})", p.name, p.param_type)
                        }
                    })
                    .collect();
                let _ = writeln!(out, "  params: {}", param_strs.join(", "));
            }
        }
        out
    }
}

/// Tokenize a string into lowercase words, splitting on non-alphanumeric chars.
fn tokenize(s: &str) -> Vec<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(String::from)
        .collect()
}

/// Score a tool against query keywords.
fn score_tool(tool: &IndexedCapability, keywords: &[String]) -> u32 {
    if keywords.is_empty() {
        return 1; // return all capabilities with minimal score when no query
    }

    let mut total = 0u32;
    let server_lower = tool.server_name.to_lowercase();

    for kw in keywords {
        // Exact capability id match
        if tool.name_tokens.iter().any(|t| t == kw) {
            total += 100;
        }
        // Exact server name match
        else if server_lower == *kw {
            total += 50;
        }
        // Capability name starts with keyword
        else if tool.name_tokens.iter().any(|t| t.starts_with(kw.as_str())) {
            total += 30;
        }
        // Keyword appears in capability id (substring)
        else if tool.name_tokens.iter().any(|t| t.contains(kw.as_str())) {
            total += 20;
        }
        // Keyword appears in description
        else if tool.desc_tokens.iter().any(|t| t.contains(kw.as_str())) {
            total += 10;
        }
    }

    total
}

/// Extract parameter summaries from a JSON Schema `input_schema`.
fn extract_params(schema: &Value) -> Vec<ParamSummary> {
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return Vec::new();
    };

    let required_set: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();

    properties
        .iter()
        .map(|(name, prop)| ParamSummary {
            name: name.clone(),
            param_type: prop
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("any")
                .to_string(),
            required: required_set.contains(&name.as_str()),
            description: prop
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn make_tool(name: &str, desc: &str, schema: Value) -> McpToolDef {
        McpToolDef {
            name: name.into(),
            description: desc.into(),
            input_schema: schema,
        }
    }

    fn sample_tools() -> Vec<McpToolDef> {
        vec![
            make_tool(
                "query",
                "Run SQL queries against the database",
                json!({
                    "type": "object",
                    "properties": {
                        "sql": {"type": "string", "description": "SQL query"},
                        "limit": {"type": "number", "description": "Row limit"}
                    },
                    "required": ["sql"]
                }),
            ),
            make_tool(
                "list_tables",
                "List all tables in the database",
                json!({
                    "type": "object"
                }),
            ),
        ]
    }

    #[test]
    fn empty_index_returns_no_results() {
        let index = McpCapabilityIndex::new();
        let results = index.search("anything", None);
        assert!(results.is_empty());
    }

    #[test]
    fn add_server_populates_index() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools("sqlite", &sample_tools());
        assert_eq!(index.capability_count(), 2);
        assert_eq!(index.server_capability_count("sqlite"), 2);
    }

    #[test]
    fn remove_server_clears_only_that_server() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools("sqlite", &sample_tools());
        index.add_server_tools(
            "postgres",
            &[make_tool("execute", "Run SQL", json!({"type": "object"}))],
        );
        assert_eq!(index.capability_count(), 3);

        index.remove_server("sqlite");
        assert_eq!(index.capability_count(), 1);
        assert_eq!(index.server_capability_count("sqlite"), 0);
        assert_eq!(index.server_capability_count("postgres"), 1);
    }

    #[test]
    fn exact_name_match_scores_highest() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools(
            "s",
            &[
                make_tool("query", "Run query", json!({"type": "object"})),
                make_tool("querylog", "Query log viewer", json!({"type": "object"})),
            ],
        );
        let results = index.search("query", None);
        assert!(results.len() >= 2);
        assert_eq!(results[0].tool, "query"); // exact match first
        assert!(results[0].score > results[1].score);
    }

    #[test]
    fn prefix_match_scores_higher_than_description() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools(
            "s",
            &[
                make_tool("list_tables", "Show tables", json!({"type": "object"})),
                make_tool("drop", "List and remove items", json!({"type": "object"})),
            ],
        );
        let results = index.search("list", None);
        assert!(!results.is_empty());
        assert_eq!(results[0].tool, "list_tables"); // prefix match > description
    }

    #[test]
    fn server_filter_restricts_results() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools("sqlite", &sample_tools());
        index.add_server_tools(
            "postgres",
            &[make_tool("query", "Run query", json!({"type": "object"}))],
        );

        let all = index.search("query", None);
        let filtered = index.search("query", Some("sqlite"));
        assert!(all.len() > filtered.len());
        assert!(filtered.iter().all(|m| m.server == "sqlite"));
    }

    #[test]
    fn results_capped_at_40() {
        let mut index = McpCapabilityIndex::new();
        let capabilities: Vec<McpToolDef> = (0..50)
            .map(|i| make_tool(&format!("tool_{i}"), "a tool", json!({"type": "object"})))
            .collect();
        index.add_server_tools("big", &capabilities);

        let results = index.search("tool", None);
        assert_eq!(results.len(), 40);
    }

    #[test]
    fn case_insensitive_matching() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools(
            "s",
            &[make_tool(
                "CreateIssue",
                "Create a GitHub issue",
                json!({"type": "object"}),
            )],
        );

        let results = index.search("createissue", None);
        assert_eq!(results.len(), 1);
        let results2 = index.search("CREATEISSUE", None);
        assert_eq!(results2.len(), 1);
    }

    #[test]
    fn multi_keyword_query_combines_scores() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools(
            "s",
            &[
                make_tool("query", "Run SQL queries", json!({"type": "object"})),
                make_tool("list_tables", "List all tables", json!({"type": "object"})),
            ],
        );
        // "sql query" should score higher for "query" tool (matches name + description)
        let results = index.search("sql query", None);
        assert!(!results.is_empty());
        assert_eq!(results[0].tool, "query");
    }

    #[test]
    fn empty_description_still_matches_by_name() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools("s", &[make_tool("ping", "", json!({"type": "object"}))]);
        let results = index.search("ping", None);
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn param_summary_extraction_from_schema() {
        let schema = json!({
            "type": "object",
            "properties": {
                "sql": {"type": "string", "description": "SQL query"},
                "limit": {"type": "number", "description": "Row limit"}
            },
            "required": ["sql"]
        });
        let params = extract_params(&schema);
        assert_eq!(params.len(), 2);
        let sql_param = params.iter().find(|p| p.name == "sql").unwrap();
        assert!(sql_param.required);
        assert_eq!(sql_param.param_type, "string");
        let limit_param = params.iter().find(|p| p.name == "limit").unwrap();
        assert!(!limit_param.required);
    }

    #[test]
    fn param_summary_handles_empty_schema() {
        let params = extract_params(&json!({}));
        assert!(params.is_empty());
        let params2 = extract_params(&json!({"type": "object"}));
        assert!(params2.is_empty());
    }

    #[test]
    fn param_summary_handles_missing_required() {
        let schema = json!({
            "type": "object",
            "properties": {
                "name": {"type": "string"}
            }
        });
        let params = extract_params(&schema);
        assert_eq!(params.len(), 1);
        assert!(!params[0].required);
    }

    #[test]
    fn format_results_readable() {
        let matches = vec![McpCapabilityMatch {
            server: "sqlite".into(),
            tool: "query".into(),
            description: "Run SQL queries".into(),
            params: vec![
                ParamSummary {
                    name: "sql".into(),
                    param_type: "string".into(),
                    required: true,
                    description: "SQL".into(),
                },
                ParamSummary {
                    name: "limit".into(),
                    param_type: "number".into(),
                    required: false,
                    description: "Limit".into(),
                },
            ],
            score: 100,
        }];
        let output = McpCapabilityIndex::format_results(&matches);
        assert!(output.contains("[sqlite] query"));
        assert!(output.contains("sql (string, required)"));
        assert!(output.contains("limit (number)"));
    }

    #[test]
    fn format_results_empty_shows_helpful_message() {
        let output = McpCapabilityIndex::format_results(&[]);
        assert!(output.contains("No capabilities found"));
    }

    #[test]
    fn blank_server_filter_lists_all_servers() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools("sqlite", &sample_tools());
        index.add_server_tools(
            "browser",
            &[make_tool("click", "Click an element", json!({}))],
        );

        let results = index.search("", Some(""));

        assert_eq!(results.len(), 3);
        assert!(results.iter().any(|tool| tool.server == "sqlite"));
        assert!(results.iter().any(|tool| tool.server == "browser"));
    }

    #[test]
    fn search_with_no_query_returns_all() {
        let mut index = McpCapabilityIndex::new();
        index.add_server_tools("s", &sample_tools());
        let results = index.search("", None);
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn browse_mode_not_capped_at_40() {
        let mut index = McpCapabilityIndex::new();
        let capabilities: Vec<McpToolDef> = (0..50)
            .map(|i| make_tool(&format!("tool_{i}"), "a tool", json!({"type": "object"})))
            .collect();
        index.add_server_tools("big", &capabilities);

        let results = index.search("", None);
        assert_eq!(results.len(), 50);
    }
}
