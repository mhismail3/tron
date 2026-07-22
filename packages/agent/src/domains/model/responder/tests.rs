use super::*;
use crate::shared::protocol::messages::{Message, UserMessageContent};
use crate::shared::protocol::model_audit::ProviderAuditPayloadKind;
use futures::{StreamExt, stream};

struct AuditProvider;

#[async_trait]
impl Provider for AuditProvider {
    fn provider_type(&self) -> crate::shared::protocol::messages::Provider {
        crate::shared::protocol::messages::Provider::OpenAi
    }

    fn model(&self) -> &str {
        "gpt-5.5-codex"
    }

    fn audit_payload(
        &self,
        _context: &Context,
        options: &ProviderStreamOptions,
    ) -> crate::domains::model::providers::shared::provider::ProviderResult<ProviderAuditPayload>
    {
        Ok(ProviderAuditPayload::exact_provider_envelope(
            serde_json::json!({
                "model": self.model(),
                "reasoningEffort": options.reasoning_effort.as_ref().map(ToString::to_string),
                "authorization": "Bearer abcdefghijklmnopqrstuvwxyz0123456789",
            }),
        ))
    }

    async fn stream(
        &self,
        _context: &Context,
        _options: &ProviderStreamOptions,
    ) -> crate::domains::model::providers::shared::provider::ProviderResult<StreamEventStream> {
        Ok(Box::pin(stream::empty()))
    }
}

#[test]
fn reasoning_level_serializes_as_snake_case() {
    assert_eq!(
        serde_json::to_string(&ModelReasoningLevel::None).unwrap(),
        "\"none\""
    );
    assert_eq!(
        serde_json::to_string(&ModelReasoningLevel::Low).unwrap(),
        "\"low\""
    );
    assert_eq!(
        serde_json::to_string(&ModelReasoningLevel::Medium).unwrap(),
        "\"medium\""
    );
    assert_eq!(
        serde_json::to_string(&ModelReasoningLevel::High).unwrap(),
        "\"high\""
    );
    assert_eq!(
        serde_json::to_string(&ModelReasoningLevel::XHigh).unwrap(),
        "\"x_high\""
    );
    assert_eq!(
        serde_json::to_string(&ModelReasoningLevel::Max).unwrap(),
        "\"max\""
    );
}

#[test]
fn reasoning_level_accepts_only_canonical_request_spelling() {
    let level: ModelReasoningLevel = serde_json::from_str("\"x_high\"").unwrap();
    assert_eq!(level, ModelReasoningLevel::XHigh);
    assert_eq!(
        ModelReasoningLevel::from_str_canonical("x_high"),
        Some(ModelReasoningLevel::XHigh)
    );
    assert_eq!(ModelReasoningLevel::from_str_canonical("xhigh"), None);
    assert_eq!(ModelReasoningLevel::from_str_canonical("x-high"), None);
    assert_eq!(ModelReasoningLevel::from_str_canonical("HIGH"), None);
}

#[test]
fn reasoning_level_maps_to_provider_options_inside_model_boundary() {
    assert_eq!(
        ModelReasoningLevel::None.as_gemini_thinking_level(),
        "THINKING_DISABLED"
    );
    assert_eq!(
        ModelReasoningLevel::Low.as_gemini_thinking_level(),
        "THINKING_LOW"
    );
    assert_eq!(
        ModelReasoningLevel::Medium.as_gemini_thinking_level(),
        "THINKING_MEDIUM"
    );
    assert_eq!(
        ModelReasoningLevel::High.as_gemini_thinking_level(),
        "THINKING_HIGH"
    );
    assert_eq!(
        ModelReasoningLevel::XHigh.as_gemini_thinking_level(),
        "THINKING_HIGH"
    );
    assert_eq!(
        ModelReasoningLevel::Max.as_gemini_thinking_level(),
        "THINKING_HIGH"
    );

    assert_eq!(ModelReasoningLevel::None.as_anthropic_effort(), None);
    assert_eq!(
        ModelReasoningLevel::Low.as_anthropic_effort(),
        Some(AnthropicEffortLevel::Low)
    );
    assert_eq!(
        ModelReasoningLevel::Medium.as_anthropic_effort(),
        Some(AnthropicEffortLevel::Medium)
    );
    assert_eq!(
        ModelReasoningLevel::High.as_anthropic_effort(),
        Some(AnthropicEffortLevel::High)
    );
    assert_eq!(
        ModelReasoningLevel::XHigh.as_anthropic_effort(),
        Some(AnthropicEffortLevel::Xhigh)
    );
    assert_eq!(
        ModelReasoningLevel::Max.as_anthropic_effort(),
        Some(AnthropicEffortLevel::Max)
    );

    assert_eq!(
        ModelReasoningLevel::None.as_openai_reasoning(),
        ReasoningEffort::None
    );
    assert_eq!(
        ModelReasoningLevel::Low.as_openai_reasoning(),
        ReasoningEffort::Low
    );
    assert_eq!(
        ModelReasoningLevel::Medium.as_openai_reasoning(),
        ReasoningEffort::Medium
    );
    assert_eq!(
        ModelReasoningLevel::High.as_openai_reasoning(),
        ReasoningEffort::High
    );
    assert_eq!(
        ModelReasoningLevel::XHigh.as_openai_reasoning(),
        ReasoningEffort::Xhigh
    );
    assert_eq!(
        ModelReasoningLevel::Max.as_openai_reasoning(),
        ReasoningEffort::Max
    );
}

