pub mod rules;
pub mod skills;
pub mod tokens;

use std::path::{Path, PathBuf};

use tron_core::context::{LlmContext, Stability, SystemBlock, SystemBlockLabel};
use tron_core::ids::{SessionId, WorkspaceId};
use tron_core::messages::Message;
use tron_core::tools::ToolDefinition;
use tron_store::memory::MemoryRepo;
use tron_store::Database;

use self::rules::RulesFile;
use self::skills::SkillRegistry;
use self::tokens::{ThresholdLevel, estimate_message_tokens, estimate_system_tokens, estimate_tool_tokens};

/// Core system prompt (shared with TS server).
pub const TRON_CORE_PROMPT: &str = include_str!("../../prompts/core.txt");

/// OAuth system prompt prefix (prepended for OAuth mode).
pub const OAUTH_PROMPT_PREFIX: &str = "You are Claude Code, Anthropic's official CLI for Claude.";

/// Configuration for the context manager.
pub struct ContextConfig {
    pub project_root: PathBuf,
    pub working_directory: PathBuf,
    pub is_oauth: bool,
    pub context_window: usize,
    pub compaction_threshold: f64, // 0.0-1.0, default 0.7
}

impl Default for ContextConfig {
    fn default() -> Self {
        Self {
            project_root: PathBuf::from("."),
            working_directory: PathBuf::from("."),
            is_oauth: false,
            context_window: 200_000,
            compaction_threshold: 0.7,
        }
    }
}

/// Manages all context sources and composes them into LlmContext.
pub struct ContextManager {
    config: ContextConfig,
    static_rules: Vec<RulesFile>,
    dynamic_rules: Vec<RulesFile>,
    skill_registry: SkillRegistry,
    memory_repo: Option<MemoryRepo>,
    active_skills: Vec<String>,
    subagent_results: Vec<String>,
    task_context: Option<String>,
}

impl ContextManager {
    pub fn new(config: ContextConfig) -> Self {
        let static_rules = rules::load_rules(&config.project_root);
        let dynamic_rules = rules::load_dynamic_rules(&config.project_root);

        // Load skills from global and project dirs
        let global_skills = home_dir().join(".tron").join("skills");
        let project_skills = config.project_root.join(".tron").join("skills");
        let skill_registry = SkillRegistry::load(&global_skills, &project_skills);

        Self {
            config,
            static_rules,
            dynamic_rules,
            skill_registry,
            memory_repo: None,
            active_skills: Vec::new(),
            subagent_results: Vec::new(),
            task_context: None,
        }
    }

    /// Create a ContextManager with a database for memory access.
    pub fn with_database(config: ContextConfig, db: Database) -> Self {
        let mut cm = Self::new(config);
        cm.memory_repo = Some(MemoryRepo::new(db));
        cm
    }

    /// Set active skill references (extracted from prompt).
    pub fn set_active_skills(&mut self, names: Vec<String>) {
        self.active_skills = names;
    }

    /// Add a subagent result for context injection.
    pub fn add_subagent_result(&mut self, result: String) {
        self.subagent_results.push(result);
    }

    /// Clear subagent results after they've been consumed.
    pub fn clear_subagent_results(&mut self) {
        self.subagent_results.clear();
    }

    /// Set task context.
    pub fn set_task_context(&mut self, context: Option<String>) {
        self.task_context = context;
    }

    /// Refresh dynamic rules (call after tool execution touches new paths).
    pub fn refresh_dynamic_rules(&mut self) {
        self.dynamic_rules = rules::load_dynamic_rules(&self.config.project_root);
    }

