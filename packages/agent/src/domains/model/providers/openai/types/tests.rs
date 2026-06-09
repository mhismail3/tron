use super::*;
use crate::domains::auth::credentials::OpenAIAuthPath;
use serde_json::json;

fn assert_float_eq(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() < f64::EPSILON,
        "expected {expected}, got {actual}"
    );
}

// ── Model registry ─────────────────────────────────────────────────

#[test]
fn default_model_exists() {
    assert!(get_openai_model(DEFAULT_MODEL).is_some());
}

#[test]
fn gpt_55_has_distinct_platform_and_codex_profiles() {
    let platform = get_openai_model_profile("gpt-5.5", OpenAIAuthPath::PlatformApiKey)
        .unwrap()
        .1;
    let codex = get_openai_model_profile("gpt-5.5", OpenAIAuthPath::ChatGptCodex)
        .unwrap()
        .1;
    assert_eq!(platform.context_window, 1_050_000);
    assert_eq!(codex.context_window, 272_000);
    assert_eq!(platform.max_output, 128_000);
    assert_eq!(codex.max_output, 128_000);
    assert_eq!(
        platform.reasoning_levels,
        &["none", "low", "medium", "high", "xhigh"]
    );
    assert_eq!(codex.reasoning_levels, &["low", "medium", "high", "xhigh"]);
    assert_eq!(platform.default_reasoning_level, "medium");
    assert_eq!(codex.default_reasoning_level, "medium");
    assert_eq!(platform.api_endpoint, ApiEndpoint::Platform);
    assert_eq!(codex.api_endpoint, ApiEndpoint::Codex);
    assert_float_eq(platform.input_cost_per_million, 5.0);
    assert_float_eq(platform.output_cost_per_million, 30.0);
    assert_eq!(platform.cache_read_cost_per_million, Some(0.50));
}

#[test]
fn gpt_55_snapshot_alias_resolves_to_canonical() {
    let m = get_openai_model("openai/gpt-5.5-2026-04-23").unwrap();
    assert_eq!(m.id, "gpt-5.5");
    assert_eq!(
        canonical_openai_model_id("gpt-5.5-2026-04-23"),
        Some("gpt-5.5")
    );
    assert_eq!(
        openai_request_model_id("gpt-5.5-2026-04-23"),
        "gpt-5.5-2026-04-23"
    );
}

#[test]
fn gpt_54_codex_default_differs_from_platform() {
    let platform = get_openai_model_profile("gpt-5.4", OpenAIAuthPath::PlatformApiKey)
        .unwrap()
        .1;
    let codex = get_openai_model_profile("gpt-5.4", OpenAIAuthPath::ChatGptCodex)
        .unwrap()
        .1;
    assert_eq!(platform.context_window, 1_050_000);
    assert_eq!(codex.context_window, 272_000);
    assert_eq!(codex.max_context_window, Some(1_000_000));
    assert_eq!(platform.default_reasoning_level, "none");
    assert_eq!(codex.default_reasoning_level, "xhigh");
    assert!(platform.reasoning_levels.contains(&"none"));
    assert!(!codex.reasoning_levels.contains(&"none"));
}

#[test]
fn gpt_53_codex_has_distinct_platform_and_codex_profiles() {
    let platform = get_openai_model_profile("gpt-5.3-codex", OpenAIAuthPath::PlatformApiKey)
        .unwrap()
        .1;
    let codex = get_openai_model_profile("gpt-5.3-codex", OpenAIAuthPath::ChatGptCodex)
        .unwrap()
        .1;
    assert_eq!(platform.context_window, 400_000);
    assert_eq!(codex.context_window, 272_000);
    assert_eq!(platform.max_output, 128_000);
    assert_eq!(codex.max_output, 128_000);
    assert_eq!(platform.api_endpoint, ApiEndpoint::Platform);
    assert_eq!(codex.api_endpoint, ApiEndpoint::Codex);
}