#[test]
fn model_response_error_preserves_provider_failure_envelope() {
    let info = ModelResponderInfo {
        provider_type: crate::shared::protocol::messages::Provider::OpenAi,
        provider_name: "openai",
        model: "gpt-5.5".to_owned(),
        context_window: 128_000,
    };
    let error = ModelResponseError::from_provider_error(
        ProviderError::Api {
            status: 429,
            message: "rate limit".to_owned(),
            code: Some("rate_limit_exceeded".to_owned()),
            retryable: true,
        },
        &info,
    );

    let failure = error.failure();

    assert_eq!(
        failure.code,
        crate::shared::server::failure::PROVIDER_API_ERROR
    );
    assert_eq!(failure.category, FailureCategory::Api);
    assert_eq!(failure.provider.as_deref(), Some("openai"));
    assert_eq!(failure.model.as_deref(), Some("gpt-5.5"));
    assert_eq!(failure.status_code, Some(429));
    assert_eq!(failure.error_type.as_deref(), Some("rate_limit_exceeded"));
    assert!(failure.retryable);
    assert!(failure.recoverable);
    assert_eq!(error.category(), "api");
    assert!(error.is_retryable());
}

#[test]
fn model_response_error_auth_has_recoverable_canonical_failure() {
    let error = ModelResponseError::auth("sign in again");

    let failure = error.failure();

    assert_eq!(
        failure.code,
        crate::shared::server::failure::MODEL_AUTH_ERROR
    );
    assert_eq!(failure.category, FailureCategory::Auth);
    assert!(!failure.retryable);
    assert!(failure.recoverable);
}

#[tokio::test]
async fn provider_stream_error_event_becomes_canonical_model_response_error() {
    let stream: StreamEventStream = Box::pin(stream::iter([Ok(StreamEvent::Error {
        error: "malformed provider stream JSON Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789".into(),
    })]));
    let health = Arc::new(ModelResponderHealth::new());
    let mut wrapped = wrap_provider_stream(
        stream,
        "openai",
        "gpt-5.5".to_owned(),
        health,
        Instant::now(),
    );

    let item = wrapped.next().await.expect("stream item");
    let error = item.expect_err("stream error should become model response error");
    let failure = error.failure();

    assert_eq!(
        failure.code,
        crate::shared::server::failure::PROVIDER_SSE_PARSE_ERROR
    );
    assert_eq!(failure.category, FailureCategory::Parse);
    assert_eq!(failure.origin, FailureOrigin::ModelProvider);
    assert_eq!(failure.provider.as_deref(), Some("openai"));
    assert_eq!(failure.model.as_deref(), Some("gpt-5.5"));
    assert_eq!(failure.error_type.as_deref(), Some("stream_event_error"));
    assert_eq!(
        failure.details.as_ref().unwrap()["kind"],
        "stream_event_error"
    );
    assert!(!failure.message.contains("abcdefghijklmnopqrstuvwxyz"));
    assert!(failure.message.contains("Bearer ****"));
}

#[tokio::test]
async fn provider_eof_without_done_becomes_recoverable_parse_error() {
    let stream: StreamEventStream = Box::pin(stream::iter([Ok(StreamEvent::Start)]));
    let health = Arc::new(ModelResponderHealth::new());
    let mut wrapped = wrap_provider_stream(
        stream,
        "openai",
        "gpt-5.5".to_owned(),
        health,
        Instant::now(),
    );

    assert!(matches!(wrapped.next().await, Some(Ok(StreamEvent::Start))));
    let error = wrapped
        .next()
        .await
        .expect("EOF should produce a terminal model error")
        .expect_err("EOF without Done must fail");
    let failure = error.failure();

    assert_eq!(
        failure.code,
        crate::shared::server::failure::PROVIDER_SSE_PARSE_ERROR
    );
    assert_eq!(failure.category, FailureCategory::Parse);
    assert!(!failure.retryable);
    assert!(failure.recoverable);
    assert_eq!(failure.provider.as_deref(), Some("openai"));
    assert_eq!(failure.model.as_deref(), Some("gpt-5.5"));
    assert!(wrapped.next().await.is_none());
}