    /// Build the complete LlmContext for a turn.
    pub fn build_context(
        &self,
        messages: Vec<Message>,
        tools: Vec<ToolDefinition>,
        workspace_id: &WorkspaceId,
        session_id: Option<&SessionId>,
    ) -> LlmContext {
        let mut system_blocks = Vec::new();

        // 1. OAuth prefix (if applicable)
        if self.config.is_oauth {
            system_blocks.push(SystemBlock {
                content: OAUTH_PROMPT_PREFIX.to_string(),
                stability: Stability::Stable,
                label: SystemBlockLabel::CorePrompt,
            });
        }

        // 2. Core system prompt + working directory
        system_blocks.push(SystemBlock {
            content: format!(
                "{}\n\nCurrent working directory: {}",
                TRON_CORE_PROMPT,
                self.config.working_directory.display()
            ),
            stability: Stability::Stable,
            label: SystemBlockLabel::CorePrompt,
        });

        // 3. Static rules (STABLE)
        if let Some(rules_content) = rules::format_rules(&self.static_rules) {
            system_blocks.push(SystemBlock {
                content: rules_content,
                stability: Stability::Stable,
                label: SystemBlockLabel::StaticRules,
            });
        }

        // 4. Memory content (STABLE)
        if let Some(repo) = &self.memory_repo {
            if let Ok(memory_content) = repo.compose_for_context(workspace_id, session_id) {
                if !memory_content.is_empty() {
                    system_blocks.push(SystemBlock {
                        content: format!("# Memory\n\n{memory_content}"),
                        stability: Stability::Stable,
                        label: SystemBlockLabel::MemoryContent,
                    });
                }
            }
        }

        // 5. Dynamic rules (VOLATILE)
        if let Some(rules_content) = rules::format_rules(&self.dynamic_rules) {
            system_blocks.push(SystemBlock {
                content: format!("# Active Rules\n\n{rules_content}"),
                stability: Stability::Volatile,
                label: SystemBlockLabel::DynamicRules,
            });
        }

        // 6. Skill context (VOLATILE)
        if let Some(skill_content) = self.skill_registry.format_skills(&self.active_skills) {
            system_blocks.push(SystemBlock {
                content: skill_content,
                stability: Stability::Volatile,
                label: SystemBlockLabel::SkillContext,
            });
        }

        // 7. Subagent results (VOLATILE)
        if !self.subagent_results.is_empty() {
            let results_content = self.subagent_results.join("\n\n---\n\n");
            system_blocks.push(SystemBlock {
                content: format!("# Subagent Results\n\n{results_content}"),
                stability: Stability::Volatile,
                label: SystemBlockLabel::SubagentResults,
            });
        }

        // 8. Task context (VOLATILE)
        if let Some(task_ctx) = &self.task_context {
            system_blocks.push(SystemBlock {
                content: format!("<task-context>\n{task_ctx}\n</task-context>"),
                stability: Stability::Volatile,
                label: SystemBlockLabel::TaskContext,
            });
        }

        LlmContext {
            messages,
            system_blocks,
            tools,
            working_directory: self.config.working_directory.clone(),
        }
    }

    /// Check if context needs compaction based on estimated token usage.
    pub fn check_threshold(
        &self,
        messages: &[Message],
        system_blocks: &[SystemBlock],
        tools: &[ToolDefinition],
    ) -> ThresholdLevel {
        let msg_tokens: u32 = messages.iter().map(estimate_message_tokens).sum();
        let sys_tokens = estimate_system_tokens(system_blocks);
        let tool_tokens = estimate_tool_tokens(tools);
        let total = msg_tokens + sys_tokens + tool_tokens;
        ThresholdLevel::from_usage(total, self.config.context_window as u32)
    }

    /// Get the skill registry reference.
    pub fn skills(&self) -> &SkillRegistry {
        &self.skill_registry
    }

    /// Get the static rules.
    pub fn static_rules(&self) -> &[RulesFile] {
        &self.static_rules
    }

    /// Get the dynamic rules.
    pub fn dynamic_rules(&self) -> &[RulesFile] {
        &self.dynamic_rules
    }

    /// Get filtered dynamic rules that apply to a specific file path.
    pub fn dynamic_rules_for_path(&self, _file_path: &Path) -> Vec<&RulesFile> {
        // For now, return all dynamic rules. In the future,
        // filter based on scope matching.
        self.dynamic_rules.iter().collect()
    }
}

