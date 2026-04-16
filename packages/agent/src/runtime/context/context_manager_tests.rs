use super::*;
use crate::runtime::context::types::CompactionConfig;

fn test_config() -> ContextManagerConfig {
    ContextManagerConfig {
        model: "claude-sonnet-4-5-20250929".into(),
        system_prompt: Some("You are helpful.".into()),
        working_directory: Some("/tmp".into()),
        tools: Vec::new(),
        rules_content: None,
        compaction: CompactionConfig {
            threshold: 0.70,
            preserve_recent_turns: 5,
            context_limit: 100_000,
        },
    }
}

// -- construction --

#[test]
fn new_context_manager() {
    let cm = ContextManager::new(test_config());
    assert_eq!(cm.get_model(), "claude-sonnet-4-5-20250929");
    assert_eq!(cm.get_system_prompt(), "You are helpful.");
    assert_eq!(cm.message_count(), 0);
    assert_eq!(cm.get_context_limit(), 100_000);
}

#[test]
fn working_directory_defaults_to_home_workspace_when_none() {
    let config = ContextManagerConfig {
        working_directory: None,
        ..test_config()
    };
    let cm = ContextManager::new(config);
    let wd = cm.get_working_directory();
    let home = crate::core::paths::home_dir();
    assert_eq!(wd, format!("{home}/Workspace"));
}

#[test]
fn default_system_prompt() {
    let config = ContextManagerConfig {
        system_prompt: None,
        ..test_config()
    };
    let cm = ContextManager::new(config);
    assert!(!cm.get_system_prompt().is_empty());
}

// -- local model system prompt --

#[test]
fn ollama_model_gets_local_prompt() {
    let config = ContextManagerConfig {
        model: "gemma4:e4b".into(),
        system_prompt: None,
        ..test_config()
    };
    let cm = ContextManager::new(config);
    let prompt = cm.get_system_prompt();
    assert!(prompt.contains("Tool routing"));
    assert!(!prompt.contains("YOUR IDENTITY"));
}

#[test]
fn ollama_model_custom_prompt_takes_precedence() {
    let config = ContextManagerConfig {
        model: "gemma4:e4b".into(),
        system_prompt: Some("Custom override".into()),
        ..test_config()
    };
    let cm = ContextManager::new(config);
    assert_eq!(cm.get_system_prompt(), "Custom override");
}

#[test]
fn non_ollama_model_gets_core_prompt() {
    let config = ContextManagerConfig {
        model: "claude-sonnet-4-5-20250929".into(),
        system_prompt: None,
        ..test_config()
    };
    let cm = ContextManager::new(config);
    assert!(cm.get_system_prompt().contains("YOUR IDENTITY"));
}

// -- volatile token accounting --

#[test]
fn cloud_session_counts_all_volatile_tokens() {
    let mut cm = ContextManager::new(test_config());
    let baseline = cm.get_current_tokens();
    cm.set_volatile_tokens(100, 50, 500);
    let delta = cm.get_current_tokens() - baseline;
    assert_eq!(delta, 100 + 50 + 500);
}

#[test]
fn local_session_excludes_job_results_from_current_tokens() {
    let config = ContextManagerConfig {
        model: "gemma4:e4b".into(),
        system_prompt: Some("You are helpful.".into()),
        ..test_config()
    };
    let mut cm = ContextManager::new(config);
    let baseline = cm.get_current_tokens();
    // Pass a non-zero job_results; set_volatile_tokens must coerce it to 0 for
    // local models, and get_current_tokens must not count it. Skill tokens
    // flow through because users can still manually activate a skill.
    cm.set_volatile_tokens(100, 50, 500);
    let delta = cm.get_current_tokens() - baseline;
    assert_eq!(delta, 100 + 50, "job_results (500) must be excluded");
}

