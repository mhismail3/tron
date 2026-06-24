use super::*;

fn text_chunk(content: &str) -> OllamaChatChunk {
    OllamaChatChunk {
        message: OllamaMessage {
            content: content.into(),
            thinking: None,
            tool_calls: None,
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    }
}

fn thinking_chunk(thinking: &str) -> OllamaChatChunk {
    OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: Some(thinking.into()),
            tool_calls: None,
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    }
}

fn done_chunk(reason: &str, prompt: u64, completion: u64) -> OllamaChatChunk {
    OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: None,
            tool_calls: None,
        },
        done: true,
        done_reason: Some(reason.into()),
        prompt_eval_count: Some(prompt),
        eval_count: Some(completion),
    }
}

fn done_chunk_no_usage() -> OllamaChatChunk {
    OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: None,
            tool_calls: None,
        },
        done: true,
        done_reason: Some("stop".into()),
        prompt_eval_count: None,
        eval_count: None,
    }
}

#[test]
fn text_only_stream() {
    let mut state = OllamaStreamState::new();
    let events1 = process_chunk(&text_chunk("Hello"), &mut state);
    assert!(matches!(events1[0], StreamEvent::TextStart));
    assert!(matches!(events1[1], StreamEvent::TextDelta { .. }));

    let events2 = process_chunk(&text_chunk(" world"), &mut state);
    assert_eq!(events2.len(), 1);
    assert!(matches!(events2[0], StreamEvent::TextDelta { .. }));
}

#[test]
fn thinking_triggers_thinking_events() {
    let mut state = OllamaStreamState::new();
    let events = process_chunk(&thinking_chunk("Let me think"), &mut state);
    assert!(matches!(events[0], StreamEvent::ThinkingStart));
    assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
}

#[test]
fn thinking_to_text_transition() {
    let mut state = OllamaStreamState::new();
    let _ = process_chunk(&thinking_chunk("thinking..."), &mut state);
    let events = process_chunk(&text_chunk("answer"), &mut state);
    assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
    assert!(matches!(events[1], StreamEvent::TextStart));
    assert!(matches!(events[2], StreamEvent::TextDelta { .. }));
}

#[test]
fn capability_invocation_complete_in_one_chunk() {
    let mut state = OllamaStreamState::new();
    let chunk = OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: None,
            tool_calls: Some(vec![OllamaCapabilityInvocationDraft {
                id: Some("call_abc123".into()),
                function: OllamaCapabilityInvocationDraftFunction {
                    name: "execute".into(),
                    arguments: {
                        let mut m = Map::new();
                        m.insert("command".into(), Value::String("ls".into()));
                        m
                    },
                },
            }]),
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    };
    let events = process_chunk(&chunk, &mut state);
    assert!(matches!(
        events[0],
        StreamEvent::CapabilityInvocationDraftStart { .. }
    ));
    assert!(matches!(
        events[1],
        StreamEvent::CapabilityInvocationDraftDelta { .. }
    ));
    assert!(matches!(
        events[2],
        StreamEvent::CapabilityInvocationDraftEnd { .. }
    ));
    if let StreamEvent::CapabilityInvocationDraftEnd {
        capability_invocation,
    } = &events[2]
    {
        assert_eq!(capability_invocation.name, "execute");
        assert_eq!(capability_invocation.arguments["command"], "ls");
    }
}

#[test]
fn native_tool_calls_field_deserializes_to_capability_invocation() {
    let chunk: OllamaChatChunk = serde_json::from_value(serde_json::json!({
        "message": {
            "tool_calls": [
                {
                    "id": "call_abc123",
                    "function": {
                        "index": 0,
                        "name": "execute",
                        "arguments": {
                            "intent": "Read README.md"
                        }
                    }
                }
            ]
        },
        "done": false
    }))
    .expect("native ollama tool call chunk");

    let calls = chunk
        .message
        .tool_calls
        .expect("tool calls should map to internal tool calls");
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].id.as_deref(), Some("call_abc123"));
    assert_eq!(calls[0].function.name, "execute");
    assert_eq!(calls[0].function.arguments["intent"], "Read README.md");
}

