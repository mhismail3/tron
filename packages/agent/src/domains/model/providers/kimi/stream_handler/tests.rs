use super::*;

fn text_chunk(content: &str) -> ChatCompletionChunk {
    ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: Some(content.into()),
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: None,
        }],
        usage: None,
    }
}

fn thinking_chunk(content: &str) -> ChatCompletionChunk {
    ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: Some(content.into()),
                capability_invocations: None,
            },
            finish_reason: None,
        }],
        usage: None,
    }
}

fn finish_chunk(reason: &str) -> ChatCompletionChunk {
    ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: Some(reason.into()),
        }],
        usage: None,
    }
}

fn usage_chunk(prompt: u64, completion: u64) -> ChatCompletionChunk {
    ChatCompletionChunk {
        choices: vec![],
        usage: Some(ChunkUsage {
            prompt_tokens: prompt,
            completion_tokens: completion,
            ..Default::default()
        }),
    }
}

#[test]
fn text_only_stream() {
    let mut state = KimiStreamState::new();
    let events1 = process_chunk(&text_chunk("Hello"), &mut state);
    assert!(matches!(events1[0], StreamEvent::TextStart));
    assert!(matches!(events1[1], StreamEvent::TextDelta { .. }));

    let events2 = process_chunk(&text_chunk(" world"), &mut state);
    assert_eq!(events2.len(), 1); // just delta, no start
    assert!(matches!(events2[0], StreamEvent::TextDelta { .. }));
}

#[test]
fn thinking_stream() {
    let mut state = KimiStreamState::new();
    let events = process_chunk(&thinking_chunk("Let me think"), &mut state);
    assert!(matches!(events[0], StreamEvent::ThinkingStart));
    assert!(matches!(events[1], StreamEvent::ThinkingDelta { .. }));
}

#[test]
fn thinking_to_text_transition() {
    let mut state = KimiStreamState::new();
    let _ = process_chunk(&thinking_chunk("thinking..."), &mut state);
    let events = process_chunk(&text_chunk("answer"), &mut state);

    // Should see ThinkingEnd, TextStart, TextDelta
    assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
    assert!(matches!(events[1], StreamEvent::TextStart));
    assert!(matches!(events[2], StreamEvent::TextDelta { .. }));
}

#[test]
fn capability_invocation_stream() {
    let mut state = KimiStreamState::new();

    // First chunk: capability invocation start with name
    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: Some(vec![ChunkCapabilityInvocationDraft {
                    index: 0,
                    id: Some("call_abc".into()),
                    function: Some(ChunkCapabilityInvocationDraftFunction {
                        name: Some("execute".into()),
                        arguments: Some("{\"cm".into()),
                    }),
                }]),
            },
            finish_reason: None,
        }],
        usage: None,
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

    // Second chunk: more arguments
    let chunk2 = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: Some(vec![ChunkCapabilityInvocationDraft {
                    index: 0,
                    id: None,
                    function: Some(ChunkCapabilityInvocationDraftFunction {
                        name: None,
                        arguments: Some("d\":\"ls\"}".into()),
                    }),
                }]),
            },
            finish_reason: None,
        }],
        usage: None,
    };
    let events2 = process_chunk(&chunk2, &mut state);
    assert_eq!(events2.len(), 1);
    assert!(matches!(
        events2[0],
        StreamEvent::CapabilityInvocationDraftDelta { .. }
    ));
}

#[test]
fn multiple_capability_invocations() {
    let mut state = KimiStreamState::new();

    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: Some(vec![
                    ChunkCapabilityInvocationDraft {
                        index: 0,
                        id: Some("call_1".into()),
                        function: Some(ChunkCapabilityInvocationDraftFunction {
                            name: Some("execute".into()),
                            arguments: Some("{}".into()),
                        }),
                    },
                    ChunkCapabilityInvocationDraft {
                        index: 1,
                        id: Some("call_2".into()),
                        function: Some(ChunkCapabilityInvocationDraftFunction {
                            name: Some("inspect".into()),
                            arguments: Some("{}".into()),
                        }),
                    },
                ]),
            },
            finish_reason: None,
        }],
        usage: None,
    };

    let events = process_chunk(&chunk, &mut state);
    let starts: Vec<_> = events
        .iter()
        .filter(|e| matches!(e, StreamEvent::CapabilityInvocationDraftStart { .. }))
        .collect();
    assert_eq!(starts.len(), 2);
}

