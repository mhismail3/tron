//! Context audit tracking.
//!
//! [`ContextAudit`] records what goes into an agent's context window:
//! loaded files, handoffs, tools, hook modifications, system prompt,
//! and token estimates. Produces markdown and JSON reports for debugging.

use std::fmt::Write as _;

use super::constants::CHARS_PER_TOKEN;

// =============================================================================
// Audit data types
// =============================================================================

/// A loaded context file.
#[derive(Clone, Debug)]
pub struct ContextFileEntry {
    /// Absolute path.
    pub path: String,
    /// Source level.
    pub file_type: ContextFileType,
    /// Character count.
    pub char_count: usize,
    /// Line count.
    pub line_count: usize,
    /// First 500 chars for preview.
    pub preview: String,
    /// When this file was loaded.
    pub loaded_at: String,
}

/// Where a context file came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ContextFileType {
    /// User-global config (`~/.tron/`).
    Global,
    /// Project-level config (`.claude/AGENTS.md`).
    Project,
    /// Nested directory config.
    Directory,
}

impl std::fmt::Display for ContextFileType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Global => f.write_str("global"),
            Self::Project => f.write_str("project"),
            Self::Directory => f.write_str("directory"),
        }
    }
}

/// A cross-session handoff entry.
#[derive(Clone, Debug)]
pub struct HandoffEntry {
    /// Handoff identifier.
    pub id: String,
    /// Source session.
    pub session_id: String,
    /// Handoff summary text.
    pub summary: String,
    /// Character count of handoff content.
    pub char_count: usize,
    /// When the handoff was created.
    pub timestamp: String,
}

/// A hook-induced context modification.
#[derive(Clone, Debug)]
pub struct HookModification {
    /// Hook identifier.
    pub hook_id: String,
    /// Hook event type (e.g. `PreToolUse`).
    pub event: String,
    /// Description of the modification.
    pub modification: String,
    /// Positive = added, negative = removed.
    pub char_delta: i64,
    /// When the modification occurred.
    pub timestamp: String,
}

/// A registered tool.
#[derive(Clone, Debug)]
pub struct ToolEntry {
    /// Tool name.
    pub name: String,
    /// Tool description.
    pub description: String,
    /// Character count of the JSON schema.
    pub schema_char_count: usize,
}

/// System prompt section.
#[derive(Clone, Debug)]
pub struct PromptSection {
    /// Section name (e.g. "core", "rules").
    pub name: String,
    /// Section content.
    pub content: String,
    /// Where the section originated (e.g. "built-in", "file").
    pub source: String,
}

/// Token estimate breakdown.
#[derive(Clone, Debug, Default)]
pub struct AuditTokenEstimates {
    /// Tokens from loaded context files.
    pub context_tokens: u64,
    /// Tokens from the system prompt.
    pub system_prompt_tokens: u64,
    /// Tokens from tool definitions.
    pub tool_tokens: u64,
    /// Sum of all components.
    pub total_base_tokens: u64,
}

/// Session metadata.
#[derive(Clone, Debug)]
pub struct AuditSession {
    /// Session identifier.
    pub id: String,
    /// Session type (e.g. "new", "resume", "fork").
    pub session_type: String,
    /// Parent session if forked.
    pub parent_session_id: Option<String>,
    /// Fork point event ID if forked.
    pub fork_point: Option<String>,
    /// Session start timestamp.
    pub started_at: String,
    /// Working directory path.
    pub working_directory: String,
    /// Model identifier.
    pub model: String,
}

// =============================================================================
// ContextAudit
// =============================================================================

/// Tracks all context sources for debugging and traceability.
#[derive(Clone, Debug)]
pub struct ContextAudit {
    session: Option<AuditSession>,
    context_files: Vec<ContextFileEntry>,
    handoffs: Vec<HandoffEntry>,
    tools: Vec<ToolEntry>,
    hook_modifications: Vec<HookModification>,
    system_prompt_sections: Vec<PromptSection>,
    system_prompt_char_count: usize,
    token_estimates: AuditTokenEstimates,
}

impl Default for ContextAudit {
    fn default() -> Self {
        Self::new()
    }
}

