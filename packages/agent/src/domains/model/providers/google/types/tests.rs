use super::*;

// ── Thinking level ───────────────────────────────────────────────

#[test]
fn thinking_level_serde_roundtrip() {
    for (level, expected) in [
        (GeminiThinkingLevel::Minimal, "\"minimal\""),
        (GeminiThinkingLevel::Low, "\"low\""),
        (GeminiThinkingLevel::Medium, "\"medium\""),
        (GeminiThinkingLevel::High, "\"high\""),
    ] {
        let json = serde_json::to_string(&level).unwrap();
        assert_eq!(json, expected);
        let back: GeminiThinkingLevel = serde_json::from_str(&json).unwrap();
        assert_eq!(back, level);
    }
}

#[test]
fn thinking_level_to_api_string() {
    assert_eq!(GeminiThinkingLevel::Minimal.to_api_string(), "MINIMAL");
    assert_eq!(GeminiThinkingLevel::Low.to_api_string(), "LOW");
    assert_eq!(GeminiThinkingLevel::Medium.to_api_string(), "MEDIUM");
    assert_eq!(GeminiThinkingLevel::High.to_api_string(), "HIGH");
}

// ── Safety types ─────────────────────────────────────────────────

#[test]
fn harm_category_serde() {
    let cat = HarmCategory::Harassment;
    let json = serde_json::to_string(&cat).unwrap();
    assert_eq!(json, "\"HARM_CATEGORY_HARASSMENT\"");
    let back: HarmCategory = serde_json::from_str(&json).unwrap();
    assert_eq!(back, cat);
}

#[test]
fn safety_setting_serde() {
    let setting = SafetySetting {
        category: HarmCategory::HateSpeech,
        threshold: HarmBlockThreshold::Off,
    };
    let json = serde_json::to_value(&setting).unwrap();
    assert_eq!(json["category"], "HARM_CATEGORY_HATE_SPEECH");
    assert_eq!(json["threshold"], "OFF");
}

#[test]
fn default_safety_settings_has_all_categories() {
    let settings = default_safety_settings();
    assert_eq!(settings.len(), 5);
    assert!(
        settings
            .iter()
            .all(|s| s.threshold == HarmBlockThreshold::Off)
    );
}

// ── Auth types ───────────────────────────────────────────────────

#[test]
fn auth_oauth_serde() {
    let auth = GoogleAuth::Oauth {
        tokens: crate::domains::auth::provider_credentials::OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: 99999,
        },
        project_id: Some("proj-123".into()),
    };
    let json = serde_json::to_value(&auth).unwrap();
    assert_eq!(json["type"], "oauth");
    assert_eq!(json["accessToken"], "at");
    assert_eq!(json["project_id"], "proj-123");
}

#[test]
fn auth_api_key_serde() {
    let auth = GoogleAuth::ApiKey {
        api_key: "key-123".into(),
    };
    let json = serde_json::to_value(&auth).unwrap();
    assert_eq!(json["type"], "api_key");
    assert_eq!(json["api_key"], "key-123");
}

#[test]
fn auth_oauth_has_no_endpoint_field() {
    let auth = GoogleAuth::Oauth {
        tokens: crate::domains::auth::provider_credentials::OAuthTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            expires_at: 99999,
        },
        project_id: None,
    };
    let json = serde_json::to_value(&auth).unwrap();
    assert!(json.get("endpoint").is_none());
}

// ── Config ───────────────────────────────────────────────────────

#[test]
fn config_serde() {
    let config = GoogleConfig {
        model: "gemini-3-pro-preview".into(),
        auth: GoogleAuth::Oauth {
            tokens: crate::domains::auth::provider_credentials::OAuthTokens {
                access_token: "at".into(),
                refresh_token: "rt".into(),
                expires_at: 99999,
            },
            project_id: None,
        },
        max_tokens: Some(4096),
        temperature: None,
        base_url: None,
        thinking_level: Some(GeminiThinkingLevel::High),
        thinking_budget: None,
        safety_settings: None,
        provider_settings: GoogleApiSettings::default(),
    };
    let json = serde_json::to_value(&config).unwrap();
    assert_eq!(json["model"], "gemini-3-pro-preview");
    assert_eq!(json["maxTokens"], 4096);
    assert_eq!(json["thinkingLevel"], "high");
}