#[test]
fn multiple_tool_calls_in_one_chunk() {
    let mut state = OllamaStreamState::new();
    let chunk = OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: None,
            tool_calls: Some(vec![
                OllamaCapabilityInvocationDraft {
                    id: Some("call_1".into()),
                    function: OllamaCapabilityInvocationDraftFunction {
                        name: "execute".into(),
                        arguments: Map::new(),
                    },
                },
                OllamaCapabilityInvocationDraft {
                    id: Some("call_2".into()),
                    function: OllamaCapabilityInvocationDraftFunction {
                        name: "inspect".into(),
                        arguments: Map::new(),
                    },
                },
            ]),
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    };
    let events = process_chunk(&chunk, &mut state);
    let starts: Vec<_> = events
        .iter()
        .filter(|e| matches!(e, StreamEvent::CapabilityInvocationDraftStart { .. }))
        .collect();
    assert_eq!(starts.len(), 2);
}

#[test]
fn done_with_stop_reason() {
    let mut state = OllamaStreamState::new();
    let _ = process_chunk(&text_chunk("hello"), &mut state);
    let events = process_chunk(&done_chunk("stop", 100, 50), &mut state);
    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    assert!(done.is_some());
    if let StreamEvent::Done {
        stop_reason,
        message,
    } = done.unwrap()
    {
        assert_eq!(stop_reason, "end_turn");
        let usage = message.token_usage.as_ref().unwrap();
        assert_eq!(usage.input_tokens, 100);
        assert_eq!(usage.output_tokens, 50);
    }
}

#[test]
fn done_without_usage() {
    let mut state = OllamaStreamState::new();
    let _ = process_chunk(&text_chunk("hi"), &mut state);
    let events = process_chunk(&done_chunk_no_usage(), &mut state);
    if let Some(StreamEvent::Done { message, .. }) = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }))
    {
        assert!(message.token_usage.is_none());
    } else {
        panic!("expected Done event");
    }
}

#[test]
fn done_with_tool_calls_overrides_stop_reason() {
    let mut state = OllamaStreamState::new();
    // Emit tool calls first
    let tc_chunk = OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: None,
            tool_calls: Some(vec![OllamaCapabilityInvocationDraft {
                id: Some("call_1".into()),
                function: OllamaCapabilityInvocationDraftFunction {
                    name: "execute".into(),
                    arguments: Map::new(),
                },
            }]),
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    };
    let _ = process_chunk(&tc_chunk, &mut state);
    // Ollama sends done_reason: "stop" even for tool calls
    let events = process_chunk(&done_chunk("stop", 100, 50), &mut state);
    if let Some(StreamEvent::Done { stop_reason, .. }) = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }))
    {
        assert_eq!(stop_reason, "capability_invocation");
    } else {
        panic!("expected Done event");
    }
}

#[test]
fn thinking_plus_tool_calls() {
    let mut state = OllamaStreamState::new();
    let _ = process_chunk(&thinking_chunk("planning..."), &mut state);
    let chunk = OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: None,
            tool_calls: Some(vec![OllamaCapabilityInvocationDraft {
                id: Some("call_1".into()),
                function: OllamaCapabilityInvocationDraftFunction {
                    name: "execute".into(),
                    arguments: Map::new(),
                },
            }]),
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    };
    let events = process_chunk(&chunk, &mut state);
    assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
    assert!(matches!(
        events[1],
        StreamEvent::CapabilityInvocationDraftStart { .. }
    ));
}

#[test]
fn empty_content_no_events() {
    let mut state = OllamaStreamState::new();
    let chunk = OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: None,
            tool_calls: None,
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    };
    let events = process_chunk(&chunk, &mut state);
    assert!(events.is_empty());
}

#[test]
fn empty_thinking_no_events() {
    let mut state = OllamaStreamState::new();
    let chunk = OllamaChatChunk {
        message: OllamaMessage {
            content: String::new(),
            thinking: Some(String::new()),
            tool_calls: None,
        },
        done: false,
        done_reason: None,
        prompt_eval_count: None,
        eval_count: None,
    };
    let events = process_chunk(&chunk, &mut state);
    assert!(events.is_empty());
}