impl ContextAudit {
    /// Create an empty audit.
    #[must_use]
    pub fn new() -> Self {
        Self {
            session: None,
            context_files: Vec::new(),
            handoffs: Vec::new(),
            tools: Vec::new(),
            hook_modifications: Vec::new(),
            system_prompt_sections: Vec::new(),
            system_prompt_char_count: 0,
            token_estimates: AuditTokenEstimates::default(),
        }
    }

    // ── Setters ─────────────────────────────────────────────────────────

    /// Set the session metadata.
    pub fn set_session(&mut self, session: AuditSession) {
        self.session = Some(session);
    }

    /// Record a loaded context file.
    pub fn add_context_file(&mut self, path: &str, file_type: ContextFileType, content: &str) {
        let char_count = content.len();
        let line_count = content.lines().count();
        let preview: String = content.chars().take(500).collect();

        self.context_files.push(ContextFileEntry {
            path: path.to_owned(),
            file_type,
            char_count,
            line_count,
            preview,
            loaded_at: String::new(),
        });

        self.recalculate_token_estimates();
    }

    /// Record a cross-session handoff.
    pub fn add_handoff(&mut self, handoff: HandoffEntry) {
        self.handoffs.push(handoff);
    }

    /// Record a registered tool.
    pub fn add_tool(&mut self, name: &str, description: &str, schema_chars: usize) {
        self.tools.push(ToolEntry {
            name: name.to_owned(),
            description: description.to_owned(),
            schema_char_count: schema_chars,
        });
        self.recalculate_token_estimates();
    }

    /// Record a hook-induced context modification.
    pub fn add_hook_modification(&mut self, modification: HookModification) {
        self.hook_modifications.push(modification);
    }

    /// Set the system prompt and its composition sections.
    pub fn set_system_prompt(&mut self, content: &str, sections: Vec<PromptSection>) {
        self.system_prompt_char_count = content.len();
        self.system_prompt_sections = sections;
        self.recalculate_token_estimates();
    }

    // ── Getters ─────────────────────────────────────────────────────────

    #[must_use]
    /// Get the session metadata, if set.
    pub fn session(&self) -> Option<&AuditSession> {
        self.session.as_ref()
    }

    #[must_use]
    /// Get all loaded context files.
    pub fn context_files(&self) -> &[ContextFileEntry] {
        &self.context_files
    }

    #[must_use]
    /// Get all handoff entries.
    pub fn handoffs(&self) -> &[HandoffEntry] {
        &self.handoffs
    }

    #[must_use]
    /// Get all registered tools.
    pub fn tools(&self) -> &[ToolEntry] {
        &self.tools
    }

    #[must_use]
    /// Get all hook modifications.
    pub fn hook_modifications(&self) -> &[HookModification] {
        &self.hook_modifications
    }

    #[must_use]
    /// Get the current token estimates.
    pub fn token_estimates(&self) -> &AuditTokenEstimates {
        &self.token_estimates
    }

    // ── Output ──────────────────────────────────────────────────────────

    #[must_use]
    /// Produce a one-line summary string.
    pub fn to_summary(&self) -> String {
        let session_id = self
            .session
            .as_ref()
            .map_or("unknown", |s| s.id.as_str());
        format!(
            "session={} files={} handoffs={} tools={} tokens={}",
            session_id,
            self.context_files.len(),
            self.handoffs.len(),
            self.tools.len(),
            self.token_estimates.total_base_tokens,
        )
    }