#[test]
fn platform_only_models_are_unavailable_on_codex_path() {
    assert!(get_openai_model("gpt-5.4-nano").is_some());
    assert!(openai_model_available_for_auth_path(
        "gpt-5.4-nano",
        OpenAIAuthPath::PlatformApiKey
    ));
    assert!(!openai_model_available_for_auth_path(
        "gpt-5.4-nano",
        OpenAIAuthPath::ChatGptCodex
    ));
    assert!(openai_model_available_for_auth_path(
        "gpt-5.4-pro",
        OpenAIAuthPath::PlatformApiKey
    ));
    assert!(!openai_model_available_for_auth_path(
        "gpt-5.4-pro",
        OpenAIAuthPath::ChatGptCodex
    ));
}

#[test]
fn codex_catalog_models_use_272k_context() {
    for id in [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.2",
    ] {
        let profile = get_openai_model_profile(id, OpenAIAuthPath::ChatGptCodex)
            .unwrap_or_else(|| panic!("{id} should have a Codex profile"))
            .1;
        assert_eq!(profile.context_window, 272_000, "{id}");
        assert_eq!(profile.max_output, 128_000, "{id}");
        assert_eq!(
            profile.reasoning_levels,
            &["low", "medium", "high", "xhigh"],
            "{id}"
        );
    }
}

#[test]
fn gpt_54_mini_profiles_match_official_contexts() {
    let platform = get_openai_model_profile("gpt-5.4-mini", OpenAIAuthPath::PlatformApiKey)
        .unwrap()
        .1;
    let codex = get_openai_model_profile("gpt-5.4-mini", OpenAIAuthPath::ChatGptCodex)
        .unwrap()
        .1;
    assert_eq!(platform.context_window, 400_000);
    assert_eq!(codex.context_window, 272_000);
    assert_eq!(platform.default_reasoning_level, "medium");
    assert_eq!(codex.default_reasoning_level, "medium");
    assert_float_eq(platform.input_cost_per_million, 0.75);
    assert_float_eq(platform.output_cost_per_million, 4.5);
    assert_eq!(platform.cache_read_cost_per_million, Some(0.075));
}

#[test]
fn model_gpt_51_codex_mini_platform_profile() {
    let m = get_openai_model("gpt-5.1-codex-mini").unwrap();
    let profile = m.default_profile();
    assert_eq!(m.tier, "standard");
    assert_eq!(profile.context_window, 400_000);
    assert_eq!(profile.max_output, 128_000);
    assert_eq!(profile.reasoning_levels, &["low", "medium", "high"]);
    assert_eq!(profile.default_reasoning_level, "low");
    assert_float_eq(profile.input_cost_per_million, 0.25);
    assert_float_eq(profile.output_cost_per_million, 2.0);
    assert_eq!(profile.cache_read_cost_per_million, Some(0.025));
}

#[test]
fn model_gpt_53_codex_spark() {
    let m = get_openai_model("gpt-5.3-codex-spark").unwrap();
    let profile = m.default_profile();
    assert_eq!(profile.context_window, 272_000);
    assert_eq!(profile.max_output, 32_000);
    assert_eq!(m.tier, "standard");
    assert!(!m.is_hidden);
    assert!(m.is_preview);
    assert!(profile.visible);
    assert_eq!(profile.reasoning_levels, &["low", "medium", "high"]);
    assert_eq!(profile.default_reasoning_level, "low");
}

#[test]
fn model_gpt_52_pricing_and_retired_alias_mapping() {
    let m = get_openai_model("gpt-5.2").unwrap();
    let profile = m.default_profile();
    assert_float_eq(profile.input_cost_per_million, 1.75);
    assert_float_eq(profile.output_cost_per_million, 14.0);
    assert_eq!(profile.cache_read_cost_per_million, Some(0.175));

    let alias = get_openai_model("gpt-5.2-codex").unwrap();
    assert!(alias.is_retired);
    assert!(!alias.is_hidden);
    assert_eq!(alias.replacement_model, Some("gpt-5.2"));
    assert_eq!(
        canonical_openai_model_id("gpt-5.2-codex"),
        Some("gpt-5.2-codex")
    );
    assert_eq!(openai_request_model_id("gpt-5.2-codex"), "gpt-5.2-codex");
}

#[test]
fn model_gpt_51_codex_max_pricing() {
    let m = get_openai_model("gpt-5.1-codex-max").unwrap();
    let profile = m.default_profile();
    assert_float_eq(profile.input_cost_per_million, 1.25);
    assert_float_eq(profile.output_cost_per_million, 10.0);
    assert_eq!(profile.cache_read_cost_per_million, Some(0.125));
}

