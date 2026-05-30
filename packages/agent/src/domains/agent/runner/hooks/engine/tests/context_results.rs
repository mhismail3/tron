use super::*;

#[test]
fn test_merge_json_both_objects() {
    let a = serde_json::json!({"a": 1, "b": 2});
    let b = serde_json::json!({"b": 3, "c": 4});
    let merged = merge_json(Some(&a), &b);
    assert_eq!(merged["a"], 1);
    assert_eq!(merged["b"], 3); // overridden
    assert_eq!(merged["c"], 4);
}

#[test]
fn test_merge_json_none_base() {
    let b = serde_json::json!({"key": "val"});
    let merged = merge_json(None, &b);
    assert_eq!(merged["key"], "val");
}

#[test]
fn test_merge_json_non_object() {
    let a = serde_json::json!("string");
    let b = serde_json::json!(42);
    let merged = merge_json(Some(&a), &b);
    assert_eq!(merged, 42);
}

// ── HookAction::AddContext ──────────────────────────────────────────

fn user_prompt_ctx() -> HookContext {
    HookContext::UserPromptSubmit {
        session_id: "s1".to_string(),
        timestamp: "t".to_string(),
        prompt: "hi".to_string(),
    }
}

#[tokio::test]
async fn test_execute_add_context_single_hook_surfaces_content() {
    let mut registry = HookRegistry::new();
    registry.register(make_simple(
        "ctx-hook",
        HookType::UserPromptSubmit,
        0,
        HookResult::add_context("remember to cite sources"),
    ));

    let engine = HookEngine::new(registry);
    let result = engine.execute(&user_prompt_ctx()).await;

    assert_eq!(result.action, HookAction::AddContext);
    assert_eq!(
        result.added_context.as_deref(),
        Some("remember to cite sources")
    );
}

#[tokio::test]
async fn test_execute_add_context_concatenates_across_hooks() {
    // Two hooks both return AddContext — engine joins their
    // contributions with newlines in registration order.
    let mut registry = HookRegistry::new();
    registry.register(make_simple(
        "first",
        HookType::UserPromptSubmit,
        10,
        HookResult::add_context("fragment one"),
    ));
    registry.register(make_simple(
        "second",
        HookType::UserPromptSubmit,
        5,
        HookResult::add_context("fragment two"),
    ));

    let engine = HookEngine::new(registry);
    let result = engine.execute(&user_prompt_ctx()).await;

    assert_eq!(result.action, HookAction::AddContext);
    assert_eq!(
        result.added_context.as_deref(),
        Some("fragment one\nfragment two")
    );
}

#[tokio::test]
async fn test_execute_add_context_rejected_when_over_budget() {
    let mut registry = HookRegistry::new();
    registry.register(make_simple(
        "bloat",
        HookType::UserPromptSubmit,
        0,
        HookResult::add_context("x".repeat(HOOK_ADDED_CONTEXT_CHAR_BUDGET + 1)),
    ));

    let engine = HookEngine::new(registry);
    let result = engine.execute(&user_prompt_ctx()).await;

    // Dropped, not truncated — action collapses to Continue.
    assert_eq!(result.action, HookAction::Continue);
    assert!(result.added_context.is_none());
}

#[tokio::test]
async fn test_execute_add_context_combined_aggregate_exceeds_budget_rejected() {
    // Each fragment is under-budget, but their sum (including
    // separator newline) exceeds it.
    let mut registry = HookRegistry::new();
    registry.register(make_simple(
        "a",
        HookType::UserPromptSubmit,
        10,
        HookResult::add_context("x".repeat(HOOK_ADDED_CONTEXT_CHAR_BUDGET / 2)),
    ));
    registry.register(make_simple(
        "b",
        HookType::UserPromptSubmit,
        5,
        HookResult::add_context("y".repeat(HOOK_ADDED_CONTEXT_CHAR_BUDGET / 2 + 1)),
    ));

    let engine = HookEngine::new(registry);
    let result = engine.execute(&user_prompt_ctx()).await;

    assert_eq!(result.action, HookAction::Continue);
    assert!(result.added_context.is_none());
}

#[tokio::test]
async fn test_execute_add_context_yields_to_block() {
    // If one hook adds context and a later hook blocks, the block
    // wins (existing chain-stopping semantic for Block) and the
    // added context is discarded — never mix a permissive hook's
    // contribution with a guard hook's veto.
    let mut registry = HookRegistry::new();
    registry.register(make_simple(
        "add-ctx",
        HookType::UserPromptSubmit,
        100, // runs first
        HookResult::add_context("should be discarded"),
    ));
    registry.register(make_simple(
        "blocker",
        HookType::UserPromptSubmit,
        50,
        HookResult::block("policy violation"),
    ));

    let engine = HookEngine::new(registry);
    let result = engine.execute(&user_prompt_ctx()).await;

    assert!(result.is_blocked());
    assert_eq!(result.reason.as_deref(), Some("policy violation"));
    assert!(
        result.added_context.is_none(),
        "block must discard any in-progress added_context"
    );
}

#[tokio::test]
async fn test_execute_add_context_empty_string_is_ignored() {
    // Hooks that return AddContext with empty content don't
    // contribute — the aggregated result collapses to Continue.
    let mut registry = HookRegistry::new();
    registry.register(make_simple(
        "ctx",
        HookType::UserPromptSubmit,
        0,
        HookResult::add_context(""),
    ));

    let engine = HookEngine::new(registry);
    let result = engine.execute(&user_prompt_ctx()).await;

    assert_eq!(result.action, HookAction::Continue);
    assert!(result.added_context.is_none());
}
