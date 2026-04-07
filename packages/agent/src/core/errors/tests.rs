use super::*;

// -- TronError --

#[test]
fn tron_error_from_message_auth() {
    let err = TronError::from_message("401 unauthorized");
    assert_eq!(err.category(), ErrorCategory::Authentication);
    assert!(!err.is_retryable());
}

#[test]
fn tron_error_from_message_rate_limit() {
    let err = TronError::from_message("429 rate limit exceeded");
    assert_eq!(err.category(), ErrorCategory::RateLimit);
    assert!(err.is_retryable());
}

#[test]
fn tron_error_from_message_network() {
    let err = TronError::from_message("ECONNREFUSED");
    assert_eq!(err.category(), ErrorCategory::Network);
    assert!(err.is_retryable());
}

#[test]
fn tron_error_from_message_unknown() {
    let err = TronError::from_message("something weird happened");
    assert_eq!(err.category(), ErrorCategory::Unknown);
    assert!(!err.is_retryable());
}

#[test]
fn tron_error_internal() {
    let err = TronError::internal("MY_CODE", "my message");
    assert_eq!(err.code(), "MY_CODE");
    assert_eq!(err.category(), ErrorCategory::Unknown);
    assert_eq!(err.severity(), ErrorSeverity::Error);
    assert!(err.to_string().contains("MY_CODE"));
    assert!(err.to_string().contains("my message"));
}

#[test]
fn tron_error_from_session() {
    let session_err = SessionError::new("sess-1", SessionOperation::Create, "failed");
    let err = TronError::from(session_err);
    assert!(err.to_string().contains("sess-1"));
    assert_eq!(err.code(), "SESSION_CREATE_ERROR");
}

#[test]
fn tron_error_from_persistence() {
    let persistence_err =
        PersistenceError::new("events", PersistenceOperation::Write, "disk full");
    let err = TronError::from(persistence_err);
    assert!(err.to_string().contains("events"));
    assert_eq!(err.code(), "PERSISTENCE_WRITE_ERROR");
}

#[test]
fn tron_error_from_provider() {
    let provider_err = ProviderError::new(Provider::Anthropic, "claude-opus-4-6", "overloaded")
        .with_status(529);
    let err = TronError::from(provider_err);
    assert!(err.to_string().contains("anthropic"));
    assert!(err.is_retryable());
}

#[test]
fn tron_error_from_tool() {
    let tool_err = ToolError::new("bash", "call-1", "timeout");
    let err = TronError::from(tool_err);
    assert!(err.to_string().contains("bash"));
    assert_eq!(err.code(), "TOOL_BASH_ERROR");
}

#[test]
fn tron_error_from_rpc_handler() {
    let rpc_err = RpcHandlerError::new("not found").with_code("SESSION_NOT_FOUND");
    let err = TronError::from(rpc_err);
    assert_eq!(err.code(), "SESSION_NOT_FOUND");
}

// -- SessionError --

#[test]
fn session_error_create() {
    let err = SessionError::new("sess-1", SessionOperation::Create, "max sessions reached");
    assert_eq!(err.session_id, "sess-1");
    assert_eq!(err.operation, SessionOperation::Create);
    assert_eq!(err.code, "SESSION_CREATE_ERROR");
    assert!(err.to_string().contains("sess-1"));
    assert!(err.to_string().contains("create"));
}

#[test]
fn session_error_with_custom_code() {
    let err = SessionError::new("sess-1", SessionOperation::Fork, "branch missing")
        .with_code("SESSION_FORK_BRANCH_ERROR");
    assert_eq!(err.code, "SESSION_FORK_BRANCH_ERROR");
}

#[test]
fn session_error_with_severity() {
    let err = SessionError::new("sess-1", SessionOperation::Run, "interrupted")
        .with_severity(ErrorSeverity::Warning);
    assert_eq!(err.severity, ErrorSeverity::Warning);
}

#[test]
fn session_error_with_source() {
    let cause = std::io::Error::other("disk error");
    let err = SessionError::new("sess-1", SessionOperation::Resume, "database read failed")
        .with_source(cause);
    assert!(err.source.is_some());
}

#[test]
fn session_operation_display() {
    assert_eq!(SessionOperation::Create.to_string(), "create");
    assert_eq!(SessionOperation::Resume.to_string(), "resume");
    assert_eq!(SessionOperation::Fork.to_string(), "fork");
    assert_eq!(SessionOperation::Run.to_string(), "run");
    assert_eq!(SessionOperation::Interrupt.to_string(), "interrupt");
    assert_eq!(SessionOperation::Close.to_string(), "close");
}

