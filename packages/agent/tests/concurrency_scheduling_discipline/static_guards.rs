use super::support::{
    production_ios_swift_paths, production_rust_paths, production_swift_paths, read_repo_file,
    text_has_any,
};

#[test]
fn production_unbounded_mpsc_is_absent() {
    let offenders = production_rust_paths()
        .into_iter()
        .filter(|path| {
            let source = read_repo_file(path);
            source.contains("mpsc::unbounded_channel")
                || source.contains("UnboundedSender")
                || source.contains("UnboundedReceiver")
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "production unbounded MPSC is not allowed:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn production_swift_banned_scheduling_patterns_are_absent() {
    let offenders = production_ios_swift_paths()
        .into_iter()
        .filter_map(|path| {
            let source = read_repo_file(&path);
            let hits = [
                "Task.detached",
                "DispatchQueue.global",
                "DispatchQueue.main.asyncAfter",
            ]
            .into_iter()
            .filter(|needle| source.contains(needle))
            .collect::<Vec<_>>();
            (!hits.is_empty()).then(|| format!("{path}: {}", hits.join(", ")))
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "production Swift banned scheduling patterns remain:\n{}",
        offenders.join("\n")
    );
}

fn mask_swift_comments_and_strings(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut code = bytes.to_vec();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index..].starts_with(b"//") {
            let end = bytes[index..]
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(bytes.len(), |offset| index + offset);
            code[index..end].fill(b' ');
            index = end;
            continue;
        }
        if bytes[index..].starts_with(b"/*") {
            let start = index;
            let mut depth = 1;
            index += 2;
            while index < bytes.len() && depth > 0 {
                if bytes[index..].starts_with(b"/*") {
                    depth += 1;
                    index += 2;
                } else if bytes[index..].starts_with(b"*/") {
                    depth -= 1;
                    index += 2;
                } else {
                    index += 1;
                }
            }
            code[start..index].fill(b' ');
            continue;
        }

        let hash_count = bytes[index..]
            .iter()
            .take_while(|byte| **byte == b'#')
            .count();
        let quote_index = index + hash_count;
        if bytes.get(quote_index) == Some(&b'"') {
            let start = index;
            let quote_count = if bytes[quote_index..].starts_with(b"\"\"\"") {
                3
            } else {
                1
            };
            index = quote_index + quote_count;
            while index < bytes.len() {
                if hash_count == 0 && bytes[index] == b'\\' {
                    index = (index + 2).min(bytes.len());
                    continue;
                }
                let quote_end = index + quote_count;
                let hash_end = quote_end + hash_count;
                if hash_end <= bytes.len()
                    && bytes[index..quote_end].iter().all(|byte| *byte == b'"')
                    && bytes[quote_end..hash_end].iter().all(|byte| *byte == b'#')
                {
                    index = hash_end;
                    break;
                }
                index += 1;
            }
            code[start..index].fill(b' ');
            continue;
        }
        index += 1;
    }
    String::from_utf8(code).expect("masking ASCII syntax preserves Swift UTF-8")
}

fn is_identifier_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || !byte.is_ascii()
}

fn skip_whitespace(code: &[u8], mut index: usize) -> usize {
    while code.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    index
}

fn skip_generic_arguments(code: &[u8], mut index: usize) -> usize {
    if code.get(index) != Some(&b'<') {
        return index;
    }
    let mut depth = 0;
    while index < code.len() {
        match code[index] {
            b'<' => depth += 1,
            b'>' => {
                depth -= 1;
                if depth == 0 {
                    return index + 1;
                }
            }
            _ => {}
        }
        index += 1;
    }
    code.len()
}

fn invocation_has_bounded_buffering_policy(code: &str, open_paren: usize) -> bool {
    let bytes = code.as_bytes();
    let mut depth = 0;
    let mut index = open_paren;
    while index < bytes.len() {
        match bytes[index] {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    let arguments = code[open_paren + 1..index]
                        .split_whitespace()
                        .collect::<String>();
                    return arguments.contains("bufferingPolicy:")
                        && !arguments.contains("bufferingPolicy:.unbounded")
                        && !arguments.contains("BufferingPolicy.unbounded");
                }
            }
            _ => {}
        }
        index += 1;
    }
    false
}

fn occurrence_is_type_declaration(code: &str, start: usize) -> bool {
    let prefix = code[..start].trim_end();
    if prefix.ends_with("->") || prefix.ends_with("extension") {
        return true;
    }
    if !prefix.ends_with(':') {
        return false;
    }
    let statement = prefix
        .rsplit(['\n', ';', '{', '}'])
        .next()
        .unwrap_or_default()
        .trim_start();
    !statement.contains('=') && (statement.starts_with("var ") || statement.contains(" var "))
}