#[test]
fn finish_reason_stop() {
    let mut state = KimiStreamState::new();
    let _ = process_chunk(&text_chunk("hello"), &mut state);

    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: Some("stop".into()),
        }],
        usage: Some(ChunkUsage {
            prompt_tokens: 100,
            completion_tokens: 50,
            ..Default::default()
        }),
    };
    let events = process_chunk(&chunk, &mut state);
    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    assert!(done.is_some());
    if let StreamEvent::Done { stop_reason, .. } = done.unwrap() {
        assert_eq!(stop_reason, "end_turn");
    }
}

#[test]
fn finish_reason_capability_invocations() {
    let mut state = KimiStreamState::new();
    state.stop_reason = Some("capability_invocation".into());
    state.usage = Some(TokenUsage::default());
    let events = process_chunk(
        &ChatCompletionChunk {
            choices: vec![],
            usage: None,
        },
        &mut state,
    );
    let done = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    assert!(done.is_some());
}

#[test]
fn finish_reason_length() {
    let mut state = KimiStreamState::new();
    let _ = process_chunk(&text_chunk("hi"), &mut state);
    let events = process_chunk(&finish_chunk("length"), &mut state);
    // TextEnd should be emitted before finish processing
    assert!(
        events
            .iter()
            .any(|e| matches!(e, StreamEvent::TextEnd { .. }))
    );
}

#[test]
fn usage_extraction() {
    let mut state = KimiStreamState::new();
    let _ = process_chunk(&text_chunk("hi"), &mut state);
    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: Some("stop".into()),
        }],
        usage: Some(ChunkUsage {
            prompt_tokens: 500,
            completion_tokens: 200,
            ..Default::default()
        }),
    };
    let events = process_chunk(&chunk, &mut state);
    if let Some(StreamEvent::Done { message, .. }) = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }))
    {
        let usage = message.token_usage.as_ref().unwrap();
        assert_eq!(usage.input_tokens, 500);
        assert_eq!(usage.output_tokens, 200);
    } else {
        panic!("expected Done event");
    }
}

#[test]
fn usage_extraction_preserves_cache_and_reasoning_details() {
    let mut state = KimiStreamState::new();
    let _ = process_chunk(&text_chunk("hi"), &mut state);
    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: Some("stop".into()),
        }],
        usage: Some(ChunkUsage {
            prompt_tokens: 500,
            completion_tokens: 200,
            total_tokens: Some(700),
            cached_tokens: Some(300),
            completion_tokens_details: Some(CompletionTokensDetails {
                reasoning_tokens: 75,
            }),
            ..Default::default()
        }),
    };
    let events = process_chunk(&chunk, &mut state);
    let Some(StreamEvent::Done { message, .. }) = events
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }))
    else {
        panic!("expected Done event");
    };
    let usage = message.token_usage.as_ref().unwrap();
    assert_eq!(usage.cache_read_tokens, Some(300));
    assert_eq!(usage.cached_input_tokens, Some(300));
    assert_eq!(usage.reasoning_output_tokens, Some(75));
    assert_eq!(usage.total_tokens, Some(700));
    assert_eq!(usage.provider_type, Some(Provider::Kimi));
}

#[test]
fn empty_delta_no_events() {
    let mut state = KimiStreamState::new();
    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: None,
        }],
        usage: None,
    };
    let events = process_chunk(&chunk, &mut state);
    assert!(events.is_empty());
}

#[test]
fn empty_content_string_no_events() {
    let mut state = KimiStreamState::new();
    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: Some(String::new()),
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: None,
        }],
        usage: None,
    };
    let events = process_chunk(&chunk, &mut state);
    assert!(events.is_empty());
}

#[test]
fn thinking_plus_capability_invocations() {
    let mut state = KimiStreamState::new();

    // Thinking
    let _ = process_chunk(&thinking_chunk("planning..."), &mut state);

    // Capability invocation — should end thinking first
    let chunk = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: Some(vec![ChunkCapabilityInvocationDraft {
                    index: 0,
                    id: Some("call_1".into()),
                    function: Some(ChunkCapabilityInvocationDraftFunction {
                        name: Some("execute".into()),
                        arguments: Some("{}".into()),
                    }),
                }]),
            },
            finish_reason: None,
        }],
        usage: None,
    };
    let events = process_chunk(&chunk, &mut state);
    assert!(matches!(events[0], StreamEvent::ThinkingEnd { .. }));
    assert!(matches!(
        events[1],
        StreamEvent::CapabilityInvocationDraftStart { .. }
    ));
}

