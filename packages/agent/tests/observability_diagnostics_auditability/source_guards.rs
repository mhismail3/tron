use super::support::{git_ls_files, read_repo_file};

#[test]
fn oda_logs_recent_honors_correlation_filters_and_returns_join_ids() {
    let logs_domain = read_repo_file("packages/agent/src/domains/logs/mod.rs");
    for required in [
        "\"traceId\":{\"type\":\"string\"}",
        "session_id: Option<String>",
        "workspace_id: Option<String>",
        "trace_id: Option<String>",
        "LogSessionFilter::OnlySession",
        "workspace_id: entry.workspace_id",
        "trace_id: entry.trace_id",
        "recent_logs_honors_session_workspace_and_trace_filters",
    ] {
        assert!(
            logs_domain.contains(required),
            "logs domain must preserve ODA logs::recent guard `{required}`"
        );
    }

    let store_logs =
        read_repo_file("packages/agent/src/domains/session/event_store/store/event_store/logs.rs");
    for required in [
        "pub workspace_id: Option<&'a str>",
        "workspace_id = ?",
        "trace_id = ?",
        "redact_and_truncate_client_log_message",
        "MAX_CLIENT_LOG_MESSAGE_BYTES",
        "INSERT OR IGNORE INTO logs",
        "list_recent_logs_applies_workspace_scope_and_keeps_correlation_ids",
    ] {
        assert!(
            store_logs.contains(required),
            "event-store logs owner must preserve ODA guard `{required}`"
        );
    }

    let execute_logs = read_repo_file("packages/agent/src/domains/capability/operations/logs.rs");
    for required in [
        "log_recent requires trusted current session context",
        "LogSessionFilter::SessionAndGlobal(&session_id)",
        "workspace_id: None",
        ".clamp(1, 500)",
    ] {
        assert!(
            execute_logs.contains(required),
            "model-facing log_recent must preserve ODA guard `{required}`"
        );
    }
}

#[test]
fn oda_cli_logs_are_bounded_filterable_and_quoted() {
    let logs_script = read_repo_file("scripts/tron-lib.d/logs.sh");
    for required in [
        "-w|--workspace",
        "-t|--trace",
        "local value=${1//\\'/\\'\\'}",
        "join_conditions()",
        "joined=\"$joined AND $condition\"",
        "where_clause=\"WHERE $(join_conditions \"${conditions[@]}\")\"",
        r#"'workspaceId', workspace_id"#,
        r#"'traceId', trace_id"#,
        r#"session_id = $(sql_quote_literal "$session")"#,
        r#"workspace_id = $(sql_quote_literal "$workspace")"#,
        r#"trace_id = $(sql_quote_literal "$trace")"#,
        "search_literal=$(sql_quote_literal \"$search\")",
        "if ! [[ \"$limit\" =~ ^[0-9]+$ ]] || [ \"$limit\" -lt 1 ]; then",
    ] {
        assert!(
            logs_script.contains(required),
            "tron logs must preserve ODA CLI guard `{required}`"
        );
    }
    assert!(
        !logs_script.contains("session_id LIKE '%$session%'"),
        "tron logs must not interpolate loose session LIKE predicates"
    );
    assert!(
        !logs_script.contains("IFS=' AND '; echo"),
        "tron logs must not rely on Bash IFS array joins for SQL AND predicates"
    );

    let service_script = read_repo_file("scripts/tron-lib.d/service.sh");
    for required in [
        "\"mode\"",
        "\"listenerPid\"",
        "\"pidFileStale\"",
        "\"healthy\"",
        "\"databasePath\"",
        "\"logPath\"",
        "[-w workspace] [-t trace]",
    ] {
        assert!(
            service_script.contains(required),
            "tron status/log UX must preserve ODA guard `{required}`"
        );
    }
}