    #[must_use]
    /// Produce a full markdown report.
    pub fn to_markdown(&self) -> String {
        let mut md = String::with_capacity(2048);

        let _ = writeln!(md, "# Context Audit\n");

        // Session
        if let Some(s) = &self.session {
            let _ = writeln!(md, "## Session\n");
            let _ = writeln!(md, "- **ID**: {}", s.id);
            let _ = writeln!(md, "- **Type**: {}", s.session_type);
            let _ = writeln!(md, "- **Model**: {}", s.model);
            let _ = writeln!(md, "- **Working Directory**: {}", s.working_directory);
            let _ = writeln!(md, "- **Started At**: {}", s.started_at);
            if let Some(parent) = &s.parent_session_id {
                let _ = writeln!(md, "- **Parent Session**: {parent}");
            }
            let _ = writeln!(md);
        }

        // Token estimates
        let est = &self.token_estimates;
        let _ = writeln!(md, "## Token Estimates\n");
        let _ = writeln!(md, "| Component | Tokens |");
        let _ = writeln!(md, "|-----------|--------|");
        let _ = writeln!(md, "| System prompt | {} |", est.system_prompt_tokens);
        let _ = writeln!(md, "| Tools | {} |", est.tool_tokens);
        let _ = writeln!(md, "| Context files | {} |", est.context_tokens);
        let _ = writeln!(md, "| **Total base** | **{}** |", est.total_base_tokens);
        let _ = writeln!(md);

        // Context files
        if !self.context_files.is_empty() {
            let _ = writeln!(md, "## Context Files ({})\n", self.context_files.len());
            for file in &self.context_files {
                let _ = writeln!(
                    md,
                    "### {} ({})\n",
                    file.path, file.file_type,
                );
                let _ = writeln!(
                    md,
                    "- {} chars, {} lines",
                    file.char_count, file.line_count,
                );
                if !file.preview.is_empty() {
                    let _ = writeln!(md, "\n```\n{}...\n```\n", file.preview);
                }
            }
        }

        // Handoffs
        if !self.handoffs.is_empty() {
            let _ = writeln!(md, "## Handoffs ({})\n", self.handoffs.len());
            for h in &self.handoffs {
                let _ = writeln!(
                    md,
                    "- **{}** from session {} ({} chars): {}",
                    h.id, h.session_id, h.char_count, h.summary,
                );
            }
            let _ = writeln!(md);
        }

        // Tools
        if !self.tools.is_empty() {
            let _ = writeln!(md, "## Tools ({})\n", self.tools.len());
            for t in &self.tools {
                let _ = writeln!(
                    md,
                    "- **{}**: {} ({} schema chars)",
                    t.name, t.description, t.schema_char_count,
                );
            }
            let _ = writeln!(md);
        }

        // Hook modifications
        if !self.hook_modifications.is_empty() {
            let _ = writeln!(
                md,
                "## Hook Modifications ({})\n",
                self.hook_modifications.len(),
            );
            for h in &self.hook_modifications {
                let delta = if h.char_delta >= 0 {
                    format!("+{}", h.char_delta)
                } else {
                    h.char_delta.to_string()
                };
                let _ = writeln!(
                    md,
                    "- [{}] {} — {} ({delta} chars)",
                    h.event, h.hook_id, h.modification,
                );
            }
            let _ = writeln!(md);
        }

        // System prompt
        if !self.system_prompt_sections.is_empty() {
            let _ = writeln!(md, "## System Prompt Composition\n");
            let _ = writeln!(md, "Total: {} chars\n", self.system_prompt_char_count);
            let _ = writeln!(md, "| Section | Source | Chars |");
            let _ = writeln!(md, "|---------|--------|-------|");
            for s in &self.system_prompt_sections {
                let _ = writeln!(
                    md,
                    "| {} | {} | {} |",
                    s.name,
                    s.source,
                    s.content.len(),
                );
            }
            let _ = writeln!(md);
        }

        md
    }

    // ── Private ─────────────────────────────────────────────────────────