#[test]
fn local_session_snapshot_and_get_current_tokens_agree() {
    // Regression for a prior bug: the snapshot adapter gated
    // volatile_job_results_tokens on is_local_model, but get_current_tokens
    // didn't — so for local sessions with a non-zero volatile job_results
    // estimate the two totals disagreed. After the fix, they must match
    // regardless of what callers pass to set_volatile_tokens.
    let config = ContextManagerConfig {
        model: "gemma4:e4b".into(),
        system_prompt: Some("You are helpful.".into()),
        ..test_config()
    };
    let mut cm = ContextManager::new(config);
    cm.set_volatile_tokens(80, 40, 500);
    let snap = cm.get_snapshot();
    assert_eq!(snap.current_tokens, cm.get_current_tokens());
}

// -- is_local_model --

#[test]
fn is_local_model_true_for_ollama() {
    let config = ContextManagerConfig {
        model: "gemma4:e4b".into(),
        ..test_config()
    };
    assert!(ContextManager::new(config).is_local_model());
}

#[test]
fn is_local_model_false_for_cloud() {
    assert!(!ContextManager::new(test_config()).is_local_model());
}

// -- volatile tokens for local models --

#[test]
fn ollama_job_results_tokens_always_zero_in_snapshot() {
    let config = ContextManagerConfig {
        model: "gemma4:e4b".into(),
        ..test_config()
    };
    let mut cm = ContextManager::new(config);
    cm.set_volatile_tokens(100, 50, 75);
    let snap = cm.get_snapshot();
    // Skill tokens flow through (user can manually activate skills)
    assert_eq!(snap.breakdown.skill_context, 100);
    assert_eq!(snap.breakdown.skill_removal, 50);
    // Job results stripped for local models
    assert_eq!(snap.breakdown.job_results, 0);
}

#[test]
fn cloud_volatile_tokens_all_reflected() {
    let mut cm = ContextManager::new(test_config());
    cm.set_volatile_tokens(100, 50, 75);
    let snap = cm.get_snapshot();
    assert_eq!(snap.breakdown.skill_context, 100);
    assert_eq!(snap.breakdown.skill_removal, 50);
    assert_eq!(snap.breakdown.job_results, 75);
}

// -- message management --

#[test]
fn add_and_get_messages() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("Hello"));
    cm.add_message(Message::assistant("Hi"));
    assert_eq!(cm.message_count(), 2);

    let msgs = cm.get_messages();
    assert_eq!(msgs.len(), 2);
}

#[test]
fn set_messages_replaces() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("old"));
    cm.set_messages(vec![Message::user("new1"), Message::user("new2")]);
    assert_eq!(cm.message_count(), 2);
}

#[test]
fn set_messages_clears_api_tokens() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(50_000);
    assert!(cm.get_api_context_tokens().is_some());
    cm.set_messages(vec![Message::user("new")]);
    assert!(cm.get_api_context_tokens().is_none());
}

#[test]
fn clear_messages() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("msg"));
    cm.clear_messages();
    assert_eq!(cm.message_count(), 0);
}

#[test]
fn clear_messages_clears_api_tokens() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(50_000);
    assert!(cm.get_api_context_tokens().is_some());
    cm.clear_messages();
    assert!(cm.get_api_context_tokens().is_none());
}

// -- dynamic rules integration --

fn make_discovered(
    scope_dir: &str,
    relative_path: &str,
    is_global: bool,
    content: &str,
) -> crate::runtime::context::rules_discovery::DiscoveredRulesFile {
    crate::runtime::context::rules_discovery::DiscoveredRulesFile {
        path: std::path::PathBuf::from(format!("/project/{relative_path}")),
        relative_path: relative_path.to_owned(),
        content: content.to_owned(),
        scope_dir: scope_dir.to_owned(),
        is_global,
        is_standalone: false,
        size_bytes: content.len() as u64,
        modified_at: std::time::SystemTime::UNIX_EPOCH,
    }
}