// ── to_api_json ───────────────────────────────────────────────────

#[test]
fn to_api_json_has_required_fields() {
    let m = get_openai_model("gpt-5.4").unwrap();
    let j = m.to_api_json(
        m.profile_for_auth_path(OpenAIAuthPath::ChatGptCodex)
            .unwrap(),
    );
    assert_eq!(j["id"], "gpt-5.4");
    assert_eq!(j["canonicalModelId"], "gpt-5.4");
    assert_eq!(j["name"], "GPT-5.4");
    assert_eq!(j["provider"], "openai-codex");
    assert_eq!(j["contextWindow"], 272_000);
    assert_eq!(j["maxOutput"], 128_000);
    assert_eq!(j["supportsThinking"], false);
    assert_eq!(j["supportsImages"], true);
    assert!(j["inputCostPerMillion"].is_number());
    assert!(j["outputCostPerMillion"].is_number());
    assert!(j["cacheReadCostPerMillion"].is_number());
    assert_eq!(j["tier"], "flagship");
    assert_eq!(j["family"], "GPT-5.4");
    assert!(j["description"].is_string());
    assert_eq!(j["supportsReasoning"], true);
    assert!(j["reasoningLevels"].is_array());
    assert!(j["defaultReasoningLevel"].is_string());
    assert_eq!(j["recommended"], false);
    assert_eq!(j["isLegacy"], false);
    assert!(j["sortOrder"].is_number());
    assert_eq!(j["apiEndpoint"], "codex");
    assert_eq!(j["authPaths"], json!(["chatgpt-codex"]));
    assert_eq!(j["supportsVerbosity"], true);
    assert_eq!(j["defaultVerbosity"], "low");
    assert_eq!(j["maxContextWindow"], 1_000_000);
}

#[test]
fn to_api_json_knowledge_cutoff_present() {
    let m = get_openai_model("gpt-5.3-codex").unwrap();
    let j = m.to_api_json(m.default_profile());
    assert_eq!(j["knowledgeCutoff"], "2025-08-31");
}

#[test]
fn to_api_json_knowledge_cutoff_absent() {
    let m = get_openai_model("gpt-5.3-codex-spark").unwrap();
    let j = m.to_api_json(m.default_profile());
    assert!(j.get("knowledgeCutoff").is_none());
}

#[test]
fn to_api_json_not_retired_no_field() {
    // Non-retired models must omit isDeprecated/deprecationDate so
    // the iOS client's default behavior (isDeprecatedModel == false)
    // remains a no-op.
    let m = get_openai_model("gpt-5.4").unwrap();
    let j = m.to_api_json(m.default_profile());
    assert!(j.get("isDeprecated").is_none());
    assert!(j.get("deprecationDate").is_none());
}

#[test]
fn gpt_52_codex_retired_2026_04_14() {
    let m = get_openai_model("gpt-5.2-codex").unwrap();
    assert!(m.is_retired);
    assert_eq!(m.deprecation_date, Some("2026-04-14"));
    let j = m.to_api_json(m.default_profile());
    assert_eq!(j["isDeprecated"], true);
    assert_eq!(j["deprecationDate"], "2026-04-14");
    assert_eq!(j["replacementModel"], "gpt-5.2");
}

#[test]
fn gpt_51_codex_max_retired_2026_04_14() {
    let m = get_openai_model("gpt-5.1-codex-max").unwrap();
    assert!(m.is_retired);
    assert_eq!(m.deprecation_date, Some("2026-04-14"));
}

#[test]
fn gpt_51_codex_mini_retired_2026_04_14() {
    let m = get_openai_model("gpt-5.1-codex-mini").unwrap();
    assert!(m.is_retired);
    assert_eq!(m.deprecation_date, Some("2026-04-14"));
}

#[test]
fn gpt_53_codex_not_retired() {
    // Regression guard: supported models must not be flipped accidentally.
    let m = get_openai_model("gpt-5.3-codex").unwrap();
    assert!(!m.is_retired);
    assert_eq!(m.deprecation_date, None);
}