    fn recalculate_token_estimates(&mut self) {
        let file_chars: usize = self.context_files.iter().map(|f| f.char_count).sum();
        let tool_chars: usize = self.tools.iter().map(|t| t.schema_char_count).sum();
        let prompt_chars = self.system_prompt_char_count;

        #[allow(clippy::cast_possible_truncation)]
        let to_tokens = |chars: usize| -> u64 { chars.div_ceil(CHARS_PER_TOKEN as usize) as u64 };

        self.token_estimates.context_tokens = to_tokens(file_chars);
        self.token_estimates.tool_tokens = to_tokens(tool_chars);
        self.token_estimates.system_prompt_tokens = to_tokens(prompt_chars);
        self.token_estimates.total_base_tokens = self.token_estimates.context_tokens
            + self.token_estimates.tool_tokens
            + self.token_estimates.system_prompt_tokens;
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_session() -> AuditSession {
        AuditSession {
            id: "sess-123".into(),
            session_type: "new".into(),
            parent_session_id: None,
            fork_point: None,
            started_at: "2026-01-15T10:00:00Z".into(),
            working_directory: "/home/user/project".into(),
            model: "claude-sonnet-4-5-20250929".into(),
        }
    }

    #[test]
    fn new_audit_is_empty() {
        let audit = ContextAudit::new();
        assert!(audit.context_files().is_empty());
        assert!(audit.handoffs().is_empty());
        assert!(audit.tools().is_empty());
        assert!(audit.hook_modifications().is_empty());
        assert!(audit.session().is_none());
        assert_eq!(audit.token_estimates().total_base_tokens, 0);
    }

    #[test]
    fn default_audit_is_empty() {
        let audit = ContextAudit::default();
        assert_eq!(audit.token_estimates().total_base_tokens, 0);
    }

    #[test]
    fn set_session() {
        let mut audit = ContextAudit::new();
        audit.set_session(sample_session());
        let s = audit.session().unwrap();
        assert_eq!(s.id, "sess-123");
        assert_eq!(s.model, "claude-sonnet-4-5-20250929");
    }

    #[test]
    fn add_context_file_tracks_metadata() {
        let mut audit = ContextAudit::new();
        audit.add_context_file("/project/.claude/AGENTS.md", ContextFileType::Project, "# Rules\n\nBe helpful.");
        assert_eq!(audit.context_files().len(), 1);
        let f = &audit.context_files()[0];
        assert_eq!(f.path, "/project/.claude/AGENTS.md");
        assert_eq!(f.file_type, ContextFileType::Project);
        assert_eq!(f.char_count, 20);
        assert_eq!(f.line_count, 3);
    }

    #[test]
    fn add_context_file_preview_truncated() {
        let mut audit = ContextAudit::new();
        let long_content = "x".repeat(1000);
        audit.add_context_file("/file.md", ContextFileType::Global, &long_content);
        assert_eq!(audit.context_files()[0].preview.len(), 500);
    }

    #[test]
    fn add_context_file_updates_token_estimates() {
        let mut audit = ContextAudit::new();
        audit.add_context_file("/file.md", ContextFileType::Project, &"a".repeat(400));
        // 400 chars / 4 = 100 tokens
        assert_eq!(audit.token_estimates().context_tokens, 100);
        assert_eq!(audit.token_estimates().total_base_tokens, 100);
    }

    #[test]
    fn add_tool_updates_token_estimates() {
        let mut audit = ContextAudit::new();
        audit.add_tool("bash", "Execute a command", 800);
        assert_eq!(audit.tools().len(), 1);
        // 800 / 4 = 200
        assert_eq!(audit.token_estimates().tool_tokens, 200);
    }

    #[test]
    fn set_system_prompt_updates_estimates() {
        let mut audit = ContextAudit::new();
        let content = "a".repeat(1200);
        audit.set_system_prompt(
            &content,
            vec![PromptSection {
                name: "core".into(),
                content: content.clone(),
                source: "built-in".into(),
            }],
        );
        // 1200 / 4 = 300
        assert_eq!(audit.token_estimates().system_prompt_tokens, 300);
    }

    #[test]
    fn total_base_tokens_sums_all_components() {
        let mut audit = ContextAudit::new();
        audit.add_context_file("/f.md", ContextFileType::Project, &"a".repeat(400)); // 100
        audit.add_tool("bash", "cmd", 400); // 100
        audit.set_system_prompt(&"b".repeat(800), vec![]); // 200
        assert_eq!(audit.token_estimates().total_base_tokens, 400);
    }

    #[test]
    fn add_handoff() {
        let mut audit = ContextAudit::new();
        audit.add_handoff(HandoffEntry {
            id: "h-1".into(),
            session_id: "s-prev".into(),
            summary: "Previous work on auth".into(),
            char_count: 500,
            timestamp: "2026-01-15T09:00:00Z".into(),
        });
        assert_eq!(audit.handoffs().len(), 1);
        assert_eq!(audit.handoffs()[0].id, "h-1");
    }

    #[test]
    fn add_hook_modification() {
        let mut audit = ContextAudit::new();
        audit.add_hook_modification(HookModification {
            hook_id: "security-check".into(),
            event: "PreToolUse".into(),
            modification: "Added security warning".into(),
            char_delta: 150,
            timestamp: "2026-01-15T10:05:00Z".into(),
        });
        assert_eq!(audit.hook_modifications().len(), 1);
        assert_eq!(audit.hook_modifications()[0].char_delta, 150);
    }

    #[test]
    fn to_summary_format() {
        let mut audit = ContextAudit::new();
        audit.set_session(sample_session());
        audit.add_context_file("/f.md", ContextFileType::Project, "hello");
        audit.add_tool("bash", "cmd", 100);
        let summary = audit.to_summary();
        assert!(summary.contains("session=sess-123"));
        assert!(summary.contains("files=1"));
        assert!(summary.contains("tools=1"));
    }

    #[test]
    fn to_summary_unknown_session() {
        let audit = ContextAudit::new();
        assert!(audit.to_summary().contains("session=unknown"));
    }

    #[test]
    fn to_markdown_contains_sections() {
        let mut audit = ContextAudit::new();
        audit.set_session(sample_session());
        audit.add_context_file("/f.md", ContextFileType::Project, "# Hello");
        audit.add_tool("read", "Read a file", 200);
        audit.add_handoff(HandoffEntry {
            id: "h-1".into(),
            session_id: "s-0".into(),
            summary: "Prior work".into(),
            char_count: 100,
            timestamp: String::new(),
        });
        audit.add_hook_modification(HookModification {
            hook_id: "hook-1".into(),
            event: "PreToolUse".into(),
            modification: "Blocked".into(),
            char_delta: -50,
            timestamp: String::new(),
        });
        audit.set_system_prompt(
            "System prompt content",
            vec![PromptSection {
                name: "core".into(),
                content: "System prompt content".into(),
                source: "built-in".into(),
            }],
        );

        let md = audit.to_markdown();
        assert!(md.contains("# Context Audit"));
        assert!(md.contains("## Session"));
        assert!(md.contains("sess-123"));
        assert!(md.contains("## Token Estimates"));
        assert!(md.contains("## Context Files (1)"));
        assert!(md.contains("## Handoffs (1)"));
        assert!(md.contains("## Tools (1)"));
        assert!(md.contains("## Hook Modifications (1)"));
        assert!(md.contains("-50 chars"));
        assert!(md.contains("## System Prompt Composition"));
    }

    #[test]
    fn to_markdown_empty_audit() {
        let audit = ContextAudit::new();
        let md = audit.to_markdown();
        assert!(md.contains("# Context Audit"));
        assert!(md.contains("## Token Estimates"));
        // No files/handoffs/tools/hooks sections
        assert!(!md.contains("## Context Files"));
        assert!(!md.contains("## Handoffs"));
        assert!(!md.contains("## Tools"));
    }

    #[test]
    fn context_file_type_display() {
        assert_eq!(format!("{}", ContextFileType::Global), "global");
        assert_eq!(format!("{}", ContextFileType::Project), "project");
        assert_eq!(format!("{}", ContextFileType::Directory), "directory");
    }

    #[test]
    fn multiple_context_files_accumulate_tokens() {
        let mut audit = ContextAudit::new();
        audit.add_context_file("/a.md", ContextFileType::Project, &"a".repeat(100)); // 25
        audit.add_context_file("/b.md", ContextFileType::Directory, &"b".repeat(200)); // 50
        assert_eq!(audit.context_files().len(), 2);
        assert_eq!(audit.token_estimates().context_tokens, 75);
    }

    #[test]
    fn multiple_tools_accumulate_tokens() {
        let mut audit = ContextAudit::new();
        audit.add_tool("bash", "cmd", 400); // 100
        audit.add_tool("read", "file", 200); // 50
        assert_eq!(audit.tools().len(), 2);
        assert_eq!(audit.token_estimates().tool_tokens, 150);
    }

    #[test]
    fn parent_session_in_markdown() {
        let mut audit = ContextAudit::new();
        audit.set_session(AuditSession {
            id: "s-2".into(),
            session_type: "resume".into(),
            parent_session_id: Some("s-1".into()),
            fork_point: None,
            started_at: String::new(),
            working_directory: "/tmp".into(),
            model: "claude-opus-4-6".into(),
        });
        let md = audit.to_markdown();
        assert!(md.contains("**Parent Session**: s-1"));
    }

    #[test]
    fn hook_modification_positive_delta_in_markdown() {
        let mut audit = ContextAudit::new();
        audit.add_hook_modification(HookModification {
            hook_id: "h".into(),
            event: "PostToolUse".into(),
            modification: "Added context".into(),
            char_delta: 200,
            timestamp: String::new(),
        });
        let md = audit.to_markdown();
        assert!(md.contains("+200 chars"));
    }
}