#[test]
fn touch_file_path_without_index_returns_empty() {
    let mut cm = ContextManager::new(test_config());
    let result = cm.touch_file_path("src/foo.rs");
    assert!(result.is_empty());
}

#[test]
fn touch_file_path_activates_matching_rule() {
    let mut cm = ContextManager::new(test_config());
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Context rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));

    let result = cm.touch_file_path("src/context/loader.rs");
    assert!(!result.is_empty());
    assert_eq!(result[0].scope_dir, "src/context");
}

#[test]
fn touch_file_path_updates_dynamic_rules_content() {
    let mut cm = ContextManager::new(test_config());
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Context rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));

    assert!(cm.get_dynamic_rules_content().is_none());
    let _ = cm.touch_file_path("src/context/loader.rs");
    assert!(cm.get_dynamic_rules_content().is_some());
    assert!(
        cm.get_dynamic_rules_content()
            .unwrap()
            .contains("# Context rules")
    );
}

#[test]
fn touch_file_path_idempotent_for_same_scope() {
    let mut cm = ContextManager::new(test_config());
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));

    let r1 = cm.touch_file_path("src/context/a.rs");
    let r2 = cm.touch_file_path("src/context/b.rs");
    assert!(!r1.is_empty());
    assert!(r2.is_empty()); // Same scope, no new activation
}

#[test]
fn clear_dynamic_rules_resets_content_and_tracker() {
    let mut cm = ContextManager::new(test_config());
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));
    let _ = cm.touch_file_path("src/context/loader.rs");
    assert!(cm.get_dynamic_rules_content().is_some());

    cm.clear_dynamic_rules();
    assert!(cm.get_dynamic_rules_content().is_none());
    assert_eq!(cm.rules_tracker().activated_scoped_rules_count(), 0);
}

#[test]
fn clear_dynamic_rules_allows_reactivation() {
    let mut cm = ContextManager::new(test_config());
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));
    let _ = cm.touch_file_path("src/context/loader.rs");

    cm.clear_dynamic_rules();

    // Should activate again
    let result = cm.touch_file_path("src/context/loader.rs");
    assert!(!result.is_empty());
}

#[test]
fn pre_activate_rule_sets_content() {
    let mut cm = ContextManager::new(test_config());
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Context rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));

    assert!(cm.pre_activate_rule("src/context/.claude/CLAUDE.md"));
    cm.finalize_rule_activations();
    assert!(
        cm.get_dynamic_rules_content()
            .unwrap()
            .contains("# Context rules")
    );
}

#[test]
fn pre_activate_rule_unknown_returns_false() {
    let mut cm = ContextManager::new(test_config());
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));

    assert!(!cm.pre_activate_rule("nonexistent/.claude/CLAUDE.md"));
}

#[test]
fn set_rules_index_enables_activation() {
    let mut cm = ContextManager::new(test_config());
    // No index → no activation
    assert!(cm.touch_file_path("src/context/loader.rs").is_empty());

    // Set index → activation works
    let scoped = make_discovered(
        "src/context",
        "src/context/.claude/CLAUDE.md",
        false,
        "# Rules",
    );
    cm.set_rules_index(RulesIndex::new(vec![scoped]));
    assert!(!cm.touch_file_path("src/context/loader.rs").is_empty());
}

#[test]
fn rules_tracker_accessible_via_getter() {
    let cm = ContextManager::new(test_config());
    assert_eq!(cm.rules_tracker().activated_scoped_rules_count(), 0);
}

// -- rules & memory --

#[test]
fn set_and_get_rules() {
    let mut cm = ContextManager::new(test_config());
    assert!(cm.get_rules_content().is_none());

    cm.set_rules_content(Some("# Rules".into()));
    assert_eq!(cm.get_rules_content(), Some("# Rules"));
}

#[test]
fn dynamic_rules() {
    let mut cm = ContextManager::new(test_config());
    cm.set_dynamic_rules_content(Some("dynamic".into()));
    assert_eq!(cm.get_dynamic_rules_content(), Some("dynamic"));
}