// -- PersistenceError --

#[test]
fn persistence_error_write() {
    let err = PersistenceError::new("events", PersistenceOperation::Write, "disk full");
    assert_eq!(err.table, "events");
    assert_eq!(err.operation, PersistenceOperation::Write);
    assert_eq!(err.code, "PERSISTENCE_WRITE_ERROR");
    assert!(err.to_string().contains("events"));
}

#[test]
fn persistence_error_with_query() {
    let err = PersistenceError::new("sessions", PersistenceOperation::Query, "timeout")
        .with_query("SELECT * FROM sessions WHERE ...");
    assert_eq!(
        err.query.as_deref(),
        Some("SELECT * FROM sessions WHERE ...")
    );
}

#[test]
fn persistence_error_with_source() {
    let cause = std::io::Error::other("sqlite busy");
    let err = PersistenceError::new("events", PersistenceOperation::Read, "locked")
        .with_source(cause);
    assert!(err.source.is_some());
}

#[test]
fn persistence_operation_display() {
    assert_eq!(PersistenceOperation::Read.to_string(), "read");
    assert_eq!(PersistenceOperation::Write.to_string(), "write");
    assert_eq!(PersistenceOperation::Delete.to_string(), "delete");
    assert_eq!(PersistenceOperation::Query.to_string(), "query");
}

// -- ProviderError --

#[test]
fn provider_error_basic() {
    let err = ProviderError::new(Provider::Anthropic, "claude-opus-4-6", "server error");
    assert_eq!(err.provider, Provider::Anthropic);
    assert_eq!(err.model, "claude-opus-4-6");
    assert_eq!(err.code, "PROVIDER_ANTHROPIC_ERROR");
    assert!(!err.retryable);
}

#[test]
fn provider_error_with_401_status() {
    let err = ProviderError::new(Provider::Anthropic, "claude-opus-4-6", "unauthorized")
        .with_status(401);
    assert_eq!(err.category, ErrorCategory::Authentication);
    assert!(!err.retryable);
}

#[test]
fn provider_error_with_429_status() {
    let err = ProviderError::new(Provider::OpenAi, "gpt-4", "rate limited").with_status(429);
    assert_eq!(err.category, ErrorCategory::RateLimit);
    assert!(err.retryable);
}

#[test]
fn provider_error_with_500_status() {
    let err =
        ProviderError::new(Provider::Google, "gemini-2.0", "internal error").with_status(500);
    assert_eq!(err.category, ErrorCategory::Server);
    assert!(err.retryable);
}

#[test]
fn provider_error_with_rate_limit_info() {
    let err = ProviderError::new(Provider::Anthropic, "claude-opus-4-6", "rate limited")
        .with_status(429)
        .with_rate_limit(RateLimitInfo {
            retry_after_ms: 5000,
            limit: Some(100),
        });
    assert!(err.retryable);
    let info = err.rate_limit_info.as_ref().unwrap();
    assert_eq!(info.retry_after_ms, 5000);
    assert_eq!(info.limit, Some(100));
}

#[test]
fn provider_error_from_error_string() {
    let err = ProviderError::from_error_string(
        Provider::Anthropic,
        "claude-opus-4-6",
        "429 rate limit exceeded",
        Some(429),
    );
    assert_eq!(err.category, ErrorCategory::RateLimit);
    assert!(err.retryable);
    assert_eq!(err.status_code, Some(429));
}

#[test]
fn provider_error_explicit_retryable() {
    let err = ProviderError::new(Provider::OpenAi, "gpt-4", "temporary").with_retryable(true);
    assert!(err.retryable);
}

#[test]
fn provider_name_display() {
    assert_eq!(Provider::Anthropic.to_string(), "anthropic");
    assert_eq!(Provider::OpenAi.to_string(), "openai");
    assert_eq!(Provider::Google.to_string(), "google");
    assert_eq!(Provider::Unknown.to_string(), "unknown");
}

// -- ToolError --

#[test]
fn tool_error_basic() {
    let err = ToolError::new("bash", "call-1", "command timed out");
    assert_eq!(err.tool_name, "bash");
    assert_eq!(err.tool_call_id, "call-1");
    assert_eq!(err.code, "TOOL_BASH_ERROR");
    assert!(err.to_string().contains("bash"));
    assert!(err.to_string().contains("call-1"));
}

#[test]
fn tool_error_with_severity() {
    let err = ToolError::new("read", "call-2", "file not found")
        .with_severity(ErrorSeverity::Warning);
    assert_eq!(err.severity, ErrorSeverity::Warning);
}