#[tokio::test]
async fn long_lived_factory_projects_api_settings_per_create_call() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let first_server = MockServer::start().await;
    let second_server = MockServer::start().await;
    for server in [&first_server, &second_server] {
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_raw("", "application/x-ndjson"))
            .expect(1)
            .mount(server)
            .await;
    }

    let factory = DefaultModelResponderFactory::new();
    for (index, server) in [&first_server, &second_server].into_iter().enumerate() {
        let mut api_settings = crate::domains::settings::ApiSettings::default();
        api_settings.ollama = crate::domains::settings::OllamaApiSettings {
            base_url: server.uri(),
        };
        let responder = factory
            .create_for_model("gemma4:e4b", &api_settings)
            .await
            .unwrap();
        let response = responder
            .respond(ModelResponseRequest {
                context: Context::default(),
                session_id: format!("settings-snapshot-{index}"),
                reasoning_level: None,
                cancel: CancellationToken::new(),
                retry_config: None,
            })
            .await
            .unwrap();
        drop(response);
    }

    first_server.verify().await;
    second_server.verify().await;
}

#[test]
fn provider_backed_request_audit_uses_stream_options_and_exact_payload() {
    let responder = ProviderBackedModelResponder {
        provider: Arc::new(AuditProvider),
        health: Arc::new(ModelResponderHealth::new()),
    };
    let request = ModelResponseRequest {
        context: Context {
            messages: vec![Message::User {
                content: UserMessageContent::Text("hello".to_owned()),
                timestamp: None,
            }]
            .into(),
            ..Context::default()
        },
        session_id: "sess-1".to_owned(),
        reasoning_level: Some(ModelReasoningLevel::XHigh),
        cancel: CancellationToken::new(),
        retry_config: None,
    };

    let audit = responder.request_audit(&request).unwrap();

    assert_eq!(audit.format, "tron.model_provider_request.v2");
    assert_eq!(
        audit.provider_type,
        crate::shared::protocol::messages::Provider::OpenAi
    );
    assert_eq!(audit.provider_name, "openai");
    assert_eq!(audit.model, "gpt-5.5-codex");
    assert_eq!(audit.session_id, "sess-1");
    assert_eq!(audit.reasoning_level.as_deref(), Some("x_high"));
    assert_eq!(audit.message_count, 1);
    assert_eq!(audit.tool_count, 0);
    assert!(audit.stream_options.get("promptCacheKey").is_none());
    assert_eq!(
        audit.stream_options["reasoningEffort"],
        serde_json::json!("xhigh")
    );
    assert_eq!(
        audit.provider_request.kind,
        ProviderAuditPayloadKind::ExactProviderEnvelope
    );
    assert!(audit.provider_request.body.get("promptCacheKey").is_none());
    assert!(
        !serde_json::to_string(&audit.provider_request.body)
            .expect("serialize provider request body")
            .contains("sess-1"),
        "server-owned session ids must not enter provider request envelopes"
    );
    assert_eq!(
        audit.provider_request.body["authorization"],
        serde_json::json!("Bearer ****")
    );
}

#[test]
fn provider_request_audit_projects_bulk_media_without_blocking_model_request() {
    let responder = ProviderBackedModelResponder {
        provider: Arc::new(AuditProvider),
        health: Arc::new(ModelResponderHealth::new()),
    };
    let request = ModelResponseRequest {
        context: Context::default(),
        session_id: "sess-media".to_owned(),
        reasoning_level: None,
        cancel: CancellationToken::new(),
        retry_config: None,
    };
    let info = responder.info();
    let provider_request = ProviderAuditPayload::exact_provider_envelope(serde_json::json!({
        "model": "gpt-5.5-codex",
        "input": [{
            "role": "user",
            "content": [{
                "type": "input_image",
                "image_url": format!(
                    "data:image/jpeg;base64,{}",
                    "a".repeat(
                        crate::shared::protocol::model_audit::MAX_PROVIDER_AUDIT_PAYLOAD_BYTES
                    )
                )
            }]
        }]
    }));

    let audit = build_request_audit(
        info,
        &request,
        ProviderStreamOptions::default(),
        provider_request,
    )
    .expect("bulk media must become bounded audit evidence");

    assert_eq!(
        audit.provider_request.kind,
        ProviderAuditPayloadKind::ProviderEnvelopeProjection
    );
    assert_eq!(
        audit.provider_request.body["input"][0]["content"][0]["image_url"]["$tronAuditProjection"],
        "bulk_string.v1"
    );
    assert!(
        serde_json::to_vec(&audit.provider_request).unwrap().len()
            < crate::shared::protocol::model_audit::MAX_PROVIDER_AUDIT_PAYLOAD_BYTES
    );
}