#[test]
fn memory_content_base_only() {
    let mut cm = ContextManager::new(test_config());
    cm.set_memory_content(Some("base memory".into()));
    assert_eq!(cm.get_full_memory_content(), Some("base memory".into()));
}

#[test]
fn memory_content_with_session() {
    let mut cm = ContextManager::new(test_config());
    cm.set_memory_content(Some("base".into()));
    cm.add_session_memory("Topic".into(), "Detail".into());

    let full = cm.get_full_memory_content().unwrap();
    assert!(full.contains("base"));
    assert!(full.contains("## Topic"));
    assert!(full.contains("Detail"));
}

#[test]
fn memory_content_session_only() {
    let mut cm = ContextManager::new(test_config());
    cm.add_session_memory("Title".into(), "Content".into());
    let full = cm.get_full_memory_content().unwrap();
    assert!(full.contains("## Title"));
}

#[test]
fn memory_content_none() {
    let cm = ContextManager::new(test_config());
    assert!(cm.get_full_memory_content().is_none());
}

#[test]
fn session_memory_cleared() {
    let mut cm = ContextManager::new(test_config());
    cm.add_session_memory("t".into(), "c".into());
    assert_eq!(cm.get_session_memories().len(), 1);
    cm.clear_session_memories();
    assert!(cm.get_session_memories().is_empty());
}

// -- token tracking --

#[test]
fn tokens_estimated_by_default() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("Hello world"));
    let tokens = cm.get_current_tokens();
    assert!(tokens > 0);
}

#[test]
fn api_tokens_override_estimate() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("Hello"));
    cm.set_api_context_tokens(42_000);
    assert_eq!(cm.get_current_tokens(), 42_000);
    assert_eq!(cm.get_api_context_tokens(), Some(42_000));
}

// -- snapshot --

#[test]
fn get_snapshot() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("Test"));
    let snap = cm.get_snapshot();
    assert_eq!(snap.context_limit, 100_000);
    assert!(snap.current_tokens > 0);
    assert!(snap.usage_percent >= 0.0);
}

#[test]
fn get_detailed_snapshot() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("Hello"));
    cm.add_message(Message::assistant("Hi"));
    let detailed = cm.get_detailed_snapshot();
    assert_eq!(detailed.messages.len(), 2);
    assert_eq!(detailed.messages[0].role, "user");
}

// -- validation --

#[test]
fn can_accept_turn_normal() {
    let cm = ContextManager::new(test_config());
    let v = cm.can_accept_turn();
    assert!(v.can_proceed);
    assert!(!v.needs_compaction);
}

#[test]
fn can_accept_turn_at_alert() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(70_000); // 70% = threshold
    let v = cm.can_accept_turn();
    assert!(v.can_proceed);
    assert!(v.needs_compaction);
}

#[test]
fn can_accept_turn_at_critical() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(85_000); // 85% = critical
    let v = cm.can_accept_turn();
    assert!(!v.can_proceed);
    assert!(v.needs_compaction);
}

#[test]
fn can_accept_turn_at_exceeded() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(95_000); // 95% = exceeded
    let v = cm.can_accept_turn();
    assert!(!v.can_proceed);
    assert!(v.needs_compaction);
}

#[test]
fn can_accept_turn_zero_limit() {
    let config = ContextManagerConfig {
        compaction: CompactionConfig {
            context_limit: 0,
            ..CompactionConfig::default()
        },
        ..test_config()
    };
    let cm = ContextManager::new(config);
    let v = cm.can_accept_turn();
    assert!(v.can_proceed); // ratio=0.0 < critical
    assert!(!v.needs_compaction); // ratio=0.0 < threshold
}

// -- compaction --

#[test]
fn should_compact_below_threshold() {
    let cm = ContextManager::new(test_config());
    assert!(!cm.should_compact());
}