/// Get user home directory.
fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tron_store::workspaces::WorkspaceRepo;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tron_ctx_test_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn build_context_basic() {
        let dir = temp_dir();
        // Create the core prompt file
        let prompts_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("prompts");
        fs::create_dir_all(&prompts_dir).unwrap();
        if !prompts_dir.join("core.txt").exists() {
            fs::write(prompts_dir.join("core.txt"), "You are a helpful assistant.").unwrap();
        }

        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            context_window: 200_000,
            ..Default::default()
        };
        let cm = ContextManager::new(config);
        let ws_id = WorkspaceId::new();

        let ctx = cm.build_context(
            vec![Message::user_text("hello")],
            vec![],
            &ws_id,
            None,
        );

        assert_eq!(ctx.messages.len(), 1);
        assert!(!ctx.system_blocks.is_empty());
        // Core prompt should be present
        assert!(ctx
            .system_blocks
            .iter()
            .any(|b| b.label == SystemBlockLabel::CorePrompt));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn build_context_with_oauth() {
        let dir = temp_dir();
        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            is_oauth: true,
            ..Default::default()
        };
        let cm = ContextManager::new(config);
        let ws_id = WorkspaceId::new();

        let ctx = cm.build_context(vec![], vec![], &ws_id, None);

        // OAuth should add prefix as first block
        assert!(ctx.system_blocks[0]
            .content
            .contains("You are Claude Code"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn build_context_with_rules() {
        let dir = temp_dir();
        fs::write(dir.join("CLAUDE.md"), "# Rules\nAlways use Rust.").unwrap();

        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            ..Default::default()
        };
        let cm = ContextManager::new(config);
        let ws_id = WorkspaceId::new();

        let ctx = cm.build_context(vec![], vec![], &ws_id, None);

        assert!(ctx
            .system_blocks
            .iter()
            .any(|b| b.label == SystemBlockLabel::StaticRules));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn build_context_with_memory() {
        let dir = temp_dir();
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();

        let mem_repo = tron_store::memory::MemoryRepo::new(db.clone());
        mem_repo
            .add(&ws.id, None, "Rust pattern", "Use Arc<Mutex>", 10, tron_store::memory::MemorySource::Auto)
            .unwrap();

        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            ..Default::default()
        };
        let mut cm = ContextManager::new(config);
        cm.memory_repo = Some(tron_store::memory::MemoryRepo::new(db));

        let ctx = cm.build_context(vec![], vec![], &ws.id, None);

        let memory_block = ctx
            .system_blocks
            .iter()
            .find(|b| b.label == SystemBlockLabel::MemoryContent);
        assert!(memory_block.is_some());
        assert!(memory_block.unwrap().content.contains("Arc<Mutex>"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn build_context_with_skills() {
        let dir = temp_dir();
        let skills_dir = dir.join(".tron").join("skills");
        fs::create_dir_all(&skills_dir).unwrap();
        fs::write(skills_dir.join("commit.md"), "Commit all changes.").unwrap();

        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            ..Default::default()
        };
        let mut cm = ContextManager::new(config);
        cm.set_active_skills(vec!["commit".to_string()]);
        let ws_id = WorkspaceId::new();

        let ctx = cm.build_context(vec![], vec![], &ws_id, None);

        let skill_block = ctx
            .system_blocks
            .iter()
            .find(|b| b.label == SystemBlockLabel::SkillContext);
        assert!(skill_block.is_some());
        assert!(skill_block.unwrap().content.contains("<skill name=\"commit\">"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn build_context_with_task_context() {
        let dir = temp_dir();
        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            ..Default::default()
        };
        let mut cm = ContextManager::new(config);
        cm.set_task_context(Some("1. Fix bug\n2. Write tests".into()));
        let ws_id = WorkspaceId::new();

        let ctx = cm.build_context(vec![], vec![], &ws_id, None);

        let task_block = ctx
            .system_blocks
            .iter()
            .find(|b| b.label == SystemBlockLabel::TaskContext);
        assert!(task_block.is_some());
        assert!(task_block.unwrap().content.contains("Fix bug"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn build_context_with_subagent_results() {
        let dir = temp_dir();
        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            ..Default::default()
        };
        let mut cm = ContextManager::new(config);
        cm.add_subagent_result("Found 3 matching files.".into());
        let ws_id = WorkspaceId::new();

        let ctx = cm.build_context(vec![], vec![], &ws_id, None);

        let subagent_block = ctx
            .system_blocks
            .iter()
            .find(|b| b.label == SystemBlockLabel::SubagentResults);
        assert!(subagent_block.is_some());
        assert!(subagent_block.unwrap().content.contains("Found 3 matching files"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn composition_order_stable_before_volatile() {
        let dir = temp_dir();
        fs::write(dir.join("CLAUDE.md"), "Project rules.").unwrap();
        let rules_dir = dir.join(".claude").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("test.md"), "Dynamic rule.").unwrap();

        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            ..Default::default()
        };
        let mut cm = ContextManager::new(config);
        cm.set_task_context(Some("task".into()));
        let ws_id = WorkspaceId::new();

        let ctx = cm.build_context(vec![], vec![], &ws_id, None);

        // Find positions of stable vs volatile blocks
        let stable_idx = ctx
            .system_blocks
            .iter()
            .position(|b| b.stability == Stability::Stable);
        let volatile_idx = ctx
            .system_blocks
            .iter()
            .position(|b| b.stability == Stability::Volatile);

        if let (Some(s), Some(v)) = (stable_idx, volatile_idx) {
            assert!(s < v, "stable blocks should come before volatile blocks");
        }

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_threshold() {
        let dir = temp_dir();
        let config = ContextConfig {
            project_root: dir.clone(),
            working_directory: dir.clone(),
            context_window: 1000,
            ..Default::default()
        };
        let cm = ContextManager::new(config);

        // Small context — normal
        let level = cm.check_threshold(
            &[Message::user_text("hi")],
            &[],
            &[],
        );
        assert_eq!(level, ThresholdLevel::Normal);

        fs::remove_dir_all(&dir).ok();
    }
}