#[test]
fn oda_client_diagnostics_hash_correlation_ids_and_keep_redaction_boundaries() {
    let protocol = read_repo_file(
        "packages/ios-app/Sources/Engine/Protocol/System/EngineProtocolTypes+System.swift",
    );
    for required in [
        "let sessionId: String?",
        "let workspaceId: String?",
        "let traceId: String?",
        "init(",
    ] {
        assert!(
            protocol.contains(required),
            "iOS logs DTOs must preserve ODA guard `{required}`"
        );
    }

    let logs_client =
        read_repo_file("packages/ios-app/Sources/Engine/Transport/Clients/LogsClient.swift");
    for required in [
        "sessionId: String? = nil",
        "workspaceId: String? = nil",
        "traceId: String? = nil",
        "LogsRecentParams(",
        "min(max(limit, 1), 1000)",
    ] {
        assert!(
            logs_client.contains(required),
            "iOS LogsClient must preserve ODA guard `{required}`"
        );
    }

    let bundle_types =
        read_repo_file("packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleTypes.swift");
    for required in ["sessionIdHash", "workspaceIdHash", "traceIdHash"] {
        assert!(
            bundle_types.contains(required),
            "iOS diagnostics bundle types must preserve ODA guard `{required}`"
        );
    }

    let bundle_builder = read_repo_file(
        "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
    );
    for required in [
        "workspaceIdHash: DiagnosticsHash.hash(entry.workspaceId)",
        "traceIdHash: DiagnosticsHash.hash(entry.traceId)",
        "message: redactor.redactMessage(entry.message)",
        "maxServerLogs = 1_000",
        "maxEvents = 5_000",
        "maxEventBytes = 5_000_000",
    ] {
        assert!(
            bundle_builder.contains(required),
            "iOS diagnostics builder must preserve ODA guard `{required}`"
        );
    }

    let diagnostics_test = read_repo_file(
        "packages/ios-app/Tests/Support/Diagnostics/DiagnosticsBundleBuilderTests.swift",
    );
    for required in [
        "serverLogDiagnosticsHashCorrelationIDs",
        "!json.contains(\"session-raw\")",
        "!json.contains(\"workspace-raw\")",
        "!json.contains(\"trace-raw\")",
    ] {
        assert!(
            diagnostics_test.contains(required),
            "iOS diagnostics tests must preserve ODA guard `{required}`"
        );
    }

    let mac_reader =
        read_repo_file("packages/mac-app/Sources/MenuBar/Presentation/MenuBarLogReader.swift");
    for required in [
        "var sessionId: String?",
        "var workspaceId: String?",
        "var traceId: String?",
        "\"payload\": [\"limit\": limit]",
    ] {
        assert!(
            mac_reader.contains(required),
            "Mac log reader must preserve ODA guard `{required}`"
        );
    }

    let mac_reader_tests =
        read_repo_file("packages/mac-app/Tests/MenuBar/Presentation/MenuBarLogReaderTests.swift");
    for required in [
        "workspaceId\":\"workspace-1\"",
        "traceId\":\"trace-1\"",
        "result.entries.first?.workspaceId == \"workspace-1\"",
        "result.entries.first?.traceId == \"trace-1\"",
    ] {
        assert!(
            mac_reader_tests.contains(required),
            "Mac log reader tests must preserve ODA guard `{required}`"
        );
    }
}