#[test]
fn map_done_reasons() {
    assert_eq!(map_done_reason(Some("stop")), "end_turn");
    assert_eq!(map_done_reason(Some("length")), "max_tokens");
    assert_eq!(map_done_reason(Some("load")), "end_turn");
    assert_eq!(map_done_reason(None), "end_turn");
    assert_eq!(map_done_reason(Some("unknown")), "unknown");
}

#[test]
fn done_finalizes_open_thinking() {
    let mut state = OllamaStreamState::new();
    let _ = process_chunk(&thinking_chunk("deep thoughts"), &mut state);
    let events = process_chunk(&done_chunk("stop", 10, 5), &mut state);
    // Should have ThinkingEnd before Done
    assert!(
        events
            .iter()
            .any(|e| matches!(e, StreamEvent::ThinkingEnd { .. }))
    );
    assert!(events.iter().any(|e| matches!(e, StreamEvent::Done { .. })));
}

#[test]
fn done_finalizes_open_text() {
    let mut state = OllamaStreamState::new();
    let _ = process_chunk(&text_chunk("hello"), &mut state);
    let events = process_chunk(&done_chunk("stop", 10, 5), &mut state);
    assert!(
        events
            .iter()
            .any(|e| matches!(e, StreamEvent::TextEnd { .. }))
    );
    assert!(events.iter().any(|e| matches!(e, StreamEvent::Done { .. })));
}

#[test]
fn done_content_includes_thinking_and_text() {
    let mut state = OllamaStreamState::new();
    let _ = process_chunk(&thinking_chunk("hmm"), &mut state);
    let _ = process_chunk(&text_chunk("answer"), &mut state);
    let events = process_chunk(&done_chunk("stop", 10, 5), &mut state);
    if let Some(StreamEvent::Done { message, .. }) = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }))
    {
        assert_eq!(message.content.len(), 2);
        assert!(matches!(
            message.content[0],
            AssistantContent::Thinking { .. }
        ));
        assert!(matches!(message.content[1], AssistantContent::Text { .. }));
    } else {
        panic!("expected Done event");
    }
}

#[test]
fn deserialization_from_real_ollama_json() {
    // Real chunk from Ollama native API
    let json = r#"{"model":"gemma4:e4b","created_at":"2026-04-10T21:37:05.295794Z","message":{"role":"assistant","content":"","thinking":"Here's"},"done":false}"#;
    let chunk: OllamaChatChunk = serde_json::from_str(json).unwrap();
    assert!(!chunk.done);
    assert_eq!(chunk.message.thinking.as_deref(), Some("Here's"));
    assert!(chunk.message.content.is_empty());

    let mut state = OllamaStreamState::new();
    let events = process_chunk(&chunk, &mut state);
    assert!(matches!(events[0], StreamEvent::ThinkingStart));
    assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
}

#[test]
fn deserialization_done_chunk() {
    let json = r#"{"model":"gemma4:e4b","created_at":"2026-04-10T21:37:05.315509Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":269220250,"load_duration":171860917,"prompt_eval_count":22,"prompt_eval_duration":76691917,"eval_count":2,"eval_duration":19558000}"#;
    let chunk: OllamaChatChunk = serde_json::from_str(json).unwrap();
    assert!(chunk.done);
    assert_eq!(chunk.done_reason.as_deref(), Some("stop"));
    assert_eq!(chunk.prompt_eval_count, Some(22));
    assert_eq!(chunk.eval_count, Some(2));
}

#[test]
fn deserialization_capability_invocation_chunk() {
    let json = r#"{"model":"gemma4:e4b","created_at":"2026-04-10T21:37:18.864432Z","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_ba7d6wq8","function":{"index":0,"name":"get_weather","arguments":{"location":"San Francisco"}}}]},"done":false}"#;
    let chunk: OllamaChatChunk = serde_json::from_str(json).unwrap();
    let tc = chunk.message.tool_calls.as_ref().unwrap();
    assert_eq!(tc.len(), 1);
    assert_eq!(tc[0].function.name, "get_weather");
    assert_eq!(tc[0].function.arguments["location"], "San Francisco");
}