#[test]
fn should_compact_above_threshold() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(80_000); // 80% >= 70%
    assert!(cm.should_compact());
}

#[test]
fn trigger_compaction_callback() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(80_000);

    let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let called_clone = called.clone();
    cm.on_compaction_needed(move || {
        called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
    });

    cm.trigger_compaction_if_needed();
    assert!(called.load(std::sync::atomic::Ordering::SeqCst));
}

// -- tool result processing --

#[test]
fn process_small_tool_result() {
    let cm = ContextManager::new(test_config());
    let result = cm.process_tool_result("tc-1", "small output");
    assert!(!result.truncated);
    assert_eq!(result.content, "small output");
    assert!(result.original_size.is_none());
}

#[test]
fn process_large_tool_result() {
    let cm = ContextManager::new(test_config());
    let large = "x".repeat(TOOL_RESULT_MAX_CHARS + 1000);
    let result = cm.process_tool_result("tc-1", &large);
    assert!(result.truncated);
    assert!(result.original_size.is_some());
    assert!(result.content.len() < large.len());
}

#[test]
fn tool_result_budget_reserves_for_response() {
    let mut cm = ContextManager::new(test_config());
    // 50k tokens used of 100k limit → 50k remaining
    cm.set_api_context_tokens(50_000);
    let max_size = cm.get_max_tool_result_size();

    // remaining=50k, reserve=8k, margin=5k → available=37k tokens → 148k chars
    // But capped at TOOL_RESULT_MAX_CHARS (100k)
    assert_eq!(max_size, TOOL_RESULT_MAX_CHARS);
}

#[test]
fn tool_result_budget_near_limit() {
    let mut cm = ContextManager::new(test_config());
    // 95k tokens used of 100k limit → 5k remaining
    cm.set_api_context_tokens(95_000);
    let max_size = cm.get_max_tool_result_size();

    // remaining=5k, reserve=8k → saturating_sub yields 0 before margin
    // Falls back to TOOL_RESULT_MIN_TOKENS (2500) * 4 = 10000 chars
    assert_eq!(
        max_size,
        (TOOL_RESULT_MIN_TOKENS as usize) * (CHARS_PER_TOKEN as usize)
    );
}

// -- memory & environment estimation --

#[test]
fn estimate_memory_tokens_empty() {
    let cm = ContextManager::new(test_config());
    assert_eq!(cm.estimate_memory_tokens(), 0);
}

#[test]
fn estimate_memory_tokens_with_content() {
    let mut cm = ContextManager::new(test_config());
    cm.set_memory_content(Some("a".repeat(400)));
    assert!(cm.estimate_memory_tokens() > 0);
}

#[test]
fn estimate_memory_tokens_includes_session() {
    let mut cm = ContextManager::new(test_config());
    cm.add_session_memory("title".into(), "content".into());
    let with_session = cm.estimate_memory_tokens();
    assert!(with_session > 0);
}

#[test]
fn estimate_environment_tokens_with_wd_only() {
    let cm = ContextManager::new(test_config());
    // test_config has working_directory = Some("/tmp")
    let tokens = cm.estimate_environment_tokens();
    assert!(tokens > 0);
}

#[test]
fn estimate_environment_tokens_with_server_origin() {
    let mut cm = ContextManager::new(test_config());
    cm.set_server_origin(Some("localhost:9847".into()));
    let tokens = cm.estimate_environment_tokens();
    assert!(tokens > 0);
}

#[test]
fn volatile_tokens_default_zero() {
    let cm = ContextManager::new(test_config());
    let snap = cm.get_snapshot();
    assert_eq!(snap.breakdown.skill_context, 0);
    assert_eq!(snap.breakdown.skill_removal, 0);
    assert_eq!(snap.breakdown.job_results, 0);
}