// ── Gemini API types ─────────────────────────────────────────────

#[test]
fn gemini_part_text_serde() {
    let part = GeminiPart::Text {
        text: "hello".into(),
        thought: None,
        thought_signature: None,
    };
    let json = serde_json::to_value(&part).unwrap();
    assert_eq!(json["text"], "hello");
    assert!(json.get("thought").is_none());
}

#[test]
fn gemini_part_text_with_thinking() {
    let part = GeminiPart::Text {
        text: "thinking...".into(),
        thought: Some(true),
        thought_signature: Some("sig-abc".into()),
    };
    let json = serde_json::to_value(&part).unwrap();
    assert_eq!(json["thought"], true);
    assert_eq!(json["thoughtSignature"], "sig-abc");
}

#[test]
fn gemini_part_function_call_serde() {
    let part = GeminiPart::FunctionCall {
        function_call: FunctionCallData {
            name: "execute".into(),
            args: serde_json::json!({"command": "ls"}),
        },
        thought_signature: Some("sig-123".into()),
    };
    let json = serde_json::to_value(&part).unwrap();
    assert_eq!(json["functionCall"]["name"], "execute");
    assert_eq!(json["thoughtSignature"], "sig-123");
}

#[test]
fn gemini_part_function_response_serde() {
    let part = GeminiPart::FunctionResponse {
        function_response: FunctionResponseData {
            name: "capability_result".into(),
            response: serde_json::json!({"result": "ok"}),
        },
    };
    let json = serde_json::to_value(&part).unwrap();
    assert_eq!(json["functionResponse"]["name"], "capability_result");
}

#[test]
fn gemini_part_inline_data_serde() {
    let part = GeminiPart::InlineData {
        inline_data: InlineDataContent {
            mime_type: "image/png".into(),
            data: "base64data".into(),
        },
    };
    let json = serde_json::to_value(&part).unwrap();
    assert_eq!(json["inlineData"]["mimeType"], "image/png");
}

#[test]
fn gemini_tool_serde() {
    let tool = GeminiTool {
        function_declarations: vec![FunctionDeclaration {
            name: "execute".into(),
            description: "Run a command".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {"command": {"type": "string"}}
            }),
        }],
    };
    let json = serde_json::to_value(&tool).unwrap();
    assert_eq!(json["functionDeclarations"][0]["name"], "execute");
}

#[test]
fn thinking_config_serde() {
    let config = ThinkingConfig {
        thinking_level: Some("HIGH".into()),
        thinking_budget: None,
        include_thoughts: Some(true),
    };
    let json = serde_json::to_value(&config).unwrap();
    assert_eq!(json["thinkingLevel"], "HIGH");
    assert_eq!(json["includeThoughts"], true);
    assert!(json.get("thinkingBudget").is_none());
}

#[test]
fn stream_chunk_serde() {
    let chunk_json = serde_json::json!({
        "candidates": [{
            "content": {
                "parts": [{"text": "hello"}],
                "role": "model"
            },
            "finishReason": "STOP"
        }],
        "usageMetadata": {
            "promptTokenCount": 10,
            "candidatesTokenCount": 5,
            "totalTokenCount": 15
        }
    });
    let chunk: GeminiStreamChunk = serde_json::from_value(chunk_json).unwrap();
    let candidates = chunk.candidates.unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].finish_reason.as_deref(), Some("STOP"));
    let usage = chunk.usage_metadata.unwrap();
    assert_eq!(usage.prompt_token_count, 10);
    assert_eq!(usage.candidates_token_count, 5);
}

#[test]
fn stream_chunk_with_error() {
    let chunk_json = serde_json::json!({
        "error": {
            "code": 429,
            "message": "Rate limit exceeded"
        }
    });
    let chunk: GeminiStreamChunk = serde_json::from_value(chunk_json).unwrap();
    let error = chunk.error.unwrap();
    assert_eq!(error.code, 429);
    assert_eq!(error.message, "Rate limit exceeded");
}