#[test]
fn capability_invocation_arguments_accumulation() {
    let mut state = KimiStreamState::new();

    // Start
    let chunk1 = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: Some(vec![ChunkCapabilityInvocationDraft {
                    index: 0,
                    id: Some("call_1".into()),
                    function: Some(ChunkCapabilityInvocationDraftFunction {
                        name: Some("execute".into()),
                        arguments: Some("{\"cm".into()),
                    }),
                }]),
            },
            finish_reason: None,
        }],
        usage: None,
    };
    let _ = process_chunk(&chunk1, &mut state);

    // Continue
    let chunk2 = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: Some(vec![ChunkCapabilityInvocationDraft {
                    index: 0,
                    id: None,
                    function: Some(ChunkCapabilityInvocationDraftFunction {
                        name: None,
                        arguments: Some("d\":\"ls\"}".into()),
                    }),
                }]),
            },
            finish_reason: None,
        }],
        usage: None,
    };
    let _ = process_chunk(&chunk2, &mut state);

    // Finish — should emit CapabilityInvocationDraftEnd with complete arguments
    let chunk3 = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: Some("capability_invocations".into()),
        }],
        usage: Some(ChunkUsage {
            prompt_tokens: 100,
            completion_tokens: 50,
            ..Default::default()
        }),
    };
    let events = process_chunk(&chunk3, &mut state);

    let capability_completed = events
        .iter()
        .find(|e| matches!(e, StreamEvent::CapabilityInvocationDraftEnd { .. }));
    assert!(capability_completed.is_some());
    if let StreamEvent::CapabilityInvocationDraftEnd {
        capability_invocation,
    } = capability_completed.unwrap()
    {
        assert_eq!(capability_invocation.name, "execute");
        assert_eq!(capability_invocation.arguments["cmd"], "ls");
    }
}

#[test]
fn malformed_capability_invocation_arguments_fail_closed() {
    let mut state = KimiStreamState::new();

    let chunk1 = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: Some(vec![ChunkCapabilityInvocationDraft {
                    index: 0,
                    id: Some("call_bad".into()),
                    function: Some(ChunkCapabilityInvocationDraftFunction {
                        name: Some("execute".into()),
                        arguments: Some("not json".into()),
                    }),
                }]),
            },
            finish_reason: None,
        }],
        usage: None,
    };
    let _ = process_chunk(&chunk1, &mut state);

    let chunk2 = ChatCompletionChunk {
        choices: vec![ChunkChoice {
            delta: ChunkDelta {
                content: None,
                reasoning_content: None,
                capability_invocations: None,
            },
            finish_reason: Some("capability_invocations".into()),
        }],
        usage: Some(ChunkUsage {
            prompt_tokens: 100,
            completion_tokens: 50,
            ..Default::default()
        }),
    };
    let events = process_chunk(&chunk2, &mut state);

    assert!(
        events
            .iter()
            .any(|event| matches!(event, StreamEvent::Error { error } if error.contains("kimi capability invocation arguments") && error.contains("malformed JSON")))
    );
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, StreamEvent::CapabilityInvocationDraftEnd { .. }))
    );
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, StreamEvent::Done { .. }))
    );
}

#[test]
fn separate_finish_and_usage_chunks() {
    let mut state = KimiStreamState::new();
    let _ = process_chunk(&text_chunk("hi"), &mut state);

    // Finish reason in one chunk
    let events1 = process_chunk(&finish_chunk("stop"), &mut state);
    // TextEnd should be emitted
    assert!(
        events1
            .iter()
            .any(|e| matches!(e, StreamEvent::TextEnd { .. }))
    );
    // No Done yet (no usage)

    // Usage in separate chunk
    let events2 = process_chunk(&usage_chunk(100, 50), &mut state);
    let done = events2
        .iter()
        .find(|e| matches!(e, StreamEvent::Done { .. }));
    assert!(done.is_some());
}

#[test]
fn map_finish_reasons() {
    assert_eq!(map_finish_reason("stop"), "end_turn");
    assert_eq!(
        map_finish_reason("capability_invocations"),
        "capability_invocation"
    );
    assert_eq!(map_finish_reason("length"), "max_tokens");
    assert_eq!(map_finish_reason("content_filter"), "content_filter");
    assert_eq!(map_finish_reason("unknown_reason"), "unknown_reason");
}