#[test]
fn volatile_tokens_set_and_reflected_in_snapshot() {
    let mut cm = ContextManager::new(test_config());
    cm.set_volatile_tokens(100, 50, 75);
    let snap = cm.get_snapshot();
    assert_eq!(snap.breakdown.skill_context, 100);
    assert_eq!(snap.breakdown.skill_removal, 50);
    assert_eq!(snap.breakdown.job_results, 75);
}

#[test]
fn get_current_tokens_includes_memory_and_environment() {
    let mut cm = ContextManager::new(test_config());
    let base = cm.get_current_tokens();
    cm.set_memory_content(Some("a".repeat(400)));
    let with_memory = cm.get_current_tokens();
    assert!(with_memory > base);
}

#[test]
fn get_current_tokens_includes_volatile() {
    let mut cm = ContextManager::new(test_config());
    let base = cm.get_current_tokens();
    cm.set_volatile_tokens(100, 50, 75);
    let with_volatile = cm.get_current_tokens();
    assert_eq!(with_volatile, base + 225);
}

// -- compaction config --

#[test]
fn compaction_config_default_turns() {
    let config = CompactionConfig::default();
    assert_eq!(config.preserve_recent_turns, 5);
}

// -- model switching --

#[test]
fn switch_model_updates_limit() {
    let mut cm = ContextManager::new(test_config());
    cm.switch_model("claude-opus-4-6".into(), 128_000);
    assert_eq!(cm.get_context_limit(), 128_000);
}

#[test]
fn switch_model_clears_api_tokens() {
    let mut cm = ContextManager::new(test_config());
    cm.set_api_context_tokens(50_000);
    cm.switch_model("claude-opus-4-6".into(), 200_000);
    assert_eq!(cm.get_model(), "claude-opus-4-6");
    assert_eq!(cm.get_context_limit(), 200_000);
    assert!(cm.get_api_context_tokens().is_none());
}

#[test]
fn switch_model_triggers_callback() {
    let mut cm = ContextManager::new(test_config());
    // Set tokens at 150k — will be above threshold for 128k model
    cm.set_api_context_tokens(150_000);

    let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let called_clone = called.clone();
    cm.on_compaction_needed(move || {
        called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
    });

    // Switch to 128k limit → 150/128 = 1.17 > 0.70 threshold
    // Note: api_context_tokens is cleared, so estimation is used.
    // Force high token count by setting tokens before switch, then clearing API
    // Actually, switch_model clears api_context_tokens, so we need actual messages.
    // Simpler: just set api_tokens high, switch to small limit — callback fires
    // before api_tokens is cleared? No — switch_model clears first, then calls trigger.
    // So we need enough estimated tokens from messages + system prompt.
    // Let's use a different approach: context_limit=100k, tokens already high from estimation
    drop(cm);

    // Better: use a manager where estimate is high
    let mut cm2 = ContextManager::new(test_config());
    let called2 = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let compaction_triggered = called2.clone();
    cm2.on_compaction_needed(move || {
        compaction_triggered.store(true, std::sync::atomic::Ordering::SeqCst);
    });

    // Add enough messages to get estimated tokens high
    for _ in 0..500 {
        cm2.add_message(Message::user("x".repeat(400)));
        cm2.add_message(Message::assistant("y".repeat(400)));
    }

    // Current estimated tokens should be substantial. Switch to small limit.
    let tokens = cm2.get_current_tokens();
    assert!(tokens > 10_000, "need substantial tokens, got {tokens}");
    cm2.switch_model("small-model".into(), 1_000);
    // tokens/1000 should be >> 0.70
    assert!(called2.load(std::sync::atomic::Ordering::SeqCst));
}

#[test]
fn switch_model_no_callback_under_threshold() {
    let mut cm = ContextManager::new(test_config());
    let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let called_clone = called.clone();
    cm.on_compaction_needed(move || {
        called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
    });

    // Low token usage, switch to larger model — should not fire
    cm.switch_model("claude-opus-4-6".into(), 500_000);
    assert!(!called.load(std::sync::atomic::Ordering::SeqCst));
}