#[test]
fn all_openai_models_api_json_sorted() {
    let models = all_openai_models_api_json();
    assert_eq!(models.len(), 6);
    // First model in each family should have lowest sort_order
    assert_eq!(models[0]["id"], "gpt-5.5");
    assert_eq!(models[0]["sortOrder"], 0);
    assert!(models.iter().all(|m| m["apiEndpoint"] == "codex"));
    assert!(!models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
    assert!(!models.iter().any(|m| m["id"] == "gpt-5.4-nano"));
    assert!(models.iter().any(|m| m["id"] == "gpt-5.3-codex-spark"));
    assert!(!models.iter().any(|m| m["id"] == "gpt-5.2-codex"));
    assert!(!models.iter().any(|m| m["id"] == "gpt-5.1-codex-max"));
    assert!(!models.iter().any(|m| m["id"] == "gpt-5.1-codex-mini"));
}

#[test]
fn platform_model_list_uses_platform_profile() {
    let models = all_openai_models_api_json_for_auth_path(OpenAIAuthPath::PlatformApiKey);
    assert_eq!(models.len(), 40);
    let gpt55 = models.iter().find(|m| m["id"] == "gpt-5.5").unwrap();
    assert_eq!(gpt55["contextWindow"], 1_050_000);
    assert_eq!(gpt55["apiEndpoint"], "platform");
    assert_eq!(gpt55["authPaths"], json!(["platform-api-key"]));
    assert!(models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
    assert!(models.iter().any(|m| m["id"] == "gpt-5.4-nano"));
    assert!(
        models
            .iter()
            .any(|m| m["id"] == "gpt-5.2-codex" && m["isDeprecated"] == true)
    );
    assert!(models.iter().any(|m| m["id"] == "gpt-4.1"));
    assert!(models.iter().any(|m| m["id"] == "o3"));
    assert!(!models.iter().any(|m| m["id"] == "gpt-5.5-pro"));
    assert!(!models.iter().any(|m| m["id"] == "o3-pro"));
    assert!(!models.iter().any(|m| m["id"] == "gpt-3.5-turbo"));
    let gpt53 = models.iter().find(|m| m["id"] == "gpt-5.3-codex").unwrap();
    assert_eq!(gpt53["contextWindow"], 400_000);
    assert_eq!(gpt53["apiEndpoint"], "platform");
}

#[test]
fn to_api_json_retired_generation_model() {
    let m = get_openai_model("gpt-5.3-codex").unwrap();
    let j = m.to_api_json(m.default_profile());
    assert_eq!(j["isLegacy"], true);
}

#[test]
fn model_unknown_returns_none() {
    assert!(get_openai_model("gpt-99").is_none());
}

#[test]
fn all_model_ids_contains_expected() {
    let ids = all_openai_model_ids();
    assert!(ids.contains(&"gpt-5.5"));
    assert!(ids.contains(&"gpt-5.5-2026-04-23"));
    assert!(ids.contains(&"gpt-5.4-nano"));
    assert!(ids.contains(&"gpt-5.2"));
    assert!(ids.contains(&"gpt-5.3-codex"));
    assert!(ids.contains(&"gpt-5.2-codex"));
    assert!(ids.contains(&"gpt-5.1-codex-max"));
    assert!(ids.contains(&"gpt-5.1-codex-mini"));
}

// ── Reasoning effort ───────────────────────────────────────────────

#[test]
fn reasoning_effort_serde_roundtrip() {
    let effort = ReasoningEffort::High;
    let json = serde_json::to_string(&effort).unwrap();
    assert_eq!(json, r#""high""#);
    let back: ReasoningEffort = serde_json::from_str(&json).unwrap();
    assert_eq!(back, ReasoningEffort::High);
}

#[test]
fn reasoning_effort_all_variants() {
    for (variant, expected) in [
        (ReasoningEffort::None, "none"),
        (ReasoningEffort::Minimal, "minimal"),
        (ReasoningEffort::Low, "low"),
        (ReasoningEffort::Medium, "medium"),
        (ReasoningEffort::High, "high"),
        (ReasoningEffort::Xhigh, "xhigh"),
        (ReasoningEffort::Max, "max"),
    ] {
        assert_eq!(variant.as_str(), expected);
        assert_eq!(variant.to_string(), expected);
    }
}

// ── ApiEndpoint ────────────────────────────────────────────────────

#[test]
fn api_endpoint_serde_roundtrip() {
    let codex = ApiEndpoint::Codex;
    let json = serde_json::to_string(&codex).unwrap();
    assert_eq!(json, r#""codex""#);
    let back: ApiEndpoint = serde_json::from_str(&json).unwrap();
    assert_eq!(back, ApiEndpoint::Codex);

    let platform = ApiEndpoint::Platform;
    let json = serde_json::to_string(&platform).unwrap();
    assert_eq!(json, r#""platform""#);
    let back: ApiEndpoint = serde_json::from_str(&json).unwrap();
    assert_eq!(back, ApiEndpoint::Platform);
}

#[test]
fn api_endpoint_default_is_codex() {
    assert_eq!(ApiEndpoint::default(), ApiEndpoint::Codex);
}

#[test]
fn api_endpoint_path() {
    assert_eq!(ApiEndpoint::Codex.path(), "/codex/responses");
    assert_eq!(ApiEndpoint::Platform.path(), "/v1/responses");
}

#[test]
fn api_endpoint_default_base_url() {
    assert_eq!(ApiEndpoint::Codex.default_base_url(), DEFAULT_BASE_URL);
    assert_eq!(
        ApiEndpoint::Platform.default_base_url(),
        DEFAULT_PLATFORM_BASE_URL
    );
}

#[test]
fn gpt_54_uses_platform_endpoint() {
    let (_, profile) = get_openai_model_profile("gpt-5.4", OpenAIAuthPath::PlatformApiKey).unwrap();
    assert_eq!(profile.api_endpoint, ApiEndpoint::Platform);
}

#[test]
fn gpt_54_pro_uses_platform_endpoint() {
    let (_, profile) =
        get_openai_model_profile("gpt-5.4-pro", OpenAIAuthPath::PlatformApiKey).unwrap();
    assert_eq!(profile.api_endpoint, ApiEndpoint::Platform);
}

#[test]
fn codex_models_use_codex_endpoint() {
    for id in [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2",
    ] {
        let (_, profile) = get_openai_model_profile(id, OpenAIAuthPath::ChatGptCodex)
            .unwrap_or_else(|| panic!("expected Codex for {id}"));
        assert_eq!(
            profile.api_endpoint,
            ApiEndpoint::Codex,
            "expected Codex for {id}"
        );
    }
}

// ── Auth ───────────────────────────────────────────────────────────

#[test]
fn auth_oauth_serde() {
    let auth = OpenAIAuth::OAuth {
        tokens: crate::domains::auth::credentials::OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: 99999,
        },
    };
    let json = serde_json::to_value(&auth).unwrap();
    assert_eq!(json["type"], "oauth");
    assert_eq!(json["tokens"]["accessToken"], "at");
}

#[test]
fn auth_api_key_serde() {
    let auth = OpenAIAuth::ApiKey {
        api_key: "sk-test-123".into(),
    };
    let json = serde_json::to_value(&auth).unwrap();
    assert_eq!(json["type"], "api_key");
    assert_eq!(json["api_key"], "sk-test-123");

    let back: OpenAIAuth = serde_json::from_value(json).unwrap();
    assert!(matches!(back, OpenAIAuth::ApiKey { api_key } if api_key == "sk-test-123"));
}

// ── Config ─────────────────────────────────────────────────────────

#[test]
fn config_serde() {
    let config = OpenAIConfig {
        model: "gpt-5.3-codex".into(),
        auth: OpenAIAuth::OAuth {
            tokens: crate::domains::auth::credentials::OAuthTokens {
                access_token: "at".into(),
                refresh_token: "rt".into(),
                expires_at: 99999,
            },
        },
        max_tokens: Some(4096),
        temperature: None,
        base_url: None,
        reasoning_effort: Some("high".into()),
        provider_settings: OpenAIApiSettings::default(),
    };
    let json = serde_json::to_value(&config).unwrap();
    assert_eq!(json["model"], "gpt-5.3-codex");
    assert_eq!(json["maxTokens"], 4096);
    assert_eq!(json["reasoningEffort"], "high");
}

// ── Responses API types ────────────────────────────────────────────

#[test]
fn responses_input_text_serde() {
    let item = ResponsesInputItem::InputText {
        text: "hello".into(),
    };
    let json = serde_json::to_value(&item).unwrap();
    assert_eq!(json["type"], "input_text");
    assert_eq!(json["text"], "hello");
}

#[test]
fn responses_input_message_serde() {
    let item = ResponsesInputItem::Message {
        role: "user".into(),
        content: vec![MessageContent::InputText {
            text: "hello".into(),
        }],
        id: None,
    };
    let json = serde_json::to_value(&item).unwrap();
    assert_eq!(json["type"], "message");
    assert_eq!(json["role"], "user");
    assert_eq!(json["content"][0]["type"], "input_text");
}

#[test]
fn responses_function_call_serde() {
    let item = ResponsesInputItem::FunctionCall {
        id: None,
        call_id: "call_abc".into(),
        name: "execute".into(),
        arguments: r#"{"cmd":"ls"}"#.into(),
    };
    let json = serde_json::to_value(&item).unwrap();
    assert_eq!(json["type"], "function_call");
    assert_eq!(json["call_id"], "call_abc");
    assert_eq!(json["name"], "execute");
}

#[test]
fn responses_function_call_output_serde() {
    let item = ResponsesInputItem::FunctionCallOutput {
        call_id: "call_abc".into(),
        output: "file.txt".into(),
    };
    let json = serde_json::to_value(&item).unwrap();
    assert_eq!(json["type"], "function_call_output");
    assert_eq!(json["call_id"], "call_abc");
    assert_eq!(json["output"], "file.txt");
}

// ── ResponsesToolEntry ───────────────────────────────────────────

#[test]
fn tool_entry_function_serde() {
    let entry = ResponsesToolEntry::Function {
        name: "execute".into(),
        description: "Run commands".into(),
        parameters: json!({"type": "object"}),
    };
    let json = serde_json::to_value(&entry).unwrap();
    assert_eq!(json["type"], "function");
    assert_eq!(json["name"], "execute");

    let back: ResponsesToolEntry = serde_json::from_value(json).unwrap();
    assert!(matches!(back, ResponsesToolEntry::Function { .. }));
}

#[test]
fn tool_entry_serde_roundtrip_all_variants() {
    let entries = vec![ResponsesToolEntry::Function {
        name: "execute".into(),
        description: "Run".into(),
        parameters: json!({}),
    }];
    let json = serde_json::to_string(&entries).unwrap();
    let back: Vec<ResponsesToolEntry> = serde_json::from_str(&json).unwrap();
    assert_eq!(back.len(), 1);
    assert!(matches!(&back[0], ResponsesToolEntry::Function { .. }));
}

#[test]
fn responses_request_serde() {
    let req = ResponsesRequest {
        model: "gpt-5.3-codex".into(),
        input: vec![ResponsesInputItem::InputText {
            text: "hello".into(),
        }],
        instructions: Some("Be helpful".into()),
        stream: true,
        store: false,
        temperature: None,
        capabilities: None,
        max_output_tokens: Some(16384),
        reasoning: Some(ReasoningConfig {
            effort: "medium".into(),
            summary: "detailed".into(),
        }),
        text: Some(ResponseTextConfig {
            verbosity: "low".into(),
        }),
        prompt_cache_key: Some("tron-session-s1".into()),
    };
    let json = serde_json::to_value(&req).unwrap();
    assert_eq!(json["model"], "gpt-5.3-codex");
    assert!(json["stream"].as_bool().unwrap());
    assert!(!json["store"].as_bool().unwrap());
    assert_eq!(json["reasoning"]["effort"], "medium");
    assert_eq!(json["reasoning"]["summary"], "detailed");
    assert_eq!(json["text"]["verbosity"], "low");
    assert_eq!(json["prompt_cache_key"], "tron-session-s1");
}

// ── SSE event types ────────────────────────────────────────────────

#[test]
fn sse_text_delta() {
    let json = json!({
        "type": "response.output_text.delta",
        "delta": "Hello ",
        "content_index": 0,
    });
    let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
    assert_eq!(event.event_type, SseEventType::OutputTextDelta);
    assert_eq!(event.delta.as_deref(), Some("Hello "));
    assert_eq!(event.content_index, Some(0));
}

#[test]
fn sse_output_item_added_function_call() {
    let json = json!({
        "type": "response.output_item.added",
        "item": {
            "type": "function_call",
            "call_id": "call_abc",
            "name": "execute",
        },
    });
    let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
    assert_eq!(event.event_type, SseEventType::OutputItemAdded);
    let item = event.item.unwrap();
    assert_eq!(item.item_type, OutputItemType::FunctionCall);
    assert_eq!(item.call_id.as_deref(), Some("call_abc"));
    assert_eq!(item.name.as_deref(), Some("execute"));
}

#[test]
fn sse_output_item_added_reasoning() {
    let json = json!({
        "type": "response.output_item.added",
        "item": { "type": "reasoning" },
    });
    let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
    let item = event.item.unwrap();
    assert_eq!(item.item_type, OutputItemType::Reasoning);
}

#[test]
fn sse_reasoning_summary_delta() {
    let json = json!({
        "type": "response.reasoning_summary_text.delta",
        "delta": "Thinking about...",
        "summary_index": 0,
    });
    let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
    assert_eq!(event.event_type, SseEventType::ReasoningSummaryTextDelta);
    assert_eq!(event.delta.as_deref(), Some("Thinking about..."));
}

#[test]
fn sse_function_call_args_delta() {
    let json = json!({
        "type": "response.function_call_arguments.delta",
        "call_id": "call_abc",
        "delta": r#"{"cmd":"#,
    });
    let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
    assert_eq!(event.event_type, SseEventType::FunctionCallArgsDelta);
    assert_eq!(event.call_id.as_deref(), Some("call_abc"));
}

#[test]
fn sse_completed() {
    let json = json!({
        "type": "response.completed",
        "response": {
            "id": "resp_123",
            "output": [],
            "usage": { "input_tokens": 100, "output_tokens": 50 },
        },
    });
    let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
    assert_eq!(event.event_type, SseEventType::Completed);
    let resp = event.response.unwrap();
    assert_eq!(resp.id.as_deref(), Some("resp_123"));
    let usage = resp.usage.unwrap();
    assert_eq!(usage.input_tokens, 100);
    assert_eq!(usage.output_tokens, 50);
}

#[test]
fn sse_unknown_event_type_deserializes() {
    let json = json!({
        "type": "response.new_feature.delta",
    });
    let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
    assert_eq!(event.event_type, SseEventType::Unknown);
}

#[test]
fn output_item_type_unknown_deserializes() {
    let json = json!({
        "type": "new_item_type",
    });
    let item: ResponsesOutputItem = serde_json::from_value(json).unwrap();
    assert_eq!(item.item_type, OutputItemType::Unknown);
}

#[test]
fn message_content_input_text() {
    let mc = MessageContent::InputText {
        text: "hello".into(),
    };
    let json = serde_json::to_value(&mc).unwrap();
    assert_eq!(json["type"], "input_text");
}

#[test]
fn message_content_input_image() {
    let mc = MessageContent::InputImage {
        image_url: "data:image/png;base64,abc".into(),
        detail: Some("auto".into()),
    };
    let json = serde_json::to_value(&mc).unwrap();
    assert_eq!(json["type"], "input_image");
    assert_eq!(json["detail"], "auto");
}

#[test]
fn output_item_function_call() {
    let item = ResponsesOutputItem {
        item_type: OutputItemType::FunctionCall,
        call_id: Some("call_abc".into()),
        name: Some("execute".into()),
        arguments: Some(r#"{"cmd":"ls"}"#.into()),
        ..Default::default()
    };
    let json = serde_json::to_value(&item).unwrap();
    assert_eq!(json["type"], "function_call");
    assert_eq!(json["call_id"], "call_abc");
}

#[test]
fn reasoning_config_serde() {
    let rc = ReasoningConfig {
        effort: "high".into(),
        summary: "detailed".into(),
    };
    let json = serde_json::to_value(&rc).unwrap();
    assert_eq!(json["effort"], "high");
    assert_eq!(json["summary"], "detailed");
    let back: ReasoningConfig = serde_json::from_value(json).unwrap();
    assert_eq!(back.effort, "high");
}