// ── Model registry ───────────────────────────────────────────────

#[test]
fn model_gemini_3_1_pro() {
    let model = get_gemini_model("gemini-3.1-pro-preview").unwrap();
    assert_eq!(model.short_name, "Gemini 3.1 Pro");
    assert_eq!(model.context_window, 1_048_576);
    assert_eq!(model.max_output, 65_536);
    assert!(model.supports_thinking);
    assert_eq!(model.tier, "pro");
    assert!(model.preview);
    assert_eq!(
        model.default_thinking_level,
        Some(GeminiThinkingLevel::High)
    );
}

#[test]
fn model_gemini_3_pro() {
    let model = get_gemini_model("gemini-3-pro-preview").unwrap();
    assert_eq!(model.short_name, "Gemini 3 Pro");
    assert_eq!(model.context_window, 1_048_576);
    assert_eq!(model.max_output, 65_536);
    assert!(model.supports_thinking);
    assert_eq!(model.tier, "pro");
    assert!(model.preview);
    assert_eq!(
        model.default_thinking_level,
        Some(GeminiThinkingLevel::High)
    );
}

#[test]
fn model_gemini_25_flash_lite() {
    let model = get_gemini_model("gemini-2.5-flash-lite").unwrap();
    assert!(!model.supports_thinking);
    assert_eq!(model.tier, "flash-lite");
    assert!(model.default_thinking_level.is_none());
}

#[test]
fn model_gemini_3_1_flash_lite() {
    let model = get_gemini_model("gemini-3.1-flash-lite-preview").unwrap();
    assert_eq!(model.short_name, "Gemini 3.1 Flash Lite");
    assert_eq!(model.context_window, 1_048_576);
    assert_eq!(model.max_output, 65_536);
    assert!(!model.supports_thinking);
    assert_eq!(model.tier, "flash-lite");
    assert!(model.preview);
    assert!(model.default_thinking_level.is_none());
    assert!((model.input_cost_per_million - 0.25).abs() < f64::EPSILON);
    assert!((model.output_cost_per_million - 1.50).abs() < f64::EPSILON);
}

#[test]
fn model_unknown_returns_none() {
    assert!(get_gemini_model("gpt-4").is_none());
}

#[test]
fn all_model_ids_has_expected() {
    let ids = all_gemini_model_ids();
    assert!(ids.contains(&"gemini-3.1-pro-preview"));
    assert!(ids.contains(&"gemini-3-pro-preview"));
    assert!(ids.contains(&"gemini-2.5-pro"));
    assert!(ids.contains(&"gemini-2.5-flash-lite"));
    assert!(ids.contains(&"gemini-3.1-flash-lite-preview"));
    assert_eq!(ids.len(), 7);
}

#[test]
fn is_gemini_3_model_check() {
    assert!(is_gemini_3_model("gemini-3.1-pro-preview"));
    assert!(is_gemini_3_model("gemini-3-pro-preview"));
    assert!(is_gemini_3_model("gemini-3-flash-preview"));
    assert!(!is_gemini_3_model("gemini-2.5-pro"));
    assert!(!is_gemini_3_model("gemini-2.5-flash"));
}

// ── Generation config ────────────────────────────────────────────

// ── GoogleApiSettings ───────────────────────────────────────────

#[test]
fn api_settings_default() {
    let settings = GoogleApiSettings::default();
    assert!(settings.token_url.is_none());
    assert!(settings.client_id.is_none());
    assert!(settings.client_secret.is_none());
}

#[test]
fn api_settings_serde() {
    let settings = GoogleApiSettings {
        token_url: Some("https://custom.url/token".into()),
        client_id: Some("cid".into()),
        client_secret: Some("csec".into()),
    };
    let json = serde_json::to_value(&settings).unwrap();
    assert_eq!(json["tokenUrl"], "https://custom.url/token");
    assert_eq!(json["clientId"], "cid");
}

// ── Generation config ────────────────────────────────────────────

// ── to_api_json ───────────────────────────────────────────────────