#[test]
fn tool_error_with_source() {
    let cause = std::io::Error::new(std::io::ErrorKind::NotFound, "no such file");
    let err = ToolError::new("read", "call-2", "file not found").with_source(cause);
    assert!(err.source.is_some());
}

// -- RpcHandlerError --

#[test]
fn rpc_handler_error_basic() {
    let err = RpcHandlerError::new("session not found");
    assert_eq!(err.code, "RPC_ERROR");
    assert_eq!(err.message, "session not found");
}

#[test]
fn rpc_handler_error_with_code() {
    let err = RpcHandlerError::new("not found").with_code("SESSION_NOT_FOUND");
    assert_eq!(err.code, "SESSION_NOT_FOUND");
}

#[test]
fn rpc_handler_error_from_response() {
    let err = RpcHandlerError::from_response("bad request", Some("INVALID_PARAMS"));
    assert_eq!(err.code, "INVALID_PARAMS");
    assert_eq!(err.message, "bad request");
}

#[test]
fn rpc_handler_error_from_response_no_code() {
    let err = RpcHandlerError::from_response("unknown error", None);
    assert_eq!(err.code, "RPC_ERROR");
}

#[test]
fn rpc_handler_error_display() {
    let err = RpcHandlerError::new("test error").with_code("MY_CODE");
    assert_eq!(err.to_string(), "[MY_CODE] test error");
}

// -- ErrorCollector --

#[test]
fn error_collector_empty() {
    let collector = ErrorCollector::new();
    assert!(!collector.has_errors());
    assert_eq!(collector.count(), 0);
    assert!(collector.errors().is_empty());
}

#[test]
fn error_collector_collect_strings() {
    let mut collector = ErrorCollector::new();
    collector.collect("task 1 failed");
    collector.collect("task 2 failed");
    assert!(collector.has_errors());
    assert_eq!(collector.count(), 2);
}

#[test]
fn error_collector_collect_error() {
    let mut collector = ErrorCollector::new();
    collector.collect_error(TronError::internal("TEST", "test error"));
    assert_eq!(collector.count(), 1);
    assert_eq!(collector.errors()[0].code(), "TEST");
}

#[test]
fn error_collector_flush() {
    let mut collector = ErrorCollector::new();
    collector.collect("error 1");
    collector.collect("error 2");
    let errors = collector.flush();
    assert_eq!(errors.len(), 2);
    assert_eq!(collector.count(), 0);
    assert!(!collector.has_errors());
}

// -- has_error_code --

#[test]
fn has_error_code_matches() {
    let err = TronError::internal("MY_CODE", "test");
    assert!(has_error_code(&err, "MY_CODE"));
}

#[test]
fn has_error_code_no_match() {
    let err = TronError::internal("MY_CODE", "test");
    assert!(!has_error_code(&err, "OTHER_CODE"));
}

#[test]
fn has_error_code_from_session() {
    let err = TronError::from(SessionError::new("s1", SessionOperation::Create, "failed"));
    assert!(has_error_code(&err, "SESSION_CREATE_ERROR"));
}

// -- Severity and category propagation --

#[test]
fn tron_error_severity_from_session() {
    let session_err = SessionError::new("s1", SessionOperation::Run, "warn")
        .with_severity(ErrorSeverity::Warning);
    let err = TronError::from(session_err);
    assert_eq!(err.severity(), ErrorSeverity::Warning);
}

#[test]
fn tron_error_severity_from_persistence() {
    let persistence_err = PersistenceError::new("events", PersistenceOperation::Write, "err");
    let err = TronError::from(persistence_err);
    assert_eq!(err.severity(), ErrorSeverity::Error);
}

#[test]
fn tron_error_severity_from_provider_retryable() {
    let provider_err =
        ProviderError::new(Provider::Anthropic, "model", "overloaded").with_retryable(true);
    let err = TronError::from(provider_err);
    assert_eq!(err.severity(), ErrorSeverity::Transient);
}

#[test]
fn tron_error_severity_from_tool() {
    let tool_err = ToolError::new("bash", "c1", "timeout").with_severity(ErrorSeverity::Fatal);
    let err = TronError::from(tool_err);
    assert_eq!(err.severity(), ErrorSeverity::Fatal);
}

#[test]
fn tron_error_category_from_provider_status() {
    let provider_err =
        ProviderError::new(Provider::OpenAi, "gpt-4", "forbidden").with_status(403);
    let err = TronError::from(provider_err);
    assert_eq!(err.category(), ErrorCategory::Authorization);
}