fn has_unbounded_stream_initializer(source: &str, stream_type: &str) -> bool {
    let code = mask_swift_comments_and_strings(source);
    let bytes = code.as_bytes();
    for (start, _) in code.match_indices(stream_type) {
        let end = start + stream_type.len();
        if start > 0 && is_identifier_byte(bytes[start - 1])
            || bytes.get(end).is_some_and(|byte| is_identifier_byte(*byte))
        {
            continue;
        }

        let mut cursor = skip_whitespace(bytes, end);
        cursor = skip_generic_arguments(bytes, cursor);
        cursor = skip_whitespace(bytes, cursor);
        let tail = &code[cursor..];
        if tail.starts_with(".Continuation") {
            continue;
        }
        if tail.starts_with(".init") {
            cursor = skip_whitespace(bytes, cursor + ".init".len());
        } else if tail.starts_with(".makeStream") {
            cursor = skip_whitespace(bytes, cursor + ".makeStream".len());
        }

        match bytes.get(cursor) {
            Some(b'(') if !invocation_has_bounded_buffering_policy(&code, cursor) => return true,
            Some(b'{') if !occurrence_is_type_declaration(&code, start) => return true,
            _ => {}
        }
    }
    false
}

#[test]
fn async_stream_guard_distinguishes_generic_code_from_prose() {
    for unbounded in [
        "let stream = AsyncStream<Event> { _ in }",
        "let stream = AsyncThrowingStream<Event, Error>.init { _ in }",
        "let pair = AsyncStream<Event>.makeStream()",
        "let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { _ in }",
        "let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)",
        "consume(stream: AsyncStream<Event> { _ in })",
        "let table = [\"events\": AsyncStream<Event> { _ in }]",
        "var result = consume(stream: AsyncStream<Event> { _ in })",
    ] {
        assert!(
            has_unbounded_stream_initializer(unbounded, "AsyncStream")
                || has_unbounded_stream_initializer(unbounded, "AsyncThrowingStream")
        );
    }

    for allowed in [
        "let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(1)) { _ in }",
        "let stream = AsyncThrowingStream<Event, Error>(bufferingPolicy: .bufferingNewest(1)) { _ in }",
        "func events() -> AsyncStream<Event> { fatalError() }",
        "private var events: AsyncStream<Event> { fatalError() }",
        "// AsyncStream<Event> { prose in }",
        "/* AsyncThrowingStream<Event, Error> { prose in } */",
        "let prose = \"AsyncStream<Event> { prose in }\"",
        "let factory = MyAsyncStream()",
    ] {
        assert!(!has_unbounded_stream_initializer(allowed, "AsyncStream"));
        assert!(!has_unbounded_stream_initializer(
            allowed,
            "AsyncThrowingStream"
        ));
    }
}

#[test]
fn production_swift_async_stream_initializers_are_bounded() {
    let offenders = production_swift_paths()
        .into_iter()
        .filter(|path| {
            let source = read_repo_file(path);
            has_unbounded_stream_initializer(&source, "AsyncStream")
                || has_unbounded_stream_initializer(&source, "AsyncThrowingStream")
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "production Swift async streams must declare a buffering policy:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn swift_owner_classes_with_task_fields_expose_cancellation_paths() {
    let offenders = production_ios_swift_paths()
        .into_iter()
        .filter(|path| {
            let source = read_repo_file(path);
            source.contains("Task<")
                && !text_has_any(
                    &source,
                    &[
                        "deinit",
                        "stop",
                        "reset",
                        "disconnect",
                        "cleanup",
                        "cancel",
                        "onDisappear",
                    ],
                )
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "Swift owner classes with stored Task fields need visible cancellation paths:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn external_worker_outbound_scheduling_is_bounded_in_source() {
    let source = read_repo_file("packages/agent/src/transport/runtime/external_workers.rs");
    for required in [
        "EXTERNAL_WORKER_OUTBOUND_CAPACITY",
        "mpsc::channel::<Message>(EXTERNAL_WORKER_OUTBOUND_CAPACITY)",
        "EXTERNAL_WORKER_OUTBOUND_SEND_TIMEOUT",
        "WORKER_OUTBOUND_BACKPRESSURE_TIMEOUT",
        "worker_invocation_fails_when_outbound_queue_stays_full",
    ] {
        assert!(
            source.contains(required),
            "external worker bounded scheduling proof missing `{required}`"
        );
    }
}

fn assert_contains_in_order(name: &str, source: &str, needles: &[&str]) {
    let mut cursor = 0;
    for needle in needles {
        let relative = source[cursor..]
            .find(needle)
            .unwrap_or_else(|| panic!("{name} is missing ordered fragment `{needle}`"));
        cursor += relative + needle.len();
    }
}

#[test]
fn ios_terminal_task_owners_cancel_and_await_exact_handles() {
    let manager =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift");
    assert_contains_in_order(
        "EventStoreManager terminal drain",
        &manager,
        &[
            "globalTask?.cancel()",
            "await globalTask?.value",
            "await refreshCoordinator.shutdown()",
            "loadTask?.cancel()",
            "await loadTask?.value",
        ],
    );
    assert!(manager.contains("if let shutdownTask"));
    assert!(manager.contains("await shutdownTask.value"));

    let refresh = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/SessionRefreshService.swift",
    );
    assert_contains_in_order(
        "SessionRefreshService terminal drain",
        &refresh,
        &[
            "isStopped = true",
            "connectionManager?.cancelHook(label: Self.hookLabel)",
            "pendingDebounceTask?.cancel()",
            "acceptedInflightTask?.cancel()",
            "await pendingDebounceTask?.value",
            "await acceptedInflightTask?.value",
        ],
    );
    assert!(refresh.contains("guard !isStopped else { return }"));
    assert!(refresh.contains("if let shutdownTask"));
    assert!(refresh.contains("await shutdownTask.value"));
}