#[test]
fn to_api_json_gemini_31_pro() {
    let m = get_gemini_model("gemini-3.1-pro-preview").unwrap();
    let j = m.to_api_json("gemini-3.1-pro-preview");
    assert_eq!(j["id"], "gemini-3.1-pro-preview");
    assert_eq!(j["name"], "Gemini 3.1 Pro");
    assert_eq!(j["provider"], "google");
    assert_eq!(j["contextWindow"], 1_048_576);
    assert_eq!(j["tier"], "pro");
    assert_eq!(j["family"], "Gemini 3");
    assert_eq!(j["supportsThinking"], true);
    assert_eq!(j["isPreview"], true);
    assert_eq!(j["thinkingLevel"], "high");
    assert!(j["supportedThinkingLevels"].is_array());
    assert_eq!(j["recommended"], true);
    assert_eq!(j["isLegacy"], false);
    assert!(j.get("isDeprecated").is_none());
}

#[test]
fn to_api_json_gemini_retired() {
    let m = get_gemini_model("gemini-3-pro-preview").unwrap();
    let j = m.to_api_json("gemini-3-pro-preview");
    assert_eq!(j["isDeprecated"], true);
    assert_eq!(j["deprecationDate"], "2026-03-09");
}

#[test]
fn to_api_json_no_thinking() {
    let m = get_gemini_model("gemini-2.5-flash-lite").unwrap();
    let j = m.to_api_json("gemini-2.5-flash-lite");
    assert_eq!(j["supportsThinking"], false);
    assert!(j.get("thinkingLevel").is_none());
    assert!(j.get("supportedThinkingLevels").is_none());
    assert!(j.get("isPreview").is_none());
}

#[test]
fn all_gemini_models_api_json_sorted() {
    let models = all_gemini_models_api_json();
    assert_eq!(models.len(), 7);
    assert_eq!(models[0]["id"], "gemini-3.1-pro-preview");
    assert_eq!(models[0]["sortOrder"], 0);
}

#[test]
fn generation_config_serde_skips_none() {
    let config = GenerationConfig {
        max_output_tokens: Some(4096),
        temperature: None,
        top_p: None,
        top_k: None,
        stop_sequences: None,
        thinking_config: None,
    };
    let json = serde_json::to_value(&config).unwrap();
    assert_eq!(json["maxOutputTokens"], 4096);
    assert!(json.get("temperature").is_none());
    assert!(json.get("topP").is_none());
    assert!(json.get("thinkingConfig").is_none());
}

#[test]
fn generation_config_with_thinking_nested() {
    let config = GenerationConfig {
        max_output_tokens: Some(65536),
        temperature: Some(1.0),
        top_p: None,
        top_k: None,
        stop_sequences: None,
        thinking_config: Some(ThinkingConfig {
            thinking_level: Some("HIGH".into()),
            thinking_budget: None,
            include_thoughts: Some(true),
        }),
    };
    let json = serde_json::to_value(&config).unwrap();
    assert_eq!(json["thinkingConfig"]["thinkingLevel"], "HIGH");
    assert_eq!(json["thinkingConfig"]["includeThoughts"], true);
    assert!(json["thinkingConfig"].get("thinkingBudget").is_none());
}

#[test]
fn generation_config_with_budget_nested() {
    let config = GenerationConfig {
        max_output_tokens: Some(8192),
        temperature: Some(0.7),
        top_p: None,
        top_k: None,
        stop_sequences: None,
        thinking_config: Some(ThinkingConfig {
            thinking_level: None,
            thinking_budget: Some(10_000),
            include_thoughts: Some(true),
        }),
    };
    let json = serde_json::to_value(&config).unwrap();
    assert_eq!(json["thinkingConfig"]["thinkingBudget"], 10_000);
    assert_eq!(json["thinkingConfig"]["includeThoughts"], true);
    assert!(json["thinkingConfig"].get("thinkingLevel").is_none());
}

#[test]
fn generation_config_no_thinking_omits_field() {
    let config = GenerationConfig {
        max_output_tokens: Some(4096),
        temperature: None,
        top_p: None,
        top_k: None,
        stop_sequences: None,
        thinking_config: None,
    };
    let json = serde_json::to_value(&config).unwrap();
    assert!(json.get("thinkingConfig").is_none());
}