// -- export --

#[test]
fn export_state() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("msg"));
    let exported = cm.export_state();
    assert_eq!(exported.model, "claude-sonnet-4-5-20250929");
    assert_eq!(exported.messages.len(), 1);
    assert_eq!(exported.system_prompt, "You are helpful.");
}

// -- rules token estimation --

#[test]
fn rules_tokens_both_static_and_dynamic() {
    let mut cm = ContextManager::new(test_config());
    cm.set_rules_content(Some("static rules".into()));
    cm.set_dynamic_rules_content(Some("dynamic rules".into()));
    let tokens = cm.estimate_rules_tokens();
    assert!(tokens > 0);
}

// -- parking_lot mutex: poison resistance --

#[test]
fn compaction_deps_no_poison_after_panic() {
    let deps = ManagerCompactionDeps {
        messages: parking_lot::Mutex::new(vec![Message::user("hello")]),
        current_tokens: 100,
        context_limit: 100_000,
        system_prompt_tokens: 10,
        tools_tokens: 5,
    };

    // Panic while holding the lock — parking_lot::Mutex doesn't poison
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _guard = deps.messages.lock();
        panic!("intentional panic while holding lock");
    }));
    assert!(result.is_err(), "panic should have been caught");

    // Main thread can still lock — no poisoning
    let msgs = deps.messages.lock();
    assert_eq!(msgs.len(), 1);
}

// -- messages_slice --

#[test]
fn messages_slice_returns_reference() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("a"));
    cm.add_message(Message::assistant("b"));
    let slice = cm.messages_slice();
    assert_eq!(slice.len(), 2);
}

#[test]
fn messages_slice_empty_on_new() {
    let cm = ContextManager::new(test_config());
    assert!(cm.messages_slice().is_empty());
}

// -- build_base_context --

#[test]
fn build_base_context_has_system_prompt() {
    let cm = ContextManager::new(test_config());
    let ctx = cm.build_base_context();
    assert_eq!(ctx.system_prompt.as_deref(), Some("You are helpful."));
}

#[test]
fn build_base_context_has_working_directory() {
    let cm = ContextManager::new(test_config());
    let ctx = cm.build_base_context();
    assert_eq!(ctx.working_directory.as_deref(), Some("/tmp"));
}

#[test]
fn build_base_context_includes_rules() {
    let mut cm = ContextManager::new(test_config());
    cm.set_rules_content(Some("# My Rules".into()));
    let ctx = cm.build_base_context();
    assert_eq!(ctx.rules_content.as_deref(), Some("# My Rules"));
}

#[test]
fn build_base_context_includes_memory() {
    let mut cm = ContextManager::new(test_config());
    cm.set_memory_content(Some("Remember this.".into()));
    let ctx = cm.build_base_context();
    assert_eq!(ctx.memory_content.as_deref(), Some("Remember this."));
}

#[test]
fn build_base_context_includes_dynamic_rules() {
    let mut cm = ContextManager::new(test_config());
    cm.set_dynamic_rules_content(Some("dynamic rule".into()));
    let ctx = cm.build_base_context();
    assert_eq!(ctx.dynamic_rules_context.as_deref(), Some("dynamic rule"));
}

#[test]
fn build_base_context_none_fields_are_none() {
    let cm = ContextManager::new(test_config());
    let ctx = cm.build_base_context();
    assert!(ctx.skill_context.is_none());
    assert!(ctx.job_results_context.is_none());
    assert!(ctx.server_origin.is_none());
}

#[test]
fn build_base_context_no_rules_no_memory() {
    let cm = ContextManager::new(test_config());
    let ctx = cm.build_base_context();
    assert!(ctx.rules_content.is_none());
    assert!(ctx.memory_content.is_none());
}