#[test]
fn oda_correlation_chain_surfaces_remain_joinable_without_product_diagnostics_api() {
    let trace_type = read_repo_file("packages/agent/src/domains/session/event_store/trace.rs");
    for required in [
        "pub trace_id: String",
        "pub invocation_id: String",
        "pub parent_invocation_id: Option<String>",
        "pub provider_invocation_id: Option<String>",
        "pub session_id: Option<String>",
        "pub workspace_id: Option<String>",
    ] {
        assert!(
            trace_type.contains(required),
            "trace record type must preserve ODA join field `{required}`"
        );
    }

    let trace_ops = read_repo_file("packages/agent/src/domains/capability/operations/trace.rs");
    for required in [
        "\"traceId\": invocation.causal_context.trace_id.as_str()",
        "\"invocationId\": invocation.id.as_str()",
        "\"providerInvocationId\": invocation.causal_context.runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID)",
        "\"authorityGrantId\": invocation.causal_context.authority_grant_id.as_str()",
        "\"requestHash\": hash_json(&invocation.payload)",
        "\"resultHash\": hash_json(result)",
        ".clamp(1, 500)",
    ] {
        assert!(
            trace_ops.contains(required),
            "trace operations must preserve ODA correlation guard `{required}`"
        );
    }

    let replay = read_repo_file("packages/agent/src/domains/session/replay/mod.rs");
    for required in [
        "provider_audits: Vec<ReplayProviderAudit>",
        "trace_records: Vec<AgentTraceRecord>",
        "engine_idempotency_entries",
        "engine_invocations",
        "engine_streams",
        "engine_queue_items",
        "ReplayInvocationRecord",
        "engine_error_replay_details",
    ] {
        assert!(
            replay.contains(required),
            "replay manifest must preserve ODA section guard `{required}`"
        );
    }

    let provider_audit = read_repo_file("packages/agent/src/shared/protocol/model_audit.rs");
    for required in [
        "MODEL_PROVIDER_REQUEST_AUDIT_FORMAT",
        "provider_type: Provider",
        "session_id: String",
        "provider_request: ProviderAuditPayload",
    ] {
        assert!(
            provider_audit.contains(required),
            "provider audit DTO must preserve ODA guard `{required}`"
        );
    }

    let persistence =
        read_repo_file("packages/agent/src/domains/agent/loop/turn_runner/persistence/mod.rs");
    let runner = read_repo_file("packages/agent/src/domains/agent/loop/turn_runner/mod.rs");
    assert!(
        persistence.contains("persist_model_provider_request_audit")
            && runner.contains("persist_model_provider_request_audit("),
        "turn runner must keep provider audit persistence wired before response streaming"
    );

    let banned = [
        "system::get_diagnostics",
        "get_diagnostics",
        "SystemDiagnostics",
    ];
    let offenders = git_ls_files()
        .into_iter()
        .filter(|path| {
            path.starts_with("packages/agent/src/")
                || path.starts_with("packages/ios-app/Sources/")
                || path.starts_with("packages/mac-app/Sources/")
        })
        .filter(|path| path.ends_with(".rs") || path.ends_with(".swift") || path.ends_with(".md"))
        .filter(|path| {
            let source = read_repo_file(path);
            banned.iter().any(|needle| source.contains(needle))
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "production source must not restore fixed diagnostics API:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn oda_runtime_decisions_have_durable_or_replayable_evidence_owners() {
    let ledger = read_repo_file("packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs");
    for required in [
        "engine_invocations",
        "engine_idempotency_entries",
        "engine_catalog_changes",
        "append_invocation",
        "list_invocations_by_session",
        "list_idempotency_by_session",
        "append_catalog_change",
    ] {
        assert!(
            ledger.contains(required),
            "engine ledger must preserve ODA evidence owner `{required}`"
        );
    }

    let grants = read_repo_file("packages/agent/src/engine/authority/grants/mod.rs");
    for required in ["record_event", "grant.budget_consumed", "grant.revoked"] {
        assert!(
            grants.contains(required),
            "authority grants must preserve ODA evidence owner `{required}`"
        );
    }

    let queue = read_repo_file("packages/agent/src/engine/durability/queue/mod.rs");
    for required in [
        "EngineQueueAttemptRecord",
        "QueueAttemptOutcome",
        "DeadLettered",
        "Cancelled",
        "attempt_records",
    ] {
        assert!(
            queue.contains(required),
            "queue model must preserve ODA evidence owner `{required}`"
        );
    }

    let queue_store = read_repo_file("packages/agent/src/engine/durability/queue/sqlite_store.rs");
    for required in [
        "attempt_records_json",
        "item.attempt_records.push(attempt)",
        "QueueItemStatus::DeadLettered",
        "QueueItemStatus::Cancelled",
    ] {
        assert!(
            queue_store.contains(required),
            "queue store must preserve ODA durable evidence owner `{required}`"
        );
    }

    let streams = read_repo_file("packages/agent/src/engine/durability/streams/mod.rs");
    for required in [
        "pub struct EngineStreamEvent",
        "pub cursor: StreamCursor",
        "pub session_id: Option<String>",
        "pub workspace_id: Option<String>",
        "pub trace_id: Option<TraceId>",
    ] {
        assert!(
            streams.contains(required),
            "stream model must preserve ODA evidence owner `{required}`"
        );
    }

    let catalog_changes =
        read_repo_file("packages/agent/src/engine/catalog/registry/catalog_changes.rs");
    for required in [
        "CatalogChange",
        "self.ledger.append_catalog_change(&change)?",
        "CatalogChangeClass::Visibility",
        "CatalogChangeClass::Health",
    ] {
        assert!(
            catalog_changes.contains(required),
            "catalog changes must preserve ODA evidence owner `{required}`"
        );
    }
}
