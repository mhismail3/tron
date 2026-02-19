//! Audit logger for guardrail decisions.
//!
//! Maintains an in-memory circular buffer of recent guardrail evaluations
//! for debugging and analysis. Redacts sensitive fields (passwords, tokens, secrets)
//! and truncates long strings.

use std::collections::VecDeque;

use super::types::{AuditEntry, AuditEntryParams, AuditStats};

/// Default maximum audit entries to keep in memory.
const DEFAULT_MAX_ENTRIES: usize = 1000;

/// Keys that indicate sensitive data requiring redaction.
const SENSITIVE_KEYS: &[&str] = &["password", "token", "secret", "key", "auth", "credential"];

/// Maximum length for string values in audit logs before truncation.
const MAX_STRING_LENGTH: usize = 1000;

/// Audit logger for guardrail decisions.
///
/// Uses a circular buffer with configurable capacity (default 1000).
/// Entries are stored in-memory only — this is for transient session
/// diagnostics, not durable persistence.
pub struct AuditLogger {
    entries: VecDeque<AuditEntry>,
    max_entries: usize,
    id_counter: u64,
}

impl AuditLogger {
    /// Create a new audit logger with the given maximum capacity.
    pub fn new(max_entries: Option<usize>) -> Self {
        Self {
            entries: VecDeque::new(),
            max_entries: max_entries.unwrap_or(DEFAULT_MAX_ENTRIES),
            id_counter: 0,
        }
    }

    /// Log a guardrail evaluation.
    ///
    /// Returns the created audit entry. If the buffer exceeds capacity,
    /// the oldest entry is evicted.
    pub fn log(&mut self, params: AuditEntryParams) -> AuditEntry {
        self.id_counter += 1;

        let entry = AuditEntry {
            id: format!("audit-{}", self.id_counter),
            timestamp: chrono::Utc::now().to_rfc3339(),
            session_id: params.session_id,
            tool_name: params.tool_name,
            tool_call_id: params.tool_call_id,
            evaluation: params.evaluation,
            tool_arguments: params.tool_arguments.map(|args| redact_sensitive(&args)),
        };

        self.entries.push_back(entry.clone());
        if self.entries.len() > self.max_entries {
            let _ = self.entries.pop_front();
        }

        entry
    }

    /// Get recent audit entries, optionally limited.
    pub fn entries(&self, limit: Option<usize>) -> Vec<&AuditEntry> {
        let count = limit.unwrap_or(self.entries.len());
        self.entries.iter().rev().take(count).rev().collect()
    }

    /// Get entries for a specific session, optionally limited.
    pub fn entries_for_session(&self, session_id: &str, limit: Option<usize>) -> Vec<&AuditEntry> {
        let session_entries: Vec<&AuditEntry> = self
            .entries
            .iter()
            .filter(|e| e.session_id.as_deref() == Some(session_id))
            .collect();
        let count = limit.unwrap_or(session_entries.len());
        session_entries
            .into_iter()
            .rev()
            .take(count)
            .rev()
            .collect()
    }

    /// Get entries where a rule was triggered.
    ///
    /// If `rule_id` is `Some`, only returns entries where that specific rule triggered.
    /// If `None`, returns all entries with any triggered rules.
    pub fn triggered_entries(&self, rule_id: Option<&str>) -> Vec<&AuditEntry> {
        self.entries
            .iter()
            .filter(|e| {
                if e.evaluation.triggered_rules.is_empty() {
                    return false;
                }
                match rule_id {
                    Some(id) => e.evaluation.triggered_rules.iter().any(|r| r.rule_id == id),
                    None => true,
                }
            })
            .collect()
    }

    /// Get entries where tool execution was blocked.
    pub fn blocked_entries(&self) -> Vec<&AuditEntry> {
        self.entries
            .iter()
            .filter(|e| e.evaluation.blocked)
            .collect()
    }

    /// Clear all entries.
    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Get statistics about audit entries.
    pub fn stats(&self) -> AuditStats {
        let mut stats = AuditStats {
            total: self.entries.len(),
            ..Default::default()
        };

        for entry in &self.entries {
            if entry.evaluation.blocked {
                stats.blocked += 1;
            } else if entry.evaluation.has_warnings {
                stats.warnings += 1;
            } else {
                stats.passed += 1;
            }

            *stats.by_tool.entry(entry.tool_name.clone()).or_insert(0) += 1;

            for rule in &entry.evaluation.triggered_rules {
                *stats.by_rule.entry(rule.rule_id.clone()).or_insert(0) += 1;
            }
        }

        stats
    }

    /// Get the total number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Check if the audit log is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

impl std::fmt::Debug for AuditLogger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuditLogger")
            .field("entries", &self.entries.len())
            .field("max_entries", &self.max_entries)
            .field("id_counter", &self.id_counter)
            .finish()
    }
}

/// Redact sensitive information from tool arguments.
///
/// Keys containing "password", "token", "secret", "key", "auth", or "credential"
/// are replaced with "[REDACTED]". Strings longer than 1000 chars are truncated.
fn redact_sensitive(args: &serde_json::Value) -> serde_json::Value {
    match args {
        serde_json::Value::Object(map) => {
            let mut redacted = serde_json::Map::new();
            for (key, value) in map {
                let lower_key = key.to_lowercase();
                let is_sensitive = SENSITIVE_KEYS.iter().any(|s| lower_key.contains(s));

                if is_sensitive {
                    let _ = redacted.insert(key.clone(), serde_json::json!("[REDACTED]"));
                } else if let serde_json::Value::String(s) = value {
                    if s.len() > MAX_STRING_LENGTH {
                        let prefix = tron_core::text::truncate_str(s, MAX_STRING_LENGTH);
                        let _ = redacted.insert(
                            key.clone(),
                            serde_json::json!(format!("{prefix}... [truncated]")),
                        );
                    } else {
                        let _ = redacted.insert(key.clone(), value.clone());
                    }
                } else {
                    let _ = redacted.insert(key.clone(), value.clone());
                }
            }
            serde_json::Value::Object(redacted)
        }
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_redact_password() {
        let args = serde_json::json!({"password": "secret123", "command": "ls"});
        let redacted = redact_sensitive(&args);
        assert_eq!(redacted["password"], "[REDACTED]");
        assert_eq!(redacted["command"], "ls");
    }

    #[test]
    fn test_redact_token() {
        let args = serde_json::json!({"apiToken": "abc", "name": "test"});
        let redacted = redact_sensitive(&args);
        assert_eq!(redacted["apiToken"], "[REDACTED]");
        assert_eq!(redacted["name"], "test");
    }

    #[test]
    fn test_truncate_long_string() {
        let long = "a".repeat(2000);
        let args = serde_json::json!({"content": long});
        let redacted = redact_sensitive(&args);
        let val = redacted["content"].as_str().unwrap();
        assert!(val.len() < 2000);
        assert!(val.ends_with("... [truncated]"));
    }
}