#[test]
fn build_base_context_messages_empty() {
    let mut cm = ContextManager::new(test_config());
    cm.add_message(Message::user("hi"));
    let ctx = cm.build_base_context();
    assert!(ctx.messages.is_empty());
}

#[test]
fn build_base_context_tools_none() {
    let cm = ContextManager::new(test_config());
    let ctx = cm.build_base_context();
    assert!(ctx.tools.is_none());
}

// -- touch_file_path returns only new activations --

#[test]
fn touch_file_path_returns_only_new_activations() {
    let mut cm = ContextManager::new(test_config());
    let scope_a = make_discovered("src/a", "src/a/.claude/CLAUDE.md", false, "# Scope A rules");
    let scope_b = make_discovered("src/b", "src/b/.claude/CLAUDE.md", false, "# Scope B rules");
    cm.set_rules_index(RulesIndex::new(vec![scope_a, scope_b]));

    // First touch activates scope A
    let r1 = cm.touch_file_path("src/a/foo.rs");
    assert_eq!(r1.len(), 1);
    assert_eq!(r1[0].scope_dir, "src/a");

    // Second touch activates scope B — must NOT include scope A again
    let r2 = cm.touch_file_path("src/b/bar.rs");
    assert_eq!(
        r2.len(),
        1,
        "should return only newly activated rules, got {r2:?}"
    );
    assert_eq!(r2[0].scope_dir, "src/b");
}

#[test]
fn extracted_data_default_when_no_compaction() {
    let cm = ContextManager::new(test_config());
    let data = cm.get_latest_extracted_data();
    assert!(data.completed_steps.is_empty());
    assert!(data.pending_tasks.is_empty());
}

#[test]
fn extracted_data_persisted_after_set() {
    let mut cm = ContextManager::new(test_config());
    cm.set_extracted_data(ExtractedData {
        current_goal: "build feature X".into(),
        completed_steps: vec!["step 1".into()],
        pending_tasks: vec!["step 2".into()],
        ..Default::default()
    });
    let data = cm.get_latest_extracted_data();
    assert_eq!(data.current_goal, "build feature X");
    assert_eq!(data.completed_steps, vec!["step 1"]);
    assert_eq!(data.pending_tasks, vec!["step 2"]);
}

// ─────────────────────────────────────────────────────────────────────────────
// 65K local-model window (Ollama)
// ─────────────────────────────────────────────────────────────────────────────

fn local_window_config() -> ContextManagerConfig {
    ContextManagerConfig {
        model: "gemma4:e4b".into(),
        system_prompt: Some("You are helpful.".into()),
        working_directory: Some("/tmp".into()),
        tools: Vec::new(),
        rules_content: None,
        compaction: CompactionConfig {
            threshold: 0.70,
            preserve_recent_turns: 2,
            context_limit: 65_536,
        },
    }
}

#[test]
fn local_window_tool_result_sizer_at_50k_used() {
    // context_limit=65_536, api_tokens=50_000 → remaining=15_536
    //   safety = 15_536 / 10 = 1_553
    //   response_reserve = 8_000
    //   available = 15_536 - 8_000 - 1_553 = 5_983 tokens
    //   budget = 5_983 * 4 = 23_932 chars
    let mut cm = ContextManager::new(local_window_config());
    cm.set_api_context_tokens(50_000);
    let budget = cm.get_max_tool_result_size();
    assert!(
        (23_000..=24_000).contains(&budget),
        "expected ~23_932 chars, got {budget}"
    );
}

#[test]
fn local_window_tool_result_sizer_floor_when_tight() {
    // When remaining < response_reserve, sizer falls back to
    // TOOL_RESULT_MIN_TOKENS * CHARS_PER_TOKEN = 2_500 * 4 = 10_000 chars.
    let mut cm = ContextManager::new(local_window_config());
    cm.set_api_context_tokens(64_000);
    let budget = cm.get_max_tool_result_size();
    assert_eq!(budget, 10_000, "expected MIN floor, got {budget}");
}
